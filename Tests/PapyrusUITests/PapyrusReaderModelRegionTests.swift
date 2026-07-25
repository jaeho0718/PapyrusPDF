import CoreGraphics
import PapyrusCore
@testable import PapyrusUI
import Testing

/// `PapyrusReaderModel`의 영역 등록부 배선(설계 §1.10 — 적재 전 등록·재생, `selectedRegion`
/// 관찰, `clearSelection()`의 영역 해제, 문서 정체성 리셋)을 검증한다 (설계 §5-4).
@MainActor
struct PapyrusReaderModelRegionTests {
  /// 텍스트 quad와 겹치지 않는 결정적 테스트 영역.
  private static func region(id: String, page: Int = 0, x: CGFloat = 500) -> SelectableRegion {
    SelectableRegion(
      id: id, pageIndex: page, quad: Quad(rect: CGRect(x: x, y: 0, width: 20, height: 20))
    )
  }

  /// 선택 컨트롤러가 배선된, 호스트에 부착된 코어를 만든다(탭 히트 재생 검증에 필요).
  private static func makeAttachedCore(
    pages: [Int] = [0], pageCount: Int = 3
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
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    return (core, host)
  }

  /// 영역 내부 콘텐츠 공간 점.
  private static func contentPoint(
    for region: SelectableRegion, core: ReaderCore
  ) throws -> CGPoint {
    let frame = try #require(core.layout.pageFrame(at: region.pageIndex))
    let rect = region.quad.boundingRect
    return CGPoint(x: frame.minX + rect.midX, y: frame.minY + rect.midY)
  }

  // MARK: 적재 전 등록 → attach 후 재생

  @Test func regionsRegisteredBeforeAttachReplayAndBecomeTappable() async throws {
    let model = PapyrusReaderModel()
    let region = Self.region(id: "r1")
    model.setSelectableRegions([region], forPage: 0) // 연결 전 — 모델 등록부에만 저장.
    #expect(model.selectableRegions(forPage: 0).map(\.id) == ["r1"])

    let (core, _) = try await Self.makeAttachedCore()
    model.attach(core: core)

    core.hostTap(atContentPoint: try Self.contentPoint(for: region, core: core))

    #expect(model.selectedRegion?.id == "r1") // 재생되지 않았다면 히트할 수 없다.
  }

  // MARK: selectableRegions(forPage:) — 위생 후 목록, 연결 전후 동일

  @Test func selectableRegionsReturnsSanitizedListBeforeAndAfterAttach() async throws {
    let model = PapyrusReaderModel()
    let valid = Self.region(id: "valid")
    let wrongPage = SelectableRegion(
      id: "wrong-page", pageIndex: 1, quad: Quad(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
    )
    model.setSelectableRegions([valid, wrongPage], forPage: 0)

    #expect(model.selectableRegions(forPage: 0).map(\.id) == ["valid"]) // 위생: pageIndex 불일치 폐기.

    let (core, _) = try await Self.makeAttachedCore()
    model.attach(core: core)

    #expect(model.selectableRegions(forPage: 0).map(\.id) == ["valid"]) // 연결 후에도 동일.
  }

  // MARK: selectedRegion 관찰

  @Test func selectedRegionObservesCoreRegionSelectionChanges() async throws {
    let model = PapyrusReaderModel()
    let (core, _) = try await Self.makeAttachedCore()
    model.attach(core: core)
    let region = Self.region(id: "r1")
    model.setSelectableRegions([region], forPage: 0)
    #expect(model.selectedRegion == nil)

    core.hostTap(atContentPoint: try Self.contentPoint(for: region, core: core))
    #expect(model.selectedRegion?.id == "r1")

    core.hostTap(atContentPoint: CGPoint(x: 1, y: 1)) // 미스 — 해제.
    #expect(model.selectedRegion == nil)
  }

  // MARK: clearSelection() — 영역도 해제

  @Test func clearSelectionAlsoDeselectsActiveRegion() async throws {
    let model = PapyrusReaderModel()
    let (core, _) = try await Self.makeAttachedCore()
    model.attach(core: core)
    let region = Self.region(id: "r1")
    model.setSelectableRegions([region], forPage: 0)
    core.hostTap(atContentPoint: try Self.contentPoint(for: region, core: core))
    #expect(model.selectedRegion != nil)

    model.clearSelection()

    #expect(model.selectedRegion == nil)
  }

  // MARK: 문서 정체성 — 같은 문서 재조립은 등록부 유지, 다른 문서는 리셋

  @Test func sameDocumentIdentityReassemblyRetainsRegionsButResetsSelectedRegion() async throws {
    let model = PapyrusReaderModel()
    let (core, _) = try await Self.makeAttachedCore()
    let documentID = ObjectIdentifier(core)
    model.beginLoading(documentID: documentID) // 최초 적재.
    model.attach(core: core)
    model.setSelectableRegions([Self.region(id: "r1")], forPage: 0)

    model.beginLoading(documentID: documentID) // 같은 문서 재조립.

    #expect(model.selectableRegions(forPage: 0).map(\.id) == ["r1"]) // 유지.
    #expect(model.selectedRegion == nil) // 선택 상태는 항상 리셋(일시 상태).
  }

  @Test func differentDocumentIdentityResetsRegionRegistry() async throws {
    let model = PapyrusReaderModel()
    let (coreA, _) = try await Self.makeAttachedCore()
    model.beginLoading(documentID: ObjectIdentifier(coreA))
    model.attach(core: coreA)
    model.setSelectableRegions([Self.region(id: "r1")], forPage: 0)
    #expect(model.selectableRegions(forPage: 0).map(\.id) == ["r1"])

    let (coreB, _) = try await Self.makeAttachedCore()
    model.beginLoading(documentID: ObjectIdentifier(coreB)) // 다른 문서.

    #expect(model.selectableRegions(forPage: 0).isEmpty) // 리셋.
  }

  @Test func firstEverLoadDoesNotResetRegionsRegisteredBeforeBeginLoading() async throws {
    // 최초 적재는 "문서 교체"가 아니다 — beginLoading이 한 번도 호출되지 않은 상태에서
    // 등록한 영역은 첫 beginLoading에서 지워지면 안 된다("모델 생성 → 영역 등록 →
    // 리더 표시" 사용 패턴).
    let model = PapyrusReaderModel()
    model.setSelectableRegions([Self.region(id: "r1")], forPage: 0)

    let (core, _) = try await Self.makeAttachedCore()
    model.beginLoading(documentID: ObjectIdentifier(core))

    #expect(model.selectableRegions(forPage: 0).map(\.id) == ["r1"])
  }

  // MARK: clearSelectableRegions() — 등록부 전체 해제

  @Test func clearSelectableRegionsRemovesRegistryAndDeselectsActiveRegion() async throws {
    let model = PapyrusReaderModel()
    let (core, _) = try await Self.makeAttachedCore()
    model.attach(core: core)
    let region = Self.region(id: "r1")
    model.setSelectableRegions([region], forPage: 0)
    core.hostTap(atContentPoint: try Self.contentPoint(for: region, core: core))
    #expect(model.selectedRegion != nil)

    model.clearSelectableRegions()

    #expect(model.selectableRegions(forPage: 0).isEmpty)
    #expect(model.selectedRegion == nil)
  }
}
