import CoreGraphics
import PapyrusCore
import PapyrusUI
import Testing

/// ``ReaderSelectionController``의 시작 정밀도(word/line)·차분 무효화·teardown을
/// 검증한다 (설계 §6-2 — 상태 전이표 T1~T22 자체는 ``ReaderSelectionControllerTests``
/// 참조, 파일 길이 한도로 분리).
@MainActor
struct ReaderSelectionGranularityTests {
  // MARK: 정밀도 — word/line/공백

  @Test func wordGranularityDragSelectsWholeWordsUnion() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    controller.dragBegan(at: SelectionTestFixtures.pagePoint(1), granularity: .word) // "Hello" 안.
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(8)) // "World" 안.
    controller.dragEnded()

    // 전체 "Hello World"(0..<11) — 두 단어 구간의 합집합.
    let expected = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 11)
    )
    #expect(controller.selection == expected)
  }

  @Test func lineGranularityDragSelectsWholeLine() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    controller.dragBegan(at: SelectionTestFixtures.pagePoint(2), granularity: .line)
    controller.dragEnded()

    let expected = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 11)
    )
    #expect(controller.selection == expected)
  }

  @Test func wordGranularityOnWhitespaceFallsBackToNearestWord() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    // 오프셋 5는 "Hello World"의 공백 — wordRange(around:)가 앞뒤 중 가까운 단어로 폴백.
    controller.dragBegan(at: SelectionTestFixtures.pagePoint(5), granularity: .word)
    controller.dragEnded()

    #expect(controller.selection != nil)
  }

  // MARK: 차분 무효화

  @Test func diffInvalidationFiresSymmetricDifferencePlusEndpoints() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(
      pages: [0, 1, 2]
    )
    let recorder = SelectionCallbackRecorder()

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(0, page: 0), granularity: .character)
    recorder.attach(to: controller)
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(0, page: 2)) // 0..2 페이지로 확장.

    #expect(Set(recorder.invalidatedPages) == [0, 1, 2])

    recorder.invalidatedPages.removeAll()
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(0, page: 1)) // 대칭차{2}+새범위끝{0,1}.
    #expect(Set(recorder.invalidatedPages) == [0, 1, 2])
  }

  // MARK: 재사용 방지 — teardown

  @Test func teardownResetsStateAndSuppressesFurtherArrivals() async throws {
    let (controller, store) = try await SelectionTestFixtures.makeReadySelectionController(
      pages: [0]
    )
    controller.select(TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    ))
    controller.teardown()

    #expect(controller.selection == nil)
    #expect(store.geometry(forPage: 0) == nil) // invalidateAll 위임 확인.
  }
}
