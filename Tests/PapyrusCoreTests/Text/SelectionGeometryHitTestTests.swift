import CoreGraphics
@testable import PapyrusCore
import Testing

/// ``SelectionGeometry``의 구축·`textOffset(at:)` 히트테스트를 검증한다 (설계 §5.4).
///
/// `displayQuads`·`lineTextRange`·`wordRange`·라인 재구성 검증은
/// `SelectionGeometryQueryTests`(타입 본문 길이 분산을 위한 스위트 분할)를 참조.
struct SelectionGeometryHitTestTests {
  /// 회전 파라미터화 테스트가 공유하는 cropBox.
  private static let cropBox = CGRect(x: 0, y: 0, width: 300, height: 800)

  // MARK: 단일 라인 히트테스트 (회전 4종)

  @Test(arguments: PageRotation.allCases)
  func singleLineHitTestAcrossRotations(rotation: PageRotation) {
    // "ABCD XY" — ABCD(0..<4)와 XY(5..<7)가 삽입 공백(인덱스4)으로 갈라진 한 줄.
    let abcd = TextRun.uniform(
      range: 0..<4,
      quad: Quad(
        bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 40, y: 0),
        topRight: CGPoint(x: 40, y: 10), topLeft: CGPoint(x: 0, y: 10)
      )
    )
    let xy = TextRun.uniform(
      range: 5..<7,
      quad: Quad(
        bottomLeft: CGPoint(x: 50, y: 0), bottomRight: CGPoint(x: 70, y: 0),
        topRight: CGPoint(x: 70, y: 10), topLeft: CGPoint(x: 50, y: 10)
      )
    )
    let content = PageTextContent(pageIndex: 0, string: "ABCD XY", runs: [abcd, xy])
    let transform = PageDisplayTransform.transform(cropBox: Self.cropBox, rotation: rotation)
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: transform)

    func offset(atPagePoint point: CGPoint) -> Int {
      geometry.textOffset(at: point.applying(transform))
    }

    // 앞쪽으로 반올림: x=13, advances 10/글자 → d=13, 경계 10과 20 중 10이 더 가깝다.
    #expect(offset(atPagePoint: CGPoint(x: 13, y: 5)) == 1)
    // 뒤쪽으로 반올림: x=27 → 경계 20과 30 중 30이 더 가깝다.
    #expect(offset(atPagePoint: CGPoint(x: 27, y: 5)) == 3)
    // 간극(공백) 안, ABCD 쪽에 더 가까움 → ABCD의 끝 오프셋(4).
    #expect(offset(atPagePoint: CGPoint(x: 42, y: 5)) == 4)
    // 간극 안, XY 쪽에 더 가까움 → XY의 시작 오프셋(5).
    #expect(offset(atPagePoint: CGPoint(x: 48, y: 5)) == 5)
    // 라인 시작 전 → 라인 시작 오프셋(0). 개정 1: 라인 축 투영 경로는 아핀 변환이
    // 직선 위 betweenness를 보존하는 한 회전 불변이라 270°(표시 축 역전)에서도
    // 성립한다 — 초판의 전역 y 극단 스냅은 270°에서 이 값이 뒤집혔다(구현 검증
    // 회부 사유, §2.2 개정 1).
    #expect(offset(atPagePoint: CGPoint(x: -10, y: 5)) == 0)
    // 라인 끝 후 → 라인 끝 오프셋(문자열 길이, 7). 위와 동일한 근거로 회전 4종 공통.
    #expect(offset(atPagePoint: CGPoint(x: 100, y: 5)) == 7)
  }

  // MARK: 여백 앵커링 — 라인 시작/끝 방향 (회전 4종, 개정 1)
  //
  // 개정 1: 여백(전 라인 밴드 밖) 점은 전역 y 극값에 스냅하지 않고, 최근접 라인의 축에
  // 투영해 처리한다(§2.2). 라인 축은 항상 그 라인 첫 run의 bl→br 방향으로 정의되므로
  // "라인 시작 방향으로 벗어난 점 → 그 라인의 시작 오프셋", "끝 방향으로 벗어난 점 →
  // 그 라인의 끝 오프셋" 대응은 아핀 변환(회전 포함)이 직선 위의 betweenness를 보존하는
  // 한 항상 성립한다 — 회전이 표시 공간 y축을 뒤집어도 축 자체가 방향 정보를 담고
  // 있어 무관하다. 아래 두 점은 각각 페이지 공간에서 "Top" 라인 시작 전 연장선,
  // "Bottom" 라인 끝 후 연장선 위에 있고, 두 라인의 표시 공간 밴드와도 회전 4종
  // 전부에서 가장 가깝다(동률이 나는 회전에서도 라인 인덱스 결정성 규칙이 텍스트
  // 순서상 해당 라인을 그대로 고른다 — 270°는 `marginAnchoringStaysCorrectAt…`에서
  // 그 동률·역전 사정을 explicit하게 짚는다).

  @Test(arguments: PageRotation.allCases)
  func marginAnchorsToLineStartAndEndAcrossRotations(rotation: PageRotation) {
    let content = SelectionGeometryTestFixtures.topBottomLinesContent()
    let transform = PageDisplayTransform.transform(cropBox: Self.cropBox, rotation: rotation)
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: transform)

    // "Top" 라인 시작 전 연장선(첫 라인의 시작 방향 여백) → 문서 시작(0).
    let beforeFirstLine = geometry.textOffset(
      at: CGPoint(x: -10_000, y: 750).applying(transform)
    )
    #expect(beforeFirstLine == 0)
    // "Bottom" 라인 끝 후 연장선(마지막 라인의 끝 방향 여백) → 문서 끝(N).
    let afterLastLine = geometry.textOffset(
      at: CGPoint(x: 10_000, y: 655).applying(transform)
    )
    #expect(afterLastLine == content.string.utf16.count)
  }

  // MARK: 여백 안에서도 라인 내부는 x 투영으로 결정 (identity 변환)
  //
  // 밴드 밖(margin) 점이라도 라인이 정해지면 그 라인의 축 투영은 x 위치를 그대로
  // 반영한다 — 여백이라고 무조건 극단(0/N)으로 스냅되는 것은 아니다. 90°/270°
  // 회전에서는 밴드 판정 좌표가 페이지 공간 x에서 파생돼(`PageDisplayTransform`
  // 변환표) "y 여백"과 "x 투영"을 동시에 독립 제어할 수 없으므로 이 케이스는 identity
  // 변환으로 고정한다 — `nearestLineChosenByBandProximity`의 회전 불변성 한계와 동일
  // 근거.

  @Test func marginPointProjectsToInteriorOffsetWithinNearestLine() {
    let content = SelectionGeometryTestFixtures.topBottomLinesContent()
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: .identity)

    // y=10,000은 두 라인 밴드 모두 밖(위쪽 여백)이지만 "Top" 밴드(700...710)에 더
    // 가까워 Top 라인이 선택된다. x=15는 Top 런("Top", advances 균등)의 정중앙이라
    // 경계 오프셋 1과 2가 동률 → 뒤쪽(2)으로 반올림된다(§2.2 동률 규칙과 동일).
    let offset = geometry.textOffset(at: CGPoint(x: 15, y: 10_000))
    #expect(offset == 2)
  }

  // MARK: 270° 여백 앵커링 회귀 방지 — 표시 공간 라인 순서 역전에도 텍스트 순서 유지
  //
  // 270°(페이지 공간 수평 run → 표시 공간 상향 수직 라인)에서는 "Bottom" 라인의 표시
  // 밴드 중점이 "Top" 라인의 밴드 중점보다 작아 시각적으로는 Bottom이 먼저 온다 —
  // 텍스트 순서(Top이 먼저)와 정반대다. 초판 설계의 전역 y 극단 스냅은 이 역전을
  // 그대로 표시 y에 반영해 문서 시작/끝을 뒤바꿨다(개정 사유, §2.2). 라인 축 투영은
  // 라인 인덱스 결정성 규칙(동률 시 텍스트 순서 앞 라인)과 축의 구조적 방향 보존
  // 덕분에 이 역전과 무관하게 옳은 결과를 낸다 — 이 테스트가 그 회귀를 직접 잡는다.

  @Test func marginAnchoringStaysCorrectAtDegrees270DespiteReversedVisualLineOrder() {
    let content = SelectionGeometryTestFixtures.topBottomLinesContent()
    let transform = PageDisplayTransform.transform(cropBox: Self.cropBox, rotation: .degrees270)
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: transform)

    let beforeFirstLine = geometry.textOffset(at: CGPoint(x: -10_000, y: 750).applying(transform))
    #expect(beforeFirstLine == 0)
    let afterLastLine = geometry.textOffset(at: CGPoint(x: 10_000, y: 655).applying(transform))
    #expect(afterLastLine == content.string.utf16.count)
  }

  // MARK: 라인 밴드 사이 → 가까운 라인 (identity 변환 — 페이지 공간 y가 곧 표시 공간 y)

  @Test func nearestLineChosenByBandProximity() {
    let content = SelectionGeometryTestFixtures.topBottomLinesContent()
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: .identity)

    // y=675: 위 밴드(700..710)까지 거리 25, 아래 밴드(650..660)까지 거리 15 → 아래 라인.
    let nearBottomLine = geometry.textOffset(at: CGPoint(x: 0, y: 675))
    #expect((4...10).contains(nearBottomLine))
    // y=705: 위 밴드 안(거리0) → 위 라인.
    let nearTopLine = geometry.textOffset(at: CGPoint(x: 0, y: 705))
    #expect((0...3).contains(nearTopLine))
  }

  // MARK: 다중 유닛 글리프(0-advance 꼬리) 경계 전진

  @Test func multiUnitGlyphAdvancesToBundleEnd() {
    // "X😀Y" — X(0..<1), 😀(1..<3, advances [20, 0] — 0-advance 꼬리), Y(3..<4).
    let x = TextRun.uniform(
      range: 0..<1,
      quad: Quad(
        bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 5, y: 0),
        topRight: CGPoint(x: 5, y: 10), topLeft: CGPoint(x: 0, y: 10)
      )
    )
    let emoji = TextRun(
      range: 1..<3,
      quad: Quad(
        bottomLeft: CGPoint(x: 5, y: 0), bottomRight: CGPoint(x: 25, y: 0),
        topRight: CGPoint(x: 25, y: 10), topLeft: CGPoint(x: 5, y: 10)
      ),
      advances: [20, 0], isInvisible: false
    )
    let y = TextRun.uniform(
      range: 3..<4,
      quad: Quad(
        bottomLeft: CGPoint(x: 25, y: 0), bottomRight: CGPoint(x: 30, y: 0),
        topRight: CGPoint(x: 30, y: 10), topLeft: CGPoint(x: 25, y: 10)
      )
    )
    let content = PageTextContent(pageIndex: 0, string: "X😀Y", runs: [x, emoji, y])
    let geometry = SelectionGeometry.build(
      content: content, pageIndex: 0, transform: .identity
    )

    // x=24 (이모지 안쪽, 끝에 가까움) — 순진한 최근접 선택이면 로컬 인덱스1(오프셋2,
    // 서로게이트 중간)이 되지만, 0-advance 꼬리 묶음 전진 규칙으로 오프셋3이 되어야 한다.
    let offset = geometry.textOffset(at: CGPoint(x: 24, y: 5))
    #expect(offset == 3)
  }

  // MARK: 써로게이트 스냅 (최종 안전망)

  @Test func surrogatePairOffsetSnapsToValidCharacterBoundary() {
    // "😀" 하나짜리 run, 부적절하게 두 유닛에 advance를 균등 배분(외부 공급 오류 시나리오).
    let run = TextRun(
      range: 0..<2,
      quad: Quad(
        bottomLeft: .zero, bottomRight: CGPoint(x: 20, y: 0), topRight: CGPoint(x: 20, y: 10),
        topLeft: CGPoint(x: 0, y: 10)
      ),
      advances: [10, 10], isInvisible: false
    )
    let content = PageTextContent(pageIndex: 0, string: "😀", runs: [run])
    let geometry = SelectionGeometry.build(
      content: content, pageIndex: 0, transform: .identity
    )
    let offset = geometry.textOffset(at: CGPoint(x: 10, y: 5))
    #expect(offset == 0 || offset == 2) // 절대 mid-서로게이트(1)가 아니어야 한다.
  }

  // MARK: 기울임(45°) run 투영 히트

  @Test func tiltedRunProjectsHitAlongItsAxis() {
    let value = 20 * CGFloat(2).squareRoot() / 2 // 45도 축의 단위 투영 성분.
    let quad = Quad(
      bottomLeft: .zero, bottomRight: CGPoint(x: value, y: value),
      topRight: CGPoint(x: value - 5, y: value + 5), topLeft: CGPoint(x: -5, y: 5)
    )
    let run = TextRun.uniform(range: 0..<2, quad: quad)
    let content = PageTextContent(pageIndex: 0, string: "AB", runs: [run])
    let geometry = SelectionGeometry.build(
      content: content, pageIndex: 0, transform: .identity
    )
    // 축 방향(대각선) 위 중점 근처 클릭 — 크래시 없이 0...2 안의 오프셋을 반환해야 한다.
    let midpoint = CGPoint(x: value / 2, y: value / 2)
    let offset = geometry.textOffset(at: midpoint)
    #expect((0...2).contains(offset))
  }

  // MARK: 퇴화 advance 합 0 → t=0 폴백(런 시작)

  @Test func degenerateAdvanceSumFallsBackToRunStart() {
    let run = TextRun(
      range: 0..<3,
      quad: Quad(
        bottomLeft: .zero, bottomRight: CGPoint(x: 30, y: 0), topRight: CGPoint(x: 30, y: 10),
        topLeft: CGPoint(x: 0, y: 10)
      ),
      advances: [0, 0, 0], isInvisible: false
    )
    let content = PageTextContent(pageIndex: 0, string: "abc", runs: [run])
    let geometry = SelectionGeometry.build(
      content: content, pageIndex: 0, transform: .identity
    )
    let offset = geometry.textOffset(at: CGPoint(x: 15, y: 5))
    #expect(offset == 0)
  }

  // MARK: 퇴화 베이스라인(bl==br) → (1,0) 폴백, 크래시 없음

  @Test func degenerateBaselineFallsBackWithoutCrashing() {
    let degenerateQuad = Quad(
      bottomLeft: CGPoint(x: 5, y: 5), bottomRight: CGPoint(x: 5, y: 5),
      topRight: CGPoint(x: 5, y: 5), topLeft: CGPoint(x: 5, y: 5)
    )
    let run = TextRun.uniform(range: 0..<1, quad: degenerateQuad)
    let content = PageTextContent(pageIndex: 0, string: "a", runs: [run])
    let geometry = SelectionGeometry.build(
      content: content, pageIndex: 0, transform: .identity
    )
    let offset = geometry.textOffset(at: CGPoint(x: 5, y: 5))
    #expect(offset >= 0 && offset <= 1)
  }

  // MARK: 단일 문자 run

  @Test func singleCharacterRunHitTests() {
    let quad = Quad(
      bottomLeft: .zero, bottomRight: CGPoint(x: 10, y: 0), topRight: CGPoint(x: 10, y: 10),
      topLeft: CGPoint(x: 0, y: 10)
    )
    let run = TextRun.uniform(range: 0..<1, quad: quad)
    let content = PageTextContent(pageIndex: 0, string: "a", runs: [run])
    let geometry = SelectionGeometry.build(
      content: content, pageIndex: 0, transform: .identity
    )
    #expect(geometry.textOffset(at: CGPoint(x: 2, y: 5)) == 0)
    #expect(geometry.textOffset(at: CGPoint(x: 9, y: 5)) == 1)
  }

  // MARK: 빈 페이지 → 0, isEmpty

  @Test func emptyContentReturnsZeroOffsetAndIsEmpty() {
    let content = PageTextContent(pageIndex: 0, string: "", runs: [])
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: .identity)
    #expect(geometry.isEmpty)
    #expect(geometry.textOffset(at: CGPoint(x: 100, y: 100)) == 0)
    #expect(geometry.displayQuads(forRange: 0..<0).isEmpty)
    #expect(geometry.lineTextRange(containing: 0) == nil)
    #expect(geometry.wordRange(around: 0) == nil)
  }
}
