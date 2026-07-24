import CoreGraphics
import Foundation

/// 원시 run → 읽기 순서 문자열 + 공개 run 조립 (순수 동기 함수, §3.7).
///
/// 출력 계약: `PageTextContent.runs`는 항상 `range.lowerBound` 오름차순(읽기 순서)이다 —
/// 문자열을 라인 순서대로 이어붙이며 run을 그 자리에서 결과 배열에 append하므로 구조적으로
/// 보장된다(M9 §0.1).
package enum TextAssembler {
  /// 원시 run 목록을 읽기 순서로 조립한다.
  ///
  /// 결정성: 정렬은 전부 stable + 명시적 동률 규칙(방출 순서). 빈 입력 →
  /// `PageTextContent(pageIndex:_, string: "", runs: [])`.
  /// - Parameters:
  ///   - runs: 인터프리터가 방출한 원시 run (방출 순서).
  ///   - pageIndex: 결과에 각인할 페이지 인덱스.
  /// - Returns: 조립된 페이지 텍스트 스냅숏 (`runs`는 읽기 순서 = `range.lowerBound` 오름차순).
  package static func assemble(_ runs: [RawGlyphRun], pageIndex: Int) -> PageTextContent {
    guard !runs.isEmpty else {
      return PageTextContent(pageIndex: pageIndex, string: "", runs: [])
    }

    let entries = runs.enumerated().map { RunEntry(originalIndex: $0.offset, run: $0.element) }
    let orderedLines = Self.orderedLines(from: entries)

    var string = ""
    var orderedRuns: [TextRun] = []
    orderedRuns.reserveCapacity(runs.count)
    var isFirstLine = true

    for line in orderedLines {
      if !isFirstLine {
        string.append("\n")
      }
      isFirstLine = false
      Self.appendLine(line, into: &string, orderedRuns: &orderedRuns)
    }

    return PageTextContent(pageIndex: pageIndex, string: string, runs: orderedRuns)
  }
}

// MARK: - 내부 타입

extension TextAssembler {
  /// 원본 인덱스를 보존한 run 하나.
  private struct RunEntry {
    let originalIndex: Int
    let run: RawGlyphRun
  }

  /// 각도 버킷 키 (수직 run은 별도 클래스, 가정 6).
  private struct AngleKey: Hashable {
    let isVertical: Bool
    let bucket: Int
  }
}

// MARK: - 각도 분류 → 라인 클러스터링 → 라인/클래스 순서 (§3.7 1~4)

extension TextAssembler {
  /// 전체 run을 각도 클래스 → 라인으로 묶고, 최종 읽기 순서(클래스는 최초 등장 순,
  /// 라인은 법선 투영 내림차순, 클래스 경계도 라인 경계와 동일하게 취급)로 정렬한다.
  private static func orderedLines(from entries: [RunEntry]) -> [[RunEntry]] {
    var byClass: [AngleKey: [RunEntry]] = [:]
    var firstIndexByClass: [AngleKey: Int] = [:]
    var classOrder: [AngleKey] = []

    for entry in entries {
      let key = Self.angleKey(for: entry.run)
      if byClass[key] == nil {
        classOrder.append(key)
        firstIndexByClass[key] = entry.originalIndex
      }
      byClass[key, default: []].append(entry)
    }

    let sortedClasses = classOrder.sorted {
      (firstIndexByClass[$0] ?? 0) < (firstIndexByClass[$1] ?? 0)
    }

    var lines: [[RunEntry]] = []
    for key in sortedClasses {
      lines.append(contentsOf: Self.clusterLines(byClass[key] ?? []))
    }
    return lines
  }

  /// 베이스라인 방향으로부터 각도 버킷(1° 단위 반올림)을 계산한다.
  private static func angleKey(for run: RawGlyphRun) -> AngleKey {
    let degrees = atan2(run.baselineDirection.dy, run.baselineDirection.dx) * 180 / .pi
    return AngleKey(isVertical: run.isVertical, bucket: Int(degrees.rounded()))
  }

  /// 같은 각도 클래스 내 run들을 법선 투영값으로 정렬·인접 병합해 라인으로 묶는다.
  /// 라인 순서는 법선 투영 내림차순(수평 텍스트 = 위→아래), 동률은 방출 순서 유지.
  private static func clusterLines(_ classEntries: [RunEntry]) -> [[RunEntry]] {
    guard !classEntries.isEmpty else {
      return []
    }
    let projected = classEntries.map { entry -> (entry: RunEntry, normalProjection: CGFloat) in
      let normal = Self.normal(of: entry.run.baselineDirection)
      let projection = entry.run.origin.x * normal.dx + entry.run.origin.y * normal.dy
      return (entry, projection)
    }
    let sorted = projected.enumerated().sorted { lhs, rhs in
      if lhs.element.normalProjection != rhs.element.normalProjection {
        return lhs.element.normalProjection < rhs.element.normalProjection
      }
      return lhs.offset < rhs.offset // stable: 원 순서(방출 순서) 유지.
    }.map(\.element)

    // 주의: `lines.last`로 배열 값을 별도 바인딩해 두면 그 참조가 살아있는 동안
    // `lines[lines.count-1].append`가 COW 복사를 유발해 O(n²)이 된다(대량 run에서
    // 실측 확인됨). 마지막 항목의 스칼라 값만 별도로 추적해 배열 별칭을 만들지 않는다.
    var lines: [[(entry: RunEntry, normalProjection: CGFloat)]] = []
    var lastProjection: CGFloat?
    var lastEffectiveFontSize: CGFloat?
    for item in sorted {
      if let lastP = lastProjection, let lastEff = lastEffectiveFontSize {
        let tolerance = 0.5 * min(item.entry.run.effectiveFontSize, lastEff)
        if abs(item.normalProjection - lastP) <= tolerance {
          lines[lines.count - 1].append(item)
          lastProjection = item.normalProjection
          lastEffectiveFontSize = item.entry.run.effectiveFontSize
          continue
        }
      }
      lines.append([item])
      lastProjection = item.normalProjection
      lastEffectiveFontSize = item.entry.run.effectiveFontSize
    }

    // 내림차순(위→아래) — 오름차순으로 쌓았으므로 뒤집는다.
    return lines.reversed().map { line in Self.orderWithinLine(line.map(\.entry)) }
  }

  /// 라인 내 정렬용 투영값 하나 (원 방출 순서 + 베이스라인 방향 투영값).
  private struct DirectionProjection {
    let emissionOrder: Int
    let entry: RunEntry
    let projection: CGFloat
  }

  /// 라인 내 run을 베이스라인 방향 투영 오름차순(좌→우)으로 정렬한다.
  private static func orderWithinLine(_ line: [RunEntry]) -> [RunEntry] {
    let projected = line.enumerated().map { offset, entry -> DirectionProjection in
      let direction = entry.run.baselineDirection
      let projection = entry.run.origin.x * direction.dx + entry.run.origin.y * direction.dy
      return DirectionProjection(emissionOrder: offset, entry: entry, projection: projection)
    }
    return projected.sorted { lhs, rhs in
      if lhs.projection != rhs.projection {
        return lhs.projection < rhs.projection
      }
      return lhs.emissionOrder < rhs.emissionOrder
    }.map(\.entry)
  }

  /// 방향벡터의 법선(90° 반시계 회전) — 수평 텍스트에서 (0,1)이 되어 위쪽이 큰 투영값을
  /// 갖는다 (라인 내림차순 정렬과 합치).
  private static func normal(of direction: CGVector) -> CGVector {
    CGVector(dx: -direction.dy, dy: direction.dx)
  }
}

// MARK: - 문자열 조립 (§3.7 5~6)

extension TextAssembler {
  /// 라인 하나(이미 좌→우 정렬됨)를 문자열에 이어붙이고, 확정된 range로 `TextRun`을
  /// 만들어 `orderedRuns`에 순서대로 append한다 (문자열 조립 순서 = 읽기 순서이므로
  /// append만으로 출력 배열이 오름차순이 된다).
  private static func appendLine(
    _ line: [RunEntry], into string: inout String, orderedRuns: inout [TextRun]
  ) {
    var previousEnd: PreviousRunEnd?
    for entry in line {
      if let previousEnd, Self.shouldInsertSpace(after: previousEnd, before: entry.run) {
        string.append(" ")
      }
      let startIndex = string.utf16.count
      string += String(decoding: entry.run.utf16, as: UTF16.self)
      let endIndex = string.utf16.count
      orderedRuns.append(
        TextRun(
          range: startIndex..<endIndex, quad: entry.run.quad, advances: entry.run.advances,
          isInvisible: entry.run.isInvisible
        )
      )
      let totalAdvance = entry.run.advances.reduce(0, +)
      let direction = entry.run.baselineDirection
      let endPoint = CGPoint(
        x: entry.run.origin.x + direction.dx * totalAdvance,
        y: entry.run.origin.y + direction.dy * totalAdvance
      )
      previousEnd = PreviousRunEnd(
        point: endPoint, direction: direction, effectiveFontSize: entry.run.effectiveFontSize
      )
    }
  }

  /// 직전 run의 끝점 + 방향 + `effectiveFontSize` (간격 허용치를 두 run 중 작은 값으로
  /// 계산하기 위해 함께 들고 다닌다, 설계 §3.7 5항목).
  private struct PreviousRunEnd {
    let point: CGPoint
    let direction: CGVector
    let effectiveFontSize: CGFloat
  }

  /// run 사이 간격이 공백 삽입 허용치(0.25 × min(effFontSize), 양쪽 run 중 작은 값)를
  /// 넘는지 판정한다.
  private static func shouldInsertSpace(
    after previous: PreviousRunEnd, before run: RawGlyphRun
  ) -> Bool {
    let direction = run.baselineDirection
    let startProjection = run.origin.x * direction.dx + run.origin.y * direction.dy
    let endProjection = previous.point.x * direction.dx + previous.point.y * direction.dy
    let gap = startProjection - endProjection
    let tolerance = 0.25 * min(run.effectiveFontSize, previous.effectiveFontSize)
    return gap > tolerance
  }
}
