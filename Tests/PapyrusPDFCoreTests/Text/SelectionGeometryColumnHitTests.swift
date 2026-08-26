import CoreGraphics
@testable import PapyrusPDFCore
import Testing

/// `SelectionGeometry`의 2차원(밴드 + 축 투영) 히트테스트를 검증한다 — 같은 밴드(y)에
/// 열이 둘 있을 때 x가 맞는 열을 고르는지 (설계 `_workspace/11_architect_column-aware-
/// text-order.md` §6 TH1). 단일 라인·회전·여백 앵커링은 `SelectionGeometryHitTestTests`
/// 참조.
struct SelectionGeometryColumnHitTests {
  // MARK: TH1 — 같은 밴드의 두 열 중 x로 판별
  //
  // identity 변환 전용(회전 미파라미터화): 90°/270°에서는 밴드 판정 좌표가 페이지 공간
  // x에서 파생돼(`PageDisplayTransform` 변환표) "같은 y 밴드"와 "x 투영 차이"를 동시에
  // 독립 제어할 수 없다 — `nearestLineChosenByBandProximity`·
  // `marginPointProjectsToInteriorOffsetWithinNearestLine`(SelectionGeometryHitTestTests)
  // 와 동일 근거로 identity에 고정한다.

  @Test func sameBandTwoColumnsResolveByXProjection() {
    // "Left\nRight" — Left quad x 0..32(4글자), Right quad x 100..140(5글자), 두 라인이
    // 같은 y 밴드(700..710)를 공유한다(다단 페이지의 같은 베이스라인 시나리오 재현).
    let left = TextRun.uniform(
      range: 0..<4,
      quad: Quad(
        bottomLeft: CGPoint(x: 0, y: 700), bottomRight: CGPoint(x: 32, y: 700),
        topRight: CGPoint(x: 32, y: 710), topLeft: CGPoint(x: 0, y: 710)
      )
    )
    let right = TextRun.uniform(
      range: 5..<10,
      quad: Quad(
        bottomLeft: CGPoint(x: 100, y: 700), bottomRight: CGPoint(x: 140, y: 700),
        topRight: CGPoint(x: 140, y: 710), topLeft: CGPoint(x: 100, y: 710)
      )
    )
    let content = PageTextContent(pageIndex: 0, string: "Left\nRight", runs: [left, right])
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: .identity)

    func offset(atPagePoint point: CGPoint) -> Int {
      geometry.textOffset(at: point)
    }

    // Right 안쪽(x=116) — 축 투영 구간 안이라 거리0, Left까지 거리(84)보다 가까워 Right.
    #expect(offset(atPagePoint: CGPoint(x: 116, y: 705)) == 7)
    // Left 안쪽(x=18) — 같은 논리로 Left.
    #expect(offset(atPagePoint: CGPoint(x: 18, y: 705)) == 2)
    // 거터 안, Left 끝(32)에 더 가까움(거리28 < 40) → Left의 끝 오프셋(4).
    #expect(offset(atPagePoint: CGPoint(x: 60, y: 705)) == 4)
    // 거터 안, Right 시작(100)에 더 가까움(거리20 < 48) → Right의 시작 오프셋(5).
    #expect(offset(atPagePoint: CGPoint(x: 80, y: 705)) == 5)
    // Right 오른쪽 여백 → Right 끝(문자열 길이,10).
    #expect(offset(atPagePoint: CGPoint(x: 200, y: 705)) == 10)
    // Left 왼쪽 여백 → Left 시작(0).
    #expect(offset(atPagePoint: CGPoint(x: -20, y: 705)) == 0)
  }
}
