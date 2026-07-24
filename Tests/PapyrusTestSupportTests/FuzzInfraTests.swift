import Foundation
import PapyrusTestSupport
import Testing

/// 퍼즈 인프라 자체(PRNG·케이스 ID·뮤테이터·시드 카탈로그·hostile 픽스처)의 결정성·불변식을
/// 검증한다 (M8 설계 §2.1-§2.4, 테스트 포인트 1-5). `PapyrusTestSupport`는 `PapyrusCore`에
/// 의존하지 않으므로 이 파일도 원시 바이트 검사만 한다 — 실제 열기 검증은
/// `Tests/PapyrusTests/Fuzz/`가 맡는다.
struct FuzzInfraTests {
  // MARK: 1 — SplitMix64 레퍼런스 수열

  /// 시드 0의 첫 3개 출력이 고정된 레퍼런스 값과 일치한다 (표준 SplitMix64 알고리즘 —
  /// 값 자체는 이 구현을 1회 실행해 얻은 뒤 회귀 고정한 것).
  @Test func splitMix64ProducesKnownSequenceForKnownSeed() {
    var generator = SplitMix64(seed: 0)
    #expect(generator.next() == 16_294_208_416_658_607_535)
    #expect(generator.next() == 7_960_286_522_194_355_700)
    #expect(generator.next() == 487_617_019_471_545_679)
  }

  /// 시드가 다르면 첫 출력도 달라진다 (같은 시드가 아니고서야 수열이 겹치지 않음을
  /// 최소한으로 확인).
  @Test func splitMix64DiffersAcrossSeeds() {
    var first = SplitMix64(seed: 1)
    var second = SplitMix64(seed: 2)
    #expect(first.next() != second.next())
  }

  // MARK: 2 — FuzzCaseID 결정성

  /// 같은 케이스 ID를 2회 `makeInput()`하면 완전히 같은 바이트가 나온다.
  @Test func caseIDMakeInputIsDeterministic() {
    let id = FuzzCaseID(seed: .xrefStreamText, mutationSeed: 0xDEAD_BEEF, mutationCount: 6)
    #expect(id.makeInput() == id.makeInput())
  }

  /// mutationSeed만 다른 두 케이스 ID는 (통계적으로 거의 항상) 다른 바이트를 낸다.
  @Test func caseIDDiffersAcrossMutationSeeds() {
    let first = FuzzCaseID(seed: .xrefStreamText, mutationSeed: 1, mutationCount: 6)
    let second = FuzzCaseID(seed: .xrefStreamText, mutationSeed: 2, mutationCount: 6)
    #expect(first.makeInput() != second.makeInput())
  }

  /// `mutationCount == 0`이면 시드 원본과 바이트가 완전히 동일하다.
  @Test func caseIDWithZeroMutationCountReturnsSeedVerbatim() {
    let id = FuzzCaseID(seed: .classicMinimal, mutationSeed: 999, mutationCount: 0)
    #expect(id.makeInput() == FuzzSeedFixture.classicMinimal.build().data)
  }

  /// 재현 문자열이 설계 포맷(`seed=... mut=0x... n=...`)을 따른다.
  @Test func caseIDDescriptionFollowsReproductionFormat() {
    let id = FuzzCaseID(
      seed: .classicMinimal, mutationSeed: 0x1A2B_3C4D_5E6F_7788, mutationCount: 4
    )
    #expect(id.description == "seed=classicMinimal mut=0x1A2B3C4D5E6F7788 n=4")
  }

  // MARK: 3 — FuzzMutator 출력 크기 상한

  /// 극단적으로 큰 연산 수(1000)에서도 출력이 `입력*2+4096` 상한을 넘지 않는다.
  @Test(arguments: FuzzSeedFixture.allCases)
  func mutatorOutputRespectsSizeCapUnderExtremeCount(seed: FuzzSeedFixture) {
    let original = seed.build().data
    let cap = original.count * 2 + 4_096
    let mutated = FuzzMutator.mutate(original, seed: 0x1234, count: 1_000)
    #expect(mutated.count <= cap)
  }

  /// 빈 입력은 그대로 반환한다 (연산이 적용될 바이트가 없음).
  @Test func mutatorReturnsEmptyDataUnchanged() {
    #expect(FuzzMutator.mutate(Data(), seed: 1, count: 10) == Data())
  }

  /// `count`가 같으면 같은 시드는 항상 같은 결과를 낸다 (결정성 재확인).
  @Test func mutatorIsDeterministicForSameSeedAndCount() {
    let original = FuzzSeedFixture.classicMinimal.build().data
    let first = FuzzMutator.mutate(original, seed: 77, count: 20)
    let second = FuzzMutator.mutate(original, seed: 77, count: 20)
    #expect(first == second)
  }

  // MARK: 4 — FuzzSeedFixture 카탈로그

  /// 전 시드 픽스처가 `%PDF-` 서명으로 시작하고 최소 크기를 넘으며, 두 번 빌드해도
  /// 바이트가 동일하다(결정성).
  @Test(arguments: FuzzSeedFixture.allCases)
  func everySeedFixtureBuildsValidAndDeterministicBytes(seed: FuzzSeedFixture) {
    let first = seed.build()
    let second = seed.build()
    #expect(first.data == second.data)

    let signature = Array("%PDF-".utf8)
    #expect(Array(first.data.prefix(signature.count)) == signature)
    #expect(first.data.count > 32)
    #expect(Array(first.data.suffix(5)) == Array("%%EOF".utf8))
  }

  // MARK: 5 — HostileFixtures 경계값

  /// `CoreLimits.maxNestingDepth`(512, `PapyrusTestSupport`는 `PapyrusCore`에 의존하지
  /// 않으므로 값을 리터럴로 미러링) 경계 양쪽에서 `deepNesting`이 크래시 없이 유효
  /// PDF 바이트를 생성한다.
  @Test(arguments: [511, 513])
  func deepNestingBuildsAtNestingDepthBoundary(depth: Int) {
    let fixture = HostileFixtures.deepNesting(depth: depth)
    let signature = Array("%PDF-".utf8)
    #expect(Array(fixture.data.prefix(signature.count)) == signature)
    #expect(Array(fixture.data.suffix(5)) == Array("%%EOF".utf8))
  }

  /// 나머지 hostile 픽스처들도 크래시 없이 유효한 바이트 골격을 만든다.
  @Test func remainingHostileFixturesBuildValidBytes() {
    let fixtures: [PDFFixture] = [
      HostileFixtures.hugeClaimedLength(),
      HostileFixtures.referenceCycle(length: 40),
      HostileFixtures.lyingPageCount(),
      HostileFixtures.selfReferentialObjectStream()
    ]
    let signature = Array("%PDF-".utf8)
    for fixture in fixtures {
      #expect(Array(fixture.data.prefix(signature.count)) == signature)
      #expect(Array(fixture.data.suffix(5)) == Array("%%EOF".utf8))
    }
  }
}
