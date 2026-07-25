import CoreGraphics
import PapyrusCore
import PapyrusUI
import QuartzCore
import Testing

/// ``SelectionOverlay``·``QuadPathBuilder``·``OverlayZPosition``을 검증한다 (설계 §6-4).
@MainActor
struct SelectionOverlayTests {
  /// 축 정렬 표본 quad (10×10).
  private static var sampleQuad: Quad {
    Quad(
      bottomLeft: CGPoint(x: 0, y: 10), bottomRight: CGPoint(x: 10, y: 10),
      topRight: CGPoint(x: 10, y: 0), topLeft: CGPoint(x: 0, y: 0)
    )
  }

  /// `layer`의 `CAShapeLayer` 서브레이어들 (삽입 순서).
  private static func shapeLayers(of layer: CALayer) -> [CAShapeLayer] {
    (layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
  }

  // MARK: 지연 생성 — 삽입 시점까지 서브레이어가 없다

  @Test func overlayLazilyInsertsLayersOnInit() {
    let parent = CALayer()
    parent.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    #expect(Self.shapeLayers(of: parent).isEmpty)

    _ = SelectionOverlay(parent: parent)

    #expect(!Self.shapeLayers(of: parent).isEmpty) // init 시점에 채움(+ iOS 핸들) 레이어 삽입.
  }

  // MARK: apply → 채움 path 반영

  @Test func applyPopulatesFillPath() {
    let parent = CALayer()
    parent.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let overlay = SelectionOverlay(parent: parent)

    overlay.apply(quads: [Self.sampleQuad], handles: nil, handleScale: 1)

    let fillLayer = Self.shapeLayers(of: parent).first {
      $0.zPosition == OverlayZPosition.selectionFill
    }
    #expect(!(fillLayer?.path?.isEmpty ?? true))
  }

  // MARK: handles nil → 핸들 path 비움 (iOS만 의미 있는 검증)

  #if canImport(UIKit)
  @Test func applyWithNilHandlesLeavesHandleLayersEmpty() {
    let parent = CALayer()
    parent.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let overlay = SelectionOverlay(parent: parent)

    overlay.apply(quads: [Self.sampleQuad], handles: nil, handleScale: 1)

    let handleLayers = Self.shapeLayers(of: parent).filter {
      $0.zPosition == OverlayZPosition.selectionHandles
    }
    #expect(!handleLayers.isEmpty)
    #expect(handleLayers.allSatisfy { $0.path == nil })
  }

  @Test func applyWithHandlesPopulatesHandleLayersAndReflectsScale() {
    let parent = CALayer()
    parent.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let overlay = SelectionOverlay(parent: parent)
    let placement = SelectionHandlePlacement(
      start: SelectionHandlePlacement.Anchor(
        knobEnd: CGPoint(x: 0, y: 10), baseEnd: CGPoint(x: 0, y: 0)
      ),
      end: SelectionHandlePlacement.Anchor(
        knobEnd: CGPoint(x: 10, y: 10), baseEnd: CGPoint(x: 10, y: 0)
      )
    )

    overlay.apply(quads: [Self.sampleQuad], handles: placement, handleScale: 1)
    let smallScaleBounds = Self.handlePathBounds(parent)

    overlay.apply(quads: [Self.sampleQuad], handles: placement, handleScale: 3)
    let largeScaleBounds = Self.handlePathBounds(parent)

    // 노브 반지름이 스케일에 비례 — 더 큰 스케일이 더 큰 bounding box를 만든다.
    #expect(largeScaleBounds.width > smallScaleBounds.width)
  }

  /// 핸들 레이어들 path의 합집합 bounding box.
  private static func handlePathBounds(_ parent: CALayer) -> CGRect {
    let handleLayers = Self.shapeLayers(of: parent).filter {
      $0.zPosition == OverlayZPosition.selectionHandles
    }
    return handleLayers.reduce(CGRect.null) { partial, layer in
      guard let path = layer.path else {
        return partial
      }
      return partial.union(path.boundingBoxOfPath)
    }
  }
  #endif

  // MARK: clear

  @Test func clearRemovesFillPath() {
    let parent = CALayer()
    parent.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let overlay = SelectionOverlay(parent: parent)
    overlay.apply(quads: [Self.sampleQuad], handles: nil, handleScale: 1)

    overlay.clear()

    let fillLayer = Self.shapeLayers(of: parent).first {
      $0.zPosition == OverlayZPosition.selectionFill
    }
    #expect(fillLayer?.path == nil)
  }

  // MARK: zPosition 순서 (회귀 방지)

  @Test func zPositionOrderingIsSelectionAboveSearch() {
    #expect(OverlayZPosition.selectionFill > OverlayZPosition.searchCurrentMatch)
    #expect(OverlayZPosition.searchCurrentMatch > OverlayZPosition.searchAllMatches)
    #expect(OverlayZPosition.searchAllMatches > OverlayZPosition.persistentHighlight)
    #expect(OverlayZPosition.selectionHandles > OverlayZPosition.selectionFill)
  }

  // MARK: QuadPathBuilder 단독 — HighlightOverlay 이동 무손상 증명

  @Test func quadPathBuilderProducesClosedQuadPath() {
    let path = QuadPathBuilder.path(for: Self.sampleQuad)
    #expect(!path.isEmpty)
    #expect(path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 10, height: 10))
  }

  @Test func quadPathBuilderCombinesMultipleQuadsInOrder() {
    let second = Quad(
      bottomLeft: CGPoint(x: 20, y: 10), bottomRight: CGPoint(x: 30, y: 10),
      topRight: CGPoint(x: 30, y: 0), topLeft: CGPoint(x: 20, y: 0)
    )
    let path = QuadPathBuilder.path(for: [Self.sampleQuad, second])
    #expect(path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 30, height: 10))
  }
}
