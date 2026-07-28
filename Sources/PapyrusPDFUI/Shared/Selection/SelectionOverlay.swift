import CoreGraphics
import PapyrusPDFCore
import QuartzCore

/// 페이지의 핸들 배치 (표시 공간 캐럿 선분 — 첫 quad의 왼변 / 끝 quad의 오른변).
package struct SelectionHandlePlacement: Sendable, Equatable {
  /// 핸들 하나의 캐럿 선분 (노브 쪽 끝점, 반대 끝점).
  package struct Anchor: Sendable, Equatable {
    /// 캐럿 선분 (노브 쪽 끝점, 반대 끝점) — 회전 텍스트도 quad 변을 그대로 쓴다.
    package let knobEnd: CGPoint
    /// 캐럿 선분의 반대쪽(노브 없는) 끝점.
    package let baseEnd: CGPoint

    /// 핸들 캐럿 선분을 만든다.
    /// - Parameters:
    ///   - knobEnd: 노브 쪽 끝점.
    ///   - baseEnd: 반대쪽 끝점.
    package init(knobEnd: CGPoint, baseEnd: CGPoint) {
      self.knobEnd = knobEnd
      self.baseEnd = baseEnd
    }
  }

  /// 시작 핸들 (이 페이지에 선택 첫 quad가 없으면 `nil`).
  package let start: Anchor?
  /// 끝 핸들 (이 페이지에 선택 끝 quad가 없으면 `nil`).
  package let end: Anchor?

  /// 핸들 배치를 만든다.
  /// - Parameters:
  ///   - start: 시작 핸들.
  ///   - end: 끝 핸들.
  package init(start: Anchor?, end: Anchor?) {
    self.start = start
    self.end = end
  }
}

/// overlayLayer 안 z-순서 상수 — 레이어 생성 순서와 무관하게 항상 같은 그리기 순서를 보장한다.
package enum OverlayZPosition {
  /// 지속 하이라이트 (향후 기능을 위해 미리 예약해 둔 하한값).
  package static let persistentHighlight: CGFloat = 0
  /// 검색 전체 매치.
  package static let searchAllMatches: CGFloat = 10
  /// 검색 현재 매치.
  package static let searchCurrentMatch: CGFloat = 11
  /// 선택 채움.
  package static let selectionFill: CGFloat = 20
  /// 선택 핸들.
  package static let selectionHandles: CGFloat = 21
}

/// 페이지 하나의 선택 오버레이: 채움 `CAShapeLayer` 1 + (iOS) 핸들 `CAShapeLayer` 2.
///
/// `PageLayerController.overlayLayer`에 얹힌다. `HighlightOverlay`와 동형 — path 좌표는
/// 페이지 표시 공간 pt, 줌은 상위 transform이 처리한다.
@MainActor
package final class SelectionOverlay {
  /// 선택 채움 레이어.
  private let fillLayer: CAShapeLayer

  #if canImport(UIKit)
  /// 시작 핸들 레이어 (캐럿 선 + 노브 원 결합 path).
  private let startHandleLayer: CAShapeLayer
  /// 끝 핸들 레이어.
  private let endHandleLayer: CAShapeLayer
  #endif

  /// 부모(overlayLayer)에 레이어를 삽입하며 생성한다 (`zPosition`은 `OverlayZPosition`).
  /// - Parameter parent: 삽입할 부모 레이어 (페이지 표시 공간 크기로 이미 프레임이 설정됨).
  package init(parent: CALayer) {
    let bounds = CGRect(origin: .zero, size: parent.bounds.size)
    let fillLayer = CAShapeLayer()
    fillLayer.frame = bounds
    fillLayer.fillColor = SelectionStyle.fillColor
    fillLayer.lineWidth = 0
    fillLayer.zPosition = OverlayZPosition.selectionFill
    parent.addSublayer(fillLayer)
    self.fillLayer = fillLayer

    #if canImport(UIKit)
    let startHandleLayer = CAShapeLayer()
    let endHandleLayer = CAShapeLayer()
    for layer in [startHandleLayer, endHandleLayer] {
      layer.frame = bounds
      layer.fillColor = SelectionStyle.handleColor
      layer.strokeColor = SelectionStyle.handleColor
      layer.zPosition = OverlayZPosition.selectionHandles
      parent.addSublayer(layer)
    }
    self.startHandleLayer = startHandleLayer
    self.endHandleLayer = endHandleLayer
    #endif
  }

  /// 채움 quad + 핸들 배치를 갱신한다 (`handles` `nil`이면 핸들 숨김 — macOS는 항상 `nil`).
  /// - Parameters:
  ///   - quads: 채울 표시 공간 quad 목록.
  ///   - handles: 핸들 배치 (macOS는 항상 `nil`).
  ///   - handleScale: 1/zoom (핸들 치수를 화면에 고정된 크기로 유지하기 위한 역보정 배율).
  package func apply(quads: [Quad], handles: SelectionHandlePlacement?, handleScale: CGFloat) {
    self.fillLayer.path = QuadPathBuilder.path(for: quads)
    #if canImport(UIKit)
    self.startHandleLayer.lineWidth = SelectionStyle.handleLineWidth * handleScale
    self.endHandleLayer.lineWidth = SelectionStyle.handleLineWidth * handleScale
    self.startHandleLayer.path = handles?.start.map {
      Self.handlePath(for: $0, scale: handleScale)
    }
    self.endHandleLayer.path = handles?.end.map { Self.handlePath(for: $0, scale: handleScale) }
    #endif
  }

  /// path 전부 제거 (레이어 유지 — 재사용 대비).
  package func clear() {
    self.fillLayer.path = nil
    #if canImport(UIKit)
    self.startHandleLayer.path = nil
    self.endHandleLayer.path = nil
    #endif
  }

  /// 래스터 선명도 갱신 (`HighlightOverlay`와 동일 캡 규칙).
  /// - Parameters:
  ///   - screenScale: 화면 배율(픽셀 밀도).
  ///   - bucketScale: 현재 스케일 버킷 배율.
  package func updateContentsScale(screenScale: CGFloat, bucketScale: CGFloat) {
    let capped = min(screenScale * bucketScale, screenScale * 4)
    self.fillLayer.contentsScale = capped
    #if canImport(UIKit)
    self.startHandleLayer.contentsScale = capped
    self.endHandleLayer.contentsScale = capped
    #endif
  }

  /// 부모에서 분리 (컨트롤러 폐기 경로).
  package func removeFromParent() {
    self.fillLayer.removeFromSuperlayer()
    #if canImport(UIKit)
    self.startHandleLayer.removeFromSuperlayer()
    self.endHandleLayer.removeFromSuperlayer()
    #endif
  }

  #if canImport(UIKit)
  /// 핸들 하나의 결합 path (캐럿 선분 + `knobEnd` 바깥쪽 노브 원).
  /// - Parameters:
  ///   - anchor: 핸들 캐럿 선분.
  ///   - scale: 핸들 치수 배율 (1/zoom).
  /// - Returns: 결합 path.
  private static func handlePath(
    for anchor: SelectionHandlePlacement.Anchor, scale: CGFloat
  ) -> CGPath {
    let path = CGMutablePath()
    path.move(to: anchor.baseEnd)
    path.addLine(to: anchor.knobEnd)

    let dx = anchor.knobEnd.x - anchor.baseEnd.x
    let dy = anchor.knobEnd.y - anchor.baseEnd.y
    let length = (dx * dx + dy * dy).squareRoot()
    let direction = length > 0 ? CGPoint(x: dx / length, y: dy / length) : CGPoint(x: 0, y: 1)
    let radius = SelectionStyle.handleKnobRadius * scale
    let knobCenter = CGPoint(
      x: anchor.knobEnd.x + direction.x * radius, y: anchor.knobEnd.y + direction.y * radius
    )
    path.addEllipse(
      in: CGRect(
        x: knobCenter.x - radius, y: knobCenter.y - radius, width: radius * 2, height: radius * 2
      )
    )
    return path
  }
  #endif
}
