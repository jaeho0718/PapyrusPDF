import Papyrus
import PapyrusTestSupport
import Testing

/// 퍼즈가 찾아낸 역대 결함의 재현 케이스. 항목마다 발견 경위·수정 커밋을 주석으로 남긴다.
/// 절대 삭제하지 않는다 — 이 배열이 곧 "코퍼스"의 영구 축적분이다 (설계 §3.4).
///
/// - Important: 바이너리 블롭 없이 트리플(`seed`/`mutationSeed`/`mutationCount`)만으로
///   재생되는 것이 이 설계의 핵심 이득이다 — 단, `FuzzMutator`/`FuzzSeedFixture`의 바이트
///   출력을 바꾸는 변경은 이 배열 전체를 무효화한다. 뮤테이터 연산 추가는 허용하되(뒤에
///   추가), 기존 연산의 의미·순서 변경은 금지한다. 뮤테이터를 불가피하게 바꿔야 할 때는
///   기존 결함을 구조적 corruptor 모드나 hostile 생성기로 승격해 보존한다 (설계 §5.5).
@Suite("퍼즈 회귀", .timeLimit(.minutes(3)))
struct FuzzRegressionTests {
  /// 퍼즈가 찾아낸 역대 결함의 재현 케이스. 비어 있으면(v1 최초 상태) 이 스위트는 자명하게
  /// 통과한다.
  static let knownFindings: [FuzzCaseID] = []

  /// 등재된 전 결함이 `.full` 표면에서 재발하지 않는지 확인한다.
  @Test func knownFindingsStayFixed() async {
    let findings = await FuzzExecutor.run(
      cases: Self.knownFindings, surface: .full, budget: FuzzBudget()
    )
    #expect(findings.isEmpty, "\(findings)")
  }
}
