import CoreGraphics
import Foundation

// 이 파일은 `TextAssembler`의 다단 읽기 순서(거터 → 구분선/넘침 분류 → 열 → 행)를 담는다 —
// y 클러스터링·문자열 조립은 `TextAssembler.swift`, 거터 탐지·좁은 열 병합은
// `TextAssembler+Gutters.swift` 참조.

extension TextAssembler {
  // MARK: - 조정 상수 (저널마다 거터·폭이 달라 상수로 노출한다)

  /// run 사이 공백 삽입 허용치 (× min effFontSize). TeX 최소 단어 간격(0.167em)보다 작게.
  static let spaceGapFactor: CGFloat = 0.15
  /// 세그먼트 분할·거터 최소 폭 (× effFontSize). 단어 간격(≤0.5em)과 거터(≥1em) 사이.
  static let columnGapFactor: CGFloat = 1.0
  /// 구분선이 되는 "전폭" 세그먼트의 최소 폭 (× 클래스 폭).
  static let wideLineFraction: CGFloat = 0.6
  /// 열로 인정하는 최소 폭 (× 클래스 폭). 미달 열은 이웃에 흡수된다(수식 번호 열 등).
  static let minColumnFraction: CGFloat = 0.2
  /// "가장자리에 붙어 있다"의 허용치 (× 클래스 세그먼트 fontSize 중앙값) — 구분선/넘침
  /// (overrun) 판정에 쓰인다(개정 2).
  static let edgeAnchorFactor: CGFloat = 3.0
  /// 폭 건전성 게이트 — 라인별 run 폭 합/스팬 비율의 중앙값이 이 미만이면 폭 추출이
  /// 깨진 것으로 보고 열 정렬을 건너뛴다(개정 4).
  static let advanceSanityFraction: CGFloat = 0.5

  /// 라인의 일부 — 베이스라인 방향으로 연속(간격 ≤ columnGapFactor·em)인 run 묶음.
  struct Segment {
    /// 소속 y 라인 인덱스 (clusterLines 출력 순서 = 상→하).
    let lineIndex: Int
    /// 방향 투영 오름차순 run들.
    let entries: [RunEntry]
    /// 방향 투영 시작·끝 (origin 투영, 끝 = 시작 + Σadvances).
    let start: CGFloat
    let end: CGFloat
    /// 대표 폰트 크기 (run effectiveFontSize 최댓값).
    let fontSize: CGFloat

    /// 방향 투영 폭 (`end - start`).
    var width: CGFloat { self.end - self.start }
    /// 방향 투영 중점.
    var center: CGFloat { (self.start + self.end) / 2 }
  }

  /// 거터 — 밴드 안에서 커버리지가 허용치 이하인 방향 투영 구간.
  struct Gutter {
    let start: CGFloat
    let end: CGFloat

    /// 방향 투영 중점.
    var center: CGFloat { (self.start + self.end) / 2 }
  }

  /// 클래스 전체 기준값 — 전폭·넘침(overrun) 판정에 쓰인다(개정 2). `orderByColumns`에서
  /// 한 번 계산해 하위로 전달한다.
  struct ClassBounds {
    /// 클래스 세그먼트 start의 5퍼센타일(여백 밖으로 넘친 run 하나에 흔들리지 않는다).
    let minStart: CGFloat
    /// 클래스 세그먼트 end의 95퍼센타일.
    let maxEnd: CGFloat
    /// 클래스 폭 (`maxEnd - minStart`).
    let extent: CGFloat
    /// "가장자리에 붙어 있다"의 허용치 (`edgeAnchorFactor × 세그먼트 fontSize 중앙값`).
    let anchor: CGFloat
  }
}

// MARK: - 다단 읽기 순서 (개정 2 — 클래스 단위 거터, 전폭 사전분할 없음)

extension TextAssembler {
  /// y 순서 라인들을 다단 읽기 순서(열 → 행, 구분선 라인이 그 사이를 가른다)로
  /// 재배열한다 (클래스 하나 단위, 순수 함수). 라인 1개 이하·폭 0(또는 비유한)이면
  /// 입력 그대로 반환한다.
  /// - Parameter lines: `clusterLines` 출력 (상→하, 각 라인은 방향 투영 오름차순).
  /// - Returns: 구분선(y 순서) → 열(좌→우) → 행(상→하) 순서로 재배열된 라인들.
  static func orderByColumns(_ lines: [[RunEntry]]) -> [[RunEntry]] {
    guard lines.count > 1 else {
      return lines
    }

    let segmentedLines = lines.enumerated().map { index, line in
      Self.segments(of: line, lineIndex: index)
    }
    guard Self.hasReliableAdvances(lines) else {
      return lines
    }
    let allSegments = segmentedLines.flatMap { $0 }
    guard !allSegments.isEmpty else {
      return lines
    }
    let minStart = Self.percentile(allSegments.map(\.start).sorted(), q: 0.05)
    let maxEnd = Self.percentile(allSegments.map(\.end).sorted(), q: 0.95)
    let extent = maxEnd - minStart
    guard extent > 0, extent.isFinite else {
      return lines
    }
    let anchor = Self.edgeAnchorFactor * Self.median(allSegments.map(\.fontSize).sorted())
    let bounds = ClassBounds(minStart: minStart, maxEnd: maxEnd, extent: extent, anchor: anchor)

    return Self.orderClass(segmentedLines, bounds: bounds)
  }

  /// 폭 건전성 게이트(개정 4 보정) — 라인별 (run 폭 합/스팬) 비율의 25퍼센타일이
  /// `advanceSanityFraction` 미만이면 폭 추출이 깨진 것으로 본다(스팬 0인 라인은 제외).
  private static func hasReliableAdvances(_ lines: [[RunEntry]]) -> Bool {
    let fills = lines.compactMap { line -> CGFloat? in
      let projections = line.map { Self.projection(of: $0.run) }
      guard
        let minStart = projections.map(\.start).min(), let maxEnd = projections.map(\.end).max()
      else {
        return nil
      }
      let span = maxEnd - minStart
      guard span > 0 else {
        return nil
      }
      let totalAdvance = projections.reduce(CGFloat(0)) { $0 + ($1.end - $1.start) }
      return totalAdvance / span
    }
    guard !fills.isEmpty else {
      return true
    }
    return Self.percentile(fills.sorted(), q: 0.25) >= Self.advanceSanityFraction
  }

  /// 클래스 전체에서 거터를 한 번 찾고(전폭 제외 커버리지, 허용치 상승 반복), 좁은 열을
  /// 병합한다. 최종 거터가 없으면 전 라인을 y 순서(세그먼트 재결합)로 반환한다.
  private static func orderClass(
    _ segmentedLines: [[Segment]], bounds: ClassBounds
  ) -> [[RunEntry]] {
    let allSegments = segmentedLines.flatMap { $0 }
    let gutterMin = Self.columnGapFactor * Self.median(allSegments.map(\.fontSize).sorted())
    let coverage = allSegments.filter { !Self.isWide($0, bounds: bounds) }
    let rawGutters = Self.detectGutters(in: coverage, gutterMin: gutterMin)
    guard !rawGutters.isEmpty else {
      return segmentedLines.map(Self.rejoinedLine)
    }

    let mergeInput = allSegments.filter {
      !Self.isWide($0, bounds: bounds) && !Self.isBridge($0, gutters: rawGutters)
    }
    let minWidth = Self.minColumnFraction * bounds.extent
    let gutters = Self.mergingNarrowColumns(rawGutters, segments: mergeInput, minWidth: minWidth)
    guard !gutters.isEmpty else {
      return segmentedLines.map(Self.rejoinedLine)
    }

    let columnMinStarts = Self.columnMinStarts(
      segments: allSegments, gutters: gutters, bounds: bounds
    )
    return Self.orderSeparatingGroups(
      segmentedLines, gutters: gutters, columnMinStarts: columnMinStarts, bounds: bounds
    )
  }

  /// 세그먼트 전폭 판정 — 순수 폭 조건(예외 없음, 가장자리 예외는 구분선/넘침 분류로
  /// 옮겨졌다).
  private static func isWide(_ segment: Segment, bounds: ClassBounds) -> Bool {
    segment.width >= Self.wideLineFraction * bounds.extent
  }

  /// 거터 탐지 — 허용치 상승 반복(0 → 1 → 2 → 4 → … → peak/2, 개정 3). 라인 수 기반
  /// 허용치는 다단 페이지에서 과소평가되므로 커버리지 최댓값의 절반을 상한으로 쓴다.
  /// 첫 성공을 취한다.
  private static func detectGutters(in coverage: [Segment], gutterMin: CGFloat) -> [Gutter] {
    let cap = max(1, Self.peakCoverage(in: coverage) / 2)
    var tolerance = 0
    var raw = Self.gutters(in: coverage, tolerance: tolerance, gutterMin: gutterMin)
    while raw.isEmpty, tolerance < cap {
      tolerance = min(max(1, tolerance * 2), cap)
      raw = Self.gutters(in: coverage, tolerance: tolerance, gutterMin: gutterMin)
    }
    return raw
  }
}

// MARK: - 구분선·넘침(overrun) 분류 → 밴드 그룹 → 열 (개정 2 §6-7)

extension TextAssembler {
  /// 클래스 라인을 separating(구분선 세그먼트 포함) 플래그가 같은 연속 구간으로 묶어
  /// separating 그룹은 y 순서(재결합), 나머지는 열 순서로 출력한다.
  private static func orderSeparatingGroups(
    _ segmentedLines: [[Segment]], gutters: [Gutter], columnMinStarts: [CGFloat?],
    bounds: ClassBounds
  ) -> [[RunEntry]] {
    var result: [[RunEntry]] = []
    var groupStart = 0
    while groupStart < segmentedLines.count {
      let isSeparating = Self.lineIsSeparating(
        segmentedLines[groupStart], gutters: gutters, columnMinStarts: columnMinStarts,
        bounds: bounds
      )
      var groupEnd = groupStart + 1
      while groupEnd < segmentedLines.count,
        Self.lineIsSeparating(
          segmentedLines[groupEnd], gutters: gutters, columnMinStarts: columnMinStarts,
          bounds: bounds
        ) == isSeparating {
        groupEnd += 1
      }
      let groupLines = Array(segmentedLines[groupStart..<groupEnd])
      if isSeparating {
        result.append(contentsOf: groupLines.map(Self.rejoinedLine))
      } else {
        result.append(
          contentsOf: Self.orderColumns(
            groupLines, gutters: gutters, columnMinStarts: columnMinStarts, bounds: bounds
          )
        )
      }
      groupStart = groupEnd
    }
    return result
  }

  /// 라인이 separating인가 — 세그먼트 중 하나라도 구분선(넘침 제외).
  private static func lineIsSeparating(
    _ segments: [Segment], gutters: [Gutter], columnMinStarts: [CGFloat?], bounds: ClassBounds
  ) -> Bool {
    segments.contains {
      Self.isSeparator($0, gutters: gutters, columnMinStarts: columnMinStarts, bounds: bounds)
    }
  }

  /// 일반 그룹을 열 순서(좌→우, 열 안은 라인 순서)로 방출한다.
  private static func orderColumns(
    _ groupLines: [[Segment]], gutters: [Gutter], columnMinStarts: [CGFloat?], bounds: ClassBounds
  ) -> [[RunEntry]] {
    let allSegments = groupLines.flatMap { $0 }
    var result: [[RunEntry]] = []
    for column in 0..<(gutters.count + 1) {
      let columnSegments = allSegments.filter {
        Self.assignedColumn(
          $0, gutters: gutters, columnMinStarts: columnMinStarts, bounds: bounds
        ) == column
      }
      result.append(contentsOf: Self.joinedLines(columnSegments))
    }
    return result
  }
}

// MARK: - 세그먼트화

extension TextAssembler {
  /// 라인 하나를 세그먼트로 쪼갠다 — 이웃 run 간격 > columnGapFactor × min(두 effFontSize).
  static func segments(of line: [RunEntry], lineIndex: Int) -> [Segment] {
    guard let first = line.first else {
      return []
    }
    let firstProjection = Self.projection(of: first.run)
    var result: [Segment] = []
    var group: [RunEntry] = [first]
    var groupStart = firstProjection.start
    var groupEnd = firstProjection.end
    var groupFontSize = first.run.effectiveFontSize
    var previousEnd = firstProjection.end
    var previousFontSize = groupFontSize

    for entry in line.dropFirst() {
      let entryProjection = Self.projection(of: entry.run)
      let tolerance = Self.columnGapFactor * min(entry.run.effectiveFontSize, previousFontSize)
      if entryProjection.start - previousEnd > tolerance {
        result.append(
          Segment(
            lineIndex: lineIndex, entries: group, start: groupStart, end: groupEnd,
            fontSize: groupFontSize
          )
        )
        group = []
        groupStart = entryProjection.start
        groupFontSize = 0
      }
      group.append(entry)
      groupEnd = entryProjection.end
      groupFontSize = max(groupFontSize, entry.run.effectiveFontSize)
      previousEnd = entryProjection.end
      previousFontSize = entry.run.effectiveFontSize
    }
    result.append(
      Segment(
        lineIndex: lineIndex, entries: group, start: groupStart, end: groupEnd,
        fontSize: groupFontSize
      )
    )
    return result
  }

  /// run 하나의 베이스라인 방향 투영 구간 (start = dot(origin, direction), end = start + Σadvances).
  private static func projection(of run: RawGlyphRun) -> (start: CGFloat, end: CGFloat) {
    let direction = run.baselineDirection
    let start = run.origin.x * direction.dx + run.origin.y * direction.dy
    let totalAdvance = run.advances.reduce(0, +)
    return (start, start + totalAdvance)
  }

  /// 한 라인의 세그먼트들을 시작 순으로 재결합해 원래 라인 형태(run 배열)로 되돌린다.
  private static func rejoinedLine(_ segments: [Segment]) -> [RunEntry] {
    segments.sorted { $0.precedesInLine($1) }.flatMap(\.entries)
  }
}

// MARK: - 브리지·구분선/넘침 판정·열 배정 (개정 2 §6)

extension TextAssembler {
  /// 세그먼트가 거터를 완전히 가로지르는가 (start < g.start && end > g.end).
  static func isBridge(_ segment: Segment, gutters: [Gutter]) -> Bool {
    gutters.contains { segment.start < $0.start && segment.end > $0.end }
  }

  /// 세그먼트 중심 기준 열 인덱스 = 중심보다 왼쪽인 거터 수.
  static func columnIndex(of segment: Segment, gutters: [Gutter]) -> Int {
    Self.columnIndex(at: segment.center, gutters: gutters)
  }

  /// 방향 투영 위치 기준 열 인덱스 = 위치보다 왼쪽인 거터 수.
  private static func columnIndex(at position: CGFloat, gutters: [Gutter]) -> Int {
    gutters.filter { $0.center < position }.count
  }

  /// 전폭이거나 거터를 가로지르는가 — 밴드를 가를 "후보"(구분선 또는 넘침)인지의 전제.
  private static func isCrossing(
    _ segment: Segment, gutters: [Gutter], bounds: ClassBounds
  ) -> Bool {
    Self.isWide(segment, bounds: bounds) || Self.isBridge(segment, gutters: gutters)
  }

  /// 넘침(overrun)인가 — 크로싱 세그먼트 중 시작점이 속한 열의 비크로싱 최소 start +
  /// anchor 이내에서 시작하고, 끝이 오른쪽 여백에 정확히 닿지 않는(못 미치거나 넘어가는)
  /// 것. 열의 왼쪽 가장자리에서 시작해 그 열 흐름에 남아야 하는 행(참고문헌 URL 등).
  private static func isOverrun(
    _ segment: Segment, gutters: [Gutter], columnMinStarts: [CGFloat?], bounds: ClassBounds
  ) -> Bool {
    guard Self.isCrossing(segment, gutters: gutters, bounds: bounds) else {
      return false
    }
    let c0 = Self.columnIndex(at: segment.start, gutters: gutters)
    guard let minStart = columnMinStarts[c0], segment.start <= minStart + bounds.anchor else {
      return false
    }
    return abs(segment.end - bounds.maxEnd) > bounds.anchor
  }

  /// 구분선(밴드를 가르는 세그먼트)인가 — 크로싱이면서 넘침이 아닌 것.
  private static func isSeparator(
    _ segment: Segment, gutters: [Gutter], columnMinStarts: [CGFloat?], bounds: ClassBounds
  ) -> Bool {
    let isOverrun = Self.isOverrun(
      segment, gutters: gutters, columnMinStarts: columnMinStarts, bounds: bounds
    )
    return Self.isCrossing(segment, gutters: gutters, bounds: bounds) && !isOverrun
  }

  /// 전폭·브리지가 아닌 세그먼트(중심 기준 열)로 구한 열별 최소 start — 세그먼트 없는
  /// 열은 nil.
  private static func columnMinStarts(
    segments: [Segment], gutters: [Gutter], bounds: ClassBounds
  ) -> [CGFloat?] {
    var result = [CGFloat?](repeating: nil, count: gutters.count + 1)
    for segment in segments
    where !Self.isWide(segment, bounds: bounds) && !Self.isBridge(segment, gutters: gutters) {
      let column = Self.columnIndex(of: segment, gutters: gutters)
      result[column] = min(result[column] ?? .greatestFiniteMagnitude, segment.start)
    }
    return result
  }

  /// 세그먼트의 배정 열 — 넘침(overrun)은 시작점 기준, 나머지는 중심 기준.
  private static func assignedColumn(
    _ segment: Segment, gutters: [Gutter], columnMinStarts: [CGFloat?], bounds: ClassBounds
  ) -> Int {
    Self.isOverrun(segment, gutters: gutters, columnMinStarts: columnMinStarts, bounds: bounds)
      ? Self.columnIndex(at: segment.start, gutters: gutters)
      : Self.columnIndex(of: segment, gutters: gutters)
  }
}

// MARK: - 열 안 라인 재결합

extension TextAssembler {
  /// (lineIndex, start, 첫 run 방출 인덱스) 정렬 후 같은 lineIndex를 한 출력 라인으로 재결합한다.
  static func joinedLines(_ segments: [Segment]) -> [[RunEntry]] {
    let sorted = segments.sorted { lhs, rhs in
      if lhs.lineIndex != rhs.lineIndex {
        return lhs.lineIndex < rhs.lineIndex
      }
      return lhs.precedesInLine(rhs)
    }
    var result: [[RunEntry]] = []
    var currentLineIndex: Int?
    for segment in sorted {
      if currentLineIndex == segment.lineIndex, !result.isEmpty {
        result[result.count - 1].append(contentsOf: segment.entries)
      } else {
        result.append(segment.entries)
        currentLineIndex = segment.lineIndex
      }
    }
    return result
  }
}
