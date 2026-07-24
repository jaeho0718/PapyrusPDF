import CoreGraphics
@testable import PapyrusCore
import Testing

/// ``PageContentSanitizer``의 위생 규칙(설계 §1.7 1-7)을 검증한다 (설계 §5.3).
struct PageContentSanitizerTests {
  // MARK: 깨끗한 입력 → fast path (원본과 동일한 값 반환)

  @Test func cleanInputReturnsEquivalentContent() {
    let run = Self.uniformRun(range: 0..<3, originX: 0)
    let content = PageTextContent(pageIndex: 2, string: "abc", runs: [run])
    let sanitized = PageContentSanitizer.sanitize(content, expectedPageIndex: 2)
    #expect(sanitized == content)
  }

  // MARK: 규칙 3 — range 이탈 클램프 + advances 절단

  @Test func rangeOutOfBoundsClampsAndTrimsAdvances() {
    let quad = Quad(
      bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 10, y: 0),
      topRight: CGPoint(x: 10, y: 10), topLeft: CGPoint(x: 0, y: 10)
    )
    // string 길이는 3인데 range가 -2..<5로 이탈 — advances 7개(원래 range.count와 일치).
    let run = TextRun(
      range: -2..<5, quad: quad, advances: [1, 2, 3, 4, 5, 6, 7], isInvisible: false
    )
    let content = PageTextContent(pageIndex: 0, string: "abc", runs: [run])
    let sanitized = PageContentSanitizer.sanitize(content, expectedPageIndex: 0)

    #expect(sanitized.runs.count == 1)
    let clamped = sanitized.runs[0]
    #expect(clamped.range == 0..<3)
    // lowerDelta = 0 - (-2) = 2, count = 3 → advances[2..<5] = [3, 4, 5].
    #expect(clamped.advances == [3, 4, 5])
  }

  // MARK: 규칙 3 — 클램프 후 빈 구간이면 run 폐기

  @Test func emptyRangeAfterClampDiscardsRun() {
    let quad = Quad(
      bottomLeft: .zero, bottomRight: CGPoint(x: 10, y: 0), topRight: CGPoint(x: 10, y: 10),
      topLeft: CGPoint(x: 0, y: 10)
    )
    // string 길이 3인데 range가 완전히 밖(5..<8) — 클램프하면 3..<3(빈 구간).
    let run = TextRun(range: 5..<8, quad: quad, advances: [1, 1, 1], isInvisible: false)
    let content = PageTextContent(pageIndex: 0, string: "abc", runs: [run])
    let sanitized = PageContentSanitizer.sanitize(content, expectedPageIndex: 0)
    #expect(sanitized.runs.isEmpty)
  }

  // MARK: 규칙 2 — 비유한 quad 좌표 → run 폐기

  @Test func nonFiniteQuadCoordinateDiscardsRun() {
    let badQuad = Quad(
      bottomLeft: CGPoint(x: CGFloat.nan, y: 0), bottomRight: CGPoint(x: 10, y: 0),
      topRight: CGPoint(x: 10, y: 10), topLeft: CGPoint(x: 0, y: 10)
    )
    let goodRun = Self.uniformRun(range: 0..<1, originX: 0)
    let badRun = TextRun(range: 1..<2, quad: badQuad, advances: [1], isInvisible: false)
    let content = PageTextContent(pageIndex: 0, string: "ab", runs: [goodRun, badRun])
    let sanitized = PageContentSanitizer.sanitize(content, expectedPageIndex: 0)
    #expect(sanitized.runs.count == 1)
    #expect(sanitized.runs[0].range == 0..<1)
  }

  // MARK: 규칙 4 — advances 개수 불일치 → 균등 교체

  @Test func advanceCountMismatchReplacesWithUniform() {
    let quad = Quad(
      bottomLeft: .zero, bottomRight: CGPoint(x: 10, y: 0), topRight: CGPoint(x: 10, y: 10),
      topLeft: CGPoint(x: 0, y: 10)
    )
    let run = TextRun(range: 0..<3, quad: quad, advances: [1, 2], isInvisible: false)
    let content = PageTextContent(pageIndex: 0, string: "abc", runs: [run])
    let sanitized = PageContentSanitizer.sanitize(content, expectedPageIndex: 0)
    #expect(sanitized.runs.count == 1)
    #expect(sanitized.runs[0].advances == [1, 1, 1])
  }

  // MARK: 규칙 4 — 음수·NaN advance → 균등 교체

  @Test func negativeOrNonFiniteAdvanceReplacesWithUniform() {
    let quad = Quad(
      bottomLeft: .zero, bottomRight: CGPoint(x: 10, y: 0), topRight: CGPoint(x: 10, y: 10),
      topLeft: CGPoint(x: 0, y: 10)
    )
    let run = TextRun(range: 0..<3, quad: quad, advances: [1, -1, .nan], isInvisible: false)
    let content = PageTextContent(pageIndex: 0, string: "abc", runs: [run])
    let sanitized = PageContentSanitizer.sanitize(content, expectedPageIndex: 0)
    #expect(sanitized.runs[0].advances == [1, 1, 1])
  }

  // MARK: 규칙 1 — 문자열 캡 절단 (문자 경계 스냅, 써로게이트 걸침)

  @Test func stringLongerThanCapIsTruncatedAtCharacterBoundary() {
    let cap = CoreLimits.maxProviderStringUTF16
    // 서로게이트 쌍(이모지, 2 UTF-16 유닛)이 정확히 캡 경계에 걸치도록 구성한다.
    let filler = String(repeating: "a", count: cap - 1)
    let text = filler + "😀tail"
    let content = PageTextContent(pageIndex: 0, string: text, runs: [])
    let sanitized = PageContentSanitizer.sanitize(content, expectedPageIndex: 0)

    #expect(sanitized.string.utf16.count <= cap)
    // 캡 지점이 이모지 서로게이트 쌍 중간이므로 안쪽(이모지 제외)으로 스냅되어야 한다.
    #expect(sanitized.string == filler)
  }

  // MARK: 규칙 5 — 글리프 총량 캡 초과 → 이후 run 전부 폐기(prefix 유지)

  @Test func glyphCountExceedingCapDiscardsSubsequentRuns() {
    let cap = CoreLimits.maxGlyphsPerPage
    let text = String(repeating: "a", count: cap + 10)
    let runA = Self.uniformRun(range: 0..<cap, originX: 0)
    let runB = Self.uniformRun(range: cap..<(cap + 10), originX: 100)
    let content = PageTextContent(pageIndex: 0, string: text, runs: [runA, runB])
    let sanitized = PageContentSanitizer.sanitize(content, expectedPageIndex: 0)

    #expect(sanitized.runs.count == 1)
    #expect(sanitized.runs[0].range == 0..<cap)
  }

  // MARK: 규칙 6 — 비정렬 정렬 (동률 결정성)

  @Test func outOfOrderRunsAreSortedDeterministically() {
    let runB = Self.uniformRun(range: 3..<6, originX: 30)
    let runA = Self.uniformRun(range: 0..<3, originX: 0)
    let content = PageTextContent(pageIndex: 0, string: "foobar", runs: [runB, runA])
    let sanitized = PageContentSanitizer.sanitize(content, expectedPageIndex: 0)

    #expect(sanitized.runs.count == 2)
    #expect(sanitized.runs[0].range == 0..<3)
    #expect(sanitized.runs[1].range == 3..<6)
  }

  /// 같은 `lowerBound`, 다른 `upperBound`를 갖는 겹침 run들의 동률 처리를 검증한다
  /// (설계 §1.7 규칙 6 — `(lowerBound, upperBound, 원래 인덱스)` 3중 키). 원본 배열
  /// 순서(runY가 runZ보다 앞)는 upperBound 오름차순(runZ의 2가 runY의 4보다 작다)과
  /// 반대라, upperBound를 동률 키로 쓰지 않고 원래 인덱스만 쓰면 순서가 뒤바뀐다 —
  /// 그 회귀를 잡는 케이스.
  @Test func overlappingSameLowerBoundRunsAreSortedByUpperBoundThenOriginalIndex() {
    let runX = Self.uniformRun(range: 5..<9, originX: 50)
    let runY = Self.uniformRun(range: 0..<4, originX: 0)
    let runZ = Self.uniformRun(range: 0..<2, originX: 0)
    let content = PageTextContent(
      pageIndex: 0, string: "abcdefghi", runs: [runX, runY, runZ]
    )
    let sanitized = PageContentSanitizer.sanitize(content, expectedPageIndex: 0)

    #expect(sanitized.runs.count == 3)
    #expect(sanitized.runs[0].range == 0..<2) // runZ — 같은 lowerBound 중 upperBound 최소.
    #expect(sanitized.runs[1].range == 0..<4) // runY — 같은 lowerBound, upperBound 다음.
    #expect(sanitized.runs[2].range == 5..<9) // runX — lowerBound 최대.
  }

  // MARK: 규칙 7 — pageIndex 재기입

  @Test func pageIndexIsRewrittenToExpectedValue() {
    let content = PageTextContent(pageIndex: 99, string: "abc", runs: [])
    let sanitized = PageContentSanitizer.sanitize(content, expectedPageIndex: 3)
    #expect(sanitized.pageIndex == 3)
  }

  // MARK: run 간 겹침은 폐기하지 않는다

  @Test func overlappingRunsAreKept() {
    let runA = Self.uniformRun(range: 0..<5, originX: 0)
    let runB = Self.uniformRun(range: 3..<8, originX: 30)
    let content = PageTextContent(pageIndex: 0, string: "abcdefgh", runs: [runA, runB])
    let sanitized = PageContentSanitizer.sanitize(content, expectedPageIndex: 0)
    #expect(sanitized.runs.count == 2)
  }
}

// MARK: - 테스트 헬퍼

extension PageContentSanitizerTests {
  /// 균일 전진량(1)을 갖는 축 정렬 run을 만든다.
  /// - Parameters:
  ///   - range: run이 차지하는 UTF-16 구간.
  ///   - originX: quad 좌하단 X 좌표.
  /// - Returns: 합성 run.
  static func uniformRun(range: Range<Int>, originX: CGFloat) -> TextRun {
    let width = CGFloat(range.count)
    let quad = Quad(
      bottomLeft: CGPoint(x: originX, y: 0), bottomRight: CGPoint(x: originX + width, y: 0),
      topRight: CGPoint(x: originX + width, y: 10), topLeft: CGPoint(x: originX, y: 10)
    )
    return TextRun.uniform(range: range, quad: quad)
  }
}
