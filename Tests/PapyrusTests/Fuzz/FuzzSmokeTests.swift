import Foundation
import Papyrus
import PapyrusTestSupport
import Testing

/// CI 상시 퍼즈 스모크 — 시드 고정 상수로 모든 실행·모든 러너에서 동일 케이스 집합을
/// 실행한다 (플레이키 없음, 설계 §3.3).
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
    for seed in FuzzSeedFixture.allCases {
      let baseFixture = seed.build()
      var modes = styleAgnosticModes
      if Self.hasClassicSection(seed) {
        modes += classicOnlyModes
      }
      for mode in modes {
        let corrupted = PDFFixtureCorruptor.apply([mode], to: baseFixture)
        let description = "seed=\(seed.rawValue) corruptor=\(mode)"
        await Self.recordIfHangs(
          description: description, data: corrupted.data, into: &hangDescriptions
        )
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
      await Self.recordIfHangs(
        description: testCase.description, data: testCase.data, into: &hangDescriptions
      )
    }
    #expect(hangDescriptions.isEmpty, "\(hangDescriptions)")
  }

  /// `.full` 표면을 예산 안에서 실행하고, 초과하면 설명을 `hangDescriptions`에 추가한다.
  private static func recordIfHangs(
    description: String, data: Data, into hangDescriptions: inout [String]
  ) async {
    let outcome = await FuzzExecutor.withTimeout(FuzzBudget().perCase, surfaceLabel: description) {
      await FuzzExecutor.execute(surface: .full, input: data)
    }
    if case .timedOut = outcome {
      hangDescriptions.append(description)
    }
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

  /// 여러 케이스가 전부 예산을 넘겨도, 첫 결함 발견 즉시 런이 중단된다 — 나머지 케이스는
  /// 시작조차 대기하지 않는다(설계 가정 3). 조기 중단의 직접 증거는 `timedOutCount == 1`
  /// (중단 없이는 20)이고, 벽시계 상한은 5초짜리 케이스 지연을 실제로 기다리지 않았음을
  /// 확인하는 보조 증거다 — 부하 걸린 CI 러너의 스케줄링 지연을 흡수하도록 단일 케이스
  /// 지연(5초) 미만에서 여유 있게 잡는다.
  @Test func artificialDelaysStopImmediatelyAfterFirstTimeout() async {
    let budget = FuzzBudget(perCase: .milliseconds(20), width: 4)
    let delays = Array(repeating: Duration.seconds(5), count: 20)
    let clock = ContinuousClock()
    let start = clock.now
    let timedOutCount = await FuzzExecutor.runArtificialDelaysForTesting(delays, budget: budget)
    let elapsed = clock.now - start
    #expect(timedOutCount == 1)
    #expect(elapsed < .seconds(4), "즉시 중단되지 않고 \(elapsed) 소요됨")
  }
}
