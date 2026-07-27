import CoreGraphics
@testable import PapyrusPDFCore
import Testing

/// ``TextAssembler``의 라인 클러스터링·간격 휴리스틱·결정성을 검증한다 (설계 §5.4 TA1-TA8).
struct TextAssemblerTests {
  // MARK: TA1 — 같은 베이스라인, 큰 gap → 공백 삽입

  @Test func largeGapOnSameBaselineInsertsSpace() {
    let runA = Self.makeRun(text: "AB", origin: CGPoint(x: 0, y: 700))
    let runB = Self.makeRun(text: "CD", origin: CGPoint(x: 100, y: 700))
    let content = TextAssembler.assemble([runA, runB], pageIndex: 0)
    #expect(content.string == "AB CD")
  }

  // MARK: TA2 — 같은 베이스라인, gap ≈ 0 → 무삽입

  @Test func nearZeroGapInsertsNothing() {
    let runA = Self.makeRun(text: "AB", origin: CGPoint(x: 0, y: 700))
    let runB = Self.makeRun(text: "CD", origin: CGPoint(x: 16, y: 700))
    let content = TextAssembler.assemble([runA, runB], pageIndex: 0)
    #expect(content.string == "ABCD")
  }

  /// TA1 회귀(리뷰 should #1): 공백 삽입 임계값은 새 run만이 아니라 "두 run 중 작은
  /// effFontSize"를 써야 한다(설계 §3.7 5항목). 직전 run은 작은 폰트(4), 다음 run은
  /// 큰 폰트(100) — 새 run 크기만 쓰면 gap(10)이 허용치(25) 이내라 공백이 빠지지만,
  /// 두 run의 최솟값(4)을 쓰면 허용치(1)를 넘어 공백이 들어가야 한다.
  @Test func spaceThresholdUsesSmallerOfBothRunFontSizes() {
    let runA = Self.makeRun(
      text: "AB", origin: CGPoint(x: 0, y: 700), effectiveFontSize: 4, advanceStep: 8
    )
    let runB = Self.makeRun(
      text: "CD", origin: CGPoint(x: 26, y: 700), effectiveFontSize: 100, advanceStep: 8
    )
    let content = TextAssembler.assemble([runA, runB], pageIndex: 0)
    #expect(content.string == "AB CD")
  }

  // MARK: TA3 — 두 라인, "\n" 삽입, 위 라인 먼저

  @Test func differentLinesInsertNewlineTopFirst() {
    let bottomRun = Self.makeRun(text: "Bottom", origin: CGPoint(x: 0, y: 650))
    let topRun = Self.makeRun(text: "Top", origin: CGPoint(x: 0, y: 700))
    let content = TextAssembler.assemble([bottomRun, topRun], pageIndex: 0)
    #expect(content.string == "Top\nBottom")
  }

  // MARK: TA4 — 방출 순서 역전 → 좌→우 재정렬, 출력 runs는 읽기 순서(오름차순)

  @Test func reversedEmissionOrderReordersLeftToRight() {
    let rightRun = Self.makeRun(text: "Right", origin: CGPoint(x: 100, y: 700))
    let leftRun = Self.makeRun(text: "Left", origin: CGPoint(x: 0, y: 700))
    let content = TextAssembler.assemble([rightRun, leftRun], pageIndex: 0)
    #expect(content.string.hasPrefix("Left"))
    #expect(content.string.hasSuffix("Right"))
    // 출력 runs 배열은 읽기 순서(range.lowerBound 오름차순) 계약을 따른다 — 방출 순서와
    // 무관하게 leftRun이 먼저(index 0) 온다 (설계 M9 §0.1).
    #expect(content.runs.count == 2)
    #expect(content.runs[0].range.lowerBound < content.runs[1].range.lowerBound)
  }

  // MARK: TA9 — 출력 runs는 항상 오름차순(방출 역전·다중 라인 혼합에서도)

  @Test func runsAreSortedByRangeAscending() {
    let bottomRight = Self.makeRun(text: "BR", origin: CGPoint(x: 100, y: 650))
    let bottomLeft = Self.makeRun(text: "BL", origin: CGPoint(x: 0, y: 650))
    let topRight = Self.makeRun(text: "TR", origin: CGPoint(x: 100, y: 700))
    let topLeft = Self.makeRun(text: "TL", origin: CGPoint(x: 0, y: 700))
    let content = TextAssembler.assemble(
      [bottomRight, topLeft, bottomLeft, topRight], pageIndex: 0
    )
    for index in 1..<content.runs.count {
      #expect(content.runs[index - 1].range.lowerBound < content.runs[index].range.lowerBound)
    }
  }

  // MARK: TA5 — range·advances 정합, 삽입 문자 미소속

  @Test func rangesExcludeInsertedSeparators() {
    let runA = Self.makeRun(text: "AB", origin: CGPoint(x: 0, y: 700))
    let runB = Self.makeRun(text: "CD", origin: CGPoint(x: 100, y: 700))
    let content = TextAssembler.assemble([runA, runB], pageIndex: 0)
    #expect(content.string == "AB CD")
    #expect(content.runs[0].range == 0..<2)
    #expect(content.runs[1].range == 3..<5) // 인덱스 2(공백)는 어느 run에도 속하지 않는다.
    for run in content.runs {
      #expect(run.range.count == run.advances.count)
    }
  }

  // MARK: TA6 — 회전 텍스트끼리 별도 라인

  @Test func rotatedTextFormsSeparateLineFromHorizontal() {
    let horizontal = Self.makeRun(text: "H", origin: CGPoint(x: 0, y: 700))
    let rotated45 = Self.makeRun(
      text: "R", origin: CGPoint(x: 0, y: 700),
      direction: CGVector(dx: cos(Double.pi / 4), dy: sin(Double.pi / 4))
    )
    let content = TextAssembler.assemble([horizontal, rotated45], pageIndex: 0)
    #expect(content.string.contains("H"))
    #expect(content.string.contains("R"))
    #expect(content.string.contains("\n")) // 서로 다른 각도 클래스는 별도 라인으로 분리.
  }

  // MARK: TA7 — 빈 입력

  @Test func emptyInputProducesEmptyResult() {
    let content = TextAssembler.assemble([], pageIndex: 3)
    #expect(content.pageIndex == 3)
    #expect(content.string.isEmpty)
    #expect(content.runs.isEmpty)
  }

  // MARK: TA8 — 결정성

  @Test func sameInputProducesSameOutputTwice() {
    let runA = Self.makeRun(text: "AB", origin: CGPoint(x: 0, y: 700))
    let runB = Self.makeRun(text: "CD", origin: CGPoint(x: 100, y: 700))
    let first = TextAssembler.assemble([runA, runB], pageIndex: 0)
    let second = TextAssembler.assemble([runA, runB], pageIndex: 0)
    #expect(first == second)
  }
}

// MARK: - 테스트 헬퍼

extension TextAssemblerTests {
  /// 단순 원시 run을 만든다. quad는 어셈블러가 사용하지 않으므로(문자열/순서만 검증)
  /// origin과 동일한 퇴화 사각형으로 채운다.
  static func makeRun(
    text: String, origin: CGPoint, direction: CGVector = CGVector(dx: 1, dy: 0),
    effectiveFontSize: CGFloat = 12, advanceStep: CGFloat = 8, isInvisible: Bool = false,
    isVertical: Bool = false
  ) -> RawGlyphRun {
    let units = Array(text.utf16)
    let advances = Array(repeating: advanceStep, count: units.count)
    let degenerateQuad = Quad(
      bottomLeft: origin, bottomRight: origin, topRight: origin, topLeft: origin
    )
    return RawGlyphRun(
      utf16: units, advances: advances, quad: degenerateQuad, origin: origin,
      baselineDirection: direction, effectiveFontSize: effectiveFontSize, isInvisible: isInvisible,
      isVertical: isVertical
    )
  }
}
