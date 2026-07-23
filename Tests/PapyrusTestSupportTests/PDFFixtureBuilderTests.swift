import Foundation
import PapyrusTestSupport
import Testing

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// ``PDFFixtureBuilder``가 생성하는 바이트를 바이트 수준으로 검증한다.
///
/// M0에는 파서가 없으므로 의미론 검증은 (F10을 제외하면) 전부 바이트 패턴 매칭이다.
struct PDFFixtureBuilderTests {
  // MARK: F1 — 헤더/푸터

  /// F1: 헤더 2줄(버전 + 바이너리 마커 주석)과 `%%EOF` 종결을 검증한다.
  @Test(arguments: [0, 1, 5, 100])
  func headerAndFooterAreWellFormed(pageCount: Int) {
    let fixture = PDFFixtureBuilder(pageCount: pageCount).build()
    let bytes = [UInt8](fixture.data)

    let firstLine = Array("%PDF-1.4\n".utf8)
    #expect(Array(bytes.prefix(firstLine.count)) == firstLine)

    let secondLineStart = firstLine.count
    #expect(bytes[secondLineStart] == UInt8(ascii: "%"))

    guard let newlineIndex = bytes[secondLineStart...].firstIndex(of: 0x0A) else {
      Issue.record("바이너리 마커 주석 줄의 개행을 찾지 못함")
      return
    }
    let markerLine = bytes[(secondLineStart + 1)..<newlineIndex]
    #expect(markerLine.filter { $0 > 127 }.count == 4)

    #expect(Array(bytes.suffix(5)) == Array("%%EOF".utf8))
  }

  // MARK: F2 — startxref 왕복

  /// F2: `startxref` 다음 줄의 숫자가 `xrefOffset`과 일치하고, 그 오프셋이 실제로
  /// `xref\n`으로 시작하는지 검증한다.
  @Test func startxrefRoundTripsToXRefOffset() throws {
    let fixture = PDFFixtureBuilder(pageCount: 3).build()
    let bytes = [UInt8](fixture.data)

    guard let keywordOffset = offset(of: "startxref\n", in: fixture.data) else {
      Issue.record("startxref 키워드를 찾지 못함")
      return
    }
    let numberStart = keywordOffset + "startxref\n".utf8.count
    guard let newlineIndex = bytes[numberStart...].firstIndex(of: 0x0A) else {
      Issue.record("startxref 숫자 줄의 개행을 찾지 못함")
      return
    }
    let numberText = try #require(
      String(bytes: bytes[numberStart..<newlineIndex], encoding: .utf8)
    )
    #expect(Int(numberText) == fixture.xrefOffset)

    let atXRefOffset = fixture.data[fixture.xrefOffset...]
    #expect(Array(atXRefOffset.prefix(5)) == Array("xref\n".utf8))
  }

  // MARK: F3 — 객체 오프셋 정합

  /// F3: `objectOffsets`의 모든 오프셋이 실제 `N 0 obj` 시작 지점을 가리키고, 키 집합이
  /// `1...(pageCount + 2)`와 일치한다.
  @Test(arguments: [0, 1, 5, 20])
  func objectOffsetsPointToObjectHeaders(pageCount: Int) {
    let fixture = PDFFixtureBuilder(pageCount: pageCount).build()

    #expect(Set(fixture.objectOffsets.keys) == Set(1...(pageCount + 2)))

    for (objectNumber, objectOffset) in fixture.objectOffsets {
      let expectedPrefix = Array("\(objectNumber) 0 obj".utf8)
      let actual = Array(fixture.data[objectOffset..<(objectOffset + expectedPrefix.count)])
      #expect(actual == expectedPrefix)
    }
  }

  // MARK: F4 — xref 테이블 형식

  /// F4: 서브섹션 헤더, 엔트리 수, 엔트리 폭(20바이트), free 엔트리, 각 객체 오프셋
  /// 인코딩을 전부 검증한다.
  @Test(arguments: [0, 1, 5, 20])
  func xRefTableHasFixedWidthEntries(pageCount: Int) throws {
    let fixture = PDFFixtureBuilder(pageCount: pageCount).build()
    let bytes = [UInt8](fixture.data)
    let totalObjects = pageCount + 3

    let headerLine = Array("xref\n0 \(totalObjects)\n".utf8)
    let headerStart = fixture.xrefOffset
    #expect(Array(bytes[headerStart..<(headerStart + headerLine.count)]) == headerLine)

    let entriesStart = headerStart + headerLine.count
    for index in 0..<totalObjects {
      let entryStart = entriesStart + (index * 20)
      let entryBytes = bytes[entryStart..<(entryStart + 20)]
      let entryText = try #require(String(bytes: entryBytes, encoding: .utf8))

      if index == 0 {
        #expect(entryText == "0000000000 65535 f\r\n")
      } else {
        let expectedOffset = zeroPadded(fixture.objectOffsets[index] ?? -1, width: 10)
        #expect(entryText == "\(expectedOffset) 00000 n\r\n")
      }
    }

    let trailerStart = entriesStart + (totalObjects * 20)
    let trailerBytes = Array("trailer\n".utf8)
    #expect(Array(bytes[trailerStart..<(trailerStart + trailerBytes.count)]) == trailerBytes)
  }

  // MARK: F5 — 트레일러

  /// F5: `trailer` 이후에 `/Size`와 `/Root`가 올바른 값으로 존재한다.
  @Test func trailerContainsSizeAndRoot() {
    let pageCount = 4
    let fixture = PDFFixtureBuilder(pageCount: pageCount).build()

    guard let trailerOffset = offset(of: "trailer\n", in: fixture.data) else {
      Issue.record("trailer 키워드를 찾지 못함")
      return
    }
    let afterTrailer = fixture.data[trailerOffset...]
    #expect(offset(of: "/Size \(pageCount + 3)", in: afterTrailer) != nil)
    #expect(offset(of: "/Root 1 0 R", in: afterTrailer) != nil)
  }

  // MARK: F6 — 페이지 트리 구조

  /// F6: `/Count`, `/Kids` 내부 참조 수, 각 페이지 객체의 `/Type /Page` +
  /// `/Parent 2 0 R`를 검증한다.
  @Test(arguments: [0, 1, 3, 10])
  func pageTreeStructureIsConsistent(pageCount: Int) throws {
    let fixture = PDFFixtureBuilder(pageCount: pageCount).build()

    #expect(offset(of: "/Count \(pageCount)", in: fixture.data) != nil)

    guard let kidsOpenOffset = offset(of: "/Kids [", in: fixture.data) else {
      Issue.record("/Kids 배열을 찾지 못함")
      return
    }
    let kidsContentStart = kidsOpenOffset + "/Kids [".utf8.count
    let bytes = [UInt8](fixture.data)
    guard let closeBracketIndex = bytes[kidsContentStart...].firstIndex(of: UInt8(ascii: "]"))
    else {
      Issue.record("/Kids 배열의 닫는 괄호를 찾지 못함")
      return
    }
    let kidsText = try #require(
      String(bytes: bytes[kidsContentStart..<closeBracketIndex], encoding: .utf8)
    )
    let referenceCount = kidsText.isEmpty ? 0 : kidsText.components(separatedBy: "0 R").count - 1
    #expect(referenceCount == pageCount)

    guard pageCount > 0 else {
      return
    }
    for objectNumber in 3...(pageCount + 2) {
      guard let objectStart = fixture.objectOffsets[objectNumber],
            let endobjOffset = offset(of: "endobj", in: fixture.data, from: objectStart)
      else {
        Issue.record("페이지 객체 \(objectNumber)의 경계를 찾지 못함")
        continue
      }
      let objectText = try #require(
        String(bytes: bytes[objectStart..<endobjOffset], encoding: .utf8)
      )
      #expect(objectText.contains("/Type /Page "))
      #expect(objectText.contains("/Parent 2 0 R"))
    }
  }

  // MARK: F7 — MediaBox 반영

  /// F7: 기본 크기와 소수 크기 모두 MediaBox에 올바르게(결정적 포맷팅으로) 반영된다.
  @Test func mediaBoxReflectsDefaultDimensions() {
    let fixture = PDFFixtureBuilder(pageCount: 1).build()
    #expect(offset(of: "[0 0 612 792]", in: fixture.data) != nil)
  }

  /// F7: 소수 크기 지정 시 뒤 0이 제거된 포맷으로 MediaBox에 반영된다.
  @Test func mediaBoxReflectsDecimalDimensions() {
    let fixture = PDFFixtureBuilder(
      pageCount: 1,
      pageWidth: 595.28,
      pageHeight: 841.89
    ).build()
    #expect(offset(of: "[0 0 595.28 841.89]", in: fixture.data) != nil)
  }

  // MARK: F8 — 결정성

  /// F8: 동일 설정으로 두 번 `build()`하면 완전히 동일한 바이트가 나온다.
  @Test func buildIsDeterministic() {
    let builder = PDFFixtureBuilder(pageCount: 7, pageWidth: 500.5, pageHeight: 700)
    #expect(builder.build().data == builder.build().data)
  }

  // MARK: F9 — 퇴화/규모

  /// F9: `pageCount == 0`이면 `/Kids []`이고 객체는 카탈로그 + Pages 2개뿐이다.
  @Test func degenerateZeroPageFixtureIsValid() {
    let fixture = PDFFixtureBuilder(pageCount: 0).build()
    #expect(offset(of: "/Kids []", in: fixture.data) != nil)
    #expect(fixture.objectCount == 2)
  }

  /// F9: `pageCount == 1000`이어도 정상적으로 빌드가 완료되고 객체 수가 맞는다.
  @Test func largeFixtureBuildsSuccessfully() {
    let fixture = PDFFixtureBuilder(pageCount: 1_000).build()
    #expect(fixture.objectCount == 1_002)
  }

  // MARK: F10 — (선택) 외부 대조

  #if canImport(CoreGraphics)
  /// F10: macOS 한정, 생성 바이트를 `CGPDFDocument`로 열어 페이지 수가 일치하는지
  /// 확인한다. 자체 파서가 아직 없으므로 M1 전 유일한 의미론 검증 수단이다.
  ///
  /// `pageCount == 0`은 제외한다 — `CGPDFDocument`는 페이지가 0개인 문서를 열지 못하는
  /// 것으로 관측되었다(외부 라이브러리의 동작이며, 바이트 구조 자체의 결함이 아니다).
  /// 해당 퇴화 케이스의 바이트 검증은 F9(``degenerateZeroPageFixtureIsValid``)가 맡는다.
  @Test(arguments: [1, 5, 25])
  func cgpdfDocumentAgreesOnPageCount(pageCount: Int) throws {
    let fixture = PDFFixtureBuilder(pageCount: pageCount).build()
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    try fixture.data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let document = try #require(CGPDFDocument(url as CFURL))
    #expect(document.numberOfPages == pageCount)
  }
  #endif

  // MARK: F11 — 콘텐츠 스트림 v1 확장

  /// F11: `contentStream == nil`이면(기본값이든 명시든) v0와 완전히 동일한 바이트를
  /// 산출한다 — 기존 F1–F10 골든 테스트가 무수정으로 계속 통과함으로써도 보증된다.
  @Test(arguments: [0, 1, 5])
  func contentStreamNilMatchesV0Bytes(pageCount: Int) {
    let withDefaultParam = PDFFixtureBuilder(pageCount: pageCount).build()
    let withExplicitNil = PDFFixtureBuilder(pageCount: pageCount, contentStream: nil).build()
    #expect(withDefaultParam.data == withExplicitNil.data)
  }

  /// F11: 콘텐츠 스트림 설정 시 신규 객체(N+3, `/Length` 간접이면 N+4)가
  /// `objectOffsets`에 포함되고 각 오프셋이 실제 `N 0 obj` 시작을 가리킨다.
  @Test func contentStreamAddsObjectOffsetsForNewObjects() throws {
    let pageCount = 2
    let fixture = PDFFixtureBuilder(
      pageCount: pageCount,
      contentStream: .init(body: Data("BT ET".utf8), lengthStyle: .indirect)
    ).build()

    #expect(Set(fixture.objectOffsets.keys) == Set(1...(pageCount + 4)))
    #expect(fixture.objectCount == pageCount + 4)

    let contentsObjectNumber = pageCount + 3
    let contentsOffset = try #require(fixture.objectOffsets[contentsObjectNumber])
    let contentsPrefix = Array("\(contentsObjectNumber) 0 obj".utf8)
    let contentsActual = fixture.data[contentsOffset..<(contentsOffset + contentsPrefix.count)]
    #expect(Array(contentsActual) == contentsPrefix)

    let lengthObjectNumber = pageCount + 4
    let lengthOffset = try #require(fixture.objectOffsets[lengthObjectNumber])
    let lengthPrefix = Array("\(lengthObjectNumber) 0 obj".utf8)
    let lengthActual = fixture.data[lengthOffset..<(lengthOffset + lengthPrefix.count)]
    #expect(Array(lengthActual) == lengthPrefix)
  }

  /// F11: 각 페이지 딕셔너리에 `/Contents (N+3) 0 R` 참조가 정확히 페이지 수만큼 존재한다.
  @Test func contentStreamAddsContentsReferenceToEachPage() {
    let pageCount = 3
    let fixture = PDFFixtureBuilder(
      pageCount: pageCount, contentStream: .init(body: Data("BT ET".utf8))
    ).build()
    let expected = "/Contents \(pageCount + 3) 0 R"

    var searchStart = 0
    var found = 0
    while let index = offset(of: expected, in: fixture.data, from: searchStart) {
      found += 1
      searchStart = index + 1
    }
    #expect(found == pageCount)
  }

  /// F11: `/Length` 기록 방식별 바이트 형태 — direct는 정확한 정수, indirect는
  /// `N 0 R`, directWrong은 실제 길이와 다른 정수를 기록한다.
  @Test func lengthStyleReflectsDeclaredBytes() {
    let body = Data("BT ET".utf8)

    let direct = PDFFixtureBuilder(
      pageCount: 1, contentStream: .init(body: body, lengthStyle: .direct)
    ).build()
    #expect(offset(of: "/Length \(body.count) ", in: direct.data) != nil)

    let indirect = PDFFixtureBuilder(
      pageCount: 1, contentStream: .init(body: body, lengthStyle: .indirect)
    ).build()
    #expect(offset(of: "/Length 5 0 R", in: indirect.data) != nil)

    let wrong = PDFFixtureBuilder(
      pageCount: 1, contentStream: .init(body: body, lengthStyle: .directWrong(delta: 7))
    ).build()
    #expect(offset(of: "/Length \(body.count + 7) ", in: wrong.data) != nil)
  }

  // MARK: F12 — PDFFilterEncoders 자가 검증

  /// F12: `PDFFilterEncoders.flate` 산출물이 유효한 zlib 헤더(CM=8, FCHECK 정합,
  /// FDICT 미설정)로 시작한다.
  @Test func flateEncoderProducesValidZlibHeader() throws {
    let encoded = PDFFilterEncoders.flate(Data("hello".utf8))
    #expect(encoded.count >= 6)
    let b0 = try #require(encoded.first)
    let b1 = try #require(encoded.dropFirst().first)
    #expect(b0 & 0x0F == 8)
    #expect((UInt16(b0) << 8 | UInt16(b1)) % 31 == 0)
    #expect(b1 & 0x20 == 0)
  }

  /// F12: 트레일러 4바이트가 원문의 Adler-32와 정확히 일치한다 (수계산 대조).
  @Test func flateEncoderAppendsCorrectAdler32Checksum() {
    let original = Data("The quick brown fox".utf8)
    let encoded = PDFFilterEncoders.flate(original)
    let trailer = encoded.suffix(4)
    let checksum = trailer.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    #expect(checksum == adler32Reference(original))
  }
}

// MARK: - 테스트 전용 바이트 헬퍼

/// `pattern`의 UTF-8 바이트 시퀀스가 `data`에서 처음 등장하는 오프셋을 찾는다.
///
/// `fixture.data`는 헤더에 비ASCII 바이너리 마커를 포함하므로 `String(decoding:)`로
/// 전체를 문자열화하지 않고, 바이트 단위로 직접 탐색한다.
func offset(of pattern: String, in data: Data, from start: Int = 0) -> Int? {
  let patternBytes = Array(pattern.utf8)
  let dataBytes = [UInt8](data)
  guard !patternBytes.isEmpty, patternBytes.count <= dataBytes.count else {
    return nil
  }

  var index = start
  while index <= dataBytes.count - patternBytes.count {
    if Array(dataBytes[index..<(index + patternBytes.count)]) == patternBytes {
      return index
    }
    index += 1
  }
  return nil
}

/// 정수를 `width`자리로 0-padding한 문자열을 만든다 (xref 오프셋 인코딩 대조용).
private func zeroPadded(_ value: Int, width: Int) -> String {
  let text = String(value)
  guard text.count < width else {
    return text
  }
  return String(repeating: "0", count: width - text.count) + text
}

/// RFC 1950 Adler-32를 독립적으로 재계산한다 (인코더 내부 구현과 대조 독립성 유지).
private func adler32Reference(_ data: Data) -> UInt32 {
  var lowSum: UInt32 = 1
  var highSum: UInt32 = 0
  let modAdler: UInt32 = 65_521
  for byte in data {
    lowSum = (lowSum + UInt32(byte)) % modAdler
    highSum = (highSum + lowSum) % modAdler
  }
  return (highSum << 16) | lowSum
}
