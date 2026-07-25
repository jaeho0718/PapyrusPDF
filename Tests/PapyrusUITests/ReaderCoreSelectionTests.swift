import CoreGraphics
import PapyrusCore
import PapyrusRendering
@testable import PapyrusUI
import QuartzCore
import Testing

/// `ReaderCore`의 선택 통합(§1.8~1.9)·모델 배선(§1.11)을 검증한다 (설계 §6-5).
@MainActor
struct ReaderCoreSelectionTests {
  /// `layer`의 `CAShapeLayer` 서브레이어 중 지정 `zPosition`이고 비어 있지 않은 path가
  /// 있는지 확인한다.
  private static func hasNonEmptyPath(_ layer: CALayer, zPosition: CGFloat) -> Bool {
    (layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
      .contains { $0.zPosition == zPosition && !($0.path?.isEmpty ?? true) }
  }

  /// 선택 컨트롤러를 미리 로드된 스토어와 함께 만든다.
  private static func makeSelectionController(
    pages: [Int]
  ) async throws -> (controller: ReaderSelectionController, store: ReaderSelectablePageStore) {
    var contents: [Int: PageTextContent] = [:]
    for page in pages {
      contents[page] = SelectionTestFixtures.singleLineContent(pageIndex: page)
    }
    let provider = DictionaryTextProvider(contents: contents)
    let store = ReaderSelectablePageStore(provider: provider, displayTransform: { _ in .identity })
    for page in pages {
      store.requestPage(page)
    }
    try await UITestSupport.waitUntil { pages.allSatisfy { store.geometry(forPage: $0) != nil } }
    return (ReaderSelectionController(store: store), store)
  }

  // MARK: pagePoint(forContentPoint:) 분해

  @Test func pagePointResolvesInteriorPointToLocalPageSpace() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, pageWidth: 200, pageHeight: 200
    )
    let frame = try #require(core.layout.pageFrame(at: 0))

    let resolved = core.pagePoint(forContentPoint: CGPoint(x: frame.minX + 38, y: frame.minY + 38))

    #expect(resolved?.pageIndex == 0)
    #expect(resolved?.point == CGPoint(x: 38, y: 38))
  }

  @Test func pagePointOverGapAttributesToNextPage() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, pageWidth: 200, pageHeight: 200
    )
    let page0 = try #require(core.layout.pageFrame(at: 0))
    let page1 = try #require(core.layout.pageFrame(at: 1))
    let gapY = page0.maxY + (page1.minY - page0.maxY) / 2 // 간격 한가운데.

    let resolved = core.pagePoint(forContentPoint: CGPoint(x: page0.minX, y: gapY))

    #expect(resolved?.pageIndex == 1) // 간격 위는 다음 페이지 귀속 (레이아웃 엔진 계약).
  }

  @Test func pagePointInMarginAllowsNegativeLocalCoordinate() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 1, pageWidth: 200, pageHeight: 200
    )
    let frame = try #require(core.layout.pageFrame(at: 0))

    let resolved = core.pagePoint(forContentPoint: CGPoint(x: 0, y: frame.minY + 10))

    #expect(resolved?.pageIndex == 0)
    #expect((resolved?.point.x ?? 0) < 0) // 좌측 여백 — 음수 로컬 x 허용.
  }

  @Test func pagePointOnEmptyDocumentReturnsNil() async throws {
    let core = try await UITestSupport.makeReaderCore(pageCount: 0)
    #expect(core.pagePoint(forContentPoint: CGPoint(x: 10, y: 10)) == nil)
  }

  // MARK: 실체화 재적용 — 창 이탈→재진입 시 선택 quad 재반영

  @Test func selectionReappliedAfterMaterializationReentry() async throws {
    let (selectionController, store) = try await Self.makeSelectionController(pages: [0])
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 30, pageWidth: 200, pageHeight: 200, selectionController: selectionController
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)

    _ = store // 참조 유지 (dealloc 방지).
    selectionController.select(
      TextSelection(
        start: TextPosition(pageIndex: 0, utf16Offset: 0),
        end: TextPosition(pageIndex: 0, utf16Offset: 5)
      )
    )
    var controller0 = try #require(core.controllers[0])
    let zPos = OverlayZPosition.selectionFill
    #expect(Self.hasNonEmptyPath(controller0.overlayLayer, zPosition: zPos))

    // 멀리 스크롤 — 페이지 0이 실체화 창을 벗어나 컨트롤러가 풀로 반환되고, 선택 상태의
    // prefetch는 보호 집합이 없어(§2.2 note) 캐시된 지오메트리도 함께 퇴거된다.
    host.visibleContentRect = CGRect(x: 0, y: 5000, width: 300, height: 300)
    core.hostViewportDidChange()
    #expect(core.controllers[0] == nil)
    #expect(store.geometry(forPage: 0) == nil)

    // 되돌아온다 — updateMaterialization의 도입 루프가 즉시 applySelection을 호출하지만,
    // 지오메트리는 store.prefetch가 비동기로 재요청한다 — 도착 시 T23(k ∈ pageRange →
    // 무효화)이 applySelection을 한 번 더 호출해 오버레이를 복원한다.
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.hostViewportDidChange()

    try await UITestSupport.waitUntil {
      guard let controller = core.controllers[0] else {
        return false
      }
      return Self.hasNonEmptyPath(
        controller.overlayLayer, zPosition: OverlayZPosition.selectionFill
      )
    }
    controller0 = try #require(core.controllers[0])
    #expect(Self.hasNonEmptyPath(controller0.overlayLayer, zPosition: zPos))
  }

  // MARK: updateOverlayContentsScale — 검색+선택 동시 갱신

  @Test func updateOverlayContentsScaleUpdatesBothSearchAndSelectionLayers() async throws {
    let (selectionController, store) = try await Self.makeSelectionController(pages: [0])
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, pageWidth: 200, pageHeight: 200, pixelScale: 2,
      selectionController: selectionController
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    _ = store

    let quad = Quad(
      bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 10, y: 0),
      topRight: CGPoint(x: 10, y: 10), topLeft: CGPoint(x: 0, y: 10)
    )
    core.handleSearchEvent(.began(query: "x"))
    core.handleSearchEvent(
      .pageResults(pageIndex: 0, highlights: PageSearchHighlights(matches: [[quad]]))
    )
    selectionController.select(
      TextSelection(
        start: TextPosition(pageIndex: 0, utf16Offset: 0),
        end: TextPosition(pageIndex: 0, utf16Offset: 5)
      )
    )

    host.zoomScale = 4 // 버킷 재스냅을 유발할 배율.
    core.hostZoomInteractionDidEnd()

    let controller0 = try #require(core.controllers[0])
    let searchLayer = (controller0.overlayLayer.sublayers ?? [])
      .compactMap { $0 as? CAShapeLayer }
      .first { $0.zPosition == OverlayZPosition.searchAllMatches }
    let selectionLayer = (controller0.overlayLayer.sublayers ?? [])
      .compactMap { $0 as? CAShapeLayer }
      .first { $0.zPosition == OverlayZPosition.selectionFill }

    #expect((searchLayer?.contentsScale ?? 0) > 2) // pixelScale(2) × bucketScale > 2.
    #expect(searchLayer?.contentsScale == selectionLayer?.contentsScale) // 동일 규칙으로 갱신.
  }

  // MARK: 모델 배선

  @Test func modelObservesSelectionChangesAfterAttach() async throws {
    let (selectionController, store) = try await Self.makeSelectionController(pages: [0])
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, selectionController: selectionController
    )
    _ = store
    let model = PapyrusReaderModel()
    model.attach(core: core)

    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    model.select(selection)

    #expect(model.selection == selection)
  }

  @Test func modelQueuesSelectBeforeAttachAndReplaysAfterAttach() async throws {
    let (selectionController, store) = try await Self.makeSelectionController(pages: [0])
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, selectionController: selectionController
    )
    _ = store
    let model = PapyrusReaderModel()
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )

    model.select(selection) // 미연결 — 보류.
    #expect(model.selection == nil)

    model.attach(core: core)

    #expect(model.selection == selection) // attach 직후 재생.
  }

  @Test func modelBeginLoadingResetsSelectionAndDropsPendingSelect() async throws {
    let (selectionController, store) = try await Self.makeSelectionController(pages: [0])
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, selectionController: selectionController
    )
    _ = store
    let model = PapyrusReaderModel()
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )

    model.select(selection) // 보류.
    model.beginLoading() // 보류 폐기 + nil 리셋.
    model.attach(core: core)

    #expect(model.selection == nil)
  }

  @Test func modelClearSelectionPropagatesToController() async throws {
    let (selectionController, store) = try await Self.makeSelectionController(pages: [0])
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, selectionController: selectionController
    )
    _ = store
    let model = PapyrusReaderModel()
    model.attach(core: core)
    model.select(
      TextSelection(
        start: TextPosition(pageIndex: 0, utf16Offset: 0),
        end: TextPosition(pageIndex: 0, utf16Offset: 5)
      )
    )
    #expect(model.selection != nil)

    model.clearSelection()

    #expect(model.selection == nil)
    #expect(selectionController.selection == nil)
  }
}
