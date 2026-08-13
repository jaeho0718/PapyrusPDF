import Foundation
import PapyrusPDF
import PapyrusPDFTestSupport
import Synchronization
import Testing

/// CI 상시 퍼즈 스모크 — 시드 고정 상수로 모든 실행·모든 러너에서 동일 케이스 집합을
/// 실행한다 (플레이키 없음, 설계 §3.3). 케이스별 행 판정은 2단 확정(스크리닝 → 4배 예산
/// 재실행)이라 공유 CI 러너의 시작 버스트 CPU 경합으로 인한 거짓 양성을 거른다(설계 38).
///
/// 재현 절차: 실패 메시지의 `seed=... mut=0x... n=...`을 `FuzzRegressionTests.knownFindings`
/// 배열에 `FuzzCaseID(seed:mutationSeed:mutationCount:)`로 그대로 옮기면 영구 회귀 케이스가
/// 된다 (설계 §3.1).
@Suite("퍼즈 스모크", .timeLimit(.minutes(3)))
struct FuzzSmokeTests {
  // MARK: 구성 1 — 구조 손상 매트릭스 (설계 §3.3-1)

  /// `FuzzSeedFixture` 6종 × 적용 가능한 `PDFFixtureCorruptor.Mode` 전종(클래식 전용
  /// 모드는 클래식 xref 섹션을 가진 시드에만) × surface `.full`을 완주시킨다.
  ///
  /// 기존 M2 테스트와 겹치지만 심화다 — M2는 `open` 결과의 정확성을, 여기는 open 이후
  /// 전 표면 완주(크래시·행 없음)를 본다.
  @Test func structuralCorruptionMatrixCompletesWithoutHangs() async {
    let styleAgnosticModes: [PDFFixtureCorruptor.Mode] = [
      .bogusStartxref, .removeStartxref, .truncateTail(byteCount: 10),
      .junkPrefix(byteCount: 16), .removeEOFMarker
    ]
    let classicOnlyModes: [PDFFixtureCorruptor.Mode] = [
      .brokenEntryOffset(objectNumber: 1, delta: 500), .malformedRowWidth(.nineteen),
      .malformedRowWidth(.twentyOne), .cyclicPrevChain
    ]

    var hangDescriptions: [String] = []
    seedLoop: for seed in FuzzSeedFixture.allCases {
      let baseFixture = seed.build()
      var modes = styleAgnosticModes
      if Self.hasClassicSection(seed) {
        modes += classicOnlyModes
      }
      for mode in modes {
        let corrupted = PDFFixtureCorruptor.apply([mode], to: baseFixture)
        let description = "seed=\(seed.rawValue) corruptor=\(mode)"
        if await Self.hangConfirmed(description: description, data: corrupted.data) {
          hangDescriptions.append(description)
          break seedLoop
        }
      }
    }
    #expect(hangDescriptions.isEmpty, "\(hangDescriptions)")
  }

  /// `mode`가 클래식 xref 섹션 전용인지에 관계없이 안전하게 적용 가능한 시드인가 —
  /// `.xrefStreamText`/`.objectStreamsText`는 클래식 `xref` 섹션이 전혀 없으므로
  /// 클래식 전용 모드를 적용하면 `PDFFixtureCorruptor`가 `precondition`으로 실패한다.
  private static func hasClassicSection(_ seed: FuzzSeedFixture) -> Bool {
    switch seed {
    case .classicMinimal, .classicOutlineMetadata, .hybridIncremental, .mediumMixed:
      return true
    case .xrefStreamText, .objectStreamsText:
      return false
    }
  }

  // MARK: 구성 2 — 적대적 구성 (설계 §3.3-2)

  /// `HostileFixtures` 5종(경계값 ±1 변형 포함) × surface `.full`을 완주시킨다.
  @Test func hostileConfigurationMatrixCompletesWithoutHangs() async {
    let cases: [(description: String, data: Data)] = [
      ("deepNesting(511)", HostileFixtures.deepNesting(depth: 511).data),
      ("deepNesting(513)", HostileFixtures.deepNesting(depth: 513).data),
      ("hugeClaimedLength", HostileFixtures.hugeClaimedLength().data),
      ("referenceCycle(40)", HostileFixtures.referenceCycle(length: 40).data),
      ("lyingPageCount", HostileFixtures.lyingPageCount().data),
      ("selfReferentialObjectStream", HostileFixtures.selfReferentialObjectStream().data)
    ]

    var hangDescriptions: [String] = []
    for testCase in cases {
      // for_where 예외: `hangConfirmed`는 순수 술어가 아니라 최대 10초 걸리는 판정 작업이다 —
      // `where` 절에 두면 필터로 오독된다. 자매 루프(구조 손상 매트릭스)와 형태를 통일한다.
      // swiftlint:disable:next for_where
      if await Self.hangConfirmed(description: testCase.description, data: testCase.data) {
        hangDescriptions.append(testCase.description)
        break
      }
    }
    #expect(hangDescriptions.isEmpty, "\(hangDescriptions)")
  }

  /// `.full` 표면을 2단 판정으로 실행하고, 행으로 확정되면 `true`를 반환한다. 호출부(매트릭스
  /// 루프)는 첫 확정에서 순회를 중단한다 — 좀비 태스크가 후속 측정을 오염시키고(설계 가정 3,
  /// `FuzzExecutor.run`과 동일 규약), 최악 소요가 스위트 `.timeLimit` 안에 남아야 하기 때문.
  private static func hangConfirmed(description: String, data: Data) async -> Bool {
    let outcome = await FuzzExecutor.withConfirmedTimeout(
      FuzzBudget(), surfaceLabel: description
    ) {
      await FuzzExecutor.execute(surface: .full, input: data)
    }
    if case .timedOut = outcome {
      return true
    }
    return false
  }

  // MARK: 구성 3 — 뮤테이션 고정 배치 (설계 §3.3-3)

  /// 시드 6종 × 케이스 96개(`mutationSeed = FNV(seedName, index)`,
  /// `mutationCount = 1 + index % 8`), 시드당 16개(`index % 6 == 0`)는 `.full`로 승격,
  /// 나머지는 `.openOnly`.
  @Test func mutationFixedBatchCompletesWithoutFindings() async {
    var openOnlyCases: [FuzzCaseID] = []
    var fullCases: [FuzzCaseID] = []
    for seed in FuzzSeedFixture.allCases {
      for index in 0..<96 {
        let mutationSeed = Self.fnv1a64(seed.rawValue, index)
        let mutationCount = 1 + index % 8
        let caseID = FuzzCaseID(
          seed: seed, mutationSeed: mutationSeed, mutationCount: mutationCount
        )
        if index % 6 == 0 {
          fullCases.append(caseID)
        } else {
          openOnlyCases.append(caseID)
        }
      }
    }

    let openOnlyFindings = await FuzzExecutor.run(
      cases: openOnlyCases, surface: .openOnly, budget: FuzzBudget()
    )
    #expect(openOnlyFindings.isEmpty, "\(openOnlyFindings)")

    let fullFindings = await FuzzExecutor.run(
      cases: fullCases, surface: .full, budget: FuzzBudget()
    )
    #expect(fullFindings.isEmpty, "\(fullFindings)")
  }

  /// FNV-1a 64비트 — `seedName`과 `index`를 이어붙인 바이트에 적용한 결정론적 해시.
  /// 재현에 필요한 건 `(seedName, index)`뿐이므로 별도 시드 저장이 필요 없다.
  private static func fnv1a64(_ seedName: String, _ index: Int) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in Array(seedName.utf8) + Array(String(index).utf8) {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
  }

  // MARK: 타임아웃 가드 자체 검증 (테스트 포인트 6)

  /// 예산 안에 끝나는 작업은 `.completed`.
  @Test func withTimeoutCompletesWhenOperationFinishesInBudget() async {
    let outcome = await FuzzExecutor.withTimeout(.milliseconds(200), surfaceLabel: "fast") {
      try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(outcome == .completed)
  }

  /// 예산을 넘는 작업은 `.timedOut(surface:)`으로 판정된다 (인위적 지연 훅).
  @Test func withTimeoutReportsTimedOutWhenOperationExceedsBudget() async {
    let outcome = await FuzzExecutor.withTimeout(.milliseconds(20), surfaceLabel: "slow") {
      try? await Task.sleep(for: .seconds(5))
    }
    #expect(outcome == .timedOut(surface: "slow"))
  }

  /// 1차 시도는 스크리닝 예산을 넘기지만(30초 sleep) 2차(확정) 시도는 1ms만에 끝나 구제되는
  /// 경우 — 일시 초과가 거짓 양성으로 판정됨을 확인한다. 판정이 뒤집히려면 "10ms 타이머가
  /// 30초간 못 울림"이라는 러너 고장 시나리오가 필요하다(설계 §6).
  @Test func confirmedTimeoutRescuesTransientOverrun() async {
    let counter = InvocationCounter()
    let budget = FuzzBudget(perCase: .milliseconds(10), confirmation: .seconds(30), width: 1)
    let outcome = await FuzzExecutor.withConfirmedTimeout(budget, surfaceLabel: "rescue") {
      let invocation = counter.next()
      if invocation == 1 {
        try? await Task.sleep(for: .seconds(30))
      } else {
        try? await Task.sleep(for: .milliseconds(1))
      }
    }
    #expect(outcome == .completed)
    #expect(counter.count == 2)
  }

  /// 1·2차 시도 모두 예산을 넘기면(매번 30초 sleep) 행으로 확정된다 — 확정 예산이 50ms라
  /// 30초 sleep은 취소로 즉시 끊겨 실제 소요는 ~60ms.
  @Test func confirmedTimeoutConfirmsPersistentOverrun() async {
    let counter = InvocationCounter()
    let budget = FuzzBudget(perCase: .milliseconds(10), confirmation: .milliseconds(50))
    let outcome = await FuzzExecutor.withConfirmedTimeout(budget, surfaceLabel: "persistent") {
      _ = counter.next()
      try? await Task.sleep(for: .seconds(30))
    }
    #expect(outcome == .timedOut(surface: "persistent"))
    #expect(counter.count == 2)
  }

  /// 여러 케이스가 전부 예산을 넘겨도, 첫 확정 결함 발견 즉시 런이 중단된다 — 나머지 케이스는
  /// 시작조차 대기하지 않는다(설계 가정 3). 조기 중단의 직접 증거는 `timedOutCount == 1`
  /// (중단 없이는 20)이고, 벽시계 상한은 스크리닝+확정을 합쳐도 30초짜리 케이스 지연을 실제로
  /// 기다리지 않았음을 확인하는 보조 증거다 — 부하 걸린 CI 러너의 스케줄링 지연을 흡수하도록
  /// 여유 있게 잡는다.
  @Test func artificialCasesStopImmediatelyAfterFirstConfirmedTimeout() async {
    let budget = FuzzBudget(perCase: .milliseconds(20), width: 4)
    let operations: [FuzzExecutor.FuzzOperation] = Array(
      repeating: { try? await Task.sleep(for: .seconds(30)) }, count: 20
    )
    let clock = ContinuousClock()
    let start = clock.now
    let timedOutCount = await FuzzExecutor.runArtificialCasesForTesting(operations, budget: budget)
    let elapsed = clock.now - start
    #expect(timedOutCount == 1)
    #expect(elapsed < .seconds(4), "즉시 중단되지 않고 \(elapsed) 소요됨")
  }

  /// 느린 CI 시뮬레이션 — 8개 중 첫 케이스만 일시 초과(1차 30초 → 2차 1ms)하고 나머지는
  /// 정상(1ms)이면, 의심이 확정 단계에서 구제되어 런이 완주한다. 다른 케이스가 부하로 의심돼도
  /// 확정에서 구제되므로 자기 치유적임을 보인다.
  @Test func runContinuesWhenSuspectIsRescued() async {
    let counter = InvocationCounter()
    let budget = FuzzBudget(perCase: .milliseconds(10), confirmation: .seconds(30), width: 4)
    var operations: [FuzzExecutor.FuzzOperation] = [{
      let invocation = counter.next()
      if invocation == 1 {
        try? await Task.sleep(for: .seconds(30))
      } else {
        try? await Task.sleep(for: .milliseconds(1))
      }
    }]
    operations += Array(
      repeating: { try? await Task.sleep(for: .milliseconds(1)) }, count: 7
    )
    let timedOutCount = await FuzzExecutor.runArtificialCasesForTesting(operations, budget: budget)
    #expect(timedOutCount == 0)
  }

  /// 스크리닝 안에서 끝나는 정상 경로는 확정 재실행을 전혀 유발하지 않는다(비용 0) — 정상
  /// 케이스가 다수인 실제 퍼즈 런의 지배적 경로.
  @Test func confirmedTimeoutSkipsConfirmationWhenScreeningCompletes() async {
    let counter = InvocationCounter()
    let budget = FuzzBudget(perCase: .seconds(30))
    let outcome = await FuzzExecutor.withConfirmedTimeout(budget, surfaceLabel: "no-retry") {
      _ = counter.next()
      try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(outcome == .completed)
    #expect(counter.count == 1)
  }

  /// 상위 태스크가 이미 취소된 상태에서 스크리닝이 `.timedOut`을 반환해도 확정 재실행은
  /// 생략된다 — 취소된 두 자식(작업/타이머)의 완주 경쟁은 비결정이므로 `outcome`은 단언하지
  /// 않고, "재호출 없음"만이 계약이다.
  @Test func confirmedTimeoutSkipsConfirmationWhenRunIsCancelled() async {
    let counter = InvocationCounter()
    let budget = FuzzBudget(perCase: .milliseconds(10), confirmation: .seconds(30))
    let task = Task {
      while !Task.isCancelled {
        await Task.yield()
      }
      return await FuzzExecutor.withConfirmedTimeout(budget, surfaceLabel: "cancelled") {
        _ = counter.next()
        try? await Task.sleep(for: .seconds(30))
      }
    }
    task.cancel()
    _ = await task.value
    #expect(counter.count == 1)
  }
}

/// 판정 단계별 재호출 횟수를 세는 테스트 보조자.
private final class InvocationCounter: Sendable {
  private let storage = Mutex(0)

  /// 호출 차수를 1 올리고 그 값을 반환한다.
  func next() -> Int {
    self.storage.withLock { count in
      count += 1
      return count
    }
  }

  /// 현재까지의 호출 수.
  var count: Int {
    self.storage.withLock { $0 }
  }
}
