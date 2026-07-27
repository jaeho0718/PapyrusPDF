import CoreGraphics
import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// ``PapyrusPDFDocument/search(_:options:provider:)`` 일반화·``DocumentTextProvider``를
/// 검증한다 (설계 §5.6).
struct TextSearchProviderTests {
  // MARK: 순서 보장 + throw 페이지 스킵

  @Test func matchesEmitInPageThenPositionOrderSkippingThrowingPages() async throws {
    let contents: [Int: PageTextContent] = [
      0: Self.content(pageIndex: 0, text: "needle here"),
      2: Self.content(pageIndex: 2, text: "another needle")
    ]
    let provider = StubPageTextProvider(contents: contents, throwingPages: [1], pageCount: 3)
    let document = try await Self.emptyDocument(pageCount: 3)

    var results: [SearchResult] = []
    for try await result in document.search("needle", provider: provider) {
      results.append(result)
    }

    #expect(results.count == 2)
    #expect(results[0].pageIndex == 0)
    #expect(results[1].pageIndex == 2)
  }

  // MARK: 총량 캡 (페이지당 캡을 채우는 페이지를 총량 캡 초과분만큼 준비)

  @Test func totalMatchesAreCappedAcrossPages() async throws {
    // 페이지당 정확히 maxSearchMatchesPerPage개 매치를 내도록 구성하고, 누적이
    // maxSearchTotalMatches를 넘기기에 충분한 페이지 수를 쓴다.
    let perPageMatches = CoreLimits.maxSearchMatchesPerPage
    let pageCount = CoreLimits.maxSearchTotalMatches / perPageMatches + 1
    var contents: [Int: PageTextContent] = [:]
    let text = String(repeating: "a", count: perPageMatches)
    for pageIndex in 0..<pageCount {
      contents[pageIndex] = Self.content(pageIndex: pageIndex, text: text)
    }
    let provider = StubPageTextProvider(
      contents: contents, throwingPages: [], pageCount: pageCount
    )
    let document = try await Self.emptyDocument(pageCount: pageCount)

    var count = 0
    for try await _ in document.search("a", provider: provider) {
      count += 1
    }
    #expect(count == CoreLimits.maxSearchTotalMatches)
  }

  // MARK: 기본 오버로드 동등성 — search(q) ≡ search(q, provider: DocumentTextProvider)

  @Test func defaultOverloadMatchesExplicitDocumentTextProvider() async throws {
    let page = ContentStreamInterpreterTests.page(
      operations: "BT /F1 12 Tf 72 720 Td (find the needle here) Tj ET",
      fonts: [ContentStreamInterpreterTests.standardFont()]
    )
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: [page])).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)

    var defaultResults: [SearchResult] = []
    for try await result in document.search("needle") {
      defaultResults.append(result)
    }
    var explicitResults: [SearchResult] = []
    for try await result in document.search(
      "needle", provider: DocumentTextProvider(document: document)
    ) {
      explicitResults.append(result)
    }
    #expect(defaultResults == explicitResults)
    #expect(!defaultResults.isEmpty)
  }

  // MARK: DocumentTextProvider.textContent ≡ document.text(forPage:)

  @Test func documentTextProviderDelegatesToDocumentText() async throws {
    let page = ContentStreamInterpreterTests.page(
      operations: "BT /F1 12 Tf 72 720 Td (Hello) Tj ET",
      fonts: [ContentStreamInterpreterTests.standardFont()]
    )
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: [page])).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)
    let provider = DocumentTextProvider(document: document)

    let viaProvider = try await provider.textContent(forPage: 0)
    let viaDocument = try await document.text(forPage: 0)
    #expect(viaProvider == viaDocument)
  }

  // MARK: 악성 프로바이더 — 크래시/행 없음 + pageIndex 교정 + quads 유한

  @Test func malformedProviderContentDoesNotCrashAndIsSanitized() async throws {
    let badQuad = Quad(
      bottomLeft: CGPoint(x: CGFloat.nan, y: 0), bottomRight: CGPoint(x: 10, y: 0),
      topRight: CGPoint(x: 10, y: 10), topLeft: CGPoint(x: 0, y: 10)
    )
    let outOfRangeRun = TextRun(range: 100..<200, quad: badQuad, advances: [], isInvisible: false)
    let goodQuad = Quad(
      bottomLeft: .zero, bottomRight: CGPoint(x: 60, y: 0), topRight: CGPoint(x: 60, y: 10),
      topLeft: CGPoint(x: 0, y: 10)
    )
    let goodRun = TextRun.uniform(range: 0..<6, quad: goodQuad)
    // pageIndex를 일부러 틀리게(99) 기록 — 위생 검사가 요청 인덱스로 교정해야 한다.
    let malformed = PageTextContent(
      pageIndex: 99, string: "needle", runs: [outOfRangeRun, goodRun]
    )
    let provider = StubPageTextProvider(
      contents: [0: malformed], throwingPages: [], pageCount: 1
    )
    let document = try await Self.emptyDocument(pageCount: 1)

    var results: [SearchResult] = []
    for try await result in document.search("needle", provider: provider) {
      results.append(result)
    }

    #expect(results.count == 1)
    #expect(results[0].pageIndex == 0)
    for quad in results[0].quads {
      #expect(quad.bottomLeft.x.isFinite && quad.bottomLeft.y.isFinite)
      #expect(quad.bottomRight.x.isFinite && quad.bottomRight.y.isFinite)
      #expect(quad.topLeft.x.isFinite && quad.topLeft.y.isFinite)
      #expect(quad.topRight.x.isFinite && quad.topRight.y.isFinite)
    }
  }
}

// MARK: - 테스트 헬퍼

extension TextSearchProviderTests {
  /// 지정 페이지 수를 갖는 빈(텍스트 없음) 문서를 연다. 페이지 수만 필요한 프로바이더
  /// 기반 테스트의 `pageCount` 공급원.
  private static func emptyDocument(pageCount: Int) async throws -> PapyrusPDFDocument {
    let fixture = PDFFixtureBuilder(pageCount: pageCount).build()
    return try await PapyrusPDFDocument.open(data: fixture.data)
  }

  /// 균일 전진량 run 하나로 이뤄진 페이지 콘텐츠를 만든다.
  /// - Parameters:
  ///   - pageIndex: 페이지 인덱스.
  ///   - text: 페이지 문자열.
  /// - Returns: 합성 페이지 콘텐츠.
  private static func content(pageIndex: Int, text: String) -> PageTextContent {
    let quad = Quad(
      bottomLeft: .zero, bottomRight: CGPoint(x: CGFloat(text.utf16.count) * 10, y: 0),
      topRight: CGPoint(x: CGFloat(text.utf16.count) * 10, y: 10), topLeft: CGPoint(x: 0, y: 10)
    )
    let run = TextRun.uniform(range: 0..<text.utf16.count, quad: quad)
    return PageTextContent(pageIndex: pageIndex, string: text, runs: [run])
  }
}

/// 고정 사전 기반 스텁 프로바이더 — 지정 페이지는 throw, 나머지는 미리 채워진 콘텐츠나
/// 빈 콘텐츠를 반환한다.
private struct StubPageTextProvider: PageTextProvider, Sendable {
  let contents: [Int: PageTextContent]
  let throwingPages: Set<Int>
  let pageCount: Int

  func textContent(forPage pageIndex: Int) async throws -> PageTextContent {
    if self.throwingPages.contains(pageIndex) {
      struct StubError: Error {}
      throw StubError()
    }
    return self.contents[pageIndex] ?? PageTextContent(pageIndex: pageIndex, string: "", runs: [])
  }
}
