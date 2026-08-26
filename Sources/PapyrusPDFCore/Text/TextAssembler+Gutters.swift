import CoreGraphics

// 이 파일은 `TextAssembler`의 거터 탐지·좁은 열 병합을 담는다 — 밴드·열·서브밴드 순서
// 조립은 `TextAssembler+Columns.swift` 참조 (파일 길이 분할, 개정 1).

// MARK: - 거터 탐지

extension TextAssembler {
  /// 세그먼트들의 커버리지 스윕으로 거터를 찾는다 (밴드 내부, 폭 ≥ gutterMin, 커버리지 ≤ tolerance).
  static func gutters(in segments: [Segment], tolerance: Int, gutterMin: CGFloat) -> [Gutter] {
    guard !segments.isEmpty else {
      return []
    }
    let bandMinStart = segments.map(\.start).min() ?? 0
    let bandMaxEnd = segments.map(\.end).max() ?? 0

    var events: [(x: CGFloat, delta: Int)] = []
    events.reserveCapacity(segments.count * 2)
    for segment in segments {
      events.append((segment.start, 1))
      events.append((segment.end, -1))
    }
    events.sort { lhs, rhs in
      if lhs.x != rhs.x {
        return lhs.x < rhs.x
      }
      return lhs.delta < rhs.delta // 같은 x면 −1(끝) 먼저.
    }

    var result: [Gutter] = []
    var coverage = 0
    var lowCoverageStart: CGFloat?
    for event in events {
      let wasLow = coverage <= tolerance
      coverage += event.delta
      let isLow = coverage <= tolerance
      if !wasLow, isLow {
        lowCoverageStart = event.x
      } else if wasLow, !isLow, let start = lowCoverageStart {
        Self.appendGutterIfValid(
          start: start, end: event.x, band: (bandMinStart, bandMaxEnd), gutterMin: gutterMin,
          into: &result
        )
        lowCoverageStart = nil
      }
    }
    return result
  }

  /// 세그먼트들의 커버리지 스윕 중 최댓값 — `detectGutters`(개정 3)의 허용치 상한
  /// (`peak / 2`) 계산에 쓰인다. 같은 이벤트·정렬 규칙을 `gutters(in:tolerance:gutterMin:)`
  /// 와 공유한다.
  static func peakCoverage(in segments: [Segment]) -> Int {
    guard !segments.isEmpty else {
      return 0
    }
    var events: [(x: CGFloat, delta: Int)] = []
    events.reserveCapacity(segments.count * 2)
    for segment in segments {
      events.append((segment.start, 1))
      events.append((segment.end, -1))
    }
    events.sort { lhs, rhs in
      if lhs.x != rhs.x {
        return lhs.x < rhs.x
      }
      return lhs.delta < rhs.delta
    }

    var coverage = 0
    var peak = 0
    for event in events {
      coverage += event.delta
      peak = max(peak, coverage)
    }
    return peak
  }

  /// 저커버리지 구간이 유효한 거터 조건(밴드 내부, 폭 ≥ gutterMin)을 만족하면 추가한다.
  private static func appendGutterIfValid(
    start: CGFloat, end: CGFloat, band: (min: CGFloat, max: CGFloat), gutterMin: CGFloat,
    into gutters: inout [Gutter]
  ) {
    guard start > band.min, end < band.max, end - start >= gutterMin else {
      return
    }
    gutters.append(Gutter(start: start, end: end))
  }

  /// 정렬된 배열의 중앙값 (짝수 개면 중간 두 값의 평균). 빈 배열이면 0. `TextAssembler+
  /// Columns.swift`(gutterMin·anchor 계산)도 호출하므로 internal이다.
  static func median(_ sorted: [CGFloat]) -> CGFloat {
    guard !sorted.isEmpty else {
      return 0
    }
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
  }

  /// 정렬된 배열의 q-분위값(`index = clamp(Int((q × (n−1)).rounded()), 0, n−1)`) — 여백
  /// 밖으로 넘친 run 하나에 흔들리지 않는 min/max 대체(개정 2). 빈 배열이면 0.
  /// `TextAssembler+Columns.swift`(ClassBounds 계산)가 호출하므로 internal이다.
  static func percentile(_ sorted: [CGFloat], q quantile: CGFloat) -> CGFloat {
    guard !sorted.isEmpty else {
      return 0
    }
    let index = Int((quantile * CGFloat(sorted.count - 1)).rounded())
    return sorted[min(max(index, 0), sorted.count - 1)]
  }
}

// MARK: - 좁은 열 병합

extension TextAssembler {
  /// 폭 미달 열을 이웃(중심이 가까운 쪽, 동률은 왼쪽)에 흡수 — 사이 거터 제거.
  /// 열이 1개 남거나 폭 미달 열이 없을 때까지 반복한다(매 반복 거터 1개 삭제 — 무한 루프 없음).
  static func mergingNarrowColumns(
    _ gutters: [Gutter], segments: [Segment], minWidth: CGFloat
  ) -> [Gutter] {
    var current = gutters
    while !current.isEmpty {
      let metrics = Self.columnMetrics(gutters: current, segments: segments)
      guard let narrowIndex = metrics.firstIndex(where: { $0.width < minWidth }) else {
        break
      }
      let removeIndex = Self.gutterToMerge(
        narrowColumnIndex: narrowIndex, gutters: current, centers: metrics.map(\.center)
      )
      current.remove(at: removeIndex)
    }
    return current
  }

  /// 열별 (폭, 중심) — 비어 있는 열은 폭 0, 중심은 인접 거터 중점의 평균으로 대체한다.
  private static func columnMetrics(
    gutters: [Gutter], segments: [Segment]
  ) -> [(width: CGFloat, center: CGFloat)] {
    var minStarts = Array(repeating: CGFloat.greatestFiniteMagnitude, count: gutters.count + 1)
    var maxEnds = Array(repeating: -CGFloat.greatestFiniteMagnitude, count: gutters.count + 1)
    for segment in segments {
      let column = Self.columnIndex(of: segment, gutters: gutters)
      minStarts[column] = min(minStarts[column], segment.start)
      maxEnds[column] = max(maxEnds[column], segment.end)
    }
    return (0..<(gutters.count + 1)).map { column in
      guard maxEnds[column] >= minStarts[column] else {
        return (width: 0, center: Self.fallbackCenter(column: column, gutters: gutters))
      }
      let center = (minStarts[column] + maxEnds[column]) / 2
      return (width: maxEnds[column] - minStarts[column], center: center)
    }
  }

  /// 세그먼트가 없는 열의 중심 대체값 — 인접 거터 중점의 평균 (경계 열은 바깥쪽 거터 재사용).
  private static func fallbackCenter(column: Int, gutters: [Gutter]) -> CGFloat {
    let left = column > 0 ? gutters[column - 1].center : gutters[0].center
    let right = column < gutters.count ? gutters[column].center : gutters[gutters.count - 1].center
    return (left + right) / 2
  }

  /// 폭 미달 열을 흡수할 때 삭제할 거터 인덱스를 고른다 — 중심이 가까운 이웃 쪽,
  /// 동률(또는 한쪽 끝 열)은 왼쪽 이웃.
  private static func gutterToMerge(
    narrowColumnIndex: Int, gutters: [Gutter], centers: [CGFloat]
  ) -> Int {
    if narrowColumnIndex == 0 {
      return 0
    }
    if narrowColumnIndex == gutters.count {
      return gutters.count - 1
    }
    let narrowCenter = centers[narrowColumnIndex]
    let leftDistance = abs(narrowCenter - centers[narrowColumnIndex - 1])
    let rightDistance = abs(centers[narrowColumnIndex + 1] - narrowCenter)
    return rightDistance < leftDistance ? narrowColumnIndex : narrowColumnIndex - 1
  }
}

// MARK: - 세그먼트 정렬 동률 키

extension TextAssembler.Segment {
  /// 첫 run의 방출 인덱스 — 같은 라인 안 세그먼트 정렬의 3차 동률 키 (결정성, 설계 §4).
  var firstOriginalIndex: Int {
    self.entries.first?.originalIndex ?? 0
  }

  /// 같은 라인 안 정렬 순서 — `(start, firstOriginalIndex)` 사전식 비교.
  /// - Parameter other: 비교 대상 세그먼트.
  /// - Returns: `self`가 앞서면 `true`.
  func precedesInLine(_ other: Self) -> Bool {
    (self.start, self.firstOriginalIndex) < (other.start, other.firstOriginalIndex)
  }
}
