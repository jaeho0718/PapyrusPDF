import CoreGraphics
import PapyrusCore
import PapyrusRendering
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import PapyrusUI
import Testing

/// 코어 선택 메뉴 파이프라인(설계 §4.2 iOS push·§4.3 macOS pull·§4.5 프리페치 캐시)을
/// 검증한다 — `ReaderCoreSelectionTests`의 파일 길이 한도로 분리(§6-4).
@MainActor
struct ReaderCoreMenuTests {
  // MARK: 코어 메뉴 파이프라인 — iOS push 표면

  @Test func presentResolvedMenuPresentsBuilderItemsAtPageOffsetAnchor() async throws {
    let (selectionController, store) = try await SelectionTestFixtures
      .makeReadySelectionController(pages: [0])
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, pageWidth: 200, pageHeight: 200, selectionController: selectionController
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    _ = store

    var capturedTexts: [String] = []
    core.selectionMenuBuilder = { context in
      guard case let .text(textContext) = context else {
        return []
      }
      capturedTexts.append(textContext.selectedText)
      return [SelectionMenuItem(title: "Highlight", systemImage: "highlighter") { _ in }]
    }
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    selectionController.select(selection)

    await core.presentResolvedMenu(anchorPage: 0)

    #expect(host.presentedMenus.count == 1)
    #expect(host.presentedMenus.first?.items.map(\.title) == ["Highlight"])
    #expect(capturedTexts == ["Hello"])
    let anchorRect = try #require(selectionController.menuAnchorRect(forPage: 0))
    let frame = try #require(core.layout.pageFrame(at: 0))
    let expectedRect = anchorRect.offsetBy(dx: frame.minX, dy: frame.minY)
    #expect(host.presentedMenus.first?.contentRect == expectedRect)
  }

  @Test func presentResolvedMenuDoesNotPresentWhenBuilderReturnsEmptyArray() async throws {
    let (selectionController, store) = try await SelectionTestFixtures
      .makeReadySelectionController(pages: [0])
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, pageWidth: 200, pageHeight: 200, selectionController: selectionController
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    _ = store
    core.selectionMenuBuilder = { _ in [] }
    selectionController.select(
      TextSelection(
        start: TextPosition(pageIndex: 0, utf16Offset: 0),
        end: TextPosition(pageIndex: 0, utf16Offset: 5)
      )
    )

    await core.presentResolvedMenu(anchorPage: 0)

    #expect(host.presentedMenus.isEmpty)
  }

  @Test func presentResolvedMenuDiscardsWhenSelectionClearedDuringResolution() async throws {
    let page0 = SelectionTestFixtures.singleLineContent(pageIndex: 0)
    let gated = GatedTextProvider(contents: [0: page0])
    let store = ReaderSelectablePageStore(provider: gated, displayTransform: { _ in .identity })
    let selectionController = ReaderSelectionController(store: store)
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, pageWidth: 200, pageHeight: 200, selectionController: selectionController
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)

    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    selectionController.select(selection)

    let presentTask = Task { await core.presentResolvedMenu(anchorPage: 0) }
    try await Task.sleep(for: .milliseconds(20)) // 게이트 대기 진입 시간 확보.
    selectionController.clear() // 해소 중(게이트 대기 중) 선택 해제 — 스테일 취급 기대.
    gated.open(0)
    await presentTask.value

    #expect(host.presentedMenus.isEmpty)
  }

  // MARK: 코어 메뉴 파이프라인 — macOS pull 표면

  @Test func hostContextMenuItemsReturnsEmptyWhenNoSelection() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    let frame = try #require(core.layout.pageFrame(at: 0))

    let items = core.hostContextMenuItems(
      atContentPoint: CGPoint(x: frame.minX + 10, y: frame.minY + 10)
    )

    #expect(items.isEmpty)
  }

  @Test func hostContextMenuItemsReturnsEmptyWhenPointOutsideSelectionQuad() async throws {
    let (selectionController, store) = try await SelectionTestFixtures
      .makeReadySelectionController(pages: [0])
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, pageWidth: 200, pageHeight: 200, selectionController: selectionController
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    _ = store
    selectionController.select(
      TextSelection(
        start: TextPosition(pageIndex: 0, utf16Offset: 0),
        end: TextPosition(pageIndex: 0, utf16Offset: 5)
      )
    )
    let frame = try #require(core.layout.pageFrame(at: 0))

    // 선택 quad는 x∈[0, 50], y∈[0, 20] 부근이다(§ SelectionTestFixtures) — 훨씬 아래쪽은 밖.
    let items = core.hostContextMenuItems(
      atContentPoint: CGPoint(x: frame.minX + 150, y: frame.minY + 150)
    )

    #expect(items.isEmpty)
  }

  @Test func hostContextMenuItemsFallsBackToCacheOnlyAssemblyWhenPrefetchPending() async throws {
    let (selectionController, store) = try await SelectionTestFixtures
      .makeReadySelectionController(pages: [0])
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, pageWidth: 200, pageHeight: 200, selectionController: selectionController
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    _ = store
    selectionController.select(
      TextSelection(
        start: TextPosition(pageIndex: 0, utf16Offset: 0),
        end: TextPosition(pageIndex: 0, utf16Offset: 5)
      )
    )
    let frame = try #require(core.layout.pageFrame(at: 0))

    // select() 직후, 어떤 await도 거치지 않고 바로 질의한다 — 프리페치 태스크가 아직
    // 스케줄되지 않은(캐시 미스) 상태를 결정적으로 재현한다(§4.5 ② 경로).
    let items = core.hostContextMenuItems(
      atContentPoint: CGPoint(x: frame.minX + 10, y: frame.minY + 10)
    )

    #expect(items.count == 1)
    items.first?.action()
    #if canImport(AppKit)
    #expect(NSPasteboard.general.string(forType: .string) == "Hello")
    #elseif canImport(UIKit)
    #expect(UIPasteboard.general.string == "Hello")
    #endif
  }

  @Test func hostContextMenuItemsUsesPrefetchedCacheWhenAvailable() async throws {
    let (selectionController, store) = try await SelectionTestFixtures
      .makeReadySelectionController(pages: [0])
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, pageWidth: 200, pageHeight: 200, selectionController: selectionController
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    _ = store
    selectionController.select(
      TextSelection(
        start: TextPosition(pageIndex: 0, utf16Offset: 0),
        end: TextPosition(pageIndex: 0, utf16Offset: 5)
      )
    )
    try await Task.sleep(for: .milliseconds(20)) // 프리페치 태스크 완료 대기(캐시 적중 유도).
    let frame = try #require(core.layout.pageFrame(at: 0))

    let items = core.hostContextMenuItems(
      atContentPoint: CGPoint(x: frame.minX + 10, y: frame.minY + 10)
    )

    #expect(items.count == 1)
    items.first?.action()
    #if canImport(AppKit)
    #expect(NSPasteboard.general.string(forType: .string) == "Hello")
    #elseif canImport(UIKit)
    #expect(UIPasteboard.general.string == "Hello")
    #endif
  }

  // MARK: 빌더 교체 — 재조립 없이 다음 확정부터 반영

  @Test func selectionMenuBuilderReplacementAppliesOnNextPresentation() async throws {
    let (selectionController, store) = try await SelectionTestFixtures
      .makeReadySelectionController(pages: [0])
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, pageWidth: 200, pageHeight: 200, selectionController: selectionController
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    _ = store
    let coreIdentity = ObjectIdentifier(core)

    core.selectionMenuBuilder = { _ in [SelectionMenuItem(title: "Old") { _ in }] }
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    selectionController.select(selection)
    await core.presentResolvedMenu(anchorPage: 0)
    #expect(host.presentedMenus.first?.items.map(\.title) == ["Old"])

    // 빌더 교체(환경 갱신에 해당) 후 같은 코어 인스턴스에서 재확정한다 — 재조립 없음.
    core.selectionMenuBuilder = { _ in [SelectionMenuItem(title: "New") { _ in }] }
    selectionController.clear()
    selectionController.select(selection)
    await core.presentResolvedMenu(anchorPage: 0)

    #expect(ObjectIdentifier(core) == coreIdentity)
    #expect(host.presentedMenus.count == 2)
    #expect(host.presentedMenus.last?.items.map(\.title) == ["New"])
  }
}
