import Foundation
@testable import PapyrusCore
import PapyrusTestSupport
import Testing

/// 페이지 텍스트/폰트 캐시의 dedupe·LRU 관찰을 검증한다 (설계 §5.5 TC1-TC4).
struct TextCacheTests {
  // MARK: TC1 — 동시 요청 dedupe

  @Test func concurrentRequestsForSamePageExtractOnce() async throws {
    let page = ContentStreamInterpreterTests.page(
      operations: "BT /F1 12 Tf 72 720 Td (Hi) Tj ET",
      fonts: [ContentStreamInterpreterTests.standardFont()]
    )
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: [page])).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)

    async let first = document.pageText(at: 0)
    async let second = document.pageText(at: 0)
    async let third = document.pageText(at: 0)
    _ = try await (first, second, third)

    let stats = await document.cacheStatistics()
    #expect(stats.textExtractionCount == 1)
  }

  // MARK: TC2 — 캐시 히트 (순차 2회)

  @Test func sequentialAccessHitsCacheWithoutRebuilding() async throws {
    let page = ContentStreamInterpreterTests.page(
      operations: "BT /F1 12 Tf 72 720 Td (Hi) Tj ET",
      fonts: [ContentStreamInterpreterTests.standardFont()]
    )
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: [page])).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)

    let first = try await document.pageText(at: 0)
    let second = try await document.pageText(at: 0)
    #expect(first == second)

    let stats = await document.cacheStatistics()
    #expect(stats.textExtractionCount == 1)
  }

  // MARK: TC3 — LRU 바이트 관찰

  @Test func textPageCacheAccumulatesObservableBytes() async throws {
    let page = ContentStreamInterpreterTests.page(
      operations: "BT /F1 12 Tf 72 720 Td (Hello World) Tj ET",
      fonts: [ContentStreamInterpreterTests.standardFont()]
    )
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: [page])).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    _ = try await document.pageText(at: 0)

    let stats = await document.cacheStatistics()
    #expect(stats.textPageCacheBytes > 0)
  }

  // MARK: TC4 — 폰트 공유 dedupe

  @Test func sharedFontSpecAcrossPagesBuildsOnce() async throws {
    let font = ContentStreamInterpreterTests.standardFont()
    let page1 = ContentStreamInterpreterTests.page(
      operations: "BT /F1 12 Tf 72 720 Td (A) Tj ET", fonts: [font]
    )
    let page2 = ContentStreamInterpreterTests.page(
      operations: "BT /F1 12 Tf 72 720 Td (B) Tj ET", fonts: [font]
    )
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: [page1, page2])).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)

    _ = try await document.pageText(at: 0)
    _ = try await document.pageText(at: 1)

    let stats = await document.cacheStatistics()
    #expect(stats.fontBuildCount == 1)
  }
}
