import CoreGraphics

// 이 파일은 `SelectionGeometry`의 히트테스트·질의(textOffset·displayQuads·라인/단어
// 경계)를 담는다 — 타입 선언·저장 필드·구축은 `SelectionGeometry.swift` 참조. 설계 §5
// 한도 초과 시 파일 분할 허용에 따른 분리.

// MARK: - 점 → 오프셋 히트테스트

extension SelectionGeometry {
  /// 표시 공간 점 → 페이지 문자열 UTF-16 오프셋 (전역 실패 없음 — 항상 스냅).
  ///
  /// 전 라인 밴드 밖의 여백 점(페이지 위/아래 포함)도 실패하지 않는다 — 밴드 거리가
  /// 최소인 라인(최근접 라인)을 고른 뒤 그 라인의 축에 투영해 처리한다. 라인 시작
  /// 방향으로 벗어난 여백 점은 그 라인의 `textRange.lowerBound`로, 끝 방향으로 벗어난
  /// 점은 `textRange.upperBound`로 향한다 — 극단 라인에서는 각각 문서 시작(0)·끝(N)과
  /// 같다. 전역 y 좌표로 즉시 0/N을 스냅하지 않는 것은 의도적이다: 그 방식은 "라인
  /// 진행 방향 = 표시 +y"를 암묵 가정해 라인 축이 표시 y와 역행하는 회전(예: 270°)에서
  /// 문서 시작/끝이 뒤바뀐다. 라인 축 투영은 축 방향에 시작/끝 정보가 이미 구조적으로
  /// 보존돼 있어(축이 항상 첫 run의 bl→br 방향) 회전 4종 전부에서 옳다.
  /// - Parameter point: 표시 공간 점.
  /// - Returns: `0...content.string.utf16.count` 안, Character 경계로 스냅된 오프셋.
  package func textOffset(at point: CGPoint) -> Int {
    guard !self.lines.isEmpty else {
      return 0
    }

    let line = self.lines[self.nearestLineIndex(for: point)]
    let projection = Self.dot(point, line.axis)
    if projection <= line.minProjection {
      return line.textRange.lowerBound
    }
    if projection >= line.maxProjection {
      return line.textRange.upperBound
    }

    let (runIndex, isInside) = self.nearestRunIndex(forProjection: projection, in: line)
    guard isInside else {
      let runProjection = self.runProjections[runIndex]
      let run = self.content.runs[runIndex]
      return projection < runProjection.start ? run.range.lowerBound : run.range.upperBound
    }

    let offset = self.characterOffset(inRunAt: runIndex, projection: projection)
    return TextBoundary.snapToCharacterBoundary(offset, in: self.content.string)
  }

  /// `visualOrder`에서 밴드 중점 기준 `y` 삽입점을 이진 탐색하고, 이웃 창 안에서
  /// "밴드 밖 y 거리 + 축 투영 구간 밖 거리"가 최소인 라인을 고른다 (동률은 텍스트 순서
  /// 앞 라인). 같은 y에 열별 라인이 여럿일 때 x가 맞는 열을 고르기 위한 2차원 거리다.
  private func nearestLineIndex(for point: CGPoint) -> Int {
    var low = 0
    var high = self.visualOrder.count
    while low < high {
      let mid = (low + high) / 2
      let band = self.lines[self.visualOrder[mid]].band
      let midY = (band.lowerBound + band.upperBound) / 2
      if midY < point.y {
        low = mid + 1
      } else {
        high = mid
      }
    }

    let windowStart = max(0, low - Self.bandNeighborWindow)
    let windowEnd = min(self.visualOrder.count, low + Self.bandNeighborWindow)
    var best = self.visualOrder[min(low, self.visualOrder.count - 1)]
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for windowIndex in windowStart..<windowEnd {
      let lineIndex = self.visualOrder[windowIndex]
      let distance = self.hitDistance(from: point, to: self.lines[lineIndex])
      if distance < bestDistance || (distance == bestDistance && lineIndex < best) {
        bestDistance = distance
        best = lineIndex
      }
    }
    return best
  }

  // ponytail: 밴드는 표시 y 전용 — 회전 페이지의 라인 간 구분은 기존과 같이 미지원.
  // 필요 시 Line에 normalRange를 추가해 밴드 거리를 대체한다.
  /// 점 → 라인의 2차원 히트 거리 (밴드 밖 y 거리 + 라인 축 투영 구간 밖 거리).
  private func hitDistance(from point: CGPoint, to line: Line) -> CGFloat {
    let band = line.band
    let bandDistance = band.contains(point.y)
      ? 0 : min(abs(point.y - band.lowerBound), abs(point.y - band.upperBound))
    let projection = Self.dot(point, line.axis)
    let projectionDistance = max(
      0, line.minProjection - projection, projection - line.maxProjection
    )
    return bandDistance + projectionDistance
  }

  /// 라인 내 run들을 선형 스캔해 투영 구간 거리(안이면 0) 최소 run을 고른다
  /// (동률은 뒤 run — 인접 경계 판정과 합치).
  private func nearestRunIndex(
    forProjection projection: CGFloat, in line: Line
  ) -> (runIndex: Int, isInside: Bool) {
    var best = line.runIndices.lowerBound
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for runIndex in line.runIndices {
      let runProjection = self.runProjections[runIndex]
      let distance: CGFloat
      if projection < runProjection.start {
        distance = runProjection.start - projection
      } else if projection > runProjection.end {
        distance = projection - runProjection.end
      } else {
        distance = 0
      }
      if distance <= bestDistance {
        bestDistance = distance
        best = runIndex
      }
    }
    return (best, bestDistance == 0)
  }

  /// run 내부의 문자 경계 오프셋을 투영값으로 보간한다 (`TextBoundary`로 최종 스냅 전).
  private func characterOffset(inRunAt runIndex: Int, projection: CGFloat) -> Int {
    let run = self.content.runs[runIndex]
    let runProjection = self.runProjections[runIndex]
    let denominator = runProjection.end - runProjection.start
    let ratio: CGFloat = denominator > 0
      ? min(max((projection - runProjection.start) / denominator, 0), 1)
      : 0

    let prefixSums = self.prefixSumsByRun[runIndex]
    let total = prefixSums.last ?? 0
    guard total > 0 else {
      // 전진량 합 0 퇴화 — ratio=0 폴백(런 시작). prefixSums도 전부 0이라 묶음 전진
      // 로직이 부적절하게 런 끝까지 밀려나는 것을 막는다.
      return run.range.lowerBound
    }

    let index = Self.nearestPrefixIndex(for: ratio * total, in: prefixSums)
    return run.range.lowerBound + index
  }

  /// `prefixSums`에서 `targetAdvance`에 가장 가까운 인덱스를 찾는다 (동률은 뒤쪽,
  /// 다중 유닛 글리프의 0-advance 꼬리 — 동일 누적값 묶음 — 는 묶음의 마지막 인덱스로
  /// 전진해 글리프 중간 오프셋을 피한다).
  private static func nearestPrefixIndex(
    for targetAdvance: CGFloat, in prefixSums: [CGFloat]
  ) -> Int {
    var low = 0
    var high = prefixSums.count - 1
    while low < high {
      let mid = (low + high) / 2
      if prefixSums[mid] < targetAdvance {
        low = mid + 1
      } else {
        high = mid
      }
    }
    var best = low
    if low > 0, abs(prefixSums[low - 1] - targetAdvance) < abs(prefixSums[low] - targetAdvance) {
      best = low - 1
    }
    while best + 1 < prefixSums.count, prefixSums[best + 1] == prefixSums[best] {
      best += 1
    }
    return best
  }
}

// MARK: - 구간 → 표시 quad

extension SelectionGeometry {
  /// 선택 구간의 표시 공간 quad (라인 단위 병합 적용, 텍스트 순서).
  ///
  /// 같은 라인에 속하고 축 정렬(회전·기울임 없음)인 인접 run 그룹은 boundingRect
  /// 합집합 quad 1개로 병합된다 (run 사이 삽입 공백 간극도 채워진다). 회전·기울임
  /// 그룹은 run별 quad를 그대로 유지한다. 결과는 표시 공간(y-아래) 기준이라 `Quad`의
  /// top/bottom 의미가 페이지 공간 정의와 시각적으로 뒤집히지만, 오버레이 path 조립
  /// (4점 다각형)에는 영향이 없다.
  /// - Parameter range: 페이지 문자열 UTF-16 구간.
  /// - Returns: 텍스트 순서의 표시 공간 quad 목록 (교차 없으면 빈 배열).
  package func displayQuads(forRange range: Range<Int>) -> [Quad] {
    let intersections = TextRunGeometry.intersections(forRange: range, in: self.content.runs)
    guard !intersections.isEmpty else {
      return []
    }

    let perRunQuads = intersections.map { intersection -> (runIndex: Int, quad: Quad) in
      let originalRun = self.content.runs[intersection.runIndex]
      let displayRun = TextRun(
        range: originalRun.range, quad: self.displayQuadsByRun[intersection.runIndex],
        advances: originalRun.advances, isInvisible: originalRun.isInvisible
      )
      let quad = TextRunGeometry.partialQuad(
        of: displayRun, localRange: intersection.localRange,
        prefixSums: self.prefixSumsByRun[intersection.runIndex]
      )
      return (intersection.runIndex, quad)
    }

    var mergedQuads: [Quad] = []
    var groupStart = 0
    while groupStart < perRunQuads.count {
      var groupEnd = groupStart + 1
      let lineIndex = self.runToLine[perRunQuads[groupStart].runIndex]
      while groupEnd < perRunQuads.count,
        self.runToLine[perRunQuads[groupEnd].runIndex] == lineIndex {
        groupEnd += 1
      }
      let groupQuads = perRunQuads[groupStart..<groupEnd].map(\.quad)
      if Self.isAxisAligned(groupQuads) {
        mergedQuads.append(Self.mergedBoundingQuad(of: groupQuads))
      } else {
        mergedQuads.append(contentsOf: groupQuads)
      }
      groupStart = groupEnd
    }
    return mergedQuads
  }

  /// 그룹 전원이 축 정렬(회전·기울임 없음)인지 검사한다 (허용치 `axisAlignEpsilon`).
  private static func isAxisAligned(_ quads: [Quad]) -> Bool {
    quads.allSatisfy { quad in
      abs(quad.bottomLeft.y - quad.bottomRight.y) <= Self.axisAlignEpsilon
        && abs(quad.topLeft.y - quad.topRight.y) <= Self.axisAlignEpsilon
        && abs(quad.bottomLeft.x - quad.topLeft.x) <= Self.axisAlignEpsilon
        && abs(quad.bottomRight.x - quad.topRight.x) <= Self.axisAlignEpsilon
    }
  }

  /// 축 정렬 quad 그룹의 boundingRect 합집합을 quad로 만든다.
  private static func mergedBoundingQuad(of quads: [Quad]) -> Quad {
    var union = quads[0].boundingRect
    for quad in quads.dropFirst() {
      union = union.union(quad.boundingRect)
    }
    return Quad(rect: union)
  }
}

// MARK: - 라인·단어 경계

extension SelectionGeometry {
  /// 오프셋이 속한 라인의 텍스트 구간 (라인 사이 개행 오프셋은 앞 라인 소속.
  /// 라인이 없으면 nil). 트리플클릭(macOS) 선택에 사용.
  /// - Parameter offset: 조회할 UTF-16 오프셋.
  /// - Returns: 소속 라인의 텍스트 구간, 라인이 없으면 `nil`.
  package func lineTextRange(containing offset: Int) -> Range<Int>? {
    guard !self.lines.isEmpty else {
      return nil
    }
    if offset <= self.lines[0].textRange.lowerBound {
      return self.lines[0].textRange
    }
    if offset >= self.lines[self.lines.count - 1].textRange.upperBound {
      return self.lines[self.lines.count - 1].textRange
    }

    // 마지막으로 lowerBound <= offset인 라인을 찾는다 — 라인 사이 간극(개행)에 있는
    // 오프셋도 그 앞 라인의 lowerBound가 여전히 최댓값이므로 앞 라인이 선택된다.
    var low = 0
    var high = self.lines.count - 1
    while low < high {
      let mid = (low + high + 1) / 2
      if self.lines[mid].textRange.lowerBound <= offset {
        low = mid
      } else {
        high = mid - 1
      }
    }
    return self.lines[low].textRange
  }

  /// 오프셋 주변 단어 구간 (라인 창 안에서 탐색, 없으면 nil).
  /// 더블클릭(macOS)·롱프레스(iOS) 초기 선택에 사용.
  /// - Parameter offset: 기준 UTF-16 오프셋.
  /// - Returns: 단어 구간, 창 안에 단어가 없거나 라인이 없으면 `nil`.
  package func wordRange(around offset: Int) -> Range<Int>? {
    guard let window = self.lineTextRange(containing: offset) else {
      return nil
    }
    return TextBoundary.wordRange(around: offset, in: self.content.string, window: window)
  }
}
