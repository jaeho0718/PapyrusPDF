import CoreGraphics
@testable import PapyrusPDFCore
import Testing

/// ``SearchMatcher``의 매칭·snippet 조립을 검증한다 (설계 §5.1 1-4, 9-10).
///
/// quad 보간 테스트(5-8)는 `TextRunGeometry`로 승격 추출되어
/// `TextRunGeometryTests`로 이동했다 (M9 §4-2).
struct SearchMatcherTests {
  // MARK: 1 — 단일 run 단일 매치 (range·quad 수치 검증)

  @Test func singleRunSingleMatchProducesExactRangeAndQuad() {
    let run = Self.uniformRun(range: 0..<11, advance: 10)
    let content = PageTextContent(pageIndex: 0, string: "hello world", runs: [run])
    let results = SearchMatcher.matches(in: content, query: "world", options: SearchOptions())

    #expect(results.count == 1)
    let result = results[0]
    #expect(result.pageIndex == 0)
    #expect(result.range == 6..<11)
    #expect(result.quads.count == 1)
    let quad = result.quads[0]
    // t0 = 60/110, t1 = 110/110 = 1.
    Self.expectClose(quad.bottomLeft.x, 60)
    Self.expectClose(quad.bottomRight.x, 110)
    Self.expectClose(quad.topLeft.x, 60)
    Self.expectClose(quad.topRight.x, 110)
  }

  // MARK: 2 — 대소문자 무시(기본) / caseSensitive true면 불일치

  @Test func caseInsensitiveByDefaultAndSensitiveWhenRequested() {
    let run = Self.uniformRun(range: 0..<5, advance: 10)
    let content = PageTextContent(pageIndex: 0, string: "Hello", runs: [run])

    let insensitive = SearchMatcher.matches(
      in: content, query: "hello", options: SearchOptions()
    )
    #expect(insensitive.count == 1)

    let sensitive = SearchMatcher.matches(
      in: content, query: "hello", options: SearchOptions(caseSensitive: true)
    )
    #expect(sensitive.isEmpty)
  }

  // MARK: 3 — 디아크리틱 무시(기본): 원문 오프셋 좌표계 유지

  @Test func diacriticInsensitiveMatchesPrecomposedCharacter() {
    // "café" (precomposed é = U+00E9, 단일 UTF-16 유닛) — 4 유닛.
    let text = "caf\u{00E9}"
    let run = Self.uniformRun(range: 0..<4, advance: 10)
    let content = PageTextContent(pageIndex: 0, string: text, runs: [run])
    let results = SearchMatcher.matches(in: content, query: "cafe", options: SearchOptions())
    #expect(results.count == 1)
    #expect(results[0].range == 0..<4)
  }

  @Test func diacriticInsensitiveMatchesDecomposedCharacter() {
    // "cafe" + combining acute (U+0301) — "e" + 결합 문자 = 5 UTF-16 유닛, 회귀 방어.
    let text = "cafe\u{0301}"
    let run = Self.uniformRun(range: 0..<5, advance: 10)
    let content = PageTextContent(pageIndex: 0, string: text, runs: [run])
    let results = SearchMatcher.matches(in: content, query: "cafe", options: SearchOptions())
    #expect(results.count == 1)
    // 원문 좌표계 — 결합 문자를 포함한 전체 그레이프 클러스터까지 매치되어야 한다.
    #expect(results[0].range == 0..<5)
  }

  // MARK: 4 — 비겹침 매치

  @Test func matchesAreNonOverlapping() {
    let run = Self.uniformRun(range: 0..<3, advance: 10)
    let content = PageTextContent(pageIndex: 0, string: "aaa", runs: [run])
    let results = SearchMatcher.matches(in: content, query: "aa", options: SearchOptions())
    #expect(results.count == 1)
    #expect(results[0].range == 0..<2)
  }

  // MARK: 9 — 페이지 매치 캡

  @Test func matchesAreCappedAtMaxPerPage() {
    let count = CoreLimits.maxSearchMatchesPerPage + 50
    let text = String(repeating: "a", count: count)
    let run = Self.uniformRun(range: 0..<count, advance: 1)
    let content = PageTextContent(pageIndex: 0, string: text, runs: [run])
    let results = SearchMatcher.matches(in: content, query: "a", options: SearchOptions())
    #expect(results.count == CoreLimits.maxSearchMatchesPerPage)
  }

  // MARK: 10 — snippet: 문자 경계 스냅(이모지) + 개행 치환 + snippetMatchRange 정확성

  @Test func snippetSnapsToCharacterBoundariesAndFoldsNewlines() {
    let leadingEmoji = String(repeating: "😀", count: 39) // 78 UTF-16 유닛.
    let prefix = leadingEmoji + "X" // 79 UTF-16 유닛 — 반경(40) 절단이 서로게이트 쌍 중간에 걸림.
    let text = prefix + "needle\ntail text long enough to fill the trailing context radius"
    let content = PageTextContent(pageIndex: 0, string: text, runs: [])
    let results = SearchMatcher.matches(in: content, query: "needle", options: SearchOptions())

    #expect(results.count == 1)
    let result = results[0]
    #expect(result.range.lowerBound == prefix.utf16.count)

    let snippetUTF16 = Array(result.snippet.utf16)
    #expect(result.snippetMatchRange.upperBound <= snippetUTF16.count)
    let matchedSlice = snippetUTF16[result.snippetMatchRange]
    #expect(String(decoding: matchedSlice, as: UTF16.self) == "needle")
    #expect(!result.snippet.contains("\n"))
  }
}

// MARK: - 테스트 헬퍼

extension SearchMatcherTests {
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
