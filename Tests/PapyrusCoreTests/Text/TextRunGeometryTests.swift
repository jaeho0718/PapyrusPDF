import CoreGraphics
@testable import PapyrusCore
import Testing

/// ``TextRunGeometry``의 교차 탐색·quad 보간을 검증한다 (설계 §5.2).
///
/// 1-2는 `SearchMatcherTests`의 `partialQuadInterpolatesRotatedQuad`·
/// `partialQuadFallsBackToFullQuadWhenAdvancesSumToZero`를, 3-4는 `matchSpanningTwoRuns
/// ProducesTwoQuads`·`matchSpanningInsertedWhitespaceSkipsWhitespaceQuad`의 quad 부분을
/// 이동한 것이다 (호출 대상만 `TextRunGeometry`로 변경, 단언 무수정, M9 §4-2).
struct TextRunGeometryTests {
  // MARK: 1 — partialQuad: 회전 quad 수치 검증

  @Test func partialQuadInterpolatesRotatedQuad() {
    // 90도 회전한 run: 베이스라인이 수직 방향.
    let quad = Quad(
      bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 0, y: 10),
      topRight: CGPoint(x: 20, y: 10), topLeft: CGPoint(x: 20, y: 0)
    )
    let run = TextRun(range: 0..<4, quad: quad, advances: [5, 5, 5, 5], isInvisible: false)
    let partial = TextRunGeometry.partialQuad(of: run, localRange: 1..<3)

    // t0 = 5/20 = 0.25, t1 = 15/20 = 0.75.
    Self.expectClose(partial.bottomLeft.x, 0)
    Self.expectClose(partial.bottomLeft.y, 2.5)
    Self.expectClose(partial.bottomRight.x, 0)
    Self.expectClose(partial.bottomRight.y, 7.5)
    Self.expectClose(partial.topRight.x, 20)
    Self.expectClose(partial.topRight.y, 7.5)
    Self.expectClose(partial.topLeft.x, 20)
    Self.expectClose(partial.topLeft.y, 2.5)
  }

  // MARK: 2 — 전진량 합 0 → 전체 quad 폴백 (0 나눗셈·NaN 없음)

  @Test func partialQuadFallsBackToFullQuadWhenAdvancesSumToZero() {
    let quad = Quad(
      bottomLeft: CGPoint(x: 1, y: 2), bottomRight: CGPoint(x: 11, y: 2),
      topRight: CGPoint(x: 11, y: 12), topLeft: CGPoint(x: 1, y: 12)
    )
    let run = TextRun(range: 0..<3, quad: quad, advances: [0, 0, 0], isInvisible: false)
    let partial = TextRunGeometry.partialQuad(of: run, localRange: 0..<2)

    #expect(partial.bottomLeft == quad.bottomLeft)
    #expect(partial.bottomRight == quad.bottomRight)
    #expect(partial.topRight == quad.topRight)
    #expect(partial.topLeft == quad.topLeft)
    #expect(!partial.bottomLeft.x.isNaN)
  }

  // MARK: 3 — 두 run에 걸친 구간 → quad 2개

  @Test func matchSpanningTwoRunsProducesTwoQuads() {
    let runA = Self.uniformRun(range: 0..<3, advance: 10) // "foo"
    let runB = Self.uniformRun(range: 3..<6, advance: 10, originX: 30) // "bar"
    let quads = TextRunGeometry.quads(forRange: 1..<4, in: [runA, runB])

    #expect(quads.count == 2)
    // runA 쪽 부분: local 1..<3 → t0=10/30, t1=1.
    Self.expectClose(quads[0].bottomLeft.x, 10)
    Self.expectClose(quads[0].bottomRight.x, 30)
    // runB 쪽 부분: local 0..<1 → t0=0, t1=10/30.
    Self.expectClose(quads[1].bottomLeft.x, 30)
    Self.expectClose(quads[1].bottomRight.x, 40)
  }

  // MARK: 4 — 삽입 공백에 걸친 구간 → 공백 부분 quad 없음

  @Test func matchSpanningInsertedWhitespaceSkipsWhitespaceQuad() {
    let runA = Self.uniformRun(range: 0..<3, advance: 10) // "foo"
    // index 3은 조립 삽입 공백 (어느 run에도 속하지 않음).
    let runB = Self.uniformRun(range: 4..<7, advance: 10, originX: 40) // "bar"
    let quads = TextRunGeometry.quads(forRange: 0..<7, in: [runA, runB])

    #expect(quads.count == 2)
    Self.expectClose(quads[0].bottomLeft.x, 0)
    Self.expectClose(quads[0].bottomRight.x, 30)
    Self.expectClose(quads[1].bottomLeft.x, 40)
    Self.expectClose(quads[1].bottomRight.x, 70)
  }

  // MARK: 5 — prefix sum 오버로드 ≡ 기본 오버로드 동등성

  @Test func prefixSumOverloadMatchesBaseOverload() {
    let quad = Quad(
      bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 100, y: 0),
      topRight: CGPoint(x: 100, y: 10), topLeft: CGPoint(x: 0, y: 10)
    )
    let advances: [CGFloat] = [5, 10, 15, 20, 25]
    let run = TextRun(range: 0..<5, quad: quad, advances: advances, isInvisible: false)
    var prefixSums: [CGFloat] = [0]
    var running: CGFloat = 0
    for advance in advances {
      running += advance
      prefixSums.append(running)
    }

    let base = TextRunGeometry.partialQuad(of: run, localRange: 1..<4)
    let withPrefix = TextRunGeometry.partialQuad(
      of: run, localRange: 1..<4, prefixSums: prefixSums
    )
    #expect(base == withPrefix)
  }

  // MARK: 6 — intersections: 겹침 run 허용 (lowerBound 단조만 요구)

  @Test func intersectionsAllowOverlappingRuns() {
    let runA = Self.uniformRun(range: 0..<5, advance: 10) // 겹침: 0..<5
    let runB = Self.uniformRun(range: 3..<8, advance: 10, originX: 30) // 겹침: 3..<8
    let intersections = TextRunGeometry.intersections(forRange: 2..<6, in: [runA, runB])

    #expect(intersections.count == 2)
    #expect(intersections[0].runIndex == 0)
    #expect(intersections[0].localRange == 2..<5)
    #expect(intersections[1].runIndex == 1)
    #expect(intersections[1].localRange == 0..<3)
  }
}

// MARK: - 테스트 헬퍼

extension TextRunGeometryTests {
  /// 균일 전진량을 갖는 축 정렬 run을 만든다.
  /// - Parameters:
  ///   - range: run이 차지하는 UTF-16 구간.
  ///   - advance: 유닛당 균일 전진량.
  ///   - originX: quad 좌하단 X 좌표 (기본 0).
  /// - Returns: 합성 run.
  static func uniformRun(range: Range<Int>, advance: CGFloat, originX: CGFloat = 0) -> TextRun {
    let width = advance * CGFloat(range.count)
    let quad = Quad(
      bottomLeft: CGPoint(x: originX, y: 0), bottomRight: CGPoint(x: originX + width, y: 0),
      topRight: CGPoint(x: originX + width, y: 20), topLeft: CGPoint(x: originX, y: 20)
    )
    let advances = Array(repeating: advance, count: range.count)
    return TextRun(range: range, quad: quad, advances: advances, isInvisible: false)
  }

  /// 부동소수 근사 비교.
  /// - Parameters:
  ///   - value: 실제 값.
  ///   - expected: 기대 값.
  static func expectClose(_ value: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.0001) {
    #expect(abs(value - expected) < tolerance)
  }
}
