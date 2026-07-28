import CoreGraphics
import PapyrusPDFCore
import PapyrusPDFRendering
@testable import PapyrusPDFUI
import QuartzCore
import Testing

/// 코어의 영역 선택 배선(설계 §1.7 — `hostTap` 분해·메뉴 파이프라인 일반화·
/// `hostHasSelection`/`hostCanCopy`·`hostContextMenuItems` 영역 분기·상호 배타 오버레이)을
/// 검증한다. 텍스트 경로는 `ReaderCoreSelectionTests`·`ReaderCoreMenuTests`가 담당한다
/// (설계 §5-3).
@MainActor
struct ReaderCoreRegionTests {
  /// `layer`의 `CAShapeLayer` 서브레이어 중 지정 `zPosition`이고 비어 있지 않은 path가
  /// 있는지 확인한다 (`ReaderCoreSelectionTests`와 동형의 로컬 헬퍼).
  private static func hasNonEmptyPath(_ layer: CALayer, zPosition: CGFloat) -> Bool {
    (layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
      .contains { $0.zPosition == zPosition && !($0.path?.isEmpty ?? true) }
  }

  /// 텍스트 quad와 겹치지 않는 결정적 테스트 영역.
  private static func region(
    id: String, page: Int = 0, x: CGFloat = 500, metadata: (any Sendable)? = nil
  ) -> SelectableRegion {
    SelectableRegion(
      id: id, pageIndex: page,
      quad: Quad(rect: CGRect(x: x, y: 0, width: 20, height: 20)), metadata: metadata
    )
  }

  /// 영역 내부 콘텐츠 공간 점.
  private static func contentPoint(
    for region: SelectableRegion, core: ReaderCore
  ) throws -> CGPoint {
    let frame = try #require(core.layout.pageFrame(at: region.pageIndex))
    let rect = region.quad.boundingRect
    return CGPoint(x: frame.minX + rect.midX, y: frame.minY + rect.midY)
  }

  /// 선택 컨트롤러를 미리 로드된 스토어와 함께 만들고, 호스트를 붙인 코어를 조립한다.
  private static func makeAttachedCore(
    pages: [Int], pageCount: Int = 3
  ) async throws -> (core: ReaderCore, host: MockScrollHost) {
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
    let selectionController = ReaderSelectionController(store: store)
    let core = try await UITestSupport.makeReaderCore(
      pageCount: pageCount, pageWidth: 200, pageHeight: 200,
      selectionController: selectionController
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 900)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 900)
    core.attach(to: host)
    return (core, host)
  }

  // MARK: hostTap 분해 — 영역 위 콘텐츠 점 탭

  @Test func hostTapOnRegionPresentsBuilderResolvedMenuAtQuadAnchor() async throws {
    let (core, host) = try await Self.makeAttachedCore(pages: [0])
    let region = Self.region(id: "r1")
    core.setSelectableRegions([region], forPage: 0)
    core.selectionMenuBuilder = { context in
      guard case .region = context else {
        return []
      }
      return [SelectionMenuItem(title: "Figure", systemImage: "photo") { _ in }]
    }

    core.hostTap(atContentPoint: try Self.contentPoint(for: region, core: core))
    try await UITestSupport.waitUntil { host.presentedMenus.count == 1 }

    #expect(host.presentedMenus.first?.items.map(\.title) == ["Figure"])
    let frame = try #require(core.layout.pageFrame(at: 0))
    let expectedRect = region.quad.boundingRect.offsetBy(dx: frame.minX, dy: frame.minY)
    #expect(host.presentedMenus.first?.contentRect == expectedRect)
  }

  // MARK: 메타데이터 왕복 (완료 기준)

  @Test func regionMetadataRoundTripsThroughBuilderAndAction() async throws {
    struct FigureInfo: Sendable, Equatable { let caption: String }
    let (core, host) = try await Self.makeAttachedCore(pages: [0])
    let region = Self.region(id: "r1", metadata: FigureInfo(caption: "그림 1"))
    core.setSelectableRegions([region], forPage: 0)

    var builderReceived: FigureInfo?
    var actionReceived: FigureInfo?
    core.selectionMenuBuilder = { context in
      guard case let .region(received) = context else {
        return []
      }
      builderReceived = received.metadata as? FigureInfo
      return [
        SelectionMenuItem(title: "Show Caption") { actionContext in
          guard case let .region(region) = actionContext else {
            return
          }
          actionReceived = region.metadata as? FigureInfo
        }
      ]
    }

    core.hostTap(atContentPoint: try Self.contentPoint(for: region, core: core))
    try await UITestSupport.waitUntil { host.presentedMenus.count == 1 }
    host.presentedMenus.first?.items.first?.action()

    #expect(builderReceived == FigureInfo(caption: "그림 1"))
    #expect(actionReceived == FigureInfo(caption: "그림 1"))
  }

  // MARK: 스테일 폐기 — 탭 직후 clear → present 미호출

  @Test func staleRegionMenuRequestDiscardedWhenClearedBeforeTaskRuns() async throws {
    let (core, host) = try await Self.makeAttachedCore(pages: [0])
    let region = Self.region(id: "r1")
    core.setSelectableRegions([region], forPage: 0)
    core.selectionMenuBuilder = { _ in [SelectionMenuItem(title: "Figure") { _ in }] }

    core.hostTap(atContentPoint: try Self.contentPoint(for: region, core: core)) // 태스크 예약.
    core.clearSelection() // 태스크 실행 전 동기 해제 — onMenuDismiss가 취소한다.

    try await Task.sleep(for: .milliseconds(30))
    #expect(host.presentedMenus.isEmpty)
    #expect(host.dismissCount >= 1)
  }

  // MARK: 기본 메뉴 — 빌더 nil은 미표시 (region no-op copy 검증은 `SelectionMenuResolverTests`)

  @Test func defaultMenuForRegionWithNoBuilderDoesNotPresent() async throws {
    let (core, host) = try await Self.makeAttachedCore(pages: [0])
    let region = Self.region(id: "r1")
    core.setSelectableRegions([region], forPage: 0)

    core.hostTap(atContentPoint: try Self.contentPoint(for: region, core: core))
    try await Task.sleep(for: .milliseconds(30))

    #expect(host.presentedMenus.isEmpty) // defaultItems(.region) == [].
  }

  // MARK: hostHasSelection / hostCanCopy 매트릭스

  @Test func hostHasSelectionAndHostCanCopyMatrixAcrossSelectionKinds() async throws {
    let (core, _) = try await Self.makeAttachedCore(pages: [0])
    #expect(core.hostHasSelection() == false)
    #expect(core.hostCanCopy() == false)

    core.select(
      TextSelection(
        start: TextPosition(pageIndex: 0, utf16Offset: 0),
        end: TextPosition(pageIndex: 0, utf16Offset: 5)
      )
    )
    #expect(core.hostHasSelection() == true)
    #expect(core.hostCanCopy() == true)

    core.clearSelection()
    let region = Self.region(id: "r1")
    core.setSelectableRegions([region], forPage: 0)
    core.hostTap(atContentPoint: try Self.contentPoint(for: region, core: core))
    #expect(core.hostHasSelection() == true) // 활성 선택(영역)이 있다.
    #expect(core.hostCanCopy() == false) // 복사할 텍스트가 없다.
  }

  // MARK: hostContextMenuItems 영역 분기 (macOS 우클릭 pull)

  @Test func hostContextMenuItemsFallsBackToRegionWhenTextMisses() async throws {
    let (core, host) = try await Self.makeAttachedCore(pages: [0])
    let region = Self.region(id: "r1")
    core.setSelectableRegions([region], forPage: 0)
    core.selectionMenuBuilder = { context in
      guard case .region = context else {
        return []
      }
      return [SelectionMenuItem(title: "Figure") { _ in }]
    }

    let items = core.hostContextMenuItems(
      atContentPoint: try Self.contentPoint(for: region, core: core)
    )

    #expect(items.map(\.title) == ["Figure"])
    // 영역 선택 전이는 일어나지만 push 경로(onMenuRequest)는 발화하지 않는다 — 호출측이
    // 반환 항목을 곧장 표시하므로 이중 표시를 막는다.
    #expect(core.hostHasSelection() == true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(host.presentedMenus.isEmpty)
  }

  @Test func hostContextMenuItemsReturnsEmptyWhenNeitherTextNorRegionHit() async throws {
    let (core, _) = try await Self.makeAttachedCore(pages: [0])
    core.setSelectableRegions([Self.region(id: "r1")], forPage: 0)
    let frame = try #require(core.layout.pageFrame(at: 0))

    let items = core.hostContextMenuItems(
      atContentPoint: CGPoint(x: frame.minX + 900, y: frame.minY + 900)
    )

    #expect(items.isEmpty)
  }

  // MARK: 상호 배타 오버레이 — 텍스트 선택 → 영역 탭

  @Test func mutualExclusionClearsOldTextPageAndDrawsNewRegionPage() async throws {
    let (core, _) = try await Self.makeAttachedCore(pages: [0, 1])
    let region = Self.region(id: "r1", page: 1)
    core.setSelectableRegions([region], forPage: 1)
    core.select(
      TextSelection(
        start: TextPosition(pageIndex: 0, utf16Offset: 0),
        end: TextPosition(pageIndex: 0, utf16Offset: 5)
      )
    )
    let textPageController = try #require(core.controllers[0])
    #expect(
      Self.hasNonEmptyPath(
        textPageController.overlayLayer, zPosition: OverlayZPosition.selectionFill
      )
    )

    core.hostTap(atContentPoint: try Self.contentPoint(for: region, core: core))

    let regionPageController = try #require(core.controllers[1])
    #expect(
      !Self.hasNonEmptyPath(
        textPageController.overlayLayer, zPosition: OverlayZPosition.selectionFill
      )
    ) // 구 텍스트 페이지는 비워진다.
    #expect(
      Self.hasNonEmptyPath(
        regionPageController.overlayLayer, zPosition: OverlayZPosition.selectionFill
      )
    ) // 새 영역 페이지에 채움이 그려진다.
  }
}
