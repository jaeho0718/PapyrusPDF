import CoreGraphics
import PapyrusPDFCore
@testable import PapyrusPDFUI
import QuartzCore
import Testing

/// ``PersistentHighlightOverlay``의 색상별 레이어 그룹핑·z-순서·클리어·contentsScale
/// 갱신(설계 §5-3)을 검증한다.
@MainActor
struct PersistentHighlightOverlayTests {
  /// 축 정렬 표본 quad.
  private static func quad(x: CGFloat = 0) -> Quad {
    Quad(rect: CGRect(x: x, y: 0, width: 10, height: 10))
  }

  private static func makeParent() -> CALayer {
    let parent = CALayer()
    parent.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    return parent
  }

  // MARK: 2색 그룹 apply

  @Test func applyWithTwoColorGroupsCreatesOneLayerPerColorWithMatchingPathAndFillColor() {
    let parent = Self.makeParent()
    let overlay = PersistentHighlightOverlay(parent: parent)
    let groups = [
      PersistentHighlightGroup(color: .yellow, quads: [Self.quad(), Self.quad(x: 20)]),
      PersistentHighlightGroup(color: .blue, quads: [Self.quad(x: 40)])
    ]

    overlay.apply(groups)

    #expect(overlay.layerCount == 2)
    let shapeLayers = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
    #expect(shapeLayers.count == 2)
    #expect(shapeLayers[0].fillColor == HighlightColor.yellow.cgColor)
    #expect(shapeLayers[1].fillColor == HighlightColor.blue.cgColor)
    // path에 두 quad가 병합돼 있는지는 직접 조회할 수 없으니 bounding box로 근사 검증한다.
    let firstBounds = shapeLayers[0].path?.boundingBoxOfPath
    #expect(firstBounds?.width ?? 0 > 10) // 두 quad(0, 20)의 합집합 폭.
  }

  // MARK: 그룹 순서 = 서브레이어 순서 (재적용 뒤집기 포함)

  @Test func groupOrderMatchesSublayerInsertionOrderAndReappliesReversedOrder() {
    let parent = Self.makeParent()
    let overlay = PersistentHighlightOverlay(parent: parent)
    overlay.apply([
      PersistentHighlightGroup(color: .yellow, quads: [Self.quad()]),
      PersistentHighlightGroup(color: .blue, quads: [Self.quad(x: 20)])
    ])
    var shapeLayers = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
    #expect(
      shapeLayers.map(\.fillColor) == [HighlightColor.yellow.cgColor, HighlightColor.blue.cgColor]
    )

    overlay.apply([
      PersistentHighlightGroup(color: .blue, quads: [Self.quad(x: 20)]),
      PersistentHighlightGroup(color: .yellow, quads: [Self.quad()])
    ])

    shapeLayers = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
    #expect(
      shapeLayers.map(\.fillColor) == [HighlightColor.blue.cgColor, HighlightColor.yellow.cgColor]
    )
  }

  // MARK: 빈 배열 apply == clear

  @Test func applyingEmptyGroupsIsEquivalentToClear() {
    let parent = Self.makeParent()
    let overlay = PersistentHighlightOverlay(parent: parent)
    overlay.apply([PersistentHighlightGroup(color: .yellow, quads: [Self.quad()])])
    #expect(overlay.layerCount == 1)

    overlay.apply([])

    #expect(overlay.layerCount == 0)
    #expect((parent.sublayers ?? []).isEmpty)
  }

  @Test func clearRemovesAllLayers() {
    let parent = Self.makeParent()
    let overlay = PersistentHighlightOverlay(parent: parent)
    overlay.apply([PersistentHighlightGroup(color: .yellow, quads: [Self.quad()])])

    overlay.clear()

    #expect(overlay.layerCount == 0)
    #expect((parent.sublayers ?? []).isEmpty)
  }

  // MARK: updateContentsScale 캡 + 재구축 후 유지

  @Test func updateContentsScaleCapsAtFourTimesScreenScaleAndPersistsAcrossRebuild() {
    let parent = Self.makeParent()
    let overlay = PersistentHighlightOverlay(parent: parent)
    overlay.apply([PersistentHighlightGroup(color: .yellow, quads: [Self.quad()])])

    overlay.updateContentsScale(screenScale: 3, bucketScale: 10) // 30 > 3*4=12 → 캡.

    var shapeLayers = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
    #expect(shapeLayers.allSatisfy { $0.contentsScale == 12 })

    // 재구축(apply 재호출)에도 마지막 contentsScale이 유지된다.
    overlay.apply([PersistentHighlightGroup(color: .green, quads: [Self.quad()])])
    shapeLayers = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
    #expect(shapeLayers.allSatisfy { $0.contentsScale == 12 })
  }

  // MARK: 비유한 성분 색 → cgColor 클램프 (크래시 없음)

  @Test func nonFiniteColorComponentsClampWithoutCrashing() {
    let color = HighlightColor(red: .nan, green: -1, blue: 2, alpha: .infinity)
    let cgColor = color.cgColor
    let components = cgColor.components ?? []
    #expect(components.count == 4)
    #expect(components[0] == 0) // nan → 0.
    #expect(components[1] == 0) // -1 → 클램프 0.
    #expect(components[2] == 1) // 2 → 클램프 1.
    #expect(components[3] == 0) // infinity → 0.
  }

  // MARK: removeFromParent

  @Test func removeFromParentDetachesAllLayers() {
    let parent = Self.makeParent()
    let overlay = PersistentHighlightOverlay(parent: parent)
    overlay.apply([PersistentHighlightGroup(color: .yellow, quads: [Self.quad()])])

    overlay.removeFromParent()

    #expect((parent.sublayers ?? []).isEmpty)
  }
}
