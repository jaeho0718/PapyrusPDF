import Foundation
import PapyrusPDF
import PapyrusPDFTestSupport
import Synchronization
import Testing

/// 케이스 하나에 대해 실행할 표면 묶음.
enum FuzzSurface: Sendable {
  /// `open(data:)`만 — 처리량 최대 티어.
  case openOnly
  /// open + pageCount + metadata + outline + page(at:) 전수(캡 64)
  /// + text(forPage:) 앞 8페이지 + search("e") 1회.
  case full
}

/// 케이스 하나의 결과.
enum FuzzOutcome: Sendable, Equatable {
  /// 정상 완료 (성공이든 `PapyrusPDFError`든 — 둘 다 "합격"이다).
  case completed
  /// 케이스 예산 초과 — 행 결함. associated value는 초과한 표면 설명.
  case timedOut(surface: String)
}

/// 퍼즈 런 설정.
struct FuzzBudget: Sendable {
  /// 케이스 1개의 스크리닝(1차) 벽시계 예산 (기본 2초 — 정상 케이스는 µs~ms 단위이므로
  /// 3자릿수 여유).
  var perCase: Duration

  /// 확정 재실행(2차) 예산 (기본 `perCase * 4`). 스크리닝 초과가 CPU 경합 탓인지 진짜
  /// 행인지 가르는 예산 — 진짜 행은 어떤 예산에서도 재초과하므로 크게 잡아도 탐지력이
  /// 줄지 않고, 공유 러너의 시작 버스트(실측 5초 미만)보다 충분히 길어야 거짓 양성을 거른다.
  var confirmation: Duration

  /// 병렬 폭 (기본 `min(activeProcessorCount, 8)`).
  var width: Int

  /// 예산을 생성한다.
  /// - Parameters:
  ///   - perCase: 케이스 1개의 스크리닝 벽시계 예산 (기본 2초).
  ///   - confirmation: 확정 재실행 예산 (기본 `nil` → `perCase * 4`).
  ///   - width: 병렬 폭 (기본 `min(activeProcessorCount, 8)`).
  init(
    perCase: Duration = .seconds(2),
    confirmation: Duration? = nil,
    width: Int = min(ProcessInfo.processInfo.activeProcessorCount, 8)
  ) {
    self.perCase = perCase
    self.confirmation = confirmation ?? perCase * 4
    self.width = width
  }
}

/// 결함 기록 — 실패 메시지와 회귀 등재에 필요한 전부.
struct FuzzFinding: Sendable, CustomStringConvertible {
  /// 결함을 일으킨 케이스 식별자.
  let caseID: FuzzCaseID
  /// 결함 종류.
  let outcome: FuzzOutcome

  /// `"HANG seed=... mut=0x... n=4 surface=full"` 형태의 진단 메시지.
  var description: String {
    switch self.outcome {
    case .completed:
      return "OK \(self.caseID)"
    case let .timedOut(surface):
      return "HANG \(self.caseID) surface=\(surface)"
    }
  }
}

/// 퍼즈 실행기 — 케이스 스트림을 병렬 소비하고 첫 결함에서 멈춘다.
enum FuzzExecutor {
  /// 결함 발견 시 해당 케이스 ID들을 반환한다 (빈 배열 = 전체 통과).
  ///
  /// 행 결함 발견 시 런을 즉시 중단한다 — 좀비 태스크가 CPU를 점유한 채로
  /// 후속 케이스의 시간 측정을 오염시키기 때문 (설계 가정 3).
  /// - Parameters:
  ///   - cases: 실행할 케이스 스트림.
  ///   - surface: 케이스마다 실행할 표면 묶음.
  ///   - budget: 케이스별 예산 + 병렬 폭.
  /// - Returns: 결함 목록 (행 결함 1건 발견 시 그 즉시 중단하고 그 1건만 반환한다).
  static func run(
    cases: some Sequence<FuzzCaseID> & Sendable, surface: FuzzSurface, budget: FuzzBudget
  ) async -> [FuzzFinding] {
    var iterator = cases.makeIterator()
    var findings: [FuzzFinding] = []
    var nextSlot = 0
    let width = max(1, budget.width)

    await withTaskGroup(of: FuzzFinding?.self) { group in
      var inFlight = 0

      func addNext() {
        guard let caseID = iterator.next() else {
          return
        }
        let slot = nextSlot % width
        nextSlot += 1
        inFlight += 1
        group.addTask {
          Self.recordSlotStart(slot: slot, caseID: caseID)
          let outcome = await Self.runOne(
            caseID: caseID, surface: surface, budget: budget
          )
          Self.recordSlotEnd(slot: slot)
          guard case .timedOut = outcome else {
            return nil
          }
          return FuzzFinding(caseID: caseID, outcome: outcome)
        }
      }

      for _ in 0..<width {
        addNext()
      }
      while inFlight > 0, let result = await group.next() {
        inFlight -= 1
        if let finding = result {
          findings.append(finding)
          group.cancelAll()
          break
        }
        addNext()
      }
    }
    return findings
  }

  /// 케이스 하나를 실행한다: 입력 생성(순수 CPU) 후 2단 판정으로 표면을 완주시킨다.
  private static func runOne(
    caseID: FuzzCaseID, surface: FuzzSurface, budget: FuzzBudget
  ) async -> FuzzOutcome {
    let input = caseID.makeInput()
    return await Self.withConfirmedTimeout(budget, surfaceLabel: Self.label(for: surface)) {
      await Self.execute(surface: surface, input: input)
    }
  }

  private static func label(for surface: FuzzSurface) -> String {
    switch surface {
    case .openOnly:
      return "openOnly"
    case .full:
      return "full"
    }
  }
}

// MARK: - 타임아웃 가드 (설계 §4.2)

extension FuzzExecutor {
  /// `operation`을 `budget` 안에서 실행한다. 초과하면 `.timedOut`을 채택하고 두 자식
  /// 태스크를 모두 취소한다 — 단, 협조 지점 없는 진짜 무한 루프는 취소되지 않는다
  /// (설계 §4.2의 정직한 한계 — 스위트 `.timeLimit`이 최종 백스톱).
  /// - Parameters:
  ///   - budget: 케이스 1개의 벽시계 예산.
  ///   - surfaceLabel: 초과 시 결함 설명에 남길 표면 이름.
  ///   - operation: 예산 안에서 완주해야 할 작업.
  /// - Returns: 먼저 완료된 쪽의 결과.
  static func withTimeout(
    _ budget: Duration, surfaceLabel: String,
    operation: @escaping @Sendable () async -> Void
  ) async -> FuzzOutcome {
    await withTaskGroup(of: FuzzOutcome.self) { group in
      group.addTask {
        await operation()
        return .completed
      }
      group.addTask {
        try? await Task.sleep(for: budget)
        return .timedOut(surface: surfaceLabel)
      }
      let first = await group.next() ?? .completed
      group.cancelAll()
      return first
    }
  }

  /// 2단 행 판정 (스크리닝 → 확정): `budget.perCase` 안에 끝나지 않은 작업을 즉시 결함으로
  /// 단정하지 않고, `budget.confirmation` 예산으로 `operation`을 1회 재실행해 재차 초과할
  /// 때만 `.timedOut`으로 확정한다. 진짜 행은 어떤 예산에서도 완주하지 못하므로 항상
  /// 재초과한다 — 탐지력 손실 없이, 공유 CI 러너 시작 버스트의 CPU 기아로 인한 거짓 양성만
  /// 걸러진다 (2026-08-13 PR #22 run 31670003395 실측: 동일 커밋 attempt 2 통과).
  ///
  /// `operation`은 재호출 가능해야 한다 — 표면 실행은 호출마다 독립 문서를 새로 열므로 이
  /// 요건을 자명하게 만족한다. 상위 태스크가 이미 취소됐으면 확정을 생략하고 스크리닝 결과를
  /// 그대로 반환한다(취소된 런의 결과는 어차피 수집되지 않는다 — `run`의 중단 규약).
  /// - Parameters:
  ///   - budget: 스크리닝(`perCase`)·확정(`confirmation`) 예산. `width`는 사용하지 않는다.
  ///   - surfaceLabel: 초과 시 결함 설명에 남길 표면 이름.
  ///   - operation: 예산 안에서 완주해야 할 작업 (재호출 가능해야 한다).
  /// - Returns: 확정된 판정 — 스크리닝 통과 또는 확정 재실행 완주는 `.completed`,
  ///   두 번 모두 초과하면 `.timedOut`.
  static func withConfirmedTimeout(
    _ budget: FuzzBudget, surfaceLabel: String,
    operation: @escaping @Sendable () async -> Void
  ) async -> FuzzOutcome {
    let screening = await Self.withTimeout(
      budget.perCase, surfaceLabel: surfaceLabel, operation: operation
    )
    guard case .timedOut = screening, !Task.isCancelled else {
      return screening
    }
    let confirmed = await Self.withTimeout(
      budget.confirmation, surfaceLabel: surfaceLabel, operation: operation
    )
    if confirmed == .completed {
      print(
        "[fuzz] 일시 초과 구제: \(surfaceLabel)"
          + " (screening=\(budget.perCase), confirmation=\(budget.confirmation))"
      )
    }
    return confirmed
  }

  /// 케이스 표면 실행 클로저 — 스크리닝과 확정 재실행에서 각각 재호출될 수 있다.
  typealias FuzzOperation = @Sendable () async -> Void

  /// 테스트 전용 훅 (테스트 포인트 6) — 실제 문서 파싱 대신 인위적 작업들로 2단 판정·즉시
  /// 중단 경로를 검증한다. `run(cases:surface:budget:)`과 동일하게 첫 확정 결함에서 즉시
  /// 멈춘다.
  /// - Parameters:
  ///   - operations: 케이스별 인위적 작업 (도착 순서대로 소비, 판정 단계마다 재호출될 수 있다).
  ///   - budget: 케이스별 예산 + 병렬 폭.
  /// - Returns: 행으로 확정된 케이스 수 (0 또는 1 — 첫 확정 결함에서 멈추므로).
  static func runArtificialCasesForTesting(
    _ operations: [FuzzOperation], budget: FuzzBudget
  ) async -> Int {
    var iterator = operations.makeIterator()
    var timedOutCount = 0

    await withTaskGroup(of: FuzzOutcome.self) { group in
      var inFlight = 0
      func addNext() {
        guard let operation = iterator.next() else {
          return
        }
        inFlight += 1
        group.addTask {
          await Self.withConfirmedTimeout(
            budget, surfaceLabel: "test-operation", operation: operation
          )
        }
      }

      for _ in 0..<max(1, budget.width) {
        addNext()
      }
      while inFlight > 0, let outcome = await group.next() {
        inFlight -= 1
        if case .timedOut = outcome {
          timedOutCount += 1
          group.cancelAll()
          break
        }
        addNext()
      }
    }
    return timedOutCount
  }
}

// MARK: - 크래시 진단 슬롯 맵 (설계 §4.4)

extension FuzzExecutor {
  /// 현재 실행 중인 케이스 ID들 — 슬롯(병렬 워커 인덱스, `0..<width`)별로 최신 값만 보관한다.
  /// 프로세스가 죽으면 이 맵 자체는 함께 사라지므로, 실질 진단 수단은 `PAPYRUSPDF_FUZZ_VERBOSE=1`
  /// 일 때 케이스 시작마다 남기는 stdout 출력이다 (크래시 재현 절차: 같은 시드로
  /// `PAPYRUSPDF_FUZZ_VERBOSE=1` 재실행 → 마지막 출력 ID들이 용의자).
  private static let slotMap = Mutex<[Int: FuzzCaseID]>([:])

  /// 케이스 시작을 슬롯 맵에 기록하고, verbose 모드면 stdout에도 출력한다.
  private static func recordSlotStart(slot: Int, caseID: FuzzCaseID) {
    Self.slotMap.withLock { $0[slot] = caseID }
    guard ProcessInfo.processInfo.environment["PAPYRUSPDF_FUZZ_VERBOSE"] == "1" else {
      return
    }
    print("[fuzz] slot=\(slot) start \(caseID)")
  }

  /// 케이스 종료를 슬롯 맵에서 제거한다.
  private static func recordSlotEnd(slot: Int) {
    Self.slotMap.withLock { slots in
      _ = slots.removeValue(forKey: slot)
    }
  }
}

// MARK: - 표면 실행 (설계 §3.7)

extension FuzzExecutor {
  /// `try?`가 정당한 이유: 퍼즈의 판정은 "throw 여부"가 아니라 "완주 여부"다. typed
  /// throws가 `PapyrusPDFError` 외 이탈을 컴파일 타임에 봉쇄하므로 에러 값 검사는 불필요하다
  /// (§4.5 예외 — `page(at:)`의 계약 위반만 별도 단언).
  ///
  /// `internal`(비공개 API 아님)인 이유: `FuzzCaseID`로 표현되지 않는 케이스(구조 손상
  /// 매트릭스·hostile 구성)도 `FuzzSmokeTests`가 `withTimeout(_:surfaceLabel:operation:)`과
  /// 함께 이 경로를 직접 재사용한다 — 문서 구동 로직의 유일한 정본.
  static func execute(surface: FuzzSurface, input: Data) async {
    switch surface {
    case .openOnly:
      _ = try? await PapyrusPDFDocument.open(data: input)
    case .full:
      await Self.executeFull(input: input)
    }
  }

  private static func executeFull(input: Data) async {
    guard let document = try? await PapyrusPDFDocument.open(data: input) else {
      return
    }
    let pageCount = (try? await document.pageCount) ?? 0
    _ = try? await document.metadata
    _ = try? await document.outline

    for index in 0..<min(pageCount, 64) {
      await Self.assertPageAtHonorsContract(document: document, index: index)
    }
    for index in 0..<min(pageCount, 8) {
      _ = try? await document.text(forPage: index)
    }
    do {
      for try await _ in document.search("e", options: SearchOptions()) {}
    } catch {
      // 검색 스트림 에러는 전부 합격 — 실제 타입은 항상 `PapyrusPDFError`다(§4.5).
    }
  }

  /// `page(at:)` 계약 단언 (§4.5): `index`가 `0..<pageCount` 안이므로 `pageOutOfRange`가
  /// 나오면 계약 위반이다 — 퍼즈가 공짜로 주는 검증이라 여기서 바로 단언한다. 그 밖의
  /// `PapyrusPDFError`는 전부 합격.
  private static func assertPageAtHonorsContract(document: PapyrusPDFDocument, index: Int) async {
    do {
      _ = try await document.page(at: index)
    } catch PapyrusPDFError.pageOutOfRange(let outOfRangeIndex, let pageCount) {
      let message = "page(at:) 계약 위반: index \(outOfRangeIndex)는 0..<\(pageCount) 안인데 "
        + "pageOutOfRange를 던짐"
      Issue.record(Comment(rawValue: message))
    } catch {
      // 그 외 PapyrusPDFError는 전부 합격 (§4.5).
    }
  }
}
