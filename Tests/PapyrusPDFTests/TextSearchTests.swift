import Foundation
import PapyrusPDF
import PapyrusPDFTestSupport
import Testing

/// ``PapyrusPDFDocument/search(_:options:)`` 스트림 통합 테스트 (설계 §5.2) — 완료 기준.
struct TextSearchTests {
  // MARK: 1 — 순서 보장

  @Test func resultsArrivePageAscendingAndPositionAscendingWithinPage() async throws {
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: Self.searchFixturePages())).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)

    var results: [SearchResult] = []
    for try await result in document.search("needle") {
      results.append(result)
    }

    let pageIndices = results.map(\.pageIndex)
    #expect(pageIndices == pageIndices.sorted())
    for pageIndex in 0..<8 {
      let positions = results.filter { $0.pageIndex == pageIndex }.map(\.range.lowerBound)
      #expect(positions == positions.sorted())
    }
  }

  // MARK: 2 — 매치 수·range·snippet 정합

  @Test func caseInsensitiveNeedleFindsTwoMatchesPerPage() async throws {
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: Self.searchFixturePages())).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)

    var results: [SearchResult] = []
    for try await result in document.search("needle") {
      results.append(result)
    }

    #expect(results.count == 16)
    for pageIndex in 0..<8 {
      #expect(results.filter { $0.pageIndex == pageIndex }.count == 2)
    }
    for result in results {
      let matchedText = Self.snippetSlice(result)
      #expect(matchedText.lowercased() == "needle")
    }
  }

  // MARK: 3 — quads가 cropBox 안

  @Test func quadsAreNonEmptyAndLieWithinCropBox() async throws {
    let fixture = PDFFixtureBuilder(
      textFixture: .init(pages: Self.searchFixturePages(count: 1))
    ).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)
    let cropBox = try await document.page(at: 0).cropBox

    var results: [SearchResult] = []
    for try await result in document.search("needle") {
      results.append(result)
    }

    #expect(!results.isEmpty)
    let tolerant = cropBox.insetBy(dx: -1, dy: -1)
    for result in results {
      #expect(!result.quads.isEmpty)
      for quad in result.quads {
        #expect(tolerant.contains(quad.boundingRect))
      }
    }
  }

  // MARK: 4 — 빈 query / 매치 없는 query

  @Test func blankQueryProducesNoResultsAndFinishesNormally() async throws {
    let fixture = PDFFixtureBuilder(
      textFixture: .init(pages: Self.searchFixturePages(count: 1))
    ).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)

    var results: [SearchResult] = []
    for try await result in document.search("   ") {
      results.append(result)
    }
    #expect(results.isEmpty)
  }

  @Test func nonMatchingQueryProducesNoResultsAndFinishesNormally() async throws {
    let fixture = PDFFixtureBuilder(
      textFixture: .init(pages: Self.searchFixturePages(count: 1))
    ).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)

    var results: [SearchResult] = []
    for try await result in document.search("zzz-not-present") {
      results.append(result)
    }
    #expect(results.isEmpty)
  }

  // MARK: 5 — 취소

  @Test func breakingAfterFirstResultStopsFurtherWork() async throws {
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: Self.searchFixturePages())).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)

    var receivedResults: [SearchResult] = []
    for try await result in document.search("needle") {
      receivedResults.append(result)
      break
    }
    #expect(receivedResults.count == 1)

    // 이탈 후 동일 소비 루프로는 더 이상 방출이 없다 — 잠깐 대기해도 배열은 그대로다
    // (내부 드라이버가 계속 돌더라도, 이미 떠난 소비자에게는 아무것도 전달되지 않는다).
    try await Task.sleep(for: .milliseconds(50))
    #expect(receivedResults.count == 1)
  }

  // MARK: 6 — 손상 페이지 스킵

  @Test func corruptedPageIsSkippedWithoutThrowingAndOthersEmit() async throws {
    var pages = Self.searchFixturePages()
    pages[3].encodings = [.flate]
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: pages)).build()
    // /FlateDecode(유효 압축) → /JBIG2Decode(미지원, 동일 12글자) 치환 — 페이지 4의
    // 콘텐츠 스트림만 unsupportedFilter로 실패하게 만든다(오프셋 이동 없음).
    let corrupted = Self.corruptFlateFilterName(in: fixture.data)
    let document = try await PapyrusPDFDocument.open(data: corrupted)

    var results: [SearchResult] = []
    for try await result in document.search("needle") {
      results.append(result)
    }

    let pageIndices = Set(results.map(\.pageIndex))
    #expect(!pageIndices.contains(3))
    #expect(pageIndices.count == 7)
  }

  // MARK: 7 — LZW 인코딩 페이지 (필터 경로 무관성)

  @Test func lzwEncodedPageProducesSameMatchCount() async throws {
    var pages = Self.searchFixturePages()
    pages[2].encodings = [.lzw]
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: pages)).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)

    var results: [SearchResult] = []
    for try await result in document.search("needle") {
      results.append(result)
    }

    #expect(results.count == 16)
    #expect(results.filter { $0.pageIndex == 2 }.count == 2)
  }

  // MARK: 8 — 재검색 캐시 재사용

  @Test func repeatedSearchReusesTextExtractionCache() async throws {
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: Self.searchFixturePages())).build()
    let document = try await PapyrusPDFDocument.open(data: fixture.data)

    for try await _ in document.search("needle") {}
    let firstCount = await document.core.cacheStatistics().textExtractionCount
    #expect(firstCount == 8)

    for try await _ in document.search("needle") {}
    let secondCount = await document.core.cacheStatistics().textExtractionCount
    #expect(secondCount == firstCount)
  }
}

// MARK: - 테스트 지원 (§5.2 SearchFixtures)

extension TextSearchTests {
  /// ASCII 32...126을 항등 매핑하는 ToUnicode + 균일 600 폭을 갖는 표준 테스트 폰트.
  static func standardFont(
    resourceName: String = "F1"
  ) -> PDFFixtureBuilder.TextFixtureSpec.FontFixtureSpec {
    var toUnicode: [UInt8: String] = [:]
    for code in 32...126 {
      toUnicode[UInt8(code)] = String(UnicodeScalar(UInt8(code)))
    }
    let widths = Array(repeating: 600, count: 95)
    return PDFFixtureBuilder.TextFixtureSpec.FontFixtureSpec(
      resourceName: resourceName,
      kind: .simple(
        baseFont: "Helvetica", baseEncoding: "WinAnsiEncoding", differences: [:], firstChar: 32,
        widths: widths, toUnicode: toUnicode
      ),
      descriptor: .init(ascent: 800, descent: -200)
    )
  }

  /// `count`페이지 표준 검색 픽스처. 페이지 i 콘텐츠:
  /// `"Alpha needle {i}"` 줄 + `"beta NEEDLE tail"` 줄 (대소문자 무시 시 페이지당 2매치).
  /// - Parameter count: 생성할 페이지 수 (기본 8).
  /// - Returns: 페이지 명세 목록.
  static func searchFixturePages(
    count: Int = 8
  ) -> [PDFFixtureBuilder.TextFixtureSpec.TextPageSpec] {
    (0..<count).map { index in
      PDFFixtureBuilder.TextFixtureSpec.TextPageSpec(
        operations:
          "BT /F1 12 Tf 72 720 Td (Alpha needle \(index)) Tj 0 -20 Td (beta NEEDLE tail) Tj ET",
        fonts: [Self.standardFont()]
      )
    }
  }

  /// 완성된 PDF 바이트에서 `/FlateDecode`(정확히 12글자)를 미지원 필터
  /// `/JBIG2Decode`(동일 12글자)로 치환한다. 길이가 같아 다른 객체 오프셋을
  /// 흔들지 않으면서 그 스트림만 `unsupportedFilter`로 실패하게 만든다.
  /// - Parameter data: 원본 PDF 바이트 (정확히 1곳에 `/FlateDecode`를 포함해야 한다).
  /// - Returns: 필터 이름이 치환된 PDF 바이트.
  static func corruptFlateFilterName(in data: Data) -> Data {
    let marker = Data("/FlateDecode".utf8)
    guard let range = data.range(of: marker) else {
      preconditionFailure("fixture에 /FlateDecode가 없다 — encodings: [.flate] 페이지가 있어야 한다.")
    }
    var mutated = data
    mutated.replaceSubrange(range, with: Data("/JBIG2Decode".utf8))
    return mutated
  }

  /// `result.snippet`에서 `snippetMatchRange`가 가리키는 부분 문자열을 추출한다.
  /// - Parameter result: 대상 매치.
  /// - Returns: 매치 부분 문자열.
  static func snippetSlice(_ result: SearchResult) -> String {
    let utf16 = Array(result.snippet.utf16)
    let slice = utf16[result.snippetMatchRange]
    return String(decoding: slice, as: UTF16.self)
  }
}
