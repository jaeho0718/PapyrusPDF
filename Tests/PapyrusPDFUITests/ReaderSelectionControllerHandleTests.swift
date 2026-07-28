import CoreGraphics
import PapyrusPDFCore
import PapyrusPDFUI
import Testing

/// ``ReaderSelectionController``의 핸들 드래그 관련 상태 전이(T19·T10·T12)를 검증한다
/// (설계 §6-2 — 나머지 T-행은 ``ReaderSelectionControllerTests`` 참조, 파일 길이 한도로 분리).
@MainActor
struct ReaderSelectionControllerHandleTests {
  // MARK: T19·T10 — 핸들 드래그 시작·취소

  @Test func t19HandleDragBeganUsesOppositeSelectionEndAsAnchor() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let base = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 2),
      end: TextPosition(pageIndex: 0, utf16Offset: 8)
    )
    controller.select(base)
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    // 시작 핸들을 오프셋 0까지 끈다 — 앵커는 기존 선택의 끝(8)이어야 한다.
    controller.handleDragBegan(.start, at: SelectionTestFixtures.pagePoint(0))
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(0))

    let expected = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 8)
    )
    #expect(controller.selection == expected)
  }

  @Test func t10HandleDragCancelledRestoresPreDragSelection() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let base = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 2),
      end: TextPosition(pageIndex: 0, utf16Offset: 8)
    )
    controller.select(base)

    controller.handleDragBegan(.start, at: SelectionTestFixtures.pagePoint(0))
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(0))
    #expect(controller.selection != base) // 진행 중 변경 확인.

    controller.dragCancelled()

    #expect(controller.selection == base) // 취소 — 원 선택 복원.
  }

  @Test func t10NewDragCancelledReturnsToIdle() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(0), granularity: .character)
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(5))
    controller.dragCancelled()

    #expect(controller.selection == nil)
    #expect(!recorder.selectionChanges.isEmpty)
    let lastNotified: TextSelection? = recorder.selectionChanges.last ?? nil
    #expect(lastNotified == nil)
  }

  // MARK: 핸들 배치 — 병합 quad에서 시각(표시 y) 기준 노브 배치 (회귀)

  /// 병합 라인 quad(`Quad(rect:)` 생성 — 꼭짓점 이름이 시각과 무관)에서도 시작 핸들의
  /// 노브가 위(작은 y), 끝 핸들의 노브가 아래(큰 y)에 오는지 확인한다. 리뷰 지적:
  /// 이름(`topLeft`/`bottomRight`) 기준 매핑은 병합 quad에서 시각과 반전됐었다.
  @Test func handlePlacementUsesVisualYNotCornerNameForMergedQuad() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    controller.select(TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    ))

    let placement = try #require(controller.handlePlacement(forPage: 0))
    let start = try #require(placement.start)
    let end = try #require(placement.end)

    #expect(start.knobEnd.y < start.baseEnd.y) // 시작 노브 = 위(작은 표시 y).
    #expect(end.knobEnd.y > end.baseEnd.y) // 끝 노브 = 아래(큰 표시 y).
  }

  // MARK: T12 — selected에서 handleDragBegan 무시

  @Test func t12HandleDragBeganWhileDraggingIsIgnored() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    controller.dragBegan(at: SelectionTestFixtures.pagePoint(0), granularity: .character)
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(3))
    let before = controller.selection

    controller.handleDragBegan(.start, at: SelectionTestFixtures.pagePoint(9)) // 무시되어야 한다.

    #expect(controller.selection == before)
  }
}
