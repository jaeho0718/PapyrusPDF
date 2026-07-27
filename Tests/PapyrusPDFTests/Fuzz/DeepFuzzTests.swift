import Foundation
import PapyrusPDF
import PapyrusPDFTestSupport
import Testing

/// 로컬/야간 심층 퍼징 — `PAPYRUSPDF_FUZZ=1`이 아니면 스위트 전체가 스킵된다(CI 상시 스위트가
/// 아니다). release 구성 권장:
/// `PAPYRUSPDF_FUZZ=1 PAPYRUSPDF_FUZZ_SEED=0x... swift test -c release --filter DeepFuzzTests`
///
/// 재현 절차(설계 §3.1, §3.5): 마스터 시드는 매 테스트 시작 시 stdout에 출력된다
/// (`PAPYRUSPDF_FUZZ_SEED`로 명시하지 않으면 현재 시각 파생 — 재현하려면 출력된 값을 그대로
/// `PAPYRUSPDF_FUZZ_SEED`에 다시 넣는다). 마스터 시드에서 `SplitMix64`로 파생한 케이스가 실패하면
/// 메시지의 `seed=... mut=0x... n=...`을 `FuzzRegressionTests.knownFindings`에 그대로 옮기면
/// 영구 회귀 케이스가 된다. `PAPYRUSPDF_FUZZ_CORPUS_DIR` 시드(외부 실PDF)는 `FuzzCaseID`로 표현할
/// 수 없으므로 `file=<이름> mut=0x... n=...` 형식으로 별도 보고하며, 회귀 등재는 구조 분석 후
/// corruptor/hostile 승격으로 한다.
///
/// - Note: 게이트 설정(`DeepFuzzConfiguration`)은 파일 최상위 타입이다 — `@Suite` 어트리뷰트가
///   `DeepFuzzTests` 자신의 중첩 타입을 참조하면 매크로 확장 중 순환 참조 오류가 난다.
@Suite(
  "딥 퍼즈", .enabled(if: DeepFuzzConfiguration.isGateEnabled), .serialized,
  .timeLimit(.minutes(30))
)
struct DeepFuzzTests {
  /// Swift Testing이 테스트 함수마다 새 인스턴스를 만들므로, 매 테스트 시작 시 마스터 시드가
  /// stdout에 출력된다(설계 §3.5 — "시작 시 반드시 stdout에 출력").
  init() {
    let seed = DeepFuzzConfiguration.current.rootSeed
    print(
      "[DeepFuzzTests] root seed = 0x\(Self.hex(seed))"
        + " (재현: PAPYRUSPDF_FUZZ_SEED=0x\(Self.hex(seed)))"
    )
  }

  /// `.openOnly` 표면 — 기본 100,000 케이스 (`PAPYRUSPDF_FUZZ_OPEN_CASES`로 조정).
  @Test func deepOpenOnlyFuzzCompletesWithoutCrashesOrHangs() async {
    let config = DeepFuzzConfiguration.current
    let cases = Self.deriveCases(
      rootSeed: config.rootSeed, salt: Self.openSalt, count: config.openCases
    )
    let findings = await FuzzExecutor.run(
      cases: cases, surface: .openOnly, budget: FuzzBudget(perCase: config.timeout)
    )
    #expect(findings.isEmpty, "\(findings)")
  }

  /// `.full` 표면 — 기본 20,000 케이스 (`PAPYRUSPDF_FUZZ_FULL_CASES`로 조정).
  @Test func deepFullSurfaceFuzzCompletesWithoutCrashesOrHangs() async {
    let config = DeepFuzzConfiguration.current
    let cases = Self.deriveCases(
      rootSeed: config.rootSeed, salt: Self.fullSalt, count: config.fullCases
    )
    let findings = await FuzzExecutor.run(
      cases: cases, surface: .full, budget: FuzzBudget(perCase: config.timeout)
    )
    #expect(findings.isEmpty, "\(findings)")
  }

  /// `PAPYRUSPDF_FUZZ_CORPUS_DIR`이 지정된 경우에만 실PDF를 추가 시드로 소비한다(설계 가정 4,
  /// §3.5). 미지정 시 이 테스트는 아무 케이스도 실행하지 않고 자명하게 통과한다 — 로컬 심층
  /// 퍼징의 선택적 확장이지 필수 항목이 아니다.
  @Test func deepCorpusDirFuzzCompletesWithoutCrashesOrHangs() async {
    let config = DeepFuzzConfiguration.current
    guard let corpusDir = config.corpusDir else {
      return
    }
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: corpusDir, includingPropertiesForKeys: nil
      )
    else {
      Issue.record(Comment(rawValue: "PAPYRUSPDF_FUZZ_CORPUS_DIR을 읽을 수 없음: \(corpusDir.path)"))
      return
    }

    var findingDescriptions: [String] = []
    var rng = SplitMix64(seed: config.rootSeed ^ Self.corpusSalt)
    fileLoop: for file in files where file.pathExtension.lowercased() == "pdf" {
      guard let raw = try? Data(contentsOf: file) else {
        continue
      }
      for variant in 0..<Self.corpusVariantsPerFile {
        let mutationSeed = rng.next()
        let mutationCount = variant == 0 ? 0 : 1 + Int(rng.next() % 16)
        let input = mutationCount == 0
          ? raw
          : FuzzMutator.mutate(raw, seed: mutationSeed, count: mutationCount)
        let description =
          "file=\(file.lastPathComponent) mut=0x\(Self.hex(mutationSeed)) n=\(mutationCount)"
        let outcome = await FuzzExecutor.withTimeout(config.timeout, surfaceLabel: description) {
          await FuzzExecutor.execute(surface: .openOnly, input: input)
        }
        if case .timedOut = outcome {
          findingDescriptions.append(description)
          break fileLoop // 첫 결함에서 즉시 중단 (설계 가정 3과 일관).
        }
      }
    }
    #expect(findingDescriptions.isEmpty, "\(findingDescriptions)")
  }
}

// MARK: - 케이스 파생 (설계 §3.5)

extension DeepFuzzTests {
  /// `.openOnly` 케이스 파생용 솔트 — 마스터 시드에서 세 스트림(open/full/corpus)을
  /// 서로 겹치지 않게 갈라낸다.
  private static let openSalt: UInt64 = 0x0BEC_0000_0000_0001
  /// `.full` 케이스 파생용 솔트.
  private static let fullSalt: UInt64 = 0x0BEC_0000_0000_0002
  /// 코퍼스 디렉터리 뮤테이션 파생용 솔트.
  private static let corpusSalt: UInt64 = 0x0BEC_0000_0000_0003
  /// 코퍼스 파일 1개당 시도할 변형 수 (index 0은 원본 그대로).
  private static let corpusVariantsPerFile = 16

  /// `rootSeed`와 `salt`로 만든 `SplitMix64` 체인에서 (시드 픽스처, mutationSeed,
  /// mutationCount 1..16)을 연쇄 파생한다(설계 §3.5).
  private static func deriveCases(rootSeed: UInt64, salt: UInt64, count: Int) -> [FuzzCaseID] {
    var rng = SplitMix64(seed: rootSeed ^ salt)
    let seedFixtures = FuzzSeedFixture.allCases
    var cases: [FuzzCaseID] = []
    cases.reserveCapacity(max(0, count))
    for _ in 0..<max(0, count) {
      let seedFixture = seedFixtures[Int(rng.next() % UInt64(seedFixtures.count))]
      let mutationSeed = rng.next()
      let mutationCount = 1 + Int(rng.next() % 16)
      cases.append(
        FuzzCaseID(seed: seedFixture, mutationSeed: mutationSeed, mutationCount: mutationCount)
      )
    }
    return cases
  }

  /// `value`를 16진 대문자 문자열로 포맷한다(zero-pad 없음 — 진단 출력용, 재현 문자열 자체는
  /// `FuzzCaseID.description`이 zero-pad 16자리로 별도 보장한다).
  private static func hex(_ value: UInt64) -> String {
    String(value, radix: 16, uppercase: true)
  }
}

// MARK: - env 설정 파싱 (설계 §3.5)

/// `DeepFuzzTests`가 env에서 파싱하는 심층 퍼즈 실행 설정. `PAPYRUSPDF_FUZZ`만 필수 게이트이고
/// 나머지는 전부 관용적으로 다룬다(파싱 실패 시 기본값 폴백).
///
/// - Note: 파일 최상위 타입이다 — `DeepFuzzTests`에 중첩하면 `@Suite` 어트리뷰트가 그 중첩
///   타입을 참조할 때 매크로 확장 중 순환 참조 오류(`circular reference resolving attached
///   macro 'Suite'`)가 난다.
struct DeepFuzzConfiguration {
  /// 마스터 시드 — `PAPYRUSPDF_FUZZ_SEED` 미지정 시 현재 시각 파생.
  let rootSeed: UInt64
  /// `.openOnly` 케이스 수 (기본 100,000).
  let openCases: Int
  /// `.full` 케이스 수 (기본 20,000).
  let fullCases: Int
  /// 케이스 1개 타임아웃 (기본 2,000ms).
  let timeout: Duration
  /// 실PDF 코퍼스 디렉터리 (선택 — 설계 가정 4).
  let corpusDir: URL?

  /// `PAPYRUSPDF_FUZZ=1`일 때만 딥 퍼즈 스위트가 실행된다.
  static var isGateEnabled: Bool {
    ProcessInfo.processInfo.environment["PAPYRUSPDF_FUZZ"] == "1"
  }

  /// 프로세스당 한 번만 계산한다(`static let`의 지연 초기화가 스레드 안전하게 1회 보장) —
  /// 미지정 시드가 테스트 함수마다 달라지면 open/full/corpus 세 스위트가 서로 다른 세션으로
  /// 갈라져 "재현 = 같은 마스터 시드 재사용"이 깨진다.
  static let current: DeepFuzzConfiguration = Self.parseEnvironment()

  private static func parseEnvironment() -> DeepFuzzConfiguration {
    let env = ProcessInfo.processInfo.environment
    let rootSeed = env["PAPYRUSPDF_FUZZ_SEED"].flatMap(Self.parseHexSeed) ?? Self.timeBasedSeed()
    let openCases = env["PAPYRUSPDF_FUZZ_OPEN_CASES"].flatMap(Int.init) ?? 100_000
    let fullCases = env["PAPYRUSPDF_FUZZ_FULL_CASES"].flatMap(Int.init) ?? 20_000
    let timeoutMS = env["PAPYRUSPDF_FUZZ_TIMEOUT_MS"].flatMap(Int.init) ?? 2_000
    let corpusDir = env["PAPYRUSPDF_FUZZ_CORPUS_DIR"].map { URL(fileURLWithPath: $0) }
    return DeepFuzzConfiguration(
      rootSeed: rootSeed, openCases: max(0, openCases), fullCases: max(0, fullCases),
      timeout: .milliseconds(max(1, timeoutMS)), corpusDir: corpusDir
    )
  }

  /// `0x`/`0X` 접두 유무 관계없이 16진 문자열을 파싱한다. 실패 시 `nil`(호출부가 시각 파생
  /// 기본값으로 폴백).
  private static func parseHexSeed(_ raw: String) -> UInt64? {
    let trimmed = raw.hasPrefix("0x") || raw.hasPrefix("0X") ? String(raw.dropFirst(2)) : raw
    return UInt64(trimmed, radix: 16)
  }

  /// 현재 시각(마이크로초)을 `SplitMix64`로 한 번 혼합한 값을 기본 마스터 시드로 쓴다
  /// (설계 §3.5: "기본: 현재 시각 파생").
  private static func timeBasedSeed() -> UInt64 {
    let micros = UInt64(bitPattern: Int64(Date().timeIntervalSince1970 * 1_000_000))
    var mixer = SplitMix64(seed: micros)
    return mixer.next()
  }
}
