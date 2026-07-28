import Foundation

/// 문자·단어 경계 유틸 (순수 함수).
package enum TextBoundary {
  /// UTF-16 오프셋을 가장 가까운 Character(그레이프 클러스터) 경계로 스냅한다.
  ///
  /// 경계 위 오프셋은 그대로 반환. 클러스터 내부면 양끝 중 가까운 쪽(동률은 뒤쪽).
  /// 범위 밖 오프셋은 `0...utf16Count`로 클램프.
  /// - Parameters:
  ///   - offset: 스냅할 UTF-16 오프셋.
  ///   - string: 대상 문자열.
  /// - Returns: Character 경계로 스냅된 UTF-16 오프셋.
  package static func snapToCharacterBoundary(_ offset: Int, in string: String) -> Int {
    let utf16View = string.utf16
    let utf16Count = utf16View.count
    let clamped = min(max(offset, 0), utf16Count)
    let index = utf16View.index(utf16View.startIndex, offsetBy: clamped)
    guard String.Index(index, within: string) == nil else {
      return clamped
    }

    var before = index
    while before > utf16View.startIndex, String.Index(before, within: string) == nil {
      before = utf16View.index(before: before)
    }
    var after = index
    while after < utf16View.endIndex, String.Index(after, within: string) == nil {
      after = utf16View.index(after: after)
    }
    let beforeOffset = utf16View.distance(from: utf16View.startIndex, to: before)
    let afterOffset = utf16View.distance(from: utf16View.startIndex, to: after)
    return (clamped - beforeOffset) < (afterOffset - clamped) ? beforeOffset : afterOffset
  }

  /// 오프셋 주변 단어의 UTF-16 구간 (`enumerateSubstrings(.byWords)` 기반).
  ///
  /// `window` 구간 안에서만 탐색한다 (호출자는 라인 구간 권장 — 전체 문자열 열거 방지).
  /// 오프셋이 단어 위면 그 단어, 공백 위면 앞뒤 단어 중 경계가 가까운 쪽
  /// (동률은 뒤 단어). 창 안에 단어가 없으면 nil.
  /// - Parameters:
  ///   - offset: 기준 UTF-16 오프셋.
  ///   - string: 대상 문자열.
  ///   - window: 탐색을 제한할 UTF-16 구간.
  /// - Returns: 단어 구간, 창 안에 단어가 없으면 `nil`.
  package static func wordRange(
    around offset: Int, in string: String, window: Range<Int>
  ) -> Range<Int>? {
    let utf16View = string.utf16
    let utf16Count = utf16View.count
    let lower = min(max(window.lowerBound, 0), utf16Count)
    let upper = min(max(window.upperBound, lower), utf16Count)
    guard lower < upper else {
      return nil
    }
    let lowerIndex = utf16View.index(utf16View.startIndex, offsetBy: lower)
    let upperIndex = utf16View.index(utf16View.startIndex, offsetBy: upper)
    guard
      let windowLower = String.Index(lowerIndex, within: string)
        ?? Self.nearestBoundary(lowerIndex, in: string, forward: true),
      let windowUpper = String.Index(upperIndex, within: string)
        ?? Self.nearestBoundary(upperIndex, in: string, forward: false),
      windowLower < windowUpper
    else {
      return nil
    }

    var candidates: [Range<Int>] = []
    string.enumerateSubstrings(
      in: windowLower..<windowUpper, options: [.byWords, .substringNotRequired]
    ) { _, subRange, _, _ in
      let candidateLower = subRange.lowerBound.utf16Offset(in: string)
      let candidateUpper = subRange.upperBound.utf16Offset(in: string)
      candidates.append(candidateLower..<candidateUpper)
    }

    guard !candidates.isEmpty else {
      return nil
    }
    if let hit = candidates.first(where: { $0.contains(offset) }) {
      return hit
    }

    var best: Range<Int>?
    var bestDistance = Int.max
    for candidate in candidates {
      let distance = offset < candidate.lowerBound
        ? candidate.lowerBound - offset : offset - candidate.upperBound
      if distance <= bestDistance {
        bestDistance = distance
        best = candidate
      }
    }
    return best
  }

  /// 인덱스가 문자 경계가 아니면 인접 경계로 스냅한다 (`wordRange`의 창 스냅 전용).
  /// - Parameters:
  ///   - index: 스냅할 UTF-16 인덱스.
  ///   - string: 대상 문자열.
  ///   - forward: `true`면 안쪽(뒤)으로, `false`면 안쪽(앞)으로 스냅한다.
  /// - Returns: 스냅된 문자 인덱스.
  private static func nearestBoundary(
    _ index: String.UTF16View.Index, in string: String, forward: Bool
  ) -> String.Index? {
    let utf16View = string.utf16
    var cursor = index
    while forward ? cursor < utf16View.endIndex : cursor > utf16View.startIndex {
      if let snapped = String.Index(cursor, within: string) {
        return snapped
      }
      cursor = forward ? utf16View.index(after: cursor) : utf16View.index(before: cursor)
    }
    return String.Index(cursor, within: string)
  }
}
