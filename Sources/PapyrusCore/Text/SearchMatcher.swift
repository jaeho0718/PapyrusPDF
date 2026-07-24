import CoreGraphics
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
      let quads = Self.quads(matchRange: utf16Range, runs: content.runs)
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

  /// run 하나에서 부분 구간 `[localRange.lowerBound, localRange.upperBound)`의 quad를
  /// 보간한다. 테스트 관찰을 위해 분리 노출.
  ///
  /// 절대 거리 대신 전진량 비율(`t0`/`t1`)을 쓴다 — quad 변 길이가 advances 합과 미세히
  /// 어긋나도(조립 반올림) 끝점이 quad 밖으로 나가지 않는다. lerp는 회전·기울임 quad에서도
  /// 그대로 성립한다(축 정렬 가정 없음). 전진량 합이 0 이하인 퇴화 run은 전체 quad로
  /// 폴백한다(0 나눗셈·NaN 없음).
  /// - Parameters:
  ///   - run: 대상 run.
  ///   - localRange: run 로컬 좌표계(0 기반)의 부분 구간.
  /// - Returns: 보간된 부분 quad.
  package static func partialQuad(of run: TextRun, localRange: Range<Int>) -> Quad {
    let advances = run.advances
    let total = advances.reduce(0, +)
    let d0 = advances[0..<localRange.lowerBound].reduce(0, +)
    let d1 = advances[0..<localRange.upperBound].reduce(0, +)
    let t0: CGFloat
    let t1: CGFloat
    if total > 0 {
      t0 = d0 / total
      t1 = d1 / total
    } else {
      t0 = 0
      t1 = 1
    }
    let quad = run.quad
    let bottomAt0 = Self.lerp(quad.bottomLeft, quad.bottomRight, t0)
    let bottomAt1 = Self.lerp(quad.bottomLeft, quad.bottomRight, t1)
    let topAt0 = Self.lerp(quad.topLeft, quad.topRight, t0)
    let topAt1 = Self.lerp(quad.topLeft, quad.topRight, t1)
    return Quad(bottomLeft: bottomAt0, bottomRight: bottomAt1, topRight: topAt1, topLeft: topAt0)
  }

  /// 두 점을 비율 `fraction`으로 선형 보간한다.
  /// - Parameters:
  ///   - start: `fraction == 0`일 때의 점.
  ///   - end: `fraction == 1`일 때의 점.
  ///   - fraction: 보간 비율.
  /// - Returns: 보간된 점.
  private static func lerp(_ start: CGPoint, _ end: CGPoint, _ fraction: CGFloat) -> CGPoint {
    CGPoint(
      x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction
    )
  }
}

// MARK: - quad 교차 탐색

extension SearchMatcher {
  /// 매치 구간과 교차하는 run들을 찾아 부분 quad들을 모은다.
  ///
  /// runs는 `range.lowerBound` 오름차순(M4 조립 순서)이므로 `upperBound >
  /// matchRange.lowerBound`인 첫 run을 이진 탐색으로 찾고, 이후 `lowerBound <
  /// matchRange.upperBound`인 동안 선형 순회한다 — O(log R + k).
  /// - Parameters:
  ///   - matchRange: 매치의 UTF-16 구간.
  ///   - runs: 페이지의 run 목록 (오름차순).
  /// - Returns: 교차한 run별 부분 quad (교차 run이 없으면 빈 배열).
  private static func quads(matchRange: Range<Int>, runs: [TextRun]) -> [Quad] {
    var low = 0
    var high = runs.count
    while low < high {
      let mid = (low + high) / 2
      if runs[mid].range.upperBound <= matchRange.lowerBound {
        low = mid + 1
      } else {
        high = mid
      }
    }

    var result: [Quad] = []
    var index = low
    while index < runs.count, runs[index].range.lowerBound < matchRange.upperBound {
      let run = runs[index]
      let intersectionStart = max(matchRange.lowerBound, run.range.lowerBound)
      let intersectionEnd = min(matchRange.upperBound, run.range.upperBound)
      if intersectionStart < intersectionEnd {
        let localRange =
          (intersectionStart - run.range.lowerBound)..<(intersectionEnd - run.range.lowerBound)
        result.append(Self.partialQuad(of: run, localRange: localRange))
      }
      index += 1
    }
    return result
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
