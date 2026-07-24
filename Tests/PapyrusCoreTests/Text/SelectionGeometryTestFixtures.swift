import CoreGraphics
@testable import PapyrusCore

/// `SelectionGeometryHitTestTests`·`SelectionGeometryQueryTests`가 공유하는 픽스처
/// 헬퍼 (스위트 분할로 양쪽에서 참조하기 위해 internal 타입으로 분리).
enum SelectionGeometryTestFixtures {
  /// `TextAssembler`용 원시 run을 만든다 (라인 재구성 테스트 전용, quad는 무관).
  /// - Parameters:
  ///   - text: run의 텍스트.
  ///   - origin: run의 원점.
  ///   - direction: 베이스라인 방향 (기본 수평).
  /// - Returns: 합성 원시 run.
  static func makeRawRun(
    text: String, origin: CGPoint, direction: CGVector = CGVector(dx: 1, dy: 0)
  ) -> RawGlyphRun {
    let units = Array(text.utf16)
    let advances = Array(repeating: CGFloat(8), count: units.count)
    let width = 8 * CGFloat(units.count)
    let degenerateQuad = Quad(
      bottomLeft: origin, bottomRight: CGPoint(x: origin.x + width, y: origin.y),
      topRight: CGPoint(x: origin.x + width, y: origin.y + 10),
      topLeft: CGPoint(x: origin.x, y: origin.y + 10)
    )
    return RawGlyphRun(
      utf16: units, advances: advances, quad: degenerateQuad, origin: origin,
      baselineDirection: direction, effectiveFontSize: 12, isInvisible: false, isVertical: false
    )
  }

  /// 여백 앵커링·밴드 근접도 테스트가 공유하는 2라인 픽스처("Top\nBottom", 각 라인
  /// 수평·축 정렬 run 1개) — 여러 `@Test`가 동일 기하를 재사용해 타입 본문 길이를
  /// 줄인다(private 헬퍼 분리, 설계 비관여 세부).
  /// - Returns: "Top"(0..<3)·"Bottom"(4..<10) 2라인 콘텐츠.
  static func topBottomLinesContent() -> PageTextContent {
    let top = TextRun.uniform(
      range: 0..<3,
      quad: Quad(
        bottomLeft: CGPoint(x: 0, y: 700), bottomRight: CGPoint(x: 30, y: 700),
        topRight: CGPoint(x: 30, y: 710), topLeft: CGPoint(x: 0, y: 710)
      )
    )
    let bottom = TextRun.uniform(
      range: 4..<10,
      quad: Quad(
        bottomLeft: CGPoint(x: 0, y: 650), bottomRight: CGPoint(x: 60, y: 650),
        topRight: CGPoint(x: 60, y: 660), topLeft: CGPoint(x: 0, y: 660)
      )
    )
    return PageTextContent(pageIndex: 0, string: "Top\nBottom", runs: [top, bottom])
  }
}
