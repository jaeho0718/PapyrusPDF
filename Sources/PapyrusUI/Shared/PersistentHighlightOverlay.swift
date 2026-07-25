import CoreGraphics
import PapyrusCore
import QuartzCore

/// 색상 그룹 하나 (표시 공간 quad — 코어가 변환을 마치고 넘긴다).
package struct PersistentHighlightGroup: Equatable, Sendable {
  /// 그룹 색.
  package let color: HighlightColor
  /// 표시 공간 quad 목록 (하이라이트 등록 순서).
  package let quads: [Quad]

  /// 그룹을 만든다.
  /// - Parameters:
  ///   - color: 그룹 색.
  ///   - quads: 표시 공간 quad 목록.
  package init(color: HighlightColor, quads: [Quad]) {
    self.color = color
    self.quads = quads
  }
}

/// 페이지 하나의 지속 하이라이트 레이어 그룹 (색상별 `CAShapeLayer` 1장).
///
/// `PageLayerController.overlayLayer`에 얹힌다. z-순서는
/// `OverlayZPosition.persistentHighlight`(최하단 — 검색·선택 아래). path 좌표는
/// 페이지 표시 공간 pt — 줌은 상위 transform이 처리한다 (`HighlightOverlay` 동형).
@MainActor
package final class PersistentHighlightOverlay {
  /// 부모(overlayLayer) — 색 구성이 바뀔 때 레이어를 새로 얹어야 하므로 기존
  /// 오버레이 2종과 달리 부모 참조를 유지한다. `overlayLayer`는 컨트롤러 수명과
  /// 같아 실사용에서 nil이 되지 않지만 순환을 원천 차단하기 위해 weak.
  private weak var parent: CALayer?

  /// 현재 색상별 레이어 (배열 순서 = 그룹 순서 = 서브레이어 삽입 순서).
  private var colorLayers: [CAShapeLayer] = []

  /// 마지막으로 적용된 contentsScale (재구축 레이어에도 그대로 적용하기 위해 보관).
  private var lastContentsScale: CGFloat = 1

  /// 부모를 보관하며 생성한다 (색 구성이 바뀔 때 레이어를 새로 얹어야 하므로
  /// 기존 오버레이 2종과 달리 부모 참조를 유지한다).
  /// - Parameter parent: 삽입할 부모 레이어.
  package init(parent: CALayer) {
    self.parent = parent
  }

  /// 그룹들을 전량 재구축해 표시한다 (빈 배열이면 `clear()`와 동일).
  ///
  /// 레이어 재사용 없이 매번 제거 후 재생성한다 — 같은 zPosition 안의 그리기
  /// 순서가 서브레이어 삽입 순서로 결정되므로, 재구축이 "그룹 순서 = 그리기
  /// 순서"를 가장 단순하게 보장한다. 색 수는 실질 소수(프리셋 5종 규모)고 호출
  /// 빈도는 실체화·등록 변경 시점뿐이라 비용은 무시 가능하다.
  /// - Parameter groups: 표시할 색상 그룹 (순서 = 그리기 순서).
  package func apply(_ groups: [PersistentHighlightGroup]) {
    for layer in self.colorLayers {
      layer.removeFromSuperlayer()
    }
    self.colorLayers.removeAll()
    guard let parent, !groups.isEmpty else {
      return
    }
    let bounds = CGRect(origin: .zero, size: parent.bounds.size)
    for group in groups {
      let layer = CAShapeLayer()
      layer.frame = bounds
      layer.fillColor = group.color.cgColor
      layer.lineWidth = 0
      layer.zPosition = OverlayZPosition.persistentHighlight
      layer.path = QuadPathBuilder.path(for: group.quads)
      layer.contentsScale = self.lastContentsScale
      parent.addSublayer(layer)
      self.colorLayers.append(layer)
    }
  }

  /// 레이어 전부 제거 (재사용 클리어 경로).
  package func clear() {
    for layer in self.colorLayers {
      layer.removeFromSuperlayer()
    }
    self.colorLayers.removeAll()
  }

  /// 래스터 선명도 갱신 (`HighlightOverlay`와 동일 캡 규칙 — 화면 배율 × 버킷
  /// 배율, 상한 4×화면 배율). 마지막 값을 보관해 재구축 레이어에도 적용한다.
  /// - Parameters:
  ///   - screenScale: 화면 배율(픽셀 밀도).
  ///   - bucketScale: 현재 스케일 버킷 배율.
  package func updateContentsScale(screenScale: CGFloat, bucketScale: CGFloat) {
    let capped = min(screenScale * bucketScale, screenScale * 4)
    self.lastContentsScale = capped
    for layer in self.colorLayers {
      layer.contentsScale = capped
    }
  }

  /// 부모에서 분리 (컨트롤러 폐기 경로).
  package func removeFromParent() {
    for layer in self.colorLayers {
      layer.removeFromSuperlayer()
    }
  }

  /// 현재 레이어 수 (테스트 관찰용 — 색상 그룹핑 검증).
  package var layerCount: Int {
    self.colorLayers.count
  }
}
