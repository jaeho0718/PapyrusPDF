import CoreGraphics
import PapyrusPDFCore
@testable import PapyrusPDFUI
import Testing

/// `PapyrusPDFReaderModel.selectedRegionAnchor`의 0.3.0 계약을 검증한다:
/// ① `selectedRegion`과 같은 통지(같은 런루프 턴)에서 함께 선다 ② 선택 해제·문서
/// 교체·텍스트 선택 전환에서 함께 `nil`이 된다 ③ 값이 리더 뷰 좌표다 — 줌·스크롤
/// 상태가 다르면 같은 영역이라도 앵커가 그 상태의 뷰 좌표로 선다(콘텐츠 좌표 유출 검출).
@MainActor
struct PapyrusPDFReaderModelAnchorTests {
  /// 텍스트 quad와 겹치지 않는 결정적 테스트 영역 (`PapyrusPDFReaderModelRegionTests` 관례).
  private static func region(id: String = "r1", page: Int = 0) -> SelectableRegion {
    SelectableRegion(
      id: id, pageIndex: page, quad: Quad(rect: CGRect(x: 500, y: 0, width: 20, height: 20))
    )
  }

  /// 선택 컨트롤러가 배선된, 호스트에 부착된 코어를 만든다 (표시 변환은 identity —
  /// 페이지 공간 quad가 곧 표시 quad).
  private static func makeAttachedCore() async throws -> (core: ReaderCore, host: MockScrollHost) {
    let provider = DictionaryTextProvider(
      contents: [0: SelectionTestFixtures.singleLineContent(pageIndex: 0)]
    )
    let store = ReaderSelectablePageStore(provider: provider, displayTransform: { _ in .identity })
    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }
    let selectionController = ReaderSelectionController(store: store)
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, pageWidth: 200, pageHeight: 200, selectionController: selectionController
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    return (core, host)
  }

  /// 영역 내부 콘텐츠 공간 탭 점.
  private static func contentPoint(
    for region: SelectableRegion, core: ReaderCore
  ) throws -> CGPoint {
    let frame = try #require(core.layout.pageFrame(at: region.pageIndex))
    let rect = region.quad.boundingRect
    return CGPoint(x: frame.minX + rect.midX, y: frame.minY + rect.midY)
  }

  /// 현재 호스트 줌·가시 원점 기준으로 기대되는 리더 뷰 좌표 앵커를 계산한다.
  private static func expectedAnchor(
    for region: SelectableRegion, core: ReaderCore, host: MockScrollHost
  ) throws -> CGRect {
    let frame = try #require(core.layout.pageFrame(at: region.pageIndex))
    let content = region.quad.boundingRect.offsetBy(dx: frame.minX, dy: frame.minY)
    let zoom = host.zoomScale
    let origin = host.visibleContentRect.origin
    return CGRect(
      x: (content.minX - origin.x) * zoom, y: (content.minY - origin.y) * zoom,
      width: content.width * zoom, height: content.height * zoom
    )
  }

  // MARK: ① 선택과 같은 턴에 함께 선다

  @Test func anchorIsSetWithSelectedRegionInSameTurn() async throws {
    let model = PapyrusPDFReaderModel()
    let (core, host) = try await Self.makeAttachedCore()
    model.attach(core: core)
    let region = Self.region()
    model.setSelectableRegions([region], forPage: 0)
    #expect(model.selectedRegionAnchor == nil)

    core.hostTap(atContentPoint: try Self.contentPoint(for: region, core: core))

    // 탭 직후 동기 단언 — await 없이 selectedRegion과 같은 턴에 서 있어야 한다.
    #expect(model.selectedRegion?.id == "r1")
    let anchor = try #require(model.selectedRegionAnchor)
    #expect(anchor == (try Self.expectedAnchor(for: region, core: core, host: host)))
  }

  // MARK: ② 해제·문서 교체·텍스트 선택 전환에서 함께 nil

  @Test func anchorClearsTogetherOnMissTapAndClearSelection() async throws {
    let model = PapyrusPDFReaderModel()
    // 호스트를 로컬로 붙든다 — `core.host`가 weak라 버리면 앵커 계산이 미부착이 된다.
    let (core, host) = try await Self.makeAttachedCore()
    model.attach(core: core)
    let region = Self.region()
    model.setSelectableRegions([region], forPage: 0)
    let tapPoint = try Self.contentPoint(for: region, core: core)
    let expected = try Self.expectedAnchor(for: region, core: core, host: host)

    core.hostTap(atContentPoint: tapPoint)
    #expect(model.selectedRegionAnchor == expected)
    core.hostTap(atContentPoint: CGPoint(x: 1, y: 1)) // 미스 — 해제.
    #expect(model.selectedRegion == nil)
    #expect(model.selectedRegionAnchor == nil)

    core.hostTap(atContentPoint: tapPoint)
    #expect(model.selectedRegionAnchor == expected)
    model.clearSelection()
    #expect(model.selectedRegion == nil)
    #expect(model.selectedRegionAnchor == nil)
  }

  @Test func anchorClearsOnDocumentReplacement() async throws {
    let model = PapyrusPDFReaderModel()
    let (core, host) = try await Self.makeAttachedCore()
    model.beginLoading(documentID: ObjectIdentifier(core))
    model.attach(core: core)
    let region = Self.region()
    model.setSelectableRegions([region], forPage: 0)
    core.hostTap(atContentPoint: try Self.contentPoint(for: region, core: core))
    #expect(model.selectedRegionAnchor == (try Self.expectedAnchor(
      for: region, core: core, host: host
    )))

    let (replacement, _) = try await Self.makeAttachedCore()
    model.beginLoading(documentID: ObjectIdentifier(replacement)) // 문서 교체.

    #expect(model.selectedRegion == nil)
    #expect(model.selectedRegionAnchor == nil)
  }

  @Test func anchorClearsWhenTextDragBegins() async throws {
    let model = PapyrusPDFReaderModel()
    let (core, host) = try await Self.makeAttachedCore()
    model.attach(core: core)
    let region = Self.region()
    model.setSelectableRegions([region], forPage: 0)
    core.hostTap(atContentPoint: try Self.contentPoint(for: region, core: core))
    #expect(model.selectedRegionAnchor == (try Self.expectedAnchor(
      for: region, core: core, host: host
    )))

    // 텍스트 드래그 시작(T28) — 영역 선택이 해제되며 앵커도 같은 통지에서 눕는다.
    core.hostSelectionDragBegan(atContentPoint: CGPoint(x: 10, y: 10), granularity: .character)

    #expect(model.selectedRegion == nil)
    #expect(model.selectedRegionAnchor == nil)
  }

  // MARK: ③ 줌·스크롤 두 상태에서 뷰 좌표 일관 (콘텐츠 좌표 유출 검출)

  @Test func anchorIsViewCoordinateUnderDifferentZoomAndScroll() async throws {
    let model = PapyrusPDFReaderModel()
    let (core, host) = try await Self.makeAttachedCore()
    model.attach(core: core)
    let region = Self.region()
    model.setSelectableRegions([region], forPage: 0)
    let tapPoint = try Self.contentPoint(for: region, core: core)

    core.hostTap(atContentPoint: tapPoint)
    let anchorAtIdentity = try #require(model.selectedRegionAnchor)
    #expect(anchorAtIdentity == (try Self.expectedAnchor(for: region, core: core, host: host)))

    core.hostTap(atContentPoint: CGPoint(x: 1, y: 1)) // 해제 후 다른 뷰 상태에서 재선택.
    host.zoomScale = 2
    host.visibleContentRect = CGRect(x: 30, y: 50, width: 150, height: 150)
    core.hostTap(atContentPoint: tapPoint)

    let anchorZoomed = try #require(model.selectedRegionAnchor)
    #expect(anchorZoomed == (try Self.expectedAnchor(for: region, core: core, host: host)))
    // 두 상태의 앵커가 달라야 한다 — 같다면 뷰 좌표가 아니라 콘텐츠 좌표를 흘린 것이다.
    #expect(anchorZoomed != anchorAtIdentity)
  }
}
