import CoreGraphics

/// run 기하 유틸 (순수 함수) — 검색 하이라이트·선택 오버레이·하이라이트 생성의 공유 기반.
///
/// 전제: 호출자가 넘기는 `runs`는 위생 검사(`PageContentSanitizer`)를 거친 값이어야 한다 —
/// `range.lowerBound` 오름차순, `advances.count == range.count`가 성립해야 이진 탐색·배열
/// 슬라이싱이 안전하다. 위생 검사 없이 외부 입력을 직접 이 타입에 넘기지 않는다.
package enum TextRunGeometry {
  /// 구간과 교차하는 run들을 (run 인덱스, run 로컬 구간)으로 나열한다.
  ///
  /// 전제: `runs`는 `range.lowerBound` 오름차순 (조립기 출력·위생 검사 후 계약).
  /// `upperBound > range.lowerBound`인 첫 run을 이진 탐색 후 선형 순회 — O(log R + k).
  /// - Parameters:
  ///   - range: 교차를 찾을 UTF-16 구간.
  ///   - runs: 페이지의 run 목록 (오름차순).
  /// - Returns: 교차한 (run 인덱스, run 로컬 구간) 목록 (텍스트 순서).
  package static func intersections(
    forRange range: Range<Int>, in runs: [TextRun]
  ) -> [(runIndex: Int, localRange: Range<Int>)] {
    var low = 0
    var high = runs.count
    while low < high {
      let mid = (low + high) / 2
      if runs[mid].range.upperBound <= range.lowerBound {
        low = mid + 1
      } else {
        high = mid
      }
    }

    var result: [(runIndex: Int, localRange: Range<Int>)] = []
    var index = low
    while index < runs.count, runs[index].range.lowerBound < range.upperBound {
      let run = runs[index]
      let intersectionStart = max(range.lowerBound, run.range.lowerBound)
      let intersectionEnd = min(range.upperBound, run.range.upperBound)
      if intersectionStart < intersectionEnd {
        let localRange =
          (intersectionStart - run.range.lowerBound)..<(intersectionEnd - run.range.lowerBound)
        result.append((runIndex: index, localRange: localRange))
      }
      index += 1
    }
    return result
  }

  /// 구간이 덮는 부분 quad들 (교차 run당 1개).
  /// - Parameters:
  ///   - range: quad를 구할 UTF-16 구간.
  ///   - runs: 페이지의 run 목록 (오름차순).
  /// - Returns: 교차한 run별 부분 quad (교차 run이 없으면 빈 배열).
  package static func quads(forRange range: Range<Int>, in runs: [TextRun]) -> [Quad] {
    Self.intersections(forRange: range, in: runs).map {
      Self.partialQuad(of: runs[$0.runIndex], localRange: $0.localRange)
    }
  }

  /// run 부분 구간의 보간 quad.
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
    var prefixSums: [CGFloat] = [0]
    prefixSums.reserveCapacity(run.advances.count + 1)
    var running: CGFloat = 0
    for advance in run.advances {
      running += advance
      prefixSums.append(running)
    }
    return Self.partialQuad(of: run, localRange: localRange, prefixSums: prefixSums)
  }

  /// prefix sum을 이미 가진 호출자용 오버로드 (`SelectionGeometry` 핫패스).
  ///
  /// `prefixSums.count == advances.count + 1`, `prefixSums[0] == 0`,
  /// `total = prefixSums.last`. `total <= 0` 퇴화는 전체 quad 폴백 (기존 방어 유지).
  /// - Parameters:
  ///   - run: 대상 run.
  ///   - localRange: run 로컬 좌표계(0 기반)의 부분 구간.
  ///   - prefixSums: run의 advance 누적합 (`count == advances.count + 1`, `[0] == 0`).
  /// - Returns: 보간된 부분 quad.
  package static func partialQuad(
    of run: TextRun, localRange: Range<Int>, prefixSums: [CGFloat]
  ) -> Quad {
    let total = prefixSums.last ?? 0
    let d0 = prefixSums[localRange.lowerBound]
    let d1 = prefixSums[localRange.upperBound]
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
