import CoreGraphics
import PapyrusCore
@testable import PapyrusUI
import Testing

/// 영역 선택 상태 기계의 나머지 전이(설계 §3 전이표 T28~T39)와 조회 일반화(§1.4)·변환
/// 미스 경로를 검증한다. 탭 전이(T4′~T27)는 ``ReaderSelectionControllerRegionTests``
/// (파일 길이 한도로 분리) 참조. 헬퍼(`region`/`pointIn`/`missPoint`)는 그 타입의 것을
/// 재사용한다.
@MainActor
struct ReaderRegionLifecycleTests {
  private typealias Fixtures = ReaderSelectionControllerRegionTests

  // MARK: T28 — 영역 선택 중 드래그 시작

  @Test func t28DragBeganFromRegionSelectedClearsRegionAndStartsDrag() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let region = Fixtures.region(id: "r1")
    controller.setRegions([region], forPage: 0)
    controller.tap(at: Fixtures.pointIn(region))
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(0), granularity: .character)

    #expect(recorder.regionChanges == [nil])
    #expect(recorder.menuDismissCount == 1)
    // 드래그가 정상 진행된다 — 이어서 dragEnded로 확정할 수 있다.
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(5))
    controller.dragEnded()
    let expected = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    #expect(controller.selection == expected)
  }

  // MARK: T29/T30 — 영역 선택 중 잔여 드래그·핸들 이벤트 무시

  @Test func t29RegionSelectedIgnoresResidualDragEvents() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let region = Fixtures.region(id: "r1")
    controller.setRegions([region], forPage: 0)
    controller.tap(at: Fixtures.pointIn(region))
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.dragChanged(to: SelectionTestFixtures.pagePoint(2))
    controller.dragEnded()
    controller.dragCancelled()

    #expect(recorder.regionChanges.isEmpty)
    #expect(recorder.selectionChanges.isEmpty)
  }

  @Test func t30RegionSelectedIgnoresHandleDragBegan() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let region = Fixtures.region(id: "r1")
    controller.setRegions([region], forPage: 0)
    controller.tap(at: Fixtures.pointIn(region))
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.handleDragBegan(.start, at: SelectionTestFixtures.pagePoint(0))

    #expect(recorder.regionChanges.isEmpty)
    #expect(recorder.menuDismissCount == 0)
  }

  // MARK: T31 — 영역 선택 중 프로그램적 select

  @Test func t31SelectWhileRegionSelectedAdoptsTextAndClearsRegion() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let region = Fixtures.region(id: "r1")
    controller.setRegions([region], forPage: 0)
    controller.tap(at: Fixtures.pointIn(region))
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)
    let text = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )

    controller.select(text)

    #expect(controller.selection == text)
    #expect(recorder.regionChanges == [nil])
    #expect(recorder.selectionChanges == [text])
    #expect(recorder.menuRequests.isEmpty) // 메뉴는 표시하지 않는다.
  }

  // MARK: T32/T38 — clear·clearAllRegions

  @Test func t32ClearWhileRegionSelectedReturnsToIdle() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let region = Fixtures.region(id: "r1")
    controller.setRegions([region], forPage: 0)
    controller.tap(at: Fixtures.pointIn(region))
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.clear()

    #expect(controller.activeSelection == nil)
    #expect(recorder.regionChanges == [nil])
    #expect(recorder.invalidatedPages == [0])
    #expect(recorder.menuDismissCount == 1)
  }

  @Test func t38ClearAllRegionsDeselectsActiveRegion() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let region = Fixtures.region(id: "r1")
    controller.setRegions([region], forPage: 0)
    controller.tap(at: Fixtures.pointIn(region))
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.clearAllRegions()

    #expect(controller.activeSelection == nil)
    #expect(controller.regions(forPage: 0).isEmpty)
    #expect(recorder.regionChanges == [nil])
    #expect(recorder.menuDismissCount == 1)
  }

  @Test func t37ClearAllRegionsWhileIdleOrTextSelectedDoesNotInterfere() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let text = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    controller.select(text)
    controller.setRegions([Fixtures.region(id: "r1")], forPage: 0)
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.clearAllRegions()

    #expect(controller.selection == text) // 텍스트 선택은 무간섭.
    #expect(recorder.regionChanges.isEmpty)
    #expect(recorder.menuDismissCount == 0)
  }

  // MARK: T33 — 창 재진입 시 오버레이 복원

  @Test func t33ContentArrivedOnRegionPageAfterEvictionReinvalidatesOverlay() async throws {
    let (controller, store) = try await SelectionTestFixtures
      .makeReadySelectionController(pages: [0])
    let region = Fixtures.region(id: "r1")
    controller.setRegions([region], forPage: 0)
    controller.tap(at: Fixtures.pointIn(region))
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.prefetch(range: 5..<10) // regionSelected는 보호 페이지가 없다 — 0 퇴거.
    #expect(store.geometry(forPage: 0) == nil)

    controller.prefetch(range: 0..<1) // 재요청.
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }

    #expect(recorder.invalidatedPages.contains(0)) // T33 — contentArrived가 재무효화한다.
    #expect(controller.activeSelection != nil) // 선택 자체는 유지된다.
  }

  // MARK: T35 — 같은 페이지 재등록: 유지·갱신 / 해제

  @Test func t35ReRegistrationWithSameIdKeepsSelectionAndUpdatesMetadata() async throws {
    struct Info: Sendable, Equatable { let caption: String }
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let original = Fixtures.region(id: "r1", metadata: Info(caption: "old"))
    controller.setRegions([original], forPage: 0)
    controller.tap(at: Fixtures.pointIn(original))
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    let updated = Fixtures.region(id: "r1", metadata: Info(caption: "new"))
    controller.setRegions([updated], forPage: 0)

    #expect(recorder.regionChanges == [RegionKey(pageIndex: 0, id: "r1")])
    #expect(recorder.menuDismissCount == 0)
    guard case let .region(active) = controller.activeSelection else {
      Issue.record("expected an active region selection")
      return
    }
    #expect((active.metadata as? Info) == Info(caption: "new"))
  }

  @Test func t35ReRegistrationWithoutIdDeselects() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let region = Fixtures.region(id: "r1")
    controller.setRegions([region], forPage: 0)
    controller.tap(at: Fixtures.pointIn(region))
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.setRegions([Fixtures.region(id: "other")], forPage: 0)

    #expect(controller.activeSelection == nil)
    #expect(recorder.regionChanges == [nil])
    #expect(recorder.menuDismissCount == 1)
  }

  // MARK: T36 — 다른 페이지 등록은 활성 선택과 무간섭

  @Test func t36RegistrationOnOtherPageDoesNotAffectActiveSelection() async throws {
    let (controller, _) = try await SelectionTestFixtures
      .makeReadySelectionController(pages: [0, 1])
    let region = Fixtures.region(id: "r1", page: 0)
    controller.setRegions([region], forPage: 0)
    controller.tap(at: Fixtures.pointIn(region))
    let recorder = SelectionCallbackRecorder()
    recorder.attach(to: controller)

    controller.setRegions([Fixtures.region(id: "r2", page: 1)], forPage: 1)

    #expect(recorder.regionChanges.isEmpty)
    guard case let .region(active) = controller.activeSelection else {
      Issue.record("expected an active region selection")
      return
    }
    #expect(active.id == "r1")
  }

  // MARK: T34 — 영역 선택 중 copy는 no-op

  @Test func t34CopyWhileRegionSelectedYieldsNilSelectedString() async throws {
    let (controller, _) = try await SelectionTestFixtures.makeReadySelectionController(pages: [0])
    let region = Fixtures.region(id: "r1")
    controller.setRegions([region], forPage: 0)
    controller.tap(at: Fixtures.pointIn(region))

    let string = await controller.selectedString()

    #expect(string == nil)
    #expect(controller.selectedStringFromCache() == nil)
  }

  // MARK: 조회 일반화 — displayQuads/handlePlacement/menuAnchorRect/activeSelection

  @Test func queryGeneralizationReturnsTransformedRegionQuadOnlyOnItsOwnPage() async throws {
    let (controller, _) = try await SelectionTestFixtures
      .makeReadySelectionController(pages: [0, 1])
    let region = Fixtures.region(id: "r1", page: 0)
    controller.setRegions([region], forPage: 0)
    controller.tap(at: Fixtures.pointIn(region))

    let quadsOnRegionPage = controller.displayQuads(forPage: 0)
    let quadsOnOtherPage = controller.displayQuads(forPage: 1)

    #expect(quadsOnRegionPage == [region.quad]) // identity 변환이므로 그대로 일치.
    #expect(quadsOnOtherPage.isEmpty)
    #expect(controller.handlePlacement(forPage: 0) == nil) // 영역엔 핸들이 없다.
    #expect(controller.menuAnchorRect(forPage: 0) == region.quad.boundingRect)
    #expect(controller.selection == nil)
    guard case .region = controller.activeSelection else {
      Issue.record("expected activeSelection == .region")
      return
    }
  }

  // MARK: 변환 미스 경로 — 미로드 페이지 탭은 히트 없음 + requestPage

  @Test func hitTestOnUnloadedPageMissesAndTriggersRequestPage() async throws {
    let page0 = SelectionTestFixtures.singleLineContent(pageIndex: 0)
    let page1 = SelectionTestFixtures.singleLineContent(pageIndex: 1)
    let gated = GatedTextProvider(contents: [0: page0, 1: page1])
    let store = ReaderSelectablePageStore(provider: gated, displayTransform: { _ in .identity })
    gated.open(0)
    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }

    let controller = ReaderSelectionController(store: store)
    let region = Fixtures.region(id: "r1", page: 1)
    controller.setRegions([region], forPage: 1)
    #expect(store.geometry(forPage: 1) == nil) // 아직 미로드.

    controller.tap(at: Fixtures.pointIn(region))

    #expect(controller.activeSelection == nil) // 변환 미보유 — 히트 없음.

    gated.open(1)
    try await UITestSupport.waitUntil { store.geometry(forPage: 1) != nil }
    // tap이 store.requestPage(1)을 트리거했기 때문에 게이트 해제 후 로드가 완료된다.
  }
}
