import CoreGraphics
import PapyrusPDFCore
import PapyrusPDFUI
import Testing

/// ``ReaderSelectionController/selectedStringFromCache()``(동기 캐시 전용 조립, 설계
/// §4.5)를 검증한다 — `ReaderSelectionControllerTests`의 파일 길이 한도로 분리(§6-3).
@MainActor
struct ReaderSelectionControllerQueryTests {
  @Test func selectedStringFromCacheMatchesAsyncPathWhenAllPagesCached() async throws {
    let (controller, store) = try await SelectionTestFixtures.makeReadySelectionController(
      pages: [0, 1], texts: [0: "Hello World", 1: "Second Page"]
    )
    _ = store
    controller.select(
      TextSelection(
        start: TextPosition(pageIndex: 0, utf16Offset: 0),
        end: TextPosition(pageIndex: 1, utf16Offset: 6)
      )
    )

    let cached = controller.selectedStringFromCache()
    let resolvedAsync = await controller.selectedString()

    #expect(cached == resolvedAsync)
    #expect(cached == "Hello World\nSecond")
  }

  @Test func selectedStringFromCacheReturnsNilWhenAPageIsUncached() async throws {
    let contents: [Int: PageTextContent] = [
      0: SelectionTestFixtures.singleLineContent(pageIndex: 0),
      1: SelectionTestFixtures.singleLineContent(pageIndex: 1)
    ]
    let provider = DictionaryTextProvider(contents: contents)
    let store = ReaderSelectablePageStore(provider: provider, displayTransform: { _ in .identity })
    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }
    // 페이지 1은 의도적으로 요청하지 않는다 — 캐시 미스를 재현한다.

    let controller = ReaderSelectionController(store: store)
    controller.select(
      TextSelection(
        start: TextPosition(pageIndex: 0, utf16Offset: 0),
        end: TextPosition(pageIndex: 1, utf16Offset: 5)
      )
    )

    #expect(controller.selectedStringFromCache() == nil)
  }

  @Test func selectedStringFromCacheTruncatesAtCapSameAsAsyncPath() async throws {
    let cap = UILimits.maxSelectedTextUTF16
    let page0Text = String(repeating: "A", count: 1_500_000)
    let page1Text = String(repeating: "A", count: 1_500_000)
    let page2Prefix = cap - 1_500_000 - 1_500_000 - 1
    let page2Text = String(repeating: "A", count: page2Prefix) + "😀" + "B"
    let (controller, store) = try await SelectionTestFixtures.makeReadySelectionController(
      pages: [0, 1, 2], texts: [0: page0Text, 1: page1Text, 2: page2Text]
    )
    _ = store
    controller.select(
      TextSelection(
        start: TextPosition(pageIndex: 0, utf16Offset: 0),
        end: TextPosition(pageIndex: 2, utf16Offset: page2Text.utf16.count)
      )
    )

    let cached = controller.selectedStringFromCache()
    let resolvedAsync = await controller.selectedString()

    #expect(cached == resolvedAsync)
    #expect((cached?.utf16.count ?? 0) > cap) // 개행 2개만큼은 캡을 넘어도 된다.
  }
}
