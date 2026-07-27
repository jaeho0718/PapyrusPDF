import Foundation

/// 페이지 문자열 매칭 + quad 보간 (순수 함수 — ARCHITECTURE 131행 알고리즘의 구현체).
///
/// 액터·I/O 없음, 입출력 전부 Sendable 값 타입 — 호출측 태스크에서 그대로 실행된다.
package enum SearchMatcher {
  /// 페이지 하나에서 매치를 전부 찾는다 (페이지당 캡 적용).
  ///
  /// 원문 문자열 위에서 `range(of:options:range:)`를 반복 호출한다 — 대소문자·발음
  /// 구별 부호 폴딩으로 매치 텍스트 길이가 변해도 반환 `range`는 항상 원문 좌표계다.
  /// 매치는 비겹침(non-overlapping)이며, 빈(퇴화) range는 커서를 1유닛 전진시켜
  /// 무한루프를 방어한다.
  /// - Parameters:
  ///   - content: 매칭 대상 페이지 텍스트 스냅숏.
  ///   - query: 검색어 (빈 문자열이면 빈 결과).
  ///   - options: 검색 옵션.
  /// - Returns: 위치 오름차순 매치 목록 (최대 `CoreLimits.maxSearchMatchesPerPage`개).
  package static func matches(
    in content: PageTextContent, query: String, options: SearchOptions
  ) -> [SearchResult] {
    guard !query.isEmpty else {
      return []
    }
    let string = content.string
    var compareOptions: String.CompareOptions = []
    if !options.caseSensitive {
      compareOptions.insert(.caseInsensitive)
    }
    if !options.diacriticSensitive {
      compareOptions.insert(.diacriticInsensitive)
    }

    var results: [SearchResult] = []
    var cursor = string.startIndex
    while results.count < CoreLimits.maxSearchMatchesPerPage, cursor < string.endIndex,
      let found = string.range(
        of: query, options: compareOptions, range: cursor..<string.endIndex
      ) {
      guard found.lowerBound < found.upperBound else {
        // 퇴화(빈) range — 도달 불가 방어선 (§3.2 핵심 불변식: 무한루프 없음).
        cursor = string.index(after: cursor)
        continue
      }
      let utf16Range =
        found.lowerBound.utf16Offset(in: string)..<found.upperBound.utf16Offset(in: string)
      let quads = TextRunGeometry.quads(forRange: utf16Range, in: content.runs)
      let (snippetText, snippetMatchRange) = Self.snippet(matchRange: utf16Range, in: string)
      results.append(
        SearchResult(
          pageIndex: content.pageIndex, range: utf16Range, quads: quads, snippet: snippetText,
          snippetMatchRange: snippetMatchRange
        )
      )
      cursor = found.upperBound // 비겹침 — 다음 탐색은 이번 매치 끝부터.
    }
    return results
  }
}

// MARK: - snippet 조립

extension SearchMatcher {
  /// 문맥 확장 반경 (매치 전후 각 UTF-16 유닛 수).
  private static let snippetContextRadius = 40

  /// 매치 전후 문맥을 발췌한다.
  ///
  /// 매치 전후 각 `snippetContextRadius` UTF-16 유닛으로 확장한 뒤 문자(Character)
  /// 경계로 안쪽 스냅하고, 개행·탭을 공백 1개로 치환한다. 치환은 항상 1:1(길이 불변)이므로
  /// `snippetMatchRange`는 재계산 없이 오프셋 차감만으로 정확하다.
  /// - Parameters:
  ///   - matchRange: 매치의 UTF-16 구간 (원문 좌표계).
  ///   - string: 페이지 문자열.
  /// - Returns: 발췌 문자열과 그 안에서 매치가 차지하는 UTF-16 구간.
  private static func snippet(
    matchRange: Range<Int>, in string: String
  ) -> (snippet: String, matchRange: Range<Int>) {
    let utf16Count = string.utf16.count
    let rawStart = max(0, matchRange.lowerBound - Self.snippetContextRadius)
    let rawEnd = min(utf16Count, matchRange.upperBound + Self.snippetContextRadius)
    let startIndex = Self.snapInward(utf16Offset: rawStart, in: string, movingForward: true)
    let endIndex = Self.snapInward(utf16Offset: rawEnd, in: string, movingForward: false)
    let snippetStartOffset = startIndex.utf16Offset(in: string)

    var folded = ""
    for character in string[startIndex..<endIndex] {
      switch character {
      case "\n", "\r", "\t":
        folded.append(" ")
      default:
        folded.append(character)
      }
    }

    let matchStartInSnippet = matchRange.lowerBound - snippetStartOffset
    let matchLength = matchRange.upperBound - matchRange.lowerBound
    return (folded, matchStartInSnippet..<(matchStartInSnippet + matchLength))
  }

  /// UTF-16 오프셋을 문자(Character) 경계로 안쪽 스냅한다 (그레이프 클러스터 절단 방지).
  /// - Parameters:
  ///   - offset: 스냅할 UTF-16 오프셋.
  ///   - string: 대상 문자열.
  ///   - movingForward: `true`면 문자열 안쪽(앞)으로, `false`면 안쪽(뒤)으로 스냅한다.
  /// - Returns: 스냅된 문자 인덱스.
  private static func snapInward(
    utf16Offset offset: Int, in string: String, movingForward: Bool
  ) -> String.Index {
    let utf16View = string.utf16
    var utf16Index = utf16View.index(utf16View.startIndex, offsetBy: offset)
    while String.Index(utf16Index, within: string) == nil {
      if movingForward {
        utf16Index = utf16View.index(after: utf16Index)
      } else {
        utf16Index = utf16View.index(before: utf16Index)
      }
    }
    return String.Index(utf16Index, within: string)
      ?? (movingForward ? string.endIndex : string.startIndex)
  }
}
