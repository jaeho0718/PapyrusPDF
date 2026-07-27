import CoreGraphics
import PapyrusPDFCore
import PapyrusPDFRendering
@testable import PapyrusPDFUI
import QuartzCore
import Testing

/// 코어의 지속 하이라이트 mirror·반영·색상 그룹핑·z-순서(설계 §5-4)를 검증한다.
@MainActor
struct ReaderCoreHighlightTests {
  /// `layer`의 `CAShapeLayer` 서브레이어 중 지정 `zPosition`이고 비어 있지 않은 path가
  /// 있는지 확인한다 (`ReaderCoreRegionTests`와 동형의 로컬 헬퍼).
  private static func hasNonEmptyPath(_ layer: CALayer, zPosition: CGFloat) -> Bool {
    (layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
      .contains { $0.zPosition == zPosition && !($0.path?.isEmpty ?? true) }
  }

  /// 결정적 테스트 quad.
  private static func quad(x: CGFloat = 0) -> Quad {
    Quad(rect: CGRect(x: x, y: 0, width: 10, height: 10))
  }

  private static func highlight(page: Int, x: CGFloat = 0, color: HighlightColor = .yellow)
    -> Highlight {
    Highlight(pageIndex: page, quads: [Self.quad(x: x)], color: color)
  }

  /// 지정 페이지들을 미리 로드한 스토어로 선택 컨트롤러를 만들고, 넓은 문서(8페이지, 뷰포트
  /// 상단만 가시)에 부착한다 — 앞쪽 몇 페이지만 실체화되고 뒤쪽은 mirror만 쌓이는 창을
  /// 만들기 위함이다.
  private static func makeAttachedCore(
    preloadedPages: [Int], pageCount: Int = 8
  ) async throws -> (core: ReaderCore, host: MockScrollHost) {
    var contents: [Int: PageTextContent] = [:]
    for page in preloadedPages {
      contents[page] = SelectionTestFixtures.singleLineContent(pageIndex: page)
    }
    let provider = DictionaryTextProvider(contents: contents)
    let store = ReaderSelectablePageStore(provider: provider, displayTransform: { _ in .identity })
    for page in preloadedPages {
      store.requestPage(page)
    }
    try await UITestSupport.waitUntil {
      preloadedPages.allSatisfy { store.geometry(forPage: $0) != nil }
    }
    let selectionController = ReaderSelectionController(store: store)
    let core = try await UITestSupport.makeReaderCore(
      pageCount: pageCount, pageWidth: 200, pageHeight: 200,
      selectionController: selectionController
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    return (core, host)
  }

  // MARK: highlightGroups — 순수 함수

  @Test func highlightGroupsPreservesFirstAppearanceColorOrder() {
    let highlights = [
      Self.highlight(page: 0, x: 0, color: .blue),
      Self.highlight(page: 0, x: 10, color: .yellow),
      Self.highlight(page: 0, x: 20, color: .blue)
    ]

    let groups = ReaderCore.highlightGroups(for: highlights, transform: .identity)

    #expect(groups.map(\.color) == [.blue, .yellow])
    #expect(groups[0].quads.count == 2) // 두 파랑 하이라이트가 한 그룹으로 합쳐진다.
    #expect(groups[1].quads.count == 1)
  }

  @Test func highlightGroupsAppliesTransformToQuads() {
    let translation = CGAffineTransform(translationX: 100, y: 50)
    let highlights = [Self.highlight(page: 0, color: .yellow)]

    let groups = ReaderCore.highlightGroups(for: highlights, transform: translation)

    let expected = PageDisplayTransform.apply(translation, to: Self.quad())
    #expect(groups.first?.quads.first == expected)
  }

  @Test func highlightGroupsSkipsNonFiniteResultsFromPathologicalTransformAndDropsEmptyGroups() {
    let pathological = CGAffineTransform(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    let highlights = [Self.highlight(page: 0, color: .yellow)]

    let groups = ReaderCore.highlightGroups(for: highlights, transform: pathological)

    #expect(groups.isEmpty) // 유일한 quad가 비유한이 되어 그룹 자체가 제외된다.
  }

  // MARK: setHighlights — 실체화/미실체화 분기

  @Test func setHighlightsOnMaterializedPageAppliesGroupToController() async throws {
    let (core, _) = try await Self.makeAttachedCore(preloadedPages: [0])

    core.setHighlights([Self.highlight(page: 0)], forPage: 0)

    let controller = try #require(core.controllers[0])
    #expect(
      Self.hasNonEmptyPath(
        controller.overlayLayer, zPosition: OverlayZPosition.persistentHighlight
      )
    )
  }

  @Test func setHighlightsOnUnmaterializedPageOnlyUpdatesMirror() async throws {
    let (core, _) = try await Self.makeAttachedCore(preloadedPages: [0])
    // 8페이지 문서에서 상단만 보이므로 뒤쪽 페이지는 실체화되지 않는다.
    #expect(core.controllers[7] == nil)

    core.setHighlights([Self.highlight(page: 7)], forPage: 7)

    #expect(core.controllers[7] == nil) // 여전히 미실체화 — 레이어 작업 없음.
    #expect(core.persistentHighlights[7]?.count == 1) // mirror만 갱신.
  }

  // MARK: 변환 미보유 → 미표시, onPageContentReady 발화 후 반영

  @Test func highlightWaitsForTransformThenAppliesOnContentReady() async throws {
    let page0 = SelectionTestFixtures.singleLineContent(pageIndex: 0)
    let page1 = SelectionTestFixtures.singleLineContent(pageIndex: 1)
    let gated = GatedTextProvider(contents: [0: page0, 1: page1])
    let store = ReaderSelectablePageStore(provider: gated, displayTransform: { _ in .identity })
    gated.open(0)
    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }

    let selectionController = ReaderSelectionController(store: store)
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 2, pageWidth: 200, pageHeight: 200, selectionController: selectionController
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 900)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 900)
    core.attach(to: host) // 페이지 1도 실체화되지만 store 로드는 게이트로 막혀 있다.

    core.setHighlights([Self.highlight(page: 1)], forPage: 1)
    let controller = try #require(core.controllers[1])
    #expect(
      !Self.hasNonEmptyPath(
        controller.overlayLayer, zPosition: OverlayZPosition.persistentHighlight
      )
    ) // 변환 미보유 — 아직 미표시.

    gated.open(1)
    try await UITestSupport.waitUntil {
      Self.hasNonEmptyPath(
        controller.overlayLayer, zPosition: OverlayZPosition.persistentHighlight
      )
    }
  }

  // MARK: 실체화 창 이탈 → 재진입 복원, prepareForReuse 잔류 없음

  @Test func highlightSurvivesMaterializationExitAndReenters() async throws {
    let (core, host) = try await Self.makeAttachedCore(preloadedPages: [0, 3], pageCount: 8)
    core.setHighlights([Self.highlight(page: 3)], forPage: 3)
    let originalController = try #require(core.controllers[3])
    #expect(
      Self.hasNonEmptyPath(
        originalController.overlayLayer, zPosition: OverlayZPosition.persistentHighlight
      )
    )

    // 뒤쪽으로 스크롤 — 페이지 3이 실체화 창을 벗어나 풀로 회수된다.
    let farFrame = try #require(core.layout.pageFrame(at: 7))
    host.visibleContentRect = CGRect(
      x: 0, y: farFrame.minY, width: host.viewportSize.width, height: host.viewportSize.height
    )
    core.hostViewportDidChange()
    #expect(core.controllers[3] == nil)
    #expect(
      !Self.hasNonEmptyPath(
        originalController.overlayLayer, zPosition: OverlayZPosition.persistentHighlight
      )
    ) // prepareForReuse가 잔류를 지웠다.

    // 원위치로 복귀 — 페이지 3이 재실체화되며 mirror·memoize된 변환으로 즉시 복원된다.
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.hostViewportDidChange()

    let restoredController = try #require(core.controllers[3])
    #expect(
      Self.hasNonEmptyPath(
        restoredController.overlayLayer, zPosition: OverlayZPosition.persistentHighlight
      )
    )
  }

  // MARK: z-순서 — 검색+선택+지속 하이라이트 동시 설정

  @Test func layerZOrderIsPersistentThenSearchAllThenSearchCurrentThenSelectionFill()
    async throws {
    let (core, _) = try await Self.makeAttachedCore(preloadedPages: [0])
    let controller = try #require(core.controllers[0])
    let quad = Self.quad()

    // 삽입 순서를 의도적으로 지속 하이라이트가 "마지막"이 되도록 만든다 — z-순서가
    // 서브레이어 배열 삽입 순서가 아니라 zPosition 자체로 결정됨을 관찰하기 위함이다.
    controller.setSearchHighlights(PageSearchHighlights(matches: [[quad]]), currentOrdinal: 0)
    controller.setSelection([quad], handles: nil, handleScale: 1)
    core.setHighlights([Self.highlight(page: 0)], forPage: 0)

    let shapeLayers = (controller.overlayLayer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
      .filter { !($0.path?.isEmpty ?? true) }
    let sortedZPositions = shapeLayers.map(\.zPosition).sorted()

    #expect(
      sortedZPositions == [
        OverlayZPosition.persistentHighlight, OverlayZPosition.searchAllMatches,
        OverlayZPosition.searchCurrentMatch, OverlayZPosition.selectionFill
      ]
    )
  }
}
