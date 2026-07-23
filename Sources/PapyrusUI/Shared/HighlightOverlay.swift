import CoreGraphics
import PapyrusCore
import QuartzCore

/// 표시 공간으로 변환 완료된 페이지 하나의 매치 목록.
package struct PageSearchHighlights: Sendable, Equatable {
  /// 매치별 표시 공간 quad 배열 (페이지 안 위치 오름차순 — 스트림 방출 순서 보존).
  package let matches: [[Quad]]

  /// 페이지 검색 하이라이트를 생성한다.
  /// - Parameter matches: 매치별 표시 공간 quad 배열.
  package init(matches: [[Quad]]) {
    self.matches = matches
  }
}

/// PDF 페이지 공간 → 페이지 표시 공간(좌상단 원점, y-아래) 변환.
///
/// `c = p - cropBox.origin`, `W = cropBox.width`, `H = cropBox.height`일 때 회전별
/// 대응은 다음과 같다 (도출: 꼭짓점 대응 검증 완료).
///
/// | rotation | display.x | display.y |
/// |---|---|---|
/// | 0°   | cx     | H − cy |
/// | 90°  | cy     | cx     |
/// | 180° | W − cx | cy     |
/// | 270° | H − cy | W − cx |
package enum PageDisplayTransform {
  /// cropBox·회전으로 변환을 만든다. 반환 변환은 `Quad` 4점에 각각 적용한다.
  /// - Parameters:
  ///   - cropBox: 페이지 /CropBox (PDF 사용자 공간).
  ///   - rotation: 페이지 회전.
  /// - Returns: PDF 페이지 공간 → 페이지 표시 공간 변환.
  package static func transform(cropBox: CGRect, rotation: PageRotation) -> CGAffineTransform {
    let originX = cropBox.origin.x
    let originY = cropBox.origin.y
    let width = cropBox.width
    let height = cropBox.height
    switch rotation {
    case .degrees0:
      return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -originX, ty: height + originY)
    case .degrees90:
      return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: -originY, ty: -originX)
    case .degrees180:
      return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: originX + width, ty: -originY)
    case .degrees270:
      return CGAffineTransform(
        a: 0, b: -1, c: -1, d: 0, tx: originY + height, ty: originX + width
      )
    }
  }

  /// quad에 변환을 적용한다 (4점 개별 적용 — 꼭짓점 의미는 유지된다).
  /// - Parameters:
  ///   - transform: 적용할 변환.
  ///   - quad: 변환할 PDF 페이지 공간 quad.
  /// - Returns: 표시 공간으로 옮겨진 quad.
  package static func apply(_ transform: CGAffineTransform, to quad: Quad) -> Quad {
    Quad(
      bottomLeft: quad.bottomLeft.applying(transform),
      bottomRight: quad.bottomRight.applying(transform),
      topRight: quad.topRight.applying(transform),
      topLeft: quad.topLeft.applying(transform)
    )
  }
}

/// 검색 하이라이트 스타일 상수 (v2 공개 커스터마이징 확장 심).
package enum HighlightStyle {
  /// 전체 매치 채우기 색 (옅은 노랑, 반투명).
  package static let allMatchesFill = CGColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 0.35)
  /// 현재 매치 채우기 색 (짙은 주황, 더 불투명).
  package static let currentMatchFill = CGColor(srgbRed: 1, green: 0.55, blue: 0.05, alpha: 0.55)
}

/// 페이지 하나의 하이라이트 레이어 쌍 (전체 매치 + 현재 매치 강조).
///
/// `PageLayerController.overlayLayer`에 얹힌다. path 좌표는 페이지 표시 공간 pt —
/// 줌은 상위 레이어 transform이 처리하므로 재계산 불필요.
@MainActor
package final class HighlightOverlay {
  /// 전체 매치를 그리는 레이어 (아래).
  private let allMatchesLayer: CAShapeLayer

  /// 현재 매치를 강조하는 레이어 (위).
  private let currentMatchLayer: CAShapeLayer

  /// 부모(overlayLayer)에 레이어 2장을 삽입하며 생성한다.
  /// - Parameter parent: 삽입할 부모 레이어 (페이지 표시 공간 크기로 이미 프레임이 설정됨).
  package init(parent: CALayer) {
    let allMatchesLayer = CAShapeLayer()
    let currentMatchLayer = CAShapeLayer()
    let bounds = CGRect(origin: .zero, size: parent.bounds.size)
    allMatchesLayer.frame = bounds
    currentMatchLayer.frame = bounds
    allMatchesLayer.fillColor = HighlightStyle.allMatchesFill
    currentMatchLayer.fillColor = HighlightStyle.currentMatchFill
    allMatchesLayer.lineWidth = 0
    currentMatchLayer.lineWidth = 0
    parent.addSublayer(allMatchesLayer)
    parent.addSublayer(currentMatchLayer)
    self.allMatchesLayer = allMatchesLayer
    self.currentMatchLayer = currentMatchLayer
  }

  /// 전체 매치 path + 현재 매치 path를 갱신한다.
  /// - Parameters:
  ///   - highlights: 이 페이지의 표시 공간 매치들.
  ///   - currentOrdinal: 현재 매치의 페이지 내 순번 (이 페이지에 없으면 `nil`).
  package func apply(_ highlights: PageSearchHighlights, currentOrdinal: Int?) {
    let allPath = CGMutablePath()
    for quads in highlights.matches {
      for quad in quads {
        allPath.addPath(Self.path(for: quad))
      }
    }
    self.allMatchesLayer.path = allPath

    let currentPath = CGMutablePath()
    if let currentOrdinal, highlights.matches.indices.contains(currentOrdinal) {
      for quad in highlights.matches[currentOrdinal] {
        currentPath.addPath(Self.path(for: quad))
      }
    }
    self.currentMatchLayer.path = currentPath
  }

  /// path 전부 제거 (레이어는 유지 — 재사용 대비).
  package func clear() {
    self.allMatchesLayer.path = nil
    self.currentMatchLayer.path = nil
  }

  /// 스케일 버킷 변경 시 래스터 선명도 갱신 (contentsScale = 화면 배율 × 버킷 배율,
  /// 상한 4×화면 배율 — 반투명 사각형이라 상한 초과 이득 없음).
  /// - Parameters:
  ///   - screenScale: 화면 배율(픽셀 밀도).
  ///   - bucketScale: 현재 스케일 버킷 배율.
  package func updateContentsScale(screenScale: CGFloat, bucketScale: CGFloat) {
    let capped = min(screenScale * bucketScale, screenScale * 4)
    self.allMatchesLayer.contentsScale = capped
    self.currentMatchLayer.contentsScale = capped
  }

  /// 부모에서 분리 (컨트롤러 폐기 경로).
  package func removeFromParent() {
    self.allMatchesLayer.removeFromSuperlayer()
    self.currentMatchLayer.removeFromSuperlayer()
  }

  /// quad 하나를 닫힌 사변형 경로로 변환한다.
  /// - Parameter quad: 변환할 quad.
  /// - Returns: bottomLeft → bottomRight → topRight → topLeft → 닫힘 순의 경로.
  private static func path(for quad: Quad) -> CGPath {
    let path = CGMutablePath()
    path.move(to: quad.bottomLeft)
    path.addLine(to: quad.bottomRight)
    path.addLine(to: quad.topRight)
    path.addLine(to: quad.topLeft)
    path.closeSubpath()
    return path
  }
}
