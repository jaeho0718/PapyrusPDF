import CoreGraphics
import PapyrusCore

/// 영역 히트테스트·등록 위생 (순수 함수 — 표시 공간 점 → 등록 영역).
package enum RegionHitTester {
  /// 표시 공간 점의 히트 영역을 찾는다 (겹침은 **나중 등록 우선** — 뒤에서부터 탐색).
  /// - Parameters:
  ///   - point: 페이지 표시 공간의 점.
  ///   - regions: 그 페이지의 등록 영역 (등록 순서 그대로).
  ///   - displayTransform: PDF 페이지 공간 → 표시 공간 변환.
  /// - Returns: 히트된 영역, 없으면 `nil`.
  package static func hitRegion(
    at point: CGPoint, regions: [SelectableRegion], displayTransform: CGAffineTransform
  ) -> SelectableRegion? {
    for region in regions.reversed() {
      let displayQuad = PageDisplayTransform.apply(displayTransform, to: region.quad)
      if Self.contains(point, in: displayQuad) {
        return region
      }
    }
    return nil
  }

  /// 점이 볼록 quad 내부(경계 포함)인지 판정한다 — 변별 외적 부호 일치.
  /// 비유한 좌표·퇴화(전 변 외적 0) quad는 항상 `false` (NaN 비교의 자연 안전성).
  /// - Parameters:
  ///   - point: 판정할 점.
  ///   - quad: 대상 quad (판정 좌표 공간과 동일 공간).
  /// - Returns: 내부(경계 포함)면 `true`.
  package static func contains(_ point: CGPoint, in quad: Quad) -> Bool {
    let vertices = [quad.bottomLeft, quad.bottomRight, quad.topRight, quad.topLeft]
    guard point.x.isFinite, point.y.isFinite,
      vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
    else {
      return false
    }
    var sawPositive = false
    var sawNegative = false
    for index in vertices.indices {
      let current = vertices[index]
      let next = vertices[(index + 1) % vertices.count]
      let cross = (next.x - current.x) * (point.y - current.y)
        - (next.y - current.y) * (point.x - current.x)
      if cross > 0 {
        sawPositive = true
      } else if cross < 0 {
        sawNegative = true
      }
      if sawPositive, sawNegative {
        return false
      }
    }
    return sawPositive || sawNegative
  }

  /// 등록 위생: 규칙 위반 항목 폐기 + 페이지당 상한 절단 (등록 경계 한 곳 원칙 —
  /// 모델 `setSelectableRegions`가 저장 전에 1회 적용한다).
  /// 폐기 규칙: ① quad 좌표에 비유한 값 ② `region.pageIndex != pageIndex`.
  /// 상한: 앞에서부터 `UILimits.maxSelectableRegionsPerPage`개 유지.
  /// - Parameters:
  ///   - regions: 등록 요청 목록 (순서 보존).
  ///   - pageIndex: 등록 대상 페이지.
  /// - Returns: 위생 처리된 목록.
  package static func sanitized(
    _ regions: [SelectableRegion], forPage pageIndex: Int
  ) -> [SelectableRegion] {
    let filtered = regions.filter { region in
      region.pageIndex == pageIndex && Self.isFinite(region.quad)
    }
    return Array(filtered.prefix(UILimits.maxSelectableRegionsPerPage))
  }

  /// quad 4점 전부가 유한 좌표인지 확인한다.
  /// - Parameter quad: 판정할 quad.
  /// - Returns: 전부 유한이면 `true`.
  private static func isFinite(_ quad: Quad) -> Bool {
    [quad.bottomLeft, quad.bottomRight, quad.topRight, quad.topLeft].allSatisfy {
      $0.x.isFinite && $0.y.isFinite
    }
  }
}
