import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// ``PDFDocumentCore/documentMetadata()``의 Info/XMP 수집·병합을 검증한다 (설계 §5.3 MD1-MD10).
struct MetadataTests {
  // MARK: MD1 — Info 8키 전체

  /// MD1: InfoSpec 8키 전체(ASCII) → `DocumentMetadata` 전 필드 정합.
  @Test func fullASCIIInfoDictionaryMapsAllFields() async throws {
    let info = PDFFixtureBuilder.InfoSpec(entries: [
      ("Title", "(Sample Title)"),
      ("Author", "(Jane Doe)"),
      ("Subject", "(A Subject)"),
      ("Keywords", "(pdf test fixture)"),
      ("Creator", "(Creator App)"),
      ("Producer", "(Producer App)"),
      ("CreationDate", "(D:20240101120000Z)"),
      ("ModDate", "(D:20240315093000Z)")
    ])
    let fixture = PDFFixtureBuilder(info: info).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let metadata = try await document.documentMetadata()

    #expect(metadata.title == "Sample Title")
    #expect(metadata.author == "Jane Doe")
    #expect(metadata.subject == "A Subject")
    #expect(metadata.keywords == "pdf test fixture")
    #expect(metadata.creator == "Creator App")
    #expect(metadata.producer == "Producer App")
    #expect(metadata.creationDate == PDFDateParser.parse("D:20240101120000Z"))
    #expect(metadata.modificationDate == PDFDateParser.parse("D:20240315093000Z"))
  }

  // MARK: MD2 — UTF-16BE 제목

  /// MD2: UTF-16BE 제목(`utf16BEHexLiteral`) → 한글 제목 정상 디코딩.
  @Test func utf16BETitleDecodesKorean() async throws {
    let title = "한글 제목"
    let info = PDFFixtureBuilder.InfoSpec(entries: [
      ("Title", PDFFixtureBuilder.InfoSpec.utf16BEHexLiteral(title))
    ])
    let fixture = PDFFixtureBuilder(info: info).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let metadata = try await document.documentMetadata()
    #expect(metadata.title == title)
  }

  // MARK: MD3 — /Info 부재

  /// MD3: /Info 부재 → 전 필드 nil + pdfVersion만 유효, throw 없음.
  @Test func missingInfoProducesAllNilFields() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 1).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let metadata = try await document.documentMetadata()

    #expect(metadata.title == nil)
    #expect(metadata.author == nil)
    #expect(metadata.subject == nil)
    #expect(metadata.keywords == nil)
    #expect(metadata.creator == nil)
    #expect(metadata.producer == nil)
    #expect(metadata.creationDate == nil)
    #expect(metadata.modificationDate == nil)
    #expect(!metadata.pdfVersion.isEmpty)
  }

  // MARK: MD4 — /Info 댕글링·비딕셔너리

  /// MD4: /Info 댕글링 참조 → MD3과 동일(관용) 결과.
  @Test func danglingInfoReferenceIsTolerated() async throws {
    let fixture = PDFFixtureBuilder(
      pageCount: 1, extraTrailerEntries: ["Info": "999 0 R"]
    ).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let metadata = try await document.documentMetadata()
    #expect(metadata.title == nil)
    #expect(metadata.author == nil)
  }

  // MARK: MD5 — 값 타입 오염

  /// MD5: Title에 정수(타입 오염) → 해당 필드만 nil, 나머지는 정상.
  @Test func typePollutedFieldBecomesNilOthersUnaffected() async throws {
    let info = PDFFixtureBuilder.InfoSpec(entries: [
      ("Title", "42"),
      ("Author", "(Real Author)")
    ])
    let fixture = PDFFixtureBuilder(info: info).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let metadata = try await document.documentMetadata()
    #expect(metadata.title == nil)
    #expect(metadata.author == "Real Author")
  }

  // MARK: MD6 — XMP 단독

  /// MD6: XMP 단독(Info 없음) — 요소형·애트리뷰트형 각각 필드 채택.
  @Test func xmpOnlyElementFormPopulatesFields() async throws {
    let xml = """
    <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description
          xmlns:dc="http://purl.org/dc/elements/1.1/"
          xmlns:pdf="http://ns.adobe.com/pdf/1.3/"
          xmlns:xmp="http://ns.adobe.com/xap/1.0/">
          <dc:title><rdf:Alt><rdf:li xml:lang="x-default">XMP Title</rdf:li></rdf:Alt></dc:title>
          <dc:creator><rdf:Seq><rdf:li>XMP Author</rdf:li></rdf:Seq></dc:creator>
          <pdf:Keywords>xmp keywords</pdf:Keywords>
          <pdf:Producer>XMP Producer</pdf:Producer>
          <xmp:CreatorTool>XMP Creator Tool</xmp:CreatorTool>
          <xmp:CreateDate>2024-01-01T12:00:00Z</xmp:CreateDate>
        </rdf:Description>
      </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
    let fixture = PDFFixtureBuilder(xmpMetadata: xml).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let metadata = try await document.documentMetadata()

    #expect(metadata.title == "XMP Title")
    #expect(metadata.author == "XMP Author")
    #expect(metadata.keywords == "xmp keywords")
    #expect(metadata.producer == "XMP Producer")
    #expect(metadata.creator == "XMP Creator Tool")
    #expect(metadata.creationDate != nil)
  }

  /// MD6 부가: XMP 애트리뷰트 축약형만 있는 경우도 채택된다.
  @Test func xmpAttributeFormPopulatesFields() async throws {
    let xml = """
    <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description
          pdf:Producer="Attr Producer" xmp:CreatorTool="Attr Tool"
          xmlns:pdf="http://ns.adobe.com/pdf/1.3/"
          xmlns:xmp="http://ns.adobe.com/xap/1.0/" />
      </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
    let fixture = PDFFixtureBuilder(xmpMetadata: xml).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let metadata = try await document.documentMetadata()
    #expect(metadata.producer == "Attr Producer")
    #expect(metadata.creator == "Attr Tool")
  }

  // MARK: MD7 — 병합 우선순위

  /// MD7: Info.title vs XMP.title 상충 → Info 승리; Info에 없는 필드는 XMP 보충.
  @Test func infoWinsOverXMPOnConflictAndSupplementsMissingFields() async throws {
    let info = PDFFixtureBuilder.InfoSpec(entries: [("Title", "(Info Title)")])
    let xml = """
    <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description
          xmlns:dc="http://purl.org/dc/elements/1.1/"
          xmlns:pdf="http://ns.adobe.com/pdf/1.3/">
          <dc:title><rdf:Alt><rdf:li>XMP Title</rdf:li></rdf:Alt></dc:title>
          <pdf:Producer>XMP Producer</pdf:Producer>
        </rdf:Description>
      </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
    let fixture = PDFFixtureBuilder(info: info, xmpMetadata: xml).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let metadata = try await document.documentMetadata()

    #expect(metadata.title == "Info Title")
    #expect(metadata.producer == "XMP Producer")
  }

  // MARK: MD8 — XMP 비정형·크기 초과

  /// MD8: 비정형 XML → 그 시점까지 채집분 사용(조용히 무시 가능), 크래시 없음.
  @Test func malformedXMPIsTakenBestEffortWithoutCrashing() async throws {
    let xml = """
    <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description xmlns:pdf="http://ns.adobe.com/pdf/1.3/">
          <pdf:Producer>Before The Break
        </rdf:Description>
    """
    let fixture = PDFFixtureBuilder(xmpMetadata: xml).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let metadata = try await document.documentMetadata()
    #expect(metadata.title == nil)
  }

  // MARK: MD9 — PDF 버전 비교

  /// MD9: 카탈로그 /Version "1.7" > 헤더 1.4 → pdfVersion "1.7".
  @Test func catalogVersionWinsWhenGreaterThanHeader() async throws {
    let data = Self.rawFixtureWithCatalogVersion(version: "1.7")
    let document = try await PDFDocumentCore.open(data: data)
    let metadata = try await document.documentMetadata()
    #expect(metadata.pdfVersion == "1.7")
  }

  /// MD9 부가: 훼손된 /Version → 헤더값 사용.
  @Test func malformedCatalogVersionFallsBackToHeader() async throws {
    let data = Self.rawFixtureWithCatalogVersion(version: "garbage")
    let document = try await PDFDocumentCore.open(data: data)
    let metadata = try await document.documentMetadata()
    #expect(metadata.pdfVersion == "1.4")
  }

  // MARK: MD10 — dedupe

  /// MD10: 동시 호출 → `metadataBuildCount == 1`.
  @Test func concurrentMetadataCallsBuildOnlyOnce() async throws {
    let info = PDFFixtureBuilder.InfoSpec(entries: [("Title", "(Concurrent)")])
    let fixture = PDFFixtureBuilder(info: info).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<16 {
        group.addTask {
          _ = try await document.documentMetadata()
        }
      }
      try await group.waitForAll()
    }
    let stats = await document.cacheStatistics()
    #expect(stats.metadataBuildCount == 1)
  }
}

// MARK: - 테스트 전용 헬퍼

extension MetadataTests {
  /// 카탈로그에 `/Version /name` 이름을 얹은 최소 클래식 xref PDF를 직접 조립한다
  /// (픽스처 빌더 스펙 표면 밖 — 카탈로그 자체 속성 주입).
  private static func rawFixtureWithCatalogVersion(version: String) -> Data {
    var bytes: [UInt8] = []
    func writeLine(_ text: String) {
      bytes.append(contentsOf: Array(text.utf8))
      bytes.append(0x0A)
    }
    bytes.append(contentsOf: Array("%PDF-1.4\n".utf8))

    var offsets: [Int: Int] = [:]
    offsets[1] = bytes.count
    writeLine("1 0 obj")
    writeLine("<< /Type /Catalog /Pages 2 0 R /Version /\(version) >>")
    writeLine("endobj")
    offsets[2] = bytes.count
    writeLine("2 0 obj")
    writeLine("<< /Type /Pages /Kids [] /Count 0 >>")
    writeLine("endobj")

    let xrefOffset = bytes.count
    writeLine("xref")
    let highest = offsets.keys.max() ?? 0
    writeLine("0 \(highest + 1)")
    for number in 0...highest {
      if number == 0 {
        writeLine("0000000000 65535 f")
      } else if let offset = offsets[number] {
        bytes.append(contentsOf: Array(String(format: "%010d 00000 n\n", offset).utf8))
      } else {
        writeLine("0000000000 00000 f")
      }
    }
    writeLine("trailer")
    writeLine("<< /Size \(highest + 1) /Root 1 0 R >>")
    writeLine("startxref")
    writeLine("\(xrefOffset)")
    bytes.append(contentsOf: Array("%%EOF".utf8))
    return Data(bytes)
  }
}
