import CoreGraphics
@testable import PapyrusCore
import Testing

/// ``SelectionGeometry``의 라인 재구성·`displayQuads`·`lineTextRange`·`wordRange`를
/// 검증한다 (설계 §5.4).
///
/// `textOffset(at:)` 히트테스트 검증은 `SelectionGeometryHitTestTests`(타입 본문
/// 길이 분산을 위한 스위트 분할)를 참조.
struct SelectionGeometryQueryTests {
  // MARK: 라인 재구성 — 개행 경계 복원 + 각도 클래스 경계 분리

  @Test func lineReconstructionRecoversNewlineBoundariesFromAssembledContent() {
    let bottomRun = SelectionGeometryTestFixtures.makeRawRun(
      text: "Bottom", origin: CGPoint(x: 0, y: 650)
    )
    let topRun = SelectionGeometryTestFixtures.makeRawRun(
      text: "Top", origin: CGPoint(x: 0, y: 700)
    )
    let assembled = TextAssembler.assemble([bottomRun, topRun], pageIndex: 0)
    #expect(assembled.string == "Top\nBottom")

    let geometry = SelectionGeometry.build(
      content: assembled, pageIndex: 0, transform: .identity
    )
    // "Top"과 "Bottom"은 서로 다른 라인이어야 한다 — lineTextRange가 각각 다른 구간을
    // 반환하는 것으로 검증한다.
    let topLine = geometry.lineTextRange(containing: 1)
    let bottomLine = geometry.lineTextRange(containing: 5)
    #expect(topLine == 0..<3)
    #expect(bottomLine == 4..<10)
  }

  @Test func angleClassBoundaryAlsoSeparatesLines() {
    let horizontal = SelectionGeometryTestFixtures.makeRawRun(
      text: "H", origin: CGPoint(x: 0, y: 700)
    )
    let rotated45 = SelectionGeometryTestFixtures.makeRawRun(
      text: "R", origin: CGPoint(x: 0, y: 700),
      direction: CGVector(dx: cos(Double.pi / 4), dy: sin(Double.pi / 4))
    )
    let assembled = TextAssembler.assemble([horizontal, rotated45], pageIndex: 0)
    #expect(assembled.string.contains("\n"))

    let geometry = SelectionGeometry.build(
      content: assembled, pageIndex: 0, transform: .identity
    )
    let firstLine = geometry.lineTextRange(containing: 0)
    let secondLine = geometry.lineTextRange(containing: assembled.string.utf16.count - 1)
    #expect(firstLine != secondLine)
  }

  // MARK: displayQuads

  @Test func displayQuadsMergesAxisAlignedAdjacentRunsInSameLine() {
    let runA = TextRun.uniform(
      range: 0..<3,
      quad: Quad(
        bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 30, y: 0),
        topRight: CGPoint(x: 30, y: 10), topLeft: CGPoint(x: 0, y: 10)
      )
    )
    // index3은 삽입 공백(간극), runB는 4..<7.
    let runB = TextRun.uniform(
      range: 4..<7,
      quad: Quad(
        bottomLeft: CGPoint(x: 40, y: 0), bottomRight: CGPoint(x: 70, y: 0),
        topRight: CGPoint(x: 70, y: 10), topLeft: CGPoint(x: 40, y: 10)
      )
    )
    let content = PageTextContent(pageIndex: 0, string: "foo bar", runs: [runA, runB])
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: .identity)

    let quads = geometry.displayQuads(forRange: 0..<7)
    #expect(quads.count == 1)
    let bounds = quads[0].boundingRect
    #expect(bounds.minX == 0)
    #expect(bounds.maxX == 70) // 공백 간극도 병합 결과에 채워진다.
  }

  @Test func displayQuadsDoesNotMergeRotatedRuns() {
    let tiltedQuad = Quad(
      bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 10, y: 10),
      topRight: CGPoint(x: 5, y: 15), topLeft: CGPoint(x: -5, y: 5)
    )
    let runA = TextRun.uniform(range: 0..<1, quad: tiltedQuad)
    let runB = TextRun.uniform(
      range: 1..<2,
      quad: Quad(
        bottomLeft: CGPoint(x: 10, y: 10), bottomRight: CGPoint(x: 20, y: 20),
        topRight: CGPoint(x: 15, y: 25), topLeft: CGPoint(x: 5, y: 15)
      )
    )
    let content = PageTextContent(pageIndex: 0, string: "ab", runs: [runA, runB])
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: .identity)
    let quads = geometry.displayQuads(forRange: 0..<2)
    #expect(quads.count == 2)
  }

  @Test func displayQuadsProducesOneQuadPerLineForRangeSpanningTwoLines() {
    let content = SelectionGeometryTestFixtures.topBottomLinesContent()
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: .identity)
    let quads = geometry.displayQuads(forRange: 0..<10)
    #expect(quads.count == 2)
  }

  @Test func displayQuadsIncludesInvisibleRuns() {
    let invisibleRun = TextRun(
      range: 0..<3,
      quad: Quad(
        bottomLeft: .zero, bottomRight: CGPoint(x: 30, y: 0), topRight: CGPoint(x: 30, y: 10),
        topLeft: CGPoint(x: 0, y: 10)
      ),
      advances: [10, 10, 10], isInvisible: true
    )
    let content = PageTextContent(pageIndex: 0, string: "abc", runs: [invisibleRun])
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: .identity)
    #expect(geometry.displayQuads(forRange: 0..<3).count == 1)
  }

  @Test func displayQuadsReturnsEmptyForNonIntersectingRange() {
    let run = TextRun.uniform(
      range: 0..<3,
      quad: Quad(
        bottomLeft: .zero, bottomRight: CGPoint(x: 30, y: 0), topRight: CGPoint(x: 30, y: 10),
        topLeft: CGPoint(x: 0, y: 10)
      )
    )
    // index3은 삽입 공백 — 어느 run에도 속하지 않는다.
    let content = PageTextContent(pageIndex: 0, string: "abc ", runs: [run])
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: .identity)
    #expect(geometry.displayQuads(forRange: 3..<4).isEmpty)
  }

  // MARK: lineTextRange / wordRange

  @Test func lineTextRangeAssignsNewlineOffsetToPrecedingLine() {
    let bottomRun = SelectionGeometryTestFixtures.makeRawRun(
      text: "Bottom", origin: CGPoint(x: 0, y: 650)
    )
    let topRun = SelectionGeometryTestFixtures.makeRawRun(
      text: "Top", origin: CGPoint(x: 0, y: 700)
    )
    let assembled = TextAssembler.assemble([bottomRun, topRun], pageIndex: 0)
    let geometry = SelectionGeometry.build(
      content: assembled, pageIndex: 0, transform: .identity
    )
    // 개행 오프셋(3)은 앞 라인("Top", 0..<3) 소속이어야 한다.
    #expect(geometry.lineTextRange(containing: 3) == 0..<3)
    // 마지막 오프셋 이후(10)는 마지막 라인.
    #expect(geometry.lineTextRange(containing: 10) == 4..<10)
  }

  @Test func wordRangeDelegatesToLineWindow() {
    let run = TextRun.uniform(
      range: 0..<11,
      quad: Quad(
        bottomLeft: .zero, bottomRight: CGPoint(x: 110, y: 0), topRight: CGPoint(x: 110, y: 10),
        topLeft: CGPoint(x: 0, y: 10)
      )
    )
    let content = PageTextContent(pageIndex: 0, string: "hello world", runs: [run])
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: .identity)
    #expect(geometry.wordRange(around: 2) == 0..<5)
    #expect(geometry.wordRange(around: 8) == 6..<11)
  }
}
