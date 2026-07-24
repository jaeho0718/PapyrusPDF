import CoreGraphics
import Foundation

/// 페이지 하나의 선택 히트테스트 인덱스 (표시 공간, 페이지·세션당 1회 구축).
///
/// 순수 값 타입 — 구축·질의 모두 nonisolated. UI 컨트롤러(M10)가 백그라운드 Task에서
/// 구축해 메인으로 나른다. 구현은 이 파일(타입 선언·저장 필드·구축)과
/// `SelectionGeometry+HitTest.swift`(히트테스트·질의)로 나뉜다 — 설계 §5 한도 초과 시
/// 파일 분할 허용에 따른 것.
package struct SelectionGeometry: Sendable {
  /// 위생 검사를 통과한 콘텐츠 (구축 입력의 교정본 — 질의 결과의 좌표계 원천).
  package let content: PageTextContent

  // 아래 저장 필드는 파일 분할(+HitTest.swift) 접근을 위해 internal(명시자 생략)이다 —
  // 타입 자체가 package라 모듈 밖으로는 노출되지 않는다.
  /// run별 표시 공간 quad.
  let displayQuadsByRun: [Quad]
  /// run별 advance prefix sum (count+1, [0]=0).
  let prefixSumsByRun: [[CGFloat]]
  /// run별 라인 축 투영 구간.
  let runProjections: [(start: CGFloat, end: CGFloat)]
  /// 텍스트 순서의 라인 목록.
  let lines: [Line]
  /// lines 인덱스, 밴드 중점 y 오름차순.
  let visualOrder: [Int]
  /// run 인덱스 → lines 인덱스.
  let runToLine: [Int]

  /// 선택 가능한 텍스트가 없으면 true (빈 문자열 또는 run 없음).
  package var isEmpty: Bool {
    self.lines.isEmpty
  }
}

// MARK: - 내부 타입·상수

extension SelectionGeometry {
  /// 라인 하나의 히트테스트 파생값 (구축 시점에 확정, 이후 불변).
  ///
  /// 파일 분할(+HitTest.swift) 접근을 위해 internal이다 — 모듈 밖으로는 노출되지 않는다.
  struct Line: Sendable {
    /// content.runs 안의 연속 구간 (읽기 순서).
    let runIndices: Range<Int>
    /// 첫 run lowerBound ..< 끝 run upperBound.
    let textRange: Range<Int>
    /// 표시 공간 y 밴드 (소속 quad boundingRect 합집합).
    let band: ClosedRange<CGFloat>
    /// 라인 축 단위 벡터 (첫 run 표시 quad의 bl→br, 퇴화 시 (1,0)).
    let axis: CGVector
    /// 라인 내 run 투영 구간의 최소.
    let minProjection: CGFloat
    /// 라인 내 run 투영 구간의 최대.
    let maxProjection: CGFloat
  }

  /// 밴드 탐색 이웃 창 (점 → 오프셋 히트테스트의 라인 후보 폭). 파일 분할 접근을 위해
  /// internal.
  static let bandNeighborWindow = 4
  /// 표시 pt — 라인 병합 축 정렬 판정 및 라인 축 퇴화 판정 공용 허용치. 파일 분할
  /// 접근을 위해 internal.
  static let axisAlignEpsilon: CGFloat = 0.25
}

// MARK: - 구축

extension SelectionGeometry {
  /// 콘텐츠와 페이지 표시 변환으로 인덱스를 구축한다. 내부에서
  /// `PageContentSanitizer.sanitize`를 적용한다 (이중 방어 — 비용은 1패스 검사).
  /// - Parameters:
  ///   - content: 구축 입력 콘텐츠 (프로바이더 원본이어도 안전 — 내부에서 위생 검사한다).
  ///   - pageIndex: 대상 페이지 인덱스 (위생 검사의 기대값으로 쓰인다).
  ///   - transform: PDF 페이지 공간 → 표시 공간 변환.
  /// - Returns: 구축된 히트테스트 인덱스.
  package static func build(
    content: PageTextContent, pageIndex: Int, transform: CGAffineTransform
  ) -> SelectionGeometry {
    let sanitized = PageContentSanitizer.sanitize(content, expectedPageIndex: pageIndex)
    let runs = sanitized.runs

    guard !runs.isEmpty else {
      return SelectionGeometry(
        content: sanitized, displayQuadsByRun: [], prefixSumsByRun: [], runProjections: [],
        lines: [], visualOrder: [], runToLine: []
      )
    }

    let displayQuadsByRun = runs.map { PageDisplayTransform.apply(transform, to: $0.quad) }
    let prefixSumsByRun = runs.map { Self.prefixSums(of: $0.advances) }
    let lineBoundaries = Self.lineBoundaries(for: runs, in: sanitized.string)

    var lines: [Line] = []
    lines.reserveCapacity(lineBoundaries.count)
    var runToLine = Array(repeating: 0, count: runs.count)
    var runProjections = Array(
      repeating: (start: CGFloat(0), end: CGFloat(0)), count: runs.count
    )

    for (lineIndex, runIndices) in lineBoundaries.enumerated() {
      for runIndex in runIndices {
        runToLine[runIndex] = lineIndex
      }
      lines.append(
        Self.makeLine(
          runIndices: runIndices, runs: runs, displayQuadsByRun: displayQuadsByRun,
          runProjections: &runProjections
        )
      )
    }

    let visualOrder = lines.indices.sorted { lhs, rhs in
      let lhsMid = (lines[lhs].band.lowerBound + lines[lhs].band.upperBound) / 2
      let rhsMid = (lines[rhs].band.lowerBound + lines[rhs].band.upperBound) / 2
      if lhsMid != rhsMid {
        return lhsMid < rhsMid
      }
      return lhs < rhs // 동률: 텍스트 순서(결정성).
    }

    return SelectionGeometry(
      content: sanitized, displayQuadsByRun: displayQuadsByRun, prefixSumsByRun: prefixSumsByRun,
      runProjections: runProjections, lines: lines, visualOrder: visualOrder, runToLine: runToLine
    )
  }

  /// 라인 하나(run 인덱스 구간)의 파생값을 계산하고, 그 라인에 속한 run들의
  /// `runProjections`을 채운다.
  /// - Parameters:
  ///   - runIndices: 라인에 속한 `runs`/`displayQuadsByRun` 안의 연속 구간.
  ///   - runs: 전체 run 목록(읽기 순서).
  ///   - displayQuadsByRun: run별 표시 공간 quad.
  ///   - runProjections: run별 라인 축 투영 구간 (해당 라인 소속 항목을 채워 넣는다).
  /// - Returns: 구축된 `Line`.
  private static func makeLine(
    runIndices: Range<Int>, runs: [TextRun], displayQuadsByRun: [Quad],
    runProjections: inout [(start: CGFloat, end: CGFloat)]
  ) -> Line {
    let axis = Self.lineAxis(from: displayQuadsByRun[runIndices.lowerBound])
    var minY = CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude
    var minProjection = CGFloat.greatestFiniteMagnitude
    var maxProjection = -CGFloat.greatestFiniteMagnitude

    for runIndex in runIndices {
      let quad = displayQuadsByRun[runIndex]
      let bounds = quad.boundingRect
      minY = min(minY, bounds.minY)
      maxY = max(maxY, bounds.maxY)
      let start = Self.dot(quad.bottomLeft, axis)
      let end = Self.dot(quad.bottomRight, axis)
      let projectionStart = min(start, end)
      let projectionEnd = max(start, end)
      runProjections[runIndex] = (start: projectionStart, end: projectionEnd)
      minProjection = min(minProjection, projectionStart)
      maxProjection = max(maxProjection, projectionEnd)
    }

    let textRange = runs[runIndices.lowerBound].range.lowerBound
      ..< runs[runIndices.upperBound - 1].range.upperBound
    return Line(
      runIndices: runIndices, textRange: textRange, band: minY...maxY, axis: axis,
      minProjection: minProjection, maxProjection: maxProjection
    )
  }

  /// run의 advance 누적합을 계산한다 (`count + 1`개, `[0] == 0`).
  private static func prefixSums(of advances: [CGFloat]) -> [CGFloat] {
    var sums: [CGFloat] = [0]
    sums.reserveCapacity(advances.count + 1)
    var running: CGFloat = 0
    for advance in advances {
      running += advance
      sums.append(running)
    }
    return sums
  }

  /// 읽기 순서 run들을 라인 경계(개행 포함 gap)로 나눈다 (run 인덱스 구간의 배열).
  private static func lineBoundaries(for runs: [TextRun], in string: String) -> [Range<Int>] {
    var boundaries: [Range<Int>] = []
    var lineStart = 0
    for index in 1..<runs.count {
      let gap = runs[index - 1].range.upperBound..<runs[index].range.lowerBound
      let isNewLine = gap.lowerBound < gap.upperBound && Self.gapContainsNewline(gap, in: string)
      if isNewLine {
        boundaries.append(lineStart..<index)
        lineStart = index
      }
    }
    boundaries.append(lineStart..<runs.count)
    return boundaries
  }

  /// 라인 첫 run의 표시 quad에서 라인 축(단위 벡터)을 구한다. 퇴화(길이 ~0)면 (1,0).
  private static func lineAxis(from quad: Quad) -> CGVector {
    let dx = quad.bottomRight.x - quad.bottomLeft.x
    let dy = quad.bottomRight.y - quad.bottomLeft.y
    let length = (dx * dx + dy * dy).squareRoot()
    guard length >= Self.axisAlignEpsilon else {
      return CGVector(dx: 1, dy: 0)
    }
    return CGVector(dx: dx / length, dy: dy / length)
  }

  /// 점과 축 벡터의 내적 (스칼라 투영값). `SelectionGeometry+HitTest.swift`에서도 쓰여
  /// 파일 분할 접근을 위해 internal이다.
  static func dot(_ point: CGPoint, _ axis: CGVector) -> CGFloat {
    point.x * axis.dx + point.y * axis.dy
  }

  /// gap 구간(UTF-16 오프셋)에 개행류 문자(LF/CR/LS/PS)가 있는지 검사한다.
  private static func gapContainsNewline(_ gap: Range<Int>, in string: String) -> Bool {
    let utf16View = string.utf16
    guard
      let lower = utf16View.index(
        utf16View.startIndex, offsetBy: gap.lowerBound, limitedBy: utf16View.endIndex
      ),
      let upper = utf16View.index(
        utf16View.startIndex, offsetBy: gap.upperBound, limitedBy: utf16View.endIndex
      )
    else {
      return false
    }
    for unit in utf16View[lower..<upper] where unit == 0x0A || unit == 0x0D || unit == 0x2028
      || unit == 0x2029 {
      return true
    }
    return false
  }
}
