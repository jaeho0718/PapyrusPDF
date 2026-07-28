import CoreGraphics
import PapyrusPDFCore
import PapyrusPDFUI
import Testing

/// 페이지 경계를 넘는 드래그의 잠정 클램프→재계산·지연 정련·토큰 가드·`selectedString`
/// 조립을 검증한다 (설계 §3, §6-3). ``GatedTextProvider``로 도착 시점을 수동 제어한다.
@MainActor
struct SelectionCrossPageTests {
  /// 오프셋 `offset`을 가리키는 페이지 점.
  private static func point(_ offset: Int, page: Int) -> PagePoint {
    PagePoint(pageIndex: page, point: SelectionTestFixtures.point(forOffset: offset))
  }

  // MARK: 전진 잠정 클램프 → 재계산

  @Test func forwardDragIntoUnloadedPageClampsThenRefinesOnArrival() async throws {
    let page0 = SelectionTestFixtures.singleLineContent(pageIndex: 0)
    let page1 = SelectionTestFixtures.singleLineContent(pageIndex: 1)
    let gated = GatedTextProvider(contents: [0: page0, 1: page1])
    let store = ReaderSelectablePageStore(provider: gated, displayTransform: { _ in .identity })
    gated.open(0)
    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }

    let controller = ReaderSelectionController(store: store)
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.dragBegan(at: Self.point(2, page: 0), granularity: .character)
    controller.dragChanged(to: Self.point(3, page: 1)) // 페이지 1 미보유 — 전진 클램프.

    // §3.1: 전진 → (k, 0) — 페이지 1의 시작으로 보수적 클램프.
    let clamped = controller.selection
    #expect(clamped?.end == TextPosition(pageIndex: 1, utf16Offset: 0))

    gated.open(1)
    try await UITestSupport.waitUntil { store.geometry(forPage: 1) != nil }
    // 드래그 진행 중 도착 — T16이 focus를 재해석해 즉시 갱신되어야 한다.
    try await UITestSupport.waitUntil { controller.selection?.end.utf16Offset != 0 }

    let refined = controller.selection
    #expect(refined?.end.pageIndex == 1)
    #expect((refined?.end.utf16Offset ?? 0) > 0) // 잠정 해제 — 실제 오프셋으로 확장.
    #expect(recorder.invalidatedPages.contains(1))
  }

  // MARK: T16 보조 분기 — 중간 페이지(앵커·포커스 원입력 페이지가 아닌) 도착 시 무효화만

  @Test func middlePageArrivalWhileDraggingOnlyInvalidatesWithoutRecompute() async throws {
    let page0 = SelectionTestFixtures.singleLineContent(pageIndex: 0)
    let page1 = SelectionTestFixtures.singleLineContent(pageIndex: 1)
    let page2 = SelectionTestFixtures.singleLineContent(pageIndex: 2)
    let gated = GatedTextProvider(contents: [0: page0, 1: page1, 2: page2])
    let store = ReaderSelectablePageStore(provider: gated, displayTransform: { _ in .identity })
    gated.open(0)
    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }
    gated.open(2)
    store.requestPage(2)
    try await UITestSupport.waitUntil { store.geometry(forPage: 2) != nil }

    let controller = ReaderSelectionController(store: store)

    // 앵커(0)·포커스(2) 모두 이미 로드돼 있어 잠정 없이 즉시 확정된다.
    controller.dragBegan(at: Self.point(0, page: 0), granularity: .character)
    controller.dragChanged(to: Self.point(3, page: 2))
    let selectionBeforeArrival = controller.selection

    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    // 페이지 1은 앵커·포커스의 원입력 페이지가 아니지만 현재 선택 범위(0...2) 안이다 —
    // 도착 시 재해석·통지 없이 오버레이 무효화만 일어나야 한다.
    gated.open(1)
    store.requestPage(1)
    try await UITestSupport.waitUntil { store.geometry(forPage: 1) != nil }
    try await UITestSupport.waitUntil { recorder.invalidatedPages.contains(1) }

    #expect(recorder.invalidatedPages.contains(1))
    #expect(recorder.selectionChanges.isEmpty) // 재계산·통지 없음.
    #expect(controller.selection == selectionBeforeArrival) // 선택 자체는 불변.
  }

  // MARK: 후진 잠정 클램프

  @Test func backwardDragIntoUnloadedPageClampsToAnchorPageStart() async throws {
    let page0 = SelectionTestFixtures.singleLineContent(pageIndex: 0)
    let page1 = SelectionTestFixtures.singleLineContent(pageIndex: 1)
    let gated = GatedTextProvider(contents: [0: page0, 1: page1])
    let store = ReaderSelectablePageStore(provider: gated, displayTransform: { _ in .identity })
    gated.open(1)
    store.requestPage(1)
    try await UITestSupport.waitUntil { store.geometry(forPage: 1) != nil }

    let controller = ReaderSelectionController(store: store)
    controller.dragBegan(at: Self.point(5, page: 1), granularity: .character)
    controller.dragChanged(to: Self.point(2, page: 0)) // 페이지 0 미보유, 앵커(1)보다 앞 — 후진.

    // §3.1: 후진 → (k+1, 0) = (1, 0) — 앵커 페이지 시작과 동일 지점, 페이지 0 미포함.
    let clamped = controller.selection
    #expect(clamped?.start == TextPosition(pageIndex: 1, utf16Offset: 0))

    gated.open(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }
    try await UITestSupport.waitUntil { controller.selection?.start.pageIndex == 0 }

    #expect(controller.selection?.start.pageIndex == 0)
  }

  // MARK: 종료 후 지연 정련 (T9 → T23)

  @Test func pendingRefinementResolvesAfterDragEndsWhileStillProvisional() async throws {
    let page0 = SelectionTestFixtures.singleLineContent(pageIndex: 0)
    let page1 = SelectionTestFixtures.singleLineContent(pageIndex: 1)
    let gated = GatedTextProvider(contents: [0: page0, 1: page1])
    let store = ReaderSelectablePageStore(provider: gated, displayTransform: { _ in .identity })
    gated.open(0)
    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }

    let controller = ReaderSelectionController(store: store)
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.dragBegan(at: Self.point(2, page: 0), granularity: .character)
    controller.dragChanged(to: Self.point(3, page: 1)) // 여전히 미보유.
    controller.dragEnded() // 잠정인 채로 확정 — pendingRefinement 구성.

    let atEnd = controller.selection
    #expect(atEnd?.end == TextPosition(pageIndex: 1, utf16Offset: 0))
    let notifyCountAtEnd = recorder.selectionChanges.count

    gated.open(1)
    try await UITestSupport.waitUntil { store.geometry(forPage: 1) != nil }
    try await UITestSupport.waitUntil { controller.selection?.end.utf16Offset != 0 }

    #expect(recorder.selectionChanges.count == notifyCountAtEnd + 1) // 정련 1회 통지.
    #expect((controller.selection?.end.utf16Offset ?? 0) > 0)
  }

  // MARK: 토큰 실효 — 종료 후 새 드래그가 시작되면 구 정련은 폐기된다

  @Test func staleRefinementIsDiscardedAfterNewDragStarts() async throws {
    let page0 = SelectionTestFixtures.singleLineContent(pageIndex: 0)
    let page1 = SelectionTestFixtures.singleLineContent(pageIndex: 1)
    let gated = GatedTextProvider(contents: [0: page0, 1: page1])
    let store = ReaderSelectablePageStore(provider: gated, displayTransform: { _ in .identity })
    gated.open(0)
    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }

    let controller = ReaderSelectionController(store: store)

    controller.dragBegan(at: Self.point(2, page: 0), granularity: .character)
    controller.dragChanged(to: Self.point(3, page: 1)) // 미보유 — 잠정.
    controller.dragEnded() // pendingRefinement(token=T) 구성.

    // T18: 새 드래그 시작 — dragToken 증가로 위 정련은 실효된다.
    controller.dragBegan(at: Self.point(0, page: 0), granularity: .character)
    controller.dragChanged(to: Self.point(4, page: 0))
    let selectionBeforeArrival = controller.selection

    gated.open(1) // 구 세션이 기다리던 페이지 도착 — 새 드래그에 영향 없어야 한다.
    try await UITestSupport.waitUntil { store.geometry(forPage: 1) != nil }
    try await Task.sleep(for: .milliseconds(30)) // 오염 여지가 있다면 반영될 시간을 준다.

    #expect(controller.selection == selectionBeforeArrival)
  }

  // MARK: selectedString 조립

  @Test func selectedStringJoinsPagesWithNewlineAndHandlesFailures() async throws {
    let contents: [Int: PageTextContent] = [
      0: SelectionTestFixtures.singleLineContent(pageIndex: 0, text: "Hello World"),
      2: SelectionTestFixtures.singleLineContent(pageIndex: 2, text: "Third Page")
    ]
    let provider = DictionaryTextProvider(contents: contents, throwingPages: [1])
    let store = ReaderSelectablePageStore(provider: provider, displayTransform: { _ in .identity })
    for page in [0, 2] {
      store.requestPage(page)
    }
    try await UITestSupport.waitUntil {
      store.geometry(forPage: 0) != nil && store.geometry(forPage: 2) != nil
    }
    let controller = ReaderSelectionController(store: store)
    controller.select(TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 2, utf16Offset: 5)
    ))

    let string = await controller.selectedString()

    #expect(string == "Hello World\n\nThird") // 페이지1 실패 → 빈 조각, 개행은 유지.
  }

  @Test func selectedStringTruncatesAtCapOnCharacterBoundary() async throws {
    // 캡(UILimits.maxSelectedTextUTF16)은 페이지별 위생 상한(CoreLimits.maxProviderStringUTF16
    // = 2M)보다 커서 단일 페이지로는 재현할 수 없다 — 각 페이지를 2M 밑으로 유지하며 3페이지에
    // 걸쳐 누적 총량이 캡을 넘도록 하고, 마지막 페이지 안에서 캡 경계에 서로게이트 쌍(이모지)이
    // 정확히 걸치도록 배치한다.
    let cap = UILimits.maxSelectedTextUTF16
    let page0Text = String(repeating: "A", count: 1_500_000)
    let page1Text = String(repeating: "A", count: 1_500_000)
    let page2Prefix = cap - 1_500_000 - 1_500_000 - 1
    let page2Text = String(repeating: "A", count: page2Prefix) + "😀" + "B"

    let contents: [Int: PageTextContent] = [
      0: SelectionTestFixtures.singleLineContent(pageIndex: 0, text: page0Text),
      1: SelectionTestFixtures.singleLineContent(pageIndex: 1, text: page1Text),
      2: SelectionTestFixtures.singleLineContent(pageIndex: 2, text: page2Text)
    ]
    let provider = DictionaryTextProvider(contents: contents)
    let store = ReaderSelectablePageStore(provider: provider, displayTransform: { _ in .identity })
    for page in [0, 1, 2] {
      store.requestPage(page)
    }
    try await UITestSupport.waitUntil(timeoutSeconds: 30) {
      [0, 1, 2].allSatisfy { store.geometry(forPage: $0) != nil }
    }
    let controller = ReaderSelectionController(store: store)
    controller.select(TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 2, utf16Offset: page2Text.utf16.count)
    ))

    let string = await controller.selectedString()

    // 이모지 중간(cap)에서 동률이면 뒤쪽으로 스냅 — 전체 이모지를 포함한 채 절단된다.
    let expectedPage2Fragment = String(repeating: "A", count: page2Prefix) + "😀"
    let expected = page0Text + "\n" + page1Text + "\n" + expectedPage2Fragment
    #expect(string == expected)
    #expect((string?.utf16.count ?? 0) > cap) // 개행 2개만큼은 캡을 넘어도 된다(콘텐츠 자체는 캡 이하).
  }

  // MARK: 조립 중 선택 변경 — 진입 시점 스냅숏 완주

  @Test func selectedStringCompletesWithEntrySnapshotDespiteConcurrentChange() async throws {
    let page0 = SelectionTestFixtures.singleLineContent(pageIndex: 0, text: "Hello World")
    let page1 = SelectionTestFixtures.singleLineContent(pageIndex: 1, text: "Second Page")
    let gated = GatedTextProvider(contents: [0: page0, 1: page1])
    let store = ReaderSelectablePageStore(provider: gated, displayTransform: { _ in .identity })
    gated.open(0)
    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }
    let controller = ReaderSelectionController(store: store)
    controller.select(TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 1, utf16Offset: 6)
    ))

    async let result = controller.selectedString() // 페이지 1 조회에서 게이트 대기.
    try await Task.sleep(for: .milliseconds(20))
    controller.clear() // 조립 진행 중 선택이 사라진다 — 스냅숏은 영향받지 않아야 한다.
    gated.open(1)

    let string = await result
    #expect(string == "Hello World\nSecond") // 진입 시점 선택 그대로 완주.
    #expect(controller.selection == nil) // 실제 컨트롤러 상태는 별도로 해제됨.
  }
}
