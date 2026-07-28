import CoreGraphics
import PapyrusPDFCore
import PapyrusPDFRendering
import PapyrusPDFTestSupport
@testable import PapyrusPDFUI
import QuartzCore
import Testing

/// 검색 상태 기계·매치 탐색·스크롤·모델 보류 재생을 검증한다 (설계 §5.3 4-9).
///
/// 4-8은 `ReaderCore.handleSearchEvent`를 직접 호출해 상태 기계를 결정적으로 구동한다
/// (코디네이터·실 문서 없이). 9는 실 문서 + `ReaderSearchCoordinator`로 모델의 보류 재생을
/// 통합 검증한다.
@MainActor
struct ReaderCoreSearchTests {
  // MARK: 4 — began → pageResults → finished 시퀀스

  @Test func searchEventSequenceUpdatesFlatIndexAndNotifiesState() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 5, pageWidth: 200, pageHeight: 200
    )
    var states: [ReaderSearchState] = []
    core.onSearchStateChange = { states.append($0) }

    core.handleSearchEvent(.began(query: "needle"))
    #expect(states.last?.phase == .searching)
    #expect(states.last?.matchCount == 0)
    #expect(states.last?.currentMatchIndex == nil)

    let twoMatches = PageSearchHighlights(matches: [[Self.sampleQuad], [Self.sampleQuad]])
    core.handleSearchEvent(.pageResults(pageIndex: 0, highlights: twoMatches))
    #expect(core.searchMatchIndex.count == 2)
    #expect(core.searchMatchIndex[0].pageIndex == 0 && core.searchMatchIndex[0].ordinal == 0)
    #expect(core.searchMatchIndex[1].pageIndex == 0 && core.searchMatchIndex[1].ordinal == 1)
    #expect(core.currentMatchFlatIndex == 0) // 첫 매치 자동 포커스.
    #expect(states.last?.matchCount == 2)
    #expect(states.last?.currentMatchIndex == 0)

    let oneMatch = PageSearchHighlights(matches: [[Self.sampleQuad]])
    core.handleSearchEvent(.pageResults(pageIndex: 2, highlights: oneMatch))
    #expect(core.searchMatchIndex.count == 3)
    #expect(core.searchMatchIndex[2].pageIndex == 2)

    core.handleSearchEvent(.finished)
    #expect(states.last?.phase == .completed)
    #expect(states.last?.matchCount == 3)
    #expect(states.last?.query == "needle")
  }

  // MARK: 5 — 첫 매치 자동 스크롤 (§3.6 공식 수치 검증)

  @Test func firstMatchArrivalAutoScrollsToComputedTargetY() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 5, pageWidth: 200, pageHeight: 300
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    host.scrollToCalls.removeAll()

    let quad = Quad(
      bottomLeft: CGPoint(x: 10, y: 10), bottomRight: CGPoint(x: 50, y: 10),
      topRight: CGPoint(x: 50, y: 30), topLeft: CGPoint(x: 10, y: 30)
    )
    core.handleSearchEvent(.began(query: "x"))
    core.handleSearchEvent(
      .pageResults(pageIndex: 2, highlights: PageSearchHighlights(matches: [[quad]]))
    )

    let call = try #require(host.scrollToCalls.last)
    let frame = try #require(core.layout.pageFrame(at: 2))
    let expectedTargetY = frame.minY + quad.boundingRect.midY - host.visibleContentRect.height / 2
    let maxY = max(0, core.layout.contentSize.height - host.visibleContentRect.height)
    let expectedClamped = min(max(expectedTargetY, 0), maxY)

    #expect(abs(call.contentY - expectedClamped) < 0.001)
    #expect(call.zoomScale == nil)
  }

  // MARK: 6 — advanceMatch 랩어라운드

  @Test func advanceMatchWrapsAroundInBothDirections() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 5, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)

    core.handleSearchEvent(.began(query: "x"))
    for pageIndex in 0..<3 {
      core.handleSearchEvent(
        .pageResults(
          pageIndex: pageIndex, highlights: PageSearchHighlights(matches: [[Self.sampleQuad]])
        )
      )
    }
    #expect(core.currentMatchFlatIndex == 0)

    core.advanceMatch(by: -1) // 처음 → 이전 = 마지막.
    #expect(core.currentMatchFlatIndex == 2)

    core.advanceMatch(by: 1) // 마지막 → 다음 = 처음(랩어라운드).
    #expect(core.currentMatchFlatIndex == 0)
  }

  // MARK: 7 — 비실체화 페이지 advance → 스크롤 → materialize 후 하이라이트 적용

  @Test func advanceToUnmaterializedPageAppliesHighlightsAfterMaterialization() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 20, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)

    core.handleSearchEvent(.began(query: "x"))
    core.handleSearchEvent(
      .pageResults(pageIndex: 15, highlights: PageSearchHighlights(matches: [[Self.sampleQuad]]))
    )
    core.handleSearchEvent(
      .pageResults(pageIndex: 16, highlights: PageSearchHighlights(matches: [[Self.sampleQuad]]))
    )
    #expect(!core.materializedPageIndices.contains(16))
    host.scrollToCalls.removeAll()

    core.advanceMatch(by: 1) // 15(자동 포커스) → 16.
    #expect(core.currentMatchFlatIndex == 1)
    let call = try #require(host.scrollToCalls.last)

    // 스크롤 결과를 시뮬레이션한다 (목 호스트는 실제로 콘텐츠를 이동시키지 않는다).
    host.visibleContentRect = CGRect(x: 0, y: call.contentY, width: 300, height: 300)
    core.hostViewportDidChange()

    #expect(core.materializedPageIndices.contains(16))
    let controller = try #require(core.controllers[16])
    #expect(Self.hasNonEmptyPath(controller.overlayLayer))
  }

  // MARK: 8 — clearSearch/detach 후 상태·레이어 클리어

  @Test func clearSearchAndDetachResetStateAndClearLayers() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 5, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)

    core.handleSearchEvent(.began(query: "x"))
    core.handleSearchEvent(
      .pageResults(pageIndex: 0, highlights: PageSearchHighlights(matches: [[Self.sampleQuad]]))
    )
    let controller = try #require(core.controllers[0])
    #expect(Self.hasNonEmptyPath(controller.overlayLayer))

    core.clearSearch()

    #expect(core.searchMatchIndex.isEmpty)
    #expect(core.currentMatchFlatIndex == nil)
    #expect(core.currentSearchState.phase == .idle)
    #expect(!Self.hasNonEmptyPath(controller.overlayLayer))

    // detach도 검색 상태를 정리한다.
    core.handleSearchEvent(.began(query: "y"))
    core.handleSearchEvent(
      .pageResults(pageIndex: 1, highlights: PageSearchHighlights(matches: [[Self.sampleQuad]]))
    )
    #expect(!core.searchMatchIndex.isEmpty)

    core.detach()
    #expect(core.searchMatchIndex.isEmpty)
    #expect(core.currentMatchFlatIndex == nil)
  }

  // MARK: 8 (세대 토큰) — 구세대 이벤트 폐기

  @Test func coordinatorDiscardsStaleGenerationEventsAfterRestart() async throws {
    let (_, document) = try await Self.makeSearchableCore(pages: [
      Self.page(text: "alpha beta"), Self.page(text: "alpha beta")
    ])
    let coordinator = ReaderSearchCoordinator(
      document: document, provider: DocumentTextProvider(document: document)
    )
    var events: [SearchEvent] = []
    coordinator.onEvent = { events.append($0) }

    coordinator.start(query: "alpha", options: SearchOptions())
    coordinator.start(query: "beta", options: SearchOptions()) // 즉시 재시작 — 구세대 폐기.

    try await UITestSupport.waitUntil {
      events.contains { if case .finished = $0 { return true }; return false }
    }
    try await Task.sleep(for: .milliseconds(50)) // 잔여(구세대) 이벤트가 있다면 도착할 시간.

    // 세대 토큰이 없었다면 두 스트림 모두 완주해 finished가 2번 등장했을 것이다.
    let finishedCount = events.filter { if case .finished = $0 { return true }; return false }
      .count
    #expect(finishedCount == 1)
  }

  // MARK: 9 — 모델: 연결 전 search() 보류 → attach 후 재생, beginLoading 리셋

  @Test func modelQueuesSearchBeforeAttachAndReplaysAfterAttach() async throws {
    let (core, _) = try await Self.makeSearchableCore(pages: [Self.page(text: "needle here")])
    let model = PapyrusPDFReaderModel()

    model.search("needle")
    #expect(model.searchState == .idle) // 미연결 — 보류만.

    model.attach(core: core)

    try await UITestSupport.waitUntil { model.searchState.phase != .idle }
    #expect(model.searchState.query == "needle")
  }

  @Test func modelBeginLoadingResetsSearchStateAndDropsPendingSearch() async throws {
    let (core, _) = try await Self.makeSearchableCore(pages: [Self.page(text: "needle here")])
    let model = PapyrusPDFReaderModel()

    model.search("needle") // 보류.
    model.beginLoading(documentID: ObjectIdentifier(core)) // 보류 폐기 + idle 리셋.
    model.attach(core: core)

    try await Task.sleep(for: .milliseconds(200))
    #expect(model.searchState == .idle)
  }
}

// MARK: - 테스트 헬퍼

extension ReaderCoreSearchTests {
  /// 축 정렬 표본 quad (10×10 near origin).
  static var sampleQuad: Quad {
    Quad(
      bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 10, y: 0),
      topRight: CGPoint(x: 10, y: 10), topLeft: CGPoint(x: 0, y: 10)
    )
  }

  /// `layer`의 `CAShapeLayer` 서브레이어 중 비어 있지 않은 path가 있는지 확인한다.
  static func hasNonEmptyPath(_ layer: CALayer) -> Bool {
    (layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
      .contains { !($0.path?.isEmpty ?? true) }
  }

  /// ASCII 32...126 항등 ToUnicode + 균일 600 폭의 표준 테스트 폰트.
  static func standardFont() -> PDFFixtureBuilder.TextFixtureSpec.FontFixtureSpec {
    var toUnicode: [UInt8: String] = [:]
    for code in 32...126 {
      toUnicode[UInt8(code)] = String(UnicodeScalar(UInt8(code)))
    }
    let widths = Array(repeating: 600, count: 95)
    return PDFFixtureBuilder.TextFixtureSpec.FontFixtureSpec(
      resourceName: "F1",
      kind: .simple(
        baseFont: "Helvetica", baseEncoding: "WinAnsiEncoding", differences: [:], firstChar: 32,
        widths: widths, toUnicode: toUnicode
      ),
      descriptor: .init(ascent: 800, descent: -200)
    )
  }

  /// 지정 텍스트를 표시하는 페이지 명세.
  /// - Parameter text: `Tj`로 표시할 원문 텍스트 (괄호·역슬래시는 포함하지 않는다).
  static func page(text: String) -> PDFFixtureBuilder.TextFixtureSpec.TextPageSpec {
    PDFFixtureBuilder.TextFixtureSpec.TextPageSpec(
      operations: "BT /F1 12 Tf 72 720 Td (\(text)) Tj ET", fonts: [Self.standardFont()]
    )
  }

  /// 실 문서 + 레이아웃 + 렌더 서비스 + 검색 코디네이터를 갖춘 `ReaderCore`를 조립한다.
  /// - Parameter pages: 페이지 명세 목록.
  /// - Returns: 조립된 코어와 원본 문서.
  static func makeSearchableCore(
    pages: [PDFFixtureBuilder.TextFixtureSpec.TextPageSpec]
  ) async throws -> (core: ReaderCore, document: PapyrusPDFDocument) {
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: pages)).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)
    let pageSizes = try await document.core.pageTree().records.map(\.displaySize)
    let layout = ReaderLayoutEngine(pageSizes: pageSizes)
    let configuration = RenderConfiguration(
      workerCount: 1, pixelScale: 1, installsMemoryPressureMonitor: false
    )
    let renderQueue = TileRenderQueue(
      documentData: document.core.sourceBytes, pageSizes: pageSizes, configuration: configuration
    )
    let coordinator = ReaderSearchCoordinator(
      document: document, provider: DocumentTextProvider(document: document)
    )
    let core = ReaderCore(layout: layout, renderQueue: renderQueue, searchCoordinator: coordinator)
    return (core, document)
  }
}
