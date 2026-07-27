import CoreGraphics
import PapyrusPDFCore
@testable import PapyrusPDFUI
import QuartzCore
import Testing

/// `PapyrusPDFReaderModel`의 하이라이트 등록부 배선(적재 전 등록·재생, 문서 정체성 리셋,
/// `makeHighlights` 변환·왕복)을 검증한다 (설계 §5-5).
@MainActor
struct PapyrusPDFReaderModelHighlightTests {
  /// `layer`의 `CAShapeLayer` 서브레이어 중 지정 `zPosition`이고 비어 있지 않은 path가
  /// 있는지 확인한다.
  private static func hasNonEmptyPath(_ layer: CALayer, zPosition: CGFloat) -> Bool {
    (layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
      .contains { $0.zPosition == zPosition && !($0.path?.isEmpty ?? true) }
  }

  private static func highlight(page: Int, x: CGFloat = 0) -> Highlight {
    Highlight(
      pageIndex: page, quads: [Quad(rect: CGRect(x: x, y: 0, width: 10, height: 10))],
      color: .yellow
    )
  }

  /// 지정 페이지들을 미리 로드한 스토어·컨트롤러로 부착된 코어를 만든다.
  /// - Parameter transform: 각 페이지의 표시 변환 (기본 항등).
  private static func makeAttachedCore(
    pages: [Int], pageCount: Int = 3, transform: CGAffineTransform = .identity
  ) async throws -> (core: ReaderCore, host: MockScrollHost) {
    var contents: [Int: PageTextContent] = [:]
    for page in pages {
      contents[page] = SelectionTestFixtures.singleLineContent(pageIndex: page)
    }
    let provider = DictionaryTextProvider(contents: contents)
    let store = ReaderSelectablePageStore(provider: provider, displayTransform: { _ in transform })
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
    host.viewportSize = CGSize(width: 300, height: 900)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 900)
    core.attach(to: host)
    return (core, host)
  }

  /// 두 quad의 4점을 허용 오차 안에서 비교한다.
  private static func expectQuadsClose(_ lhs: Quad, _ rhs: Quad, tolerance: CGFloat = 1e-6) {
    let lhsPoints = [lhs.bottomLeft, lhs.bottomRight, lhs.topRight, lhs.topLeft]
    let rhsPoints = [rhs.bottomLeft, rhs.bottomRight, rhs.topRight, rhs.topLeft]
    for (lhsPoint, rhsPoint) in zip(lhsPoints, rhsPoints) {
      #expect(abs(lhsPoint.x - rhsPoint.x) < tolerance)
      #expect(abs(lhsPoint.y - rhsPoint.y) < tolerance)
    }
  }

  // MARK: 적재 전 등록 → attach 후 재생

  @Test func highlightsRegisteredBeforeAttachReplayAndRender() async throws {
    let model = PapyrusPDFReaderModel()
    model.addHighlight(Self.highlight(page: 0)) // 연결 전 — 모델 등록부에만 저장.
    #expect(model.highlights(forPage: 0).count == 1)

    let (core, _) = try await Self.makeAttachedCore(pages: [0])
    model.attach(core: core)

    let controller = try #require(core.controllers[0])
    #expect(
      Self.hasNonEmptyPath(
        controller.overlayLayer, zPosition: OverlayZPosition.persistentHighlight
      )
    ) // 재생되지 않았다면 표시되지 않는다.
  }

  // MARK: 문서 정체성 — 같은 문서 재조립은 등록부 유지, 다른 문서는 리셋

  @Test func sameDocumentIdentityReassemblyRetainsHighlights() async throws {
    let model = PapyrusPDFReaderModel()
    let (core, _) = try await Self.makeAttachedCore(pages: [0])
    let documentID = ObjectIdentifier(core)
    model.beginLoading(documentID: documentID) // 최초 적재.
    model.attach(core: core)
    model.addHighlight(Self.highlight(page: 0))

    model.beginLoading(documentID: documentID) // 같은 문서 재조립.

    #expect(model.highlights(forPage: 0).count == 1) // 유지.
  }

  @Test func differentDocumentIdentityResetsHighlightRegistry() async throws {
    let model = PapyrusPDFReaderModel()
    let (coreA, _) = try await Self.makeAttachedCore(pages: [0])
    model.beginLoading(documentID: ObjectIdentifier(coreA))
    model.attach(core: coreA)
    model.addHighlight(Self.highlight(page: 0))
    #expect(model.highlights(forPage: 0).count == 1)

    let (coreB, _) = try await Self.makeAttachedCore(pages: [0])
    model.beginLoading(documentID: ObjectIdentifier(coreB)) // 다른 문서.

    #expect(model.highlights(forPage: 0).isEmpty) // 리셋.
  }

  @Test func firstEverLoadDoesNotResetHighlightsRegisteredBeforeBeginLoading() async throws {
    let model = PapyrusPDFReaderModel()
    model.addHighlight(Self.highlight(page: 0))

    let (core, _) = try await Self.makeAttachedCore(pages: [0])
    model.beginLoading(documentID: ObjectIdentifier(core))

    #expect(model.highlights(forPage: 0).count == 1)
  }

  // MARK: removeHighlight / removeAllHighlights / allHighlights

  @Test func removeHighlightAndRemoveAllHighlightsUpdateRegistryAndRender() async throws {
    let model = PapyrusPDFReaderModel()
    let (core, _) = try await Self.makeAttachedCore(pages: [0])
    model.attach(core: core)
    let highlight = Self.highlight(page: 0)
    model.addHighlight(highlight)
    let controller = try #require(core.controllers[0])
    #expect(
      Self.hasNonEmptyPath(
        controller.overlayLayer, zPosition: OverlayZPosition.persistentHighlight
      )
    )

    model.removeHighlight(id: highlight.id)

    #expect(model.highlights(forPage: 0).isEmpty)
    #expect(
      !Self.hasNonEmptyPath(
        controller.overlayLayer, zPosition: OverlayZPosition.persistentHighlight
      )
    )

    model.addHighlights([Self.highlight(page: 0), Self.highlight(page: 1, x: 5)])
    #expect(model.allHighlights.count == 2)

    model.removeAllHighlights()

    #expect(model.allHighlights.isEmpty)
  }

  // MARK: makeHighlights — 단어 선택 → 1건

  @Test func makeHighlightsFromSinglePageSelectionReturnsOneHighlightWithMatchingRange()
    async throws {
    let model = PapyrusPDFReaderModel()
    let (core, _) = try await Self.makeAttachedCore(pages: [0])
    model.attach(core: core)
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )

    let highlights = await model.makeHighlights(from: selection, color: .yellow)

    #expect(highlights.count == 1)
    #expect(highlights.first?.pageIndex == 0)
    #expect(highlights.first?.range == 0..<5)
    #expect(!(highlights.first?.quads.isEmpty ?? true))
  }

  // MARK: makeHighlights — 페이지 경계 선택 → 페이지별 1건

  @Test func makeHighlightsFromCrossPageSelectionReturnsOneHighlightPerPage() async throws {
    let model = PapyrusPDFReaderModel()
    let (core, _) = try await Self.makeAttachedCore(pages: [0, 1])
    model.attach(core: core)
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 6),
      end: TextPosition(pageIndex: 1, utf16Offset: 5)
    )

    let highlights = await model.makeHighlights(from: selection, color: .green)

    #expect(highlights.map(\.pageIndex) == [0, 1])
    #expect(highlights.allSatisfy { !$0.quads.isEmpty })
  }

  // MARK: makeHighlights — 빈 선택·미연결 → 빈 배열

  @Test func makeHighlightsReturnsEmptyForEmptySelection() async throws {
    let model = PapyrusPDFReaderModel()
    let (core, _) = try await Self.makeAttachedCore(pages: [0])
    model.attach(core: core)
    let position = TextPosition(pageIndex: 0, utf16Offset: 3)
    let emptySelection = TextSelection(start: position, end: position)

    let highlights = await model.makeHighlights(from: emptySelection, color: .yellow)

    #expect(highlights.isEmpty)
  }

  @Test func makeHighlightsReturnsEmptyWhenNotAttached() async throws {
    let model = PapyrusPDFReaderModel()
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )

    let highlights = await model.makeHighlights(from: selection, color: .yellow)

    #expect(highlights.isEmpty)
  }

  // MARK: makeHighlights — 왕복 검증 (역변환 정확성)

  @Test func makeHighlightsQuadsRoundTripThroughDisplayTransformMatchesLiveDisplayQuads()
    async throws {
    let transform = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 37, ty: -19)
    let model = PapyrusPDFReaderModel()
    let (core, _) = try await Self.makeAttachedCore(pages: [0], transform: transform)
    model.attach(core: core)
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )

    let highlights = await model.makeHighlights(from: selection, color: .yellow)
    let highlight = try #require(highlights.first)

    model.select(selection) // 같은 시점 표시 quad를 얻기 위한 확정.
    let expectedDisplayQuads = try #require(core.selectionController).displayQuads(forPage: 0)

    #expect(highlight.quads.count == expectedDisplayQuads.count)
    let reprojected = highlight.quads.map { PageDisplayTransform.apply(transform, to: $0) }
    for (lhs, rhs) in zip(reprojected, expectedDisplayQuads) {
      Self.expectQuadsClose(lhs, rhs)
    }
  }
}
