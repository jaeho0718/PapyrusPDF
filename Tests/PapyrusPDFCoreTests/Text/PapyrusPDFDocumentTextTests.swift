import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// ``PapyrusPDFDocument/text(forPage:)`` 공개 API 경계 테스트 (설계 §5.5 PA1-PA6).
struct PapyrusPDFDocumentTextTests {
  // MARK: PA1 — 정상 경로 (M4 완료 기준)

  @Test func textForPageExtractsExpectedString() async throws {
    let page = ContentStreamInterpreterTests.page(
      operations: "BT /F1 12 Tf 72 720 Td (Hello, World!) Tj ET",
      fonts: [ContentStreamInterpreterTests.standardFont()]
    )
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: [page])).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)
    let content = try await document.text(forPage: 0)
    #expect(content.string == "Hello, World!")
    #expect(content.runs.count == 1)
    #expect(content.pageIndex == 0)
  }

  // MARK: PA2 — 인덱스 이탈

  @Test func outOfRangeIndexThrowsPageOutOfRange() async throws {
    let page = ContentStreamInterpreterTests.page(
      operations: "BT /F1 12 Tf 72 720 Td (Hi) Tj ET",
      fonts: [ContentStreamInterpreterTests.standardFont()]
    )
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: [page])).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)
    do {
      _ = try await document.text(forPage: 5)
      Issue.record("pageOutOfRange 기대")
    } catch {
      guard case .pageOutOfRange = error else {
        Issue.record("예상치 못한 에러: \(error)")
        return
      }
    }
  }

  // MARK: PA3 — 콘텐츠 없는 페이지

  @Test func pageWithoutContentsProducesEmptyResult() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 1).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)
    let content = try await document.text(forPage: 0)
    #expect(content.string.isEmpty)
    #expect(content.runs.isEmpty)
  }

  // MARK: PA4 — 미지원 필터(/DCTDecode)

  @Test func unsupportedFilterThrows() async throws {
    let data = Self.buildMinimalPDF(
      dictText: "<< /Length 10 /Filter /DCTDecode >>", payload: Array("1234567890".utf8)
    )
    let document = try await PapyrusPDFDocument.open(data: data)
    do {
      _ = try await document.text(forPage: 0)
      Issue.record("unsupportedFilter 기대")
    } catch {
      guard case let .unsupportedFilter(name) = error else {
        Issue.record("예상치 못한 에러: \(error)")
        return
      }
      #expect(name == "DCTDecode")
    }
  }

  // MARK: PA5 — 손상 콘텐츠 스트림 (Flate 절단)

  @Test func truncatedFlateContentSkipsSegmentWithoutThrowing() async throws {
    let fullyEncoded = PDFFilterEncoders.flate(
      Data("BT /F1 12 Tf 72 720 Td (Hello) Tj ET".utf8)
    )
    let truncated = Array(fullyEncoded.prefix(fullyEncoded.count / 2))
    let data = Self.buildMinimalPDF(
      dictText: "<< /Length \(truncated.count) /Filter /FlateDecode >>", payload: truncated
    )
    let document = try await PapyrusPDFDocument.open(data: data)
    let content = try await document.text(forPage: 0)
    #expect(content.string.isEmpty)
    #expect(content.runs.isEmpty)
  }

  // MARK: PA6 — xref 스타일 무관

  @Test func objectStreamsStyleDocumentExtractsViaFallbackFont() async throws {
    let body = Data("BT /F1 12 Tf 72 720 Td (Hi) Tj ET".utf8)
    let fixture = PDFFixtureBuilder(
      pageCount: 1, xrefStyle: .objectStreams, contentStream: .init(body: body)
    ).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)
    let content = try await document.text(forPage: 0)
    // /Resources /Font가 없어 폴백 폰트로 처리된다 — run은 방출되고 문자는 U+FFFD.
    #expect(content.runs.count == 1)
    #expect(content.string == "\u{FFFD}\u{FFFD}")
  }
}

// MARK: - 테스트 헬퍼

extension PapyrusPDFDocumentTextTests {
  /// 카탈로그(1)/Pages(2)/Page(3)/Contents(4) 4객체 + 클래식 xref로 이루어진 최소 PDF를
  /// 손으로 조립한다. `PDFFixtureBuilder`의 폐쇄된 `Encoding` 열거형으로는 표현할 수 없는
  /// 임의 `/Filter` 이름·의도적으로 절단된 스트림 페이로드를 넣기 위함이다.
  static func buildMinimalPDF(dictText: String, payload: [UInt8]) -> Data {
    var bytes: [UInt8] = Array("%PDF-1.4\n".utf8)
    var offsets: [Int] = [0]

    func appendObject(_ text: String) {
      offsets.append(bytes.count)
      bytes.append(contentsOf: Array(text.utf8))
    }

    appendObject("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
    appendObject("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")
    appendObject(
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " +
        "/Resources << >> >>\nendobj\n"
    )

    offsets.append(bytes.count)
    bytes.append(contentsOf: Array("4 0 obj\n\(dictText)\nstream\n".utf8))
    bytes.append(contentsOf: payload)
    bytes.append(contentsOf: Array("\nendstream\nendobj\n".utf8))

    let xrefOffset = bytes.count
    var xrefText = "xref\n0 5\n0000000000 65535 f \n"
    for number in 1...4 {
      xrefText += String(format: "%010d 00000 n \n", offsets[number])
    }
    xrefText += "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF"
    bytes.append(contentsOf: Array(xrefText.utf8))
    return Data(bytes)
  }
}
