import CoreGraphics
import PapyrusPDFCore
@testable import PapyrusPDFUI
import Testing

/// 영역 선택 상태 기계의 탭 전이(설계 §3 전이표 T4′/T4″/T13/T20′/T20″/T27a/b/c)를
/// 검증한다. 드래그·핸들·select·clear·재등록·조회 일반화는
/// ``ReaderRegionLifecycleTests``(파일 길이 한도로 분리) 참조.
/// 테스트 이름에 해당 행 번호를 명기한다(`ReaderSelectionControllerTests` 전례).
@MainActor
struct ReaderSelectionControllerRegionTests {
  /// 결정적 테스트 영역을 만든다 (텍스트 콘텐츠 quad와 겹치지 않도록 x=500 근방).
  static func region(
    id: String, page: Int = 0, x: CGFloat = 500, metadata: (any Sendable)? = nil
  ) -> SelectableRegion {
    SelectableRegion(
      id: id, pageIndex: page,
      quad: Quad(rect: CGRect(x: x, y: 0, width: 20, height: 20)), metadata: metadata
    )
  }

  /// 영역 내부(경계 안쪽)의 페이지 점.
  static func pointIn(_ region: SelectableRegion) -> PagePoint {
    let rect = region.quad.boundingRect
    return PagePoint(pageIndex: region.pageIndex, point: CGPoint(x: rect.midX, y: rect.midY))
  }

  /// 등록된 어떤 영역과도 겹치지 않는 미스 점.
  static func missPoint(page: Int) -> PagePoint {
    PagePoint(pageIndex: page, point: CGPoint(x: 9_999, y: 9_999))
  }

  // MARK: T4′/T4″ — idle 탭

  @Test func t4PrimeIdleTapHitEntersRegionSelectedAndRequestsMenuOnce() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let region = Self.region(id: "r1")
    controller.setRegions([region], forPage: 0)
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.tap(at: Self.pointIn(region))

    #expect(recorder.regionChanges == [RegionKey(pageIndex: 0, id: "r1")])
    #expect(recorder.invalidatedPages == [0])
    #expect(recorder.menuRequests == [0])
    #expect(recorder.selectionChanges.isEmpty)
    #expect(controller.selection == nil)
  }

  @Test func t4DoublePrimeIdleTapMissIsIgnored() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    controller.setRegions([Self.region(id: "r1")], forPage: 0)
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.tap(at: Self.missPoint(page: 0))

    #expect(recorder.regionChanges.isEmpty)
    #expect(recorder.menuRequests.isEmpty)
    #expect(recorder.invalidatedPages.isEmpty)
  }

  // MARK: T20′/T20″ — 텍스트 선택 중 탭

  @Test func t20PrimeTextSelectedTapHitClearsTextAndEntersRegionSelected() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let region = Self.region(id: "r1")
    controller.setRegions([region], forPage: 0)
    let base = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    controller.select(base)
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.tap(at: Self.pointIn(region))

    #expect(recorder.selectionChanges == [nil]) // 텍스트 해제.
    #expect(recorder.invalidatedPages.contains(0))
    #expect(recorder.menuDismissCount == 1)
    #expect(recorder.regionChanges == [RegionKey(pageIndex: 0, id: "r1")])
    #expect(recorder.menuRequests == [0])
    #expect(controller.selection == nil)
  }

  @Test func t20DoublePrimeTextSelectedTapMissFallsBackToExistingClear() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let base = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    controller.select(base)
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.tap(at: Self.missPoint(page: 0))

    #expect(controller.selection == nil)
    #expect(recorder.selectionChanges == [nil])
    #expect(recorder.menuDismissCount == 1)
    #expect(recorder.regionChanges.isEmpty)
  }

  // MARK: T27a/b/c — 영역 선택 중 탭

  @Test func t27aSameRegionRetapKeepsStateAndRefiresMenuRequestOnly() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let region = Self.region(id: "r1")
    controller.setRegions([region], forPage: 0)
    controller.tap(at: Self.pointIn(region))
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.tap(at: Self.pointIn(region))

    #expect(recorder.menuRequests == [0])
    #expect(recorder.regionChanges.isEmpty) // 재통지 없음.
    #expect(recorder.invalidatedPages.isEmpty) // 재무효화 없음.
    #expect(recorder.menuDismissCount == 0)
  }

  @Test func t27bDifferentRegionTapReplacesSelectionWithDismissThenRequest() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let first = Self.region(id: "r1", x: 500)
    let second = Self.region(id: "r2", x: 600)
    controller.setRegions([first, second], forPage: 0)
    controller.tap(at: Self.pointIn(first))
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.tap(at: Self.pointIn(second))

    #expect(recorder.regionChanges == [RegionKey(pageIndex: 0, id: "r2")])
    #expect(recorder.menuDismissCount == 1)
    #expect(recorder.menuRequests == [0])
    #expect(Set(recorder.invalidatedPages) == [0]) // 같은 페이지 — 중복 없이 1회.
  }

  @Test func t27cRegionSelectedTapMissClearsToIdle() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let region = Self.region(id: "r1")
    controller.setRegions([region], forPage: 0)
    controller.tap(at: Self.pointIn(region))
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.tap(at: Self.missPoint(page: 0))

    #expect(recorder.regionChanges == [nil])
    #expect(recorder.invalidatedPages == [0])
    #expect(recorder.menuDismissCount == 1)
    #expect(recorder.menuRequests.isEmpty)
  }
}
