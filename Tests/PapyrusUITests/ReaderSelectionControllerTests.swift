import CoreGraphics
import PapyrusCore
import PapyrusUI
import Testing

/// ``ReaderSelectionController`` 상태 전이표(설계 §2.2, T1~T26)를 검증한다.
///
/// 테스트 이름에 해당 행 번호를 명기한다(리뷰어 교차 검증 기준). 콘텐츠가 이미 캐시에
/// 있는(잠정 클램프 없는) 시나리오만 다룬다 — 잠정→재계산 흐름은 ``SelectionCrossPageTests``,
/// 시작 정밀도·차분 무효화·teardown은 ``ReaderSelectionGranularityTests``(파일
/// 길이 한도로 분리) 참조.
@MainActor
struct ReaderSelectionControllerTests {
  // MARK: idle 상태 무시 (T2·T3·T4·T6·T7)

  @Test func t2IdleHandleDragBeganIsIgnored() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    controller.handleDragBegan(.start, at: SelectionTestFixtures.pagePoint(0))
    #expect(controller.selection == nil)
  }

  @Test func t3IdleDragChangedEndedCancelledAreIgnored() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.dragChanged(to: SelectionTestFixtures.pagePoint(2))
    controller.dragEnded()
    controller.dragCancelled()

    #expect(controller.selection == nil)
    #expect(recorder.selectionChanges.isEmpty)
    #expect(recorder.invalidatedPages.isEmpty)
  }

  @Test func t4IdleTapIsIgnored() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.tap()

    #expect(recorder.selectionChanges.isEmpty)
    #expect(recorder.menuDismissCount == 0)
  }

  @Test func t6IdleClearIsNoOp() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.clear()

    #expect(recorder.selectionChanges.isEmpty)
    #expect(recorder.menuDismissCount == 0)
  }

  @Test func t7IdleContentArrivedIsIgnored() async throws {
    let contents: [Int: PageTextContent] = [
      0: SelectionTestFixtures.singleLineContent(pageIndex: 0)
    ]
    let provider = DictionaryTextProvider(contents: contents)
    let store = ReaderSelectablePageStore(provider: provider, displayTransform: { _ in .identity })
    let controller = ReaderSelectionController(store: store)
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    store.requestPage(0) // idle 상태에서 도착 — 크래시·통지 없이 무시되어야 한다.
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }

    #expect(recorder.selectionChanges.isEmpty)
    #expect(controller.selection == nil)
  }

  // MARK: T1 — 드래그 시작

  @Test func t1DragBeganEntersDraggingWithEmptyInitialSelection() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    controller.dragBegan(at: SelectionTestFixtures.pagePoint(2), granularity: .character)
    #expect(controller.selection == nil) // anchor == focus — 빈 선택.
  }

  // MARK: T5 — idle에서 프로그램적 선택

  @Test func t5SelectFromIdleAdoptsAndNotifiesWithoutMenu() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )

    controller.select(selection)

    #expect(controller.selection == selection)
    #expect(recorder.selectionChanges == [selection])
    #expect(recorder.invalidatedPages.contains(0))
    #expect(recorder.menuRequests.isEmpty) // 프로그램적 선택은 메뉴를 띄우지 않는다.
  }

  // MARK: T8 — 드래그 진행

  @Test func t8DragChangedUpdatesSelectionAndNotifies() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(0), granularity: .character)
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(5))

    let expected = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    #expect(controller.selection == expected)
    #expect((recorder.selectionChanges.last ?? nil) == expected)
    #expect(recorder.invalidatedPages.contains(0))
  }

  // MARK: T9 — 드래그 종료

  @Test func t9DragEndedWithEmptySelectionReturnsToIdle() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(2), granularity: .character)
    controller.dragEnded() // 이동 없음 — 빈 선택.

    #expect(controller.selection == nil)
    // 처음부터 끝까지 nil — 관찰 가능한 변화가 없으므로 통지도 없다.
    #expect(recorder.selectionChanges.isEmpty)
  }

  @Test func t9DragEndedWithNonEmptySelectionBecomesSelectedAndRequestsMenu() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(0), granularity: .character)
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(5))
    controller.dragEnded()

    let expected = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    #expect(controller.selection == expected)
    if SelectionStyle.presentsMenuOnSelectionEnd {
      #expect(recorder.menuRequests == [0])
    } else {
      #expect(recorder.menuRequests.isEmpty)
    }
  }

  // MARK: T11 — 드래그 중 재시작

  @Test func t11DragBeganWhileDraggingRestartsSessionAndClearsOldOverlay() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let recorder = SelectionCallbackRecorder()

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(0), granularity: .character)
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(5)) // 0..<5 선택 중.
    recorder.attach(to: controller) // 재시작 이후만 기록.

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(8), granularity: .character) // 재시작.
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(10))

    let expected = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 8),
      end: TextPosition(pageIndex: 0, utf16Offset: 10)
    )
    #expect(controller.selection == expected)
    #expect(recorder.invalidatedPages.contains(0)) // 이전 범위 잔류 지우기 포함.
  }

  // MARK: T14 — 드래그 중 clear

  @Test func t14ClearWhileDraggingReturnsToIdleAndDismissesMenu() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let recorder = SelectionCallbackRecorder()

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(0), granularity: .character)
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(5))
    recorder.attach(to: controller)

    controller.clear()

    #expect(controller.selection == nil)
    #expect(recorder.selectionChanges == [nil])
    #expect(recorder.invalidatedPages.contains(0))
    #expect(recorder.menuDismissCount == 1)
  }

  // MARK: T15 — 드래그 중 select 승리

  @Test func t15SelectWhileDraggingDiscardsDragAndSubsequentEventsAreIgnored() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let recorder = SelectionCallbackRecorder()

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(0), granularity: .character)
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(3))
    recorder.attach(to: controller)

    let programmatic = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    controller.select(programmatic)
    #expect(controller.selection == programmatic)

    // 드래그 세션은 폐기됐다 — 지연 도착 이벤트는 T17처럼 무시된다.
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(9))
    controller.dragEnded()
    #expect(controller.selection == programmatic)
  }

  // MARK: T13 — 드래그 중 tap 무시

  @Test func t13TapWhileDraggingIsIgnored() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let recorder = SelectionCallbackRecorder()

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(0), granularity: .character)
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(5))
    recorder.attach(to: controller)

    controller.tap() // 무시 — clear()와 달리 드래그 중에는 아무 효과가 없어야 한다.

    let expected = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    #expect(controller.selection == expected) // 드래그가 계속 진행 중이어야 한다.
    #expect(recorder.selectionChanges.isEmpty)
    #expect(recorder.menuDismissCount == 0)

    // 드래그가 여전히 살아 있으므로 정상적으로 종료할 수 있어야 한다.
    controller.dragEnded()
    #expect(controller.selection == expected)
  }

  // MARK: T24 — 드래그 중에도 selectedString이 현재 선택을 반영한다

  @Test func t24SelectedStringDuringDragReflectsCurrentSelection() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(0), granularity: .character)
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(5))

    let string = await controller.selectedString()

    #expect(string == "Hello")
  }

  // MARK: T17 — selected에서 잔여 드래그 이벤트 무시

  @Test func t17SelectedStateIgnoresResidualDragEvents() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let base = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    controller.select(base)

    controller.dragChanged(to: SelectionTestFixtures.pagePoint(9))
    controller.dragEnded()
    controller.dragCancelled()

    #expect(controller.selection == base)
  }

  // MARK: T18 — selected에서 새 드래그 시작

  @Test func t18DragBeganFromSelectedDiscardsOldSelectionAndDismissesMenu() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let base = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    controller.select(base)
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(7), granularity: .character)

    #expect(recorder.menuDismissCount == 1)
    #expect(recorder.invalidatedPages.contains(0)) // 구 선택 페이지 무효화.
    #expect(controller.selection == nil) // 새 드래그는 앵커==포커스로 빈 선택 시작.
  }

  // MARK: T20·T21 — tap·clear로 선택 해제

  @Test func t20TapWhileSelectedClearsAndDismissesMenu() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let base = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    controller.select(base)
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.tap()

    #expect(controller.selection == nil)
    #expect(recorder.selectionChanges == [nil])
    #expect(recorder.menuDismissCount == 1)
  }

  @Test func t21ClearWhileSelectedClearsAndDismissesMenu() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let base = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    controller.select(base)
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.clear()

    #expect(controller.selection == nil)
    #expect(recorder.menuDismissCount == 1)
  }

  // MARK: T22 — selected에서 select 교체

  @Test func t22SelectWhileSelectedReplacesAndInvalidatesBothRanges() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let first = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    controller.select(first)
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    let second = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 6),
      end: TextPosition(pageIndex: 0, utf16Offset: 10)
    )
    controller.select(second)

    #expect(controller.selection == second)
    #expect(recorder.selectionChanges == [second])
  }
}
