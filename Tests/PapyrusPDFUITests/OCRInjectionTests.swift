import CoreGraphics
import Foundation
import PapyrusPDFCore
import PapyrusPDFRendering
import PapyrusPDFTestSupport
@testable import PapyrusPDFUI
import Testing

/// M13 완료 기준의 본체 — 스텁 OCR 프로바이더로 뷰어의 선택·복사·검색이 동작하는지
/// 종단 검증한다 (설계 §5-2).
///
/// `ReaderSession.assemble`(internal)은 직접 테스트하지 않는다. 대신 그 조립 함수가
/// 만드는 것과 동형인 객체 그래프 — `ReaderSelectablePageStore(provider:)` +
/// `ReaderSearchCoordinator(document:provider:)` + `ReaderCore` — 를 테스트가 직접
/// 조립해 검증한다 (설계 §0.2-6).
@MainActor
struct OCRInjectionTests {
  // MARK: 검색 배선 — 정방향 (텍스트 없는 문서 + OCR 스텁)

  @Test func searchMatchesStubbedTextOnTextlessDocument() async throws {
    let document = try await Self.emptyDocument(pageCount: 1)
    let content = Self.uniformContent(pageIndex: 0, text: "needle here")
    let provider = DictionaryTextProvider(contents: [0: content])
    let core = try await Self.makeSearchableCore(document: document, provider: provider)

    core.beginSearch("needle", options: SearchOptions())
    try await UITestSupport.waitUntil { core.currentSearchState.phase == .completed }

    #expect(core.searchMatchIndex.count == 1)
    #expect(core.searchMatchIndex.first?.pageIndex == 0)
  }

  // MARK: 검색 배선 — 역방향 (내장 텍스트가 있어도 프로바이더가 전체를 대체)

  @Test func searchOnlyMatchesStubbedTextEvenWhenEmbeddedTextExists() async throws {
    let document = try await Self.embeddedTextDocument(text: "an embedded phrase")
    let content = Self.uniformContent(pageIndex: 0, text: "ocr replacement text")
    let provider = DictionaryTextProvider(contents: [0: content])
    let core = try await Self.makeSearchableCore(document: document, provider: provider)

    core.beginSearch("embedded", options: SearchOptions())
    try await UITestSupport.waitUntil { core.currentSearchState.phase == .completed }
    #expect(core.searchMatchIndex.isEmpty) // 내장 텍스트는 완전히 가려진다.

    core.clearSearch()
    core.beginSearch("replacement", options: SearchOptions())
    try await UITestSupport.waitUntil { core.currentSearchState.phase == .completed }
    #expect(core.searchMatchIndex.count == 1) // 스텁 텍스트만 매치된다.
  }

  // MARK: 선택·복사 배선 — 페이지 경계 선택 + 개행 결합

  @Test func selectedStringJoinsStubbedPagesAcrossBoundary() async throws {
    let contents: [Int: PageTextContent] = [
      0: SelectionTestFixtures.singleLineContent(pageIndex: 0, text: "First Page"),
      1: SelectionTestFixtures.singleLineContent(pageIndex: 1, text: "Second Page")
    ]
    let provider = DictionaryTextProvider(contents: contents)
    let store = ReaderSelectablePageStore(provider: provider, displayTransform: { _ in .identity })
    store.requestPage(0)
    store.requestPage(1)
    try await UITestSupport.waitUntil {
      store.geometry(forPage: 0) != nil && store.geometry(forPage: 1) != nil
    }
    let controller = ReaderSelectionController(store: store)

    controller.select(
      TextSelection(
        start: TextPosition(pageIndex: 0, utf16Offset: 0),
        end: TextPosition(pageIndex: 1, utf16Offset: "Second Page".utf16.count)
      )
    )

    let selected = await controller.selectedString()
    #expect(selected == "First Page\nSecond Page")
  }

  // MARK: 선택·복사 배선 — 드래그 시퀀스 (uniform advance UI 경로 소비)

  @Test func dragSequenceProducesExpectedSelectionOverStubbedContent() async throws {
    let text = "Hello World"
    let contents: [Int: PageTextContent] = [
      0: SelectionTestFixtures.singleLineContent(pageIndex: 0, text: text)
    ]
    let provider = DictionaryTextProvider(contents: contents)
    let store = ReaderSelectablePageStore(provider: provider, displayTransform: { _ in .identity })
    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }
    let controller = ReaderSelectionController(store: store)

    controller.dragBegan(at: SelectionTestFixtures.pagePoint(0), granularity: .character)
    controller.dragChanged(to: SelectionTestFixtures.pagePoint(text.utf16.count))
    controller.dragEnded()

    let selection = try #require(controller.selection)
    #expect(selection.start == TextPosition(pageIndex: 0, utf16Offset: 0))
    #expect(selection.end == TextPosition(pageIndex: 0, utf16Offset: text.utf16.count))
    #expect(await controller.selectedString() == text)
  }

  // MARK: 악성 프로바이더 — 크래시·행 없음 + 선택·검색 완주 (UI 소비 경로 종단)

  @Test(arguments: MalformedOCRProvider.Kind.allCases)
  func malformedProviderDoesNotCrashOrHangAcrossSelectionAndSearch(
    kind: MalformedOCRProvider.Kind
  ) async throws {
    let provider = MalformedOCRProvider(kind: kind)
    let store = ReaderSelectablePageStore(provider: provider, displayTransform: { _ in .identity })
    let controller = ReaderSelectionController(store: store)
    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }

    // 전 페이지 드래그 — 극단 점으로 페이지 전체를 덮는다.
    controller.dragBegan(
      at: PagePoint(pageIndex: 0, point: CGPoint(x: -1_000, y: -1_000)), granularity: .character
    )
    controller.dragChanged(to: PagePoint(pageIndex: 0, point: CGPoint(x: 100_000, y: 100_000)))
    controller.dragEnded()

    let selectedString = await controller.selectedString()
    if let selectedString {
      #expect(selectedString.utf16.count <= UILimits.maxSelectedTextUTF16)
    }
    if let selection = controller.selection, let geometry = store.geometry(forPage: 0) {
      let range = selection.start.utf16Offset..<selection.end.utf16Offset
      for quad in geometry.displayQuads(forRange: range) {
        Self.expectFiniteQuad(quad)
      }
    }

    // 검색 1회 완주 — 크래시·행 없음. 매치가 있다면 quad도 유한해야 한다.
    let document = try await Self.emptyDocument(pageCount: 1)
    for try await result in document.search("e", provider: provider) {
      for quad in result.quads {
        Self.expectFiniteQuad(quad)
      }
    }
  }

  // MARK: pageString 정합 (§1.3 회귀) — 캐시 히트/미스 경로 동일 절단

  @Test func pageStringMatchesAcrossCacheHitAndMissForOversizedProvider() async throws {
    let provider = MalformedOCRProvider(kind: .oversizedString)

    let hitStore = ReaderSelectablePageStore(
      provider: provider, displayTransform: { _ in .identity }
    )
    hitStore.requestPage(0)
    try await UITestSupport.waitUntil { hitStore.geometry(forPage: 0) != nil }
    let hitString = await hitStore.pageString(forPage: 0)

    let missStore = ReaderSelectablePageStore(
      provider: provider, displayTransform: { _ in .identity }
    )
    let missString = await missStore.pageString(forPage: 0)

    #expect(hitString == missString)
    #expect(hitString.utf16.count == CoreLimits.maxProviderStringUTF16)
  }

  // MARK: 단일 인스턴스 공유 (§0.2-1) — store·coordinator가 같은 프로바이더에 도달

  @Test func storeAndCoordinatorShareTheSameProviderInstance() async throws {
    let recording = RecordingTextProvider(
      content: Self.uniformContent(pageIndex: 0, text: "banana")
    )
    let store = ReaderSelectablePageStore(
      provider: recording, displayTransform: { _ in .identity }
    )
    let document = try await Self.emptyDocument(pageCount: 1)
    let coordinator = ReaderSearchCoordinator(document: document, provider: recording)
    var events: [SearchEvent] = []
    coordinator.onEvent = { events.append($0) }

    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }

    coordinator.start(query: "banana", options: SearchOptions())
    try await UITestSupport.waitUntil {
      events.contains { if case .finished = $0 { return true }; return false }
    }

    // 두 소비 경로 모두 같은(공유된) 프로바이더 인스턴스에 도달했다 — 기록 누적으로 판정.
    #expect(recording.visitedPages.contains(0))
    #expect(recording.callCount >= 2)
  }
}

// MARK: - 테스트 헬퍼

extension OCRInjectionTests {
  /// 지정 페이지 수를 갖는 빈(텍스트 없음) 문서를 연다.
  static func emptyDocument(pageCount: Int) async throws -> PapyrusPDFDocument {
    let fixture = PDFFixtureBuilder(pageCount: pageCount).build()
    return try await PapyrusPDFDocument.open(data: fixture.data)
  }

  /// 내장 텍스트가 있는 1페이지 문서를 연다 (치환 계약 역방향 테스트 전용).
  static func embeddedTextDocument(text: String) async throws -> PapyrusPDFDocument {
    var toUnicode: [UInt8: String] = [:]
    for code in 32...126 {
      toUnicode[UInt8(code)] = String(UnicodeScalar(UInt8(code)))
    }
    let widths = Array(repeating: 600, count: 95)
    let font = PDFFixtureBuilder.TextFixtureSpec.FontFixtureSpec(
      resourceName: "F1",
      kind: .simple(
        baseFont: "Helvetica", baseEncoding: "WinAnsiEncoding", differences: [:], firstChar: 32,
        widths: widths, toUnicode: toUnicode
      ),
      descriptor: .init(ascent: 800, descent: -200)
    )
    let page = PDFFixtureBuilder.TextFixtureSpec.TextPageSpec(
      operations: "BT /F1 12 Tf 72 720 Td (\(text)) Tj ET", fonts: [font]
    )
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: [page])).build()
    return try await PapyrusPDFDocument.open(data: fixture.data)
  }

  /// 균등 advance run 하나로 이뤄진 페이지 콘텐츠를 만든다 (OCR 스텁 표준형).
  static func uniformContent(pageIndex: Int, text: String) -> PageTextContent {
    let quad = Quad(rect: CGRect(x: 0, y: 0, width: CGFloat(text.utf16.count) * 10, height: 14))
    let run = TextRun.uniform(range: 0..<text.utf16.count, quad: quad)
    return PageTextContent(pageIndex: pageIndex, string: text, runs: [run])
  }

  /// 실 문서 + 레이아웃 + 렌더 서비스 + (지정 프로바이더로 배선한) 검색 코디네이터를
  /// 갖춘 `ReaderCore`를 조립한다 (`ReaderSession.assemble`의 검색 배선과 동형).
  static func makeSearchableCore(
    document: PapyrusPDFDocument, provider: any PageTextProvider
  ) async throws -> ReaderCore {
    let pageSizes = try await document.core.pageTree().records.map(\.displaySize)
    let layout = ReaderLayoutEngine(pageSizes: pageSizes)
    let configuration = RenderConfiguration(
      workerCount: 1, pixelScale: 1, installsMemoryPressureMonitor: false
    )
    let renderQueue = TileRenderQueue(
      documentData: document.core.sourceBytes, pageSizes: pageSizes, configuration: configuration
    )
    let coordinator = ReaderSearchCoordinator(document: document, provider: provider)
    return ReaderCore(layout: layout, renderQueue: renderQueue, searchCoordinator: coordinator)
  }

  /// quad의 16개 성분이 전부 유한한지 단정한다.
  static func expectFiniteQuad(_ quad: Quad) {
    #expect(quad.bottomLeft.x.isFinite && quad.bottomLeft.y.isFinite)
    #expect(quad.bottomRight.x.isFinite && quad.bottomRight.y.isFinite)
    #expect(quad.topLeft.x.isFinite && quad.topLeft.y.isFinite)
    #expect(quad.topRight.x.isFinite && quad.topRight.y.isFinite)
  }
}

/// M8 퍼즈 정신을 프로바이더 입력에 적용한 악성 콘텐츠 스텁 (설계 §5-2 6종).
///
/// `Core` 위생 유닛(`PageContentSanitizerTests`)의 대응이 아니라, 그 위생 검사를 거친
/// 결과가 UI 소비 경로(선택·복사·검색)를 크래시·행 없이 끝까지 통과하는지가 검증
/// 대상이다.
struct MalformedOCRProvider: PageTextProvider, Sendable {
  /// 악성 유형.
  enum Kind: CaseIterable, Sendable {
    /// range가 문자열 길이를 벗어난 run.
    case outOfRangeRun
    /// quad 좌표에 NaN이 섞인 run.
    case nonFiniteQuad
    /// 빈 구간 run 10만 개 + 정상 run 1개 (전자는 전량 폐기되어야 한다).
    case hugeRunCount
    /// 상한(`CoreLimits.maxProviderStringUTF16`)을 넘는 문자열.
    case oversizedString
    /// 실제 요청과 다른 `pageIndex`를 기록한 콘텐츠.
    case wrongPageIndex
    /// 항상 throw.
    case throwingProvider
  }

  /// 반환할 악성 유형.
  let kind: Kind

  /// 유형에 대응하는 악성(또는 부분 악성) 콘텐츠를 반환한다 (throw 유형은 던진다).
  func textContent(forPage pageIndex: Int) async throws -> PageTextContent {
    let text = "needle"
    let goodQuad = Quad(rect: CGRect(x: 0, y: 0, width: 60, height: 14))

    switch self.kind {
    case .throwingProvider:
      throw PapyrusPDFError.damagedDocument
    case .outOfRangeRun:
      let outOfRange = TextRun(range: 100..<200, quad: goodQuad, advances: [], isInvisible: false)
      let good = TextRun.uniform(range: 0..<text.utf16.count, quad: goodQuad)
      return PageTextContent(pageIndex: pageIndex, string: text, runs: [outOfRange, good])
    case .nonFiniteQuad:
      let nanQuad = Quad(
        bottomLeft: CGPoint(x: CGFloat.nan, y: 0), bottomRight: CGPoint(x: 10, y: 0),
        topRight: CGPoint(x: 10, y: 10), topLeft: CGPoint(x: 0, y: 10)
      )
      let bad = TextRun.uniform(range: 0..<3, quad: nanQuad)
      let good = TextRun.uniform(range: 3..<text.utf16.count, quad: goodQuad)
      return PageTextContent(pageIndex: pageIndex, string: text, runs: [bad, good])
    case .hugeRunCount:
      var runs: [TextRun] = []
      runs.reserveCapacity(100_001)
      let emptyQuad = Quad(rect: .zero)
      for _ in 0..<100_000 {
        runs.append(TextRun(range: 3..<3, quad: emptyQuad, advances: [], isInvisible: false))
      }
      runs.append(TextRun.uniform(range: 0..<text.utf16.count, quad: goodQuad))
      return PageTextContent(pageIndex: pageIndex, string: text, runs: runs)
    case .oversizedString:
      let oversized = String(repeating: "a", count: CoreLimits.maxProviderStringUTF16 + 10)
      let run = TextRun.uniform(range: 0..<oversized.utf16.count, quad: goodQuad)
      return PageTextContent(pageIndex: pageIndex, string: oversized, runs: [run])
    case .wrongPageIndex:
      let run = TextRun.uniform(range: 0..<text.utf16.count, quad: goodQuad)
      return PageTextContent(pageIndex: 99, string: text, runs: [run])
    }
  }
}

/// 요청된 페이지를 기록하는 프로바이더 (단일 인스턴스 공유 검증 전용 — 락으로 보호된
/// 가변 상태를 갖는다).
final class RecordingTextProvider: PageTextProvider, @unchecked Sendable {
  /// 항상 반환할 고정 콘텐츠.
  private let content: PageTextContent

  private let lock = NSLock()
  private var recordedPages: Set<Int> = []
  private var recordedCallCount = 0

  /// 기록 프로바이더를 만든다.
  /// - Parameter content: 매 요청마다 반환할 고정 콘텐츠.
  init(content: PageTextContent) {
    self.content = content
  }

  /// 지금까지 요청된 페이지 인덱스 집합.
  var visitedPages: Set<Int> {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.recordedPages
  }

  /// 지금까지의 총 호출 횟수.
  var callCount: Int {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.recordedCallCount
  }

  /// 요청을 기록하고 고정 콘텐츠를 반환한다.
  func textContent(forPage pageIndex: Int) async throws -> PageTextContent {
    self.record(pageIndex)
    return self.content
  }

  /// 잠금 보호 하에 요청을 기록한다 (동기 헬퍼 — async 컨텍스트에서 직접 잠그지 않기 위함).
  private func record(_ pageIndex: Int) {
    self.lock.lock()
    self.recordedPages.insert(pageIndex)
    self.recordedCallCount += 1
    self.lock.unlock()
  }
}
