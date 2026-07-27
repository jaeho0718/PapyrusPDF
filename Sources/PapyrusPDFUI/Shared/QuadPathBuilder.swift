import CoreGraphics
import PapyrusPDFCore

/// quad → `CGPath` 변환 (검색·선택·향후 지속 하이라이트 오버레이가 공유하는 기반).
package enum QuadPathBuilder {
  /// quad 하나의 닫힌 사변형 경로를 만든다 (bl → br → tr → tl → 닫힘).
  /// - Parameter quad: 변환할 quad.
  /// - Returns: 닫힌 사변형 경로.
  package static func path(for quad: Quad) -> CGPath {
    let path = CGMutablePath()
    path.move(to: quad.bottomLeft)
    path.addLine(to: quad.bottomRight)
    path.addLine(to: quad.topRight)
    path.addLine(to: quad.topLeft)
    path.closeSubpath()
    return path
  }

  /// quad 목록을 하나의 복합 경로로 합친다 (순서 보존).
  /// - Parameter quads: 변환할 quad 목록.
  /// - Returns: 복합 경로.
  package static func path(for quads: [Quad]) -> CGPath {
    let path = CGMutablePath()
    for quad in quads {
      path.addPath(Self.path(for: quad))
    }
    return path
  }
}
