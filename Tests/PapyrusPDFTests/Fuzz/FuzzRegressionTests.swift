import PapyrusPDF
import PapyrusPDFTestSupport
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
  static let knownFindings: [FuzzCaseID] = [
    // 발견 경위: 2026-07-24, 심층 퍼즈 실증(PAPYRUSPDF_FUZZ_SEED=0xC0FFEE2026, openOnly 파생
    // 시퀀스의 292번째 케이스)에서 프로세스 SIGTRAP(오버플로 트랩)으로 크래시. 뮤테이션이
    // `classicMinimal` 헤더의 부 버전 자릿수를 `corruptNumber`로 20여 회 이어붙여
    // `%PDF-1.49999999999999999999...`를 만들었고, `TrailerResolver.scanShortDigitRun`이
    // 자릿수 개수 판정(1~2자리만 유효) 전에 런 전체를 무조건 `Int` 곱셈 누산해 오버플로
    // 트랩으로 죽었다. 수정: 3번째 숫자 바이트를 만나는 즉시 무효로 확정하고 스캔을
    // 중단한다(값은 항상 ≤99). 같은 부류가 `XRefTableParser.scanDigitRun`(classic xref
    // 행의 offset/generation 필드)에도 있어 `multipliedReportingOverflow` 가드로 동시에
    // 고쳤다 — 이 케이스가 실제로 타격한 것은 헤더 파서뿐이지만 부류 전체를 문서화한다.
    FuzzCaseID(seed: .classicMinimal, mutationSeed: 0x6F04_9342_4FF0_288D, mutationCount: 10)
  ]

  /// 등재된 전 결함이 `.full` 표면에서 재발하지 않는지 확인한다.
  @Test func knownFindingsStayFixed() async {
    let findings = await FuzzExecutor.run(
      cases: Self.knownFindings, surface: .full, budget: FuzzBudget()
    )
    #expect(findings.isEmpty, "\(findings)")
  }
}
