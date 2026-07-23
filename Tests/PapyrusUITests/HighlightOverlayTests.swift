import CoreGraphics
import PapyrusCore
import PapyrusUI
import QuartzCore
import Testing

/// ``PageDisplayTransform``·``HighlightOverlay``·재활용 오염 방어를 검증한다 (설계 §5.3 1-3).
@MainActor
struct HighlightOverlayTests {
  // MARK: 1 — PageDisplayTransform 회전 4종 × 꼭짓점 매핑

  @Test func rotation0MapsCorners() {
    let cropBox = CGRect(x: 10, y: 20, width: 100, height: 200) // 원점 ≠ 0.
    let transform = PageDisplayTransform.transform(cropBox: cropBox, rotation: .degrees0)
    // 좌하단 → 표시 좌하단(0,H); 좌상단 → 표시 원점(0,0).
    Self.expectClose(CGPoint(x: 10, y: 20).applying(transform), CGPoint(x: 0, y: 200))
    Self.expectClose(CGPoint(x: 10, y: 220).applying(transform), CGPoint(x: 0, y: 0))
  }

  @Test func rotation90MapsCornersWithNonZeroOrigin() {
    let cropBox = CGRect(x: 5, y: 7, width: 100, height: 200) // 원점 ≠ 0.
    let transform = PageDisplayTransform.transform(cropBox: cropBox, rotation: .degrees90)
    // 좌하단(원점) → 표시(0,0); 좌상단 → 표시(H,0) — 설계 §3.4 예시와 동일한 대응.
    Self.expectClose(CGPoint(x: 5, y: 7).applying(transform), CGPoint(x: 0, y: 0))
    Self.expectClose(CGPoint(x: 5, y: 207).applying(transform), CGPoint(x: 200, y: 0))
  }

  @Test func rotation180MapsCorners() {
    let cropBox = CGRect(x: 0, y: 0, width: 100, height: 200)
    let transform = PageDisplayTransform.transform(cropBox: cropBox, rotation: .degrees180)
    Self.expectClose(CGPoint(x: 0, y: 0).applying(transform), CGPoint(x: 100, y: 0))
    Self.expectClose(CGPoint(x: 100, y: 200).applying(transform), CGPoint(x: 0, y: 200))
  }

  @Test func rotation270MapsCorners() {
    let cropBox = CGRect(x: 0, y: 0, width: 100, height: 200)
    let transform = PageDisplayTransform.transform(cropBox: cropBox, rotation: .degrees270)
    Self.expectClose(CGPoint(x: 0, y: 0).applying(transform), CGPoint(x: 200, y: 100))
    Self.expectClose(CGPoint(x: 0, y: 200).applying(transform), CGPoint(x: 0, y: 100))
  }

  // MARK: 2 — HighlightOverlay.apply

  @Test func applyPopulatesAllMatchesPathAndLeavesCurrentEmptyWhenOrdinalNil() {
    let parent = CALayer()
    parent.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let overlay = HighlightOverlay(parent: parent)
    let highlights = PageSearchHighlights(matches: [[Self.sampleQuad], [Self.sampleQuad]])

    overlay.apply(highlights, currentOrdinal: nil)

    let shapeLayers = Self.shapeLayers(of: parent)
    #expect(shapeLayers.count == 2)
    #expect(!(shapeLayers[0].path?.isEmpty ?? true)) // 전체 매치 레이어 — 비어 있지 않음.
    #expect(shapeLayers[1].path?.isEmpty ?? true) // 현재 매치 레이어 — currentOrdinal nil.
  }

  @Test func applyWithCurrentOrdinalPopulatesCurrentLayer() {
    let parent = CALayer()
    parent.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let overlay = HighlightOverlay(parent: parent)
    let highlights = PageSearchHighlights(matches: [[Self.sampleQuad], [Self.sampleQuad]])

    overlay.apply(highlights, currentOrdinal: 1)

    let shapeLayers = Self.shapeLayers(of: parent)
    #expect(!(shapeLayers[1].path?.isEmpty ?? true))
  }

  @Test func clearRemovesBothPaths() {
    let parent = CALayer()
    parent.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let overlay = HighlightOverlay(parent: parent)
    let highlights = PageSearchHighlights(matches: [[Self.sampleQuad]])
    overlay.apply(highlights, currentOrdinal: 0)

    overlay.clear()

    let shapeLayers = Self.shapeLayers(of: parent)
    #expect(shapeLayers.allSatisfy { $0.path == nil })
  }

  // MARK: 3 — PageLayerController.prepareForReuse 후 하이라이트 잔류 없음

  @Test func prepareForReuseClearsSearchHighlights() {
    let controller = PageLayerController()
    controller.configure(pageIndex: 0, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    controller.setSearchHighlights(
      PageSearchHighlights(matches: [[Self.sampleQuad]]), currentOrdinal: 0
    )

    let before = Self.shapeLayers(of: controller.overlayLayer)
    #expect(before.contains { !($0.path?.isEmpty ?? true) })

    controller.prepareForReuse()

    let after = Self.shapeLayers(of: controller.overlayLayer)
    #expect(after.allSatisfy { $0.path == nil })
  }
}

// MARK: - 테스트 헬퍼

extension HighlightOverlayTests {
  /// 축 정렬 표본 quad (10×10).
  static var sampleQuad: Quad {
    Quad(
      bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 10, y: 0),
      topRight: CGPoint(x: 10, y: 10), topLeft: CGPoint(x: 0, y: 10)
    )
  }

  /// `layer`의 `CAShapeLayer` 서브레이어들 (삽입 순서 — 전체 매치 → 현재 매치).
  static func shapeLayers(of layer: CALayer) -> [CAShapeLayer] {
    (layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
  }

  /// 부동소수 근사 좌표 비교.
  static func expectClose(_ value: CGPoint, _ expected: CGPoint, tolerance: CGFloat = 0.0001) {
    #expect(abs(value.x - expected.x) < tolerance)
    #expect(abs(value.y - expected.y) < tolerance)
  }
}
