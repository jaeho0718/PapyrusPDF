import Foundation
@testable import PapyrusCore
import PapyrusTestSupport
import Testing

/// ``COSParser``의 재귀 하강·lookahead·스트림 조립을 검증한다 (설계 §3.2, §5.3).
struct COSParserTests {
  // MARK: P1 — 픽스처 종단 골든

  /// P1: Catalog/Pages/Page 딕셔너리가 기대 ``COSObject`` 리터럴과 정확히 일치한다.
  @Test(arguments: [0, 1, 5])
  func fixtureIndirectObjectsMatchExpectedStructure(pageCount: Int) throws {
    let fixture = PDFFixtureBuilder(pageCount: pageCount).build()
    let file = MappedFile(data: fixture.data)
    var parser = COSParser(file: file)

    let catalogOffset = try #require(fixture.objectOffsets[1])
    let catalog = try parser.parseIndirectObject(at: catalogOffset)
    #expect(catalog.id == ObjectID(number: 1, generation: 0))
    #expect(catalog.object == .dictionary(COSDictionary([
      .type: .name("Catalog"),
      COSName("Pages"): .reference(ObjectID(number: 2, generation: 0))
    ])))

    let pagesOffset = try #require(fixture.objectOffsets[2])
    let pages = try parser.parseIndirectObject(at: pagesOffset)
    let kids = (0..<pageCount).map { COSObject.reference(ObjectID(number: 3 + $0, generation: 0)) }
    #expect(pages.object == .dictionary(COSDictionary([
      .type: .name("Pages"),
      COSName("Kids"): .array(kids),
      COSName("Count"): .integer(pageCount)
    ])))

    guard pageCount > 0 else {
      return
    }
    for pageNumber in 3...(pageCount + 2) {
      let pageOffset = try #require(fixture.objectOffsets[pageNumber])
      let page = try parser.parseIndirectObject(at: pageOffset)
      #expect(page.object == .dictionary(COSDictionary([
        .type: .name("Page"),
        COSName("Parent"): .reference(ObjectID(number: 2, generation: 0)),
        COSName("MediaBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)])
      ])))
    }
  }

  // MARK: P2 — 참조 lookahead

  @Test func referenceLookaheadRecognizesSimpleReference() throws {
    #expect(
      try parseValue("[12 0 R]")
        == .array([.reference(ObjectID(number: 12, generation: 0))])
    )
  }

  @Test func referenceLookaheadFallsBackToPlainIntegers() throws {
    #expect(try parseValue("[12 0]") == .array([.integer(12), .integer(0)]))
    #expect(try parseValue("[12 0 5]") == .array([.integer(12), .integer(0), .integer(5)]))
  }

  @Test func referenceLookaheadInsideDictionaryValues() throws {
    #expect(try parseValue("<< /A 1 /B 2 >>") == .dictionary(COSDictionary([
      COSName("A"): .integer(1), COSName("B"): .integer(2)
    ])))
  }

  @Test func referenceLookaheadRecognizesMultipleReferences() throws {
    #expect(try parseValue("[12 0 R 5 0 R]") == .array([
      .reference(ObjectID(number: 12, generation: 0)),
      .reference(ObjectID(number: 5, generation: 0))
    ]))
  }

  @Test func negativeNumberBeforeRIsNotAReference() {
    do {
      _ = try parseValue("[-1 0 R]")
      Issue.record("R 앞의 음수는 unexpectedToken이어야 함")
    } catch {
      #expect(error.code == .unexpectedToken)
    }
  }

  // MARK: P3 — 중첩 깊이

  @Test func nestingWithinLimitSucceeds() throws {
    let depth = 512
    let source = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
    var current = try parseValue(source)
    for _ in 0..<depth {
      guard case let .array(elements) = current, elements.count == 1 else {
        Issue.record("예상한 중첩 배열 구조가 아님")
        return
      }
      current = elements[0]
    }
    #expect(current == .integer(0))
  }

  @Test func nestingBeyondLimitThrows() {
    let depth = 513
    let source = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
    do {
      _ = try parseValue(source)
      Issue.record("513 중첩은 nestingTooDeep이어야 함")
    } catch {
      #expect(error.code == .nestingTooDeep)
    }
  }

  // MARK: P4 — 딕셔너리 규칙

  @Test func dictionaryDropsNullEntriesAndKeepsLastDuplicate() throws {
    let value = try parseValue("<< /A null /B 1 /B 2 >>")
    #expect(value == .dictionary(COSDictionary([COSName("B"): .integer(2)])))
  }

  @Test func nonNameKeyThrowsUnexpectedToken() {
    do {
      _ = try parseValue("<< 1 2 >>")
      Issue.record("비-name 키는 unexpectedToken이어야 함")
    } catch {
      #expect(error.code == .unexpectedToken)
    }
  }

  // MARK: P5 — 간접 객체 헤더

  @Test func indirectObjectHeaderValidCase() throws {
    let file = MappedFile(data: Data("12 0 obj\n42\nendobj".utf8))
    var parser = COSParser(file: file)
    let result = try parser.parseIndirectObject(at: 0)
    #expect(result.id == ObjectID(number: 12, generation: 0))
    #expect(result.object == .integer(42))
    #expect(parser.warnings.isEmpty)
  }

  @Test func indirectObjectHeaderAllowsNonZeroGeneration() throws {
    let file = MappedFile(data: Data("12 3 obj\n42\nendobj".utf8))
    var parser = COSParser(file: file)
    let result = try parser.parseIndirectObject(at: 0)
    #expect(result.id == ObjectID(number: 12, generation: 3))
  }

  @Test(arguments: ["0 0 obj\n42\nendobj", "12 70000 obj\n42\nendobj"])
  func indirectObjectHeaderViolationsThrow(_ source: String) {
    let file = MappedFile(data: Data(source.utf8))
    var parser = COSParser(file: file)
    do {
      _ = try parser.parseIndirectObject(at: 0)
      Issue.record("헤더 위반은 invalidObjectHeader여야 함: \(source)")
    } catch {
      #expect(error.code == .invalidObjectHeader)
    }
  }

  @Test func missingEndobjProducesWarningButReturnsObject() throws {
    let file = MappedFile(data: Data("12 0 obj\n42".utf8))
    var parser = COSParser(file: file)
    let result = try parser.parseIndirectObject(at: 0)
    #expect(result.object == .integer(42))
    #expect(parser.warnings == [.missingEndobj(id: ObjectID(number: 12, generation: 0))])
  }

  // MARK: P6 — 스트림 EOL 변형

  @Test(arguments: [
    StreamEOLCase(eol: .lf, expectsWarning: false, label: "lf"),
    StreamEOLCase(eol: .crlf, expectsWarning: false, label: "crlf"),
    StreamEOLCase(eol: .cr, expectsWarning: true, label: "cr")
  ])
  func streamEOLVariantsYieldSamePayloadBytes(_ testCase: StreamEOLCase) throws {
    let body = Data("BT ET".utf8)
    let fixture = PDFFixtureBuilder(
      pageCount: 1, contentStream: .init(body: body, streamEOL: testCase.eol)
    ).build()
    let file = MappedFile(data: fixture.data)
    var parser = COSParser(file: file)
    let contentsOffset = try #require(fixture.objectOffsets[4])
    let result = try parser.parseIndirectObject(at: contentsOffset)

    let range = try fileRange(of: result.object)
    #expect(file.bytes(in: range) == body)
    #expect(hasNonstandardStreamEOLWarning(parser.warnings) == testCase.expectsWarning)
  }

  /// S1 회귀: `stream` 키워드 직후 EOL이 전혀 없어도(데이터가 바로 이어져도) 크래시·행 없이
  /// 파싱에 성공하고, 관찰 가능한 `nonstandardStreamEOL` 경고를 남긴다.
  ///
  /// 페이로드 첫 바이트로 구분자(`(`)를 쓴다 — regular 바이트(영숫자 등)를 쓰면 렉서가
  /// `stream` 키워드 자체에 이어 붙여 스캔해버려(`streamABC` 하나의 bare keyword)
  /// "EOL 없음" 경로 자체에 도달하지 못한다.
  @Test func streamWithoutEOLProducesNonstandardEOLWarning() throws {
    let source = "1 0 obj\n<< /Type /Stream >>\nstream(ABC)\nendstream\nendobj"
    let file = MappedFile(data: Data(source.utf8))
    var parser = COSParser(file: file)
    let result = try parser.parseIndirectObject(at: 0)
    let range = try fileRange(of: result.object)
    #expect(file.bytes(in: range) == Data("(ABC)".utf8))
    #expect(hasNonstandardStreamEOLWarning(parser.warnings))
  }
}

/// ``COSParser``의 스트림 `/Length` 해석·손상 내성·퍼징을 검증한다 (설계 §3.2, §5.3).
/// `COSParserTests`와 분리한 이유는 순수 조직적(타입 길이 제한)이며, 같은 설계 절
/// P7–P11을 다룬다.
struct COSParserStreamTests {
  // MARK: P7 — /Length 경로

  @Test func directLengthMatchProducesNoWarnings() throws {
    let body = Data("BT ET".utf8)
    let fixture = PDFFixtureBuilder(
      pageCount: 1, contentStream: .init(body: body, lengthStyle: .direct)
    ).build()
    let file = MappedFile(data: fixture.data)
    var parser = COSParser(file: file)
    let offset = try #require(fixture.objectOffsets[4])
    _ = try parser.parseIndirectObject(at: offset)
    #expect(parser.warnings.isEmpty)
  }

  @Test(arguments: [5, -5])
  func directWrongLengthRecoversViaScanWithWarning(_ delta: Int) throws {
    let body = Data("BT ET".utf8)
    let fixture = PDFFixtureBuilder(
      pageCount: 1, contentStream: .init(body: body, lengthStyle: .directWrong(delta: delta))
    ).build()
    let file = MappedFile(data: fixture.data)
    var parser = COSParser(file: file)
    let offset = try #require(fixture.objectOffsets[4])
    let result = try parser.parseIndirectObject(at: offset)
    let range = try fileRange(of: result.object)
    #expect(file.bytes(in: range) == body)
    #expect(hasStreamLengthMismatchWarning(parser.warnings))
  }

  /// B1 회귀: `/Length`에 `Int.max`급 값이 와도 `dataStart + declared` 오버플로 트랩 없이
  /// 스캔 폴백으로 안전하게 복구한다.
  @Test func hugeDirectLengthDoesNotOverflowAndFallsBackToScan() throws {
    let source = "1 0 obj\n<< /Length \(Int.max) >>\nstream\nABC\nendstream\nendobj"
    let file = MappedFile(data: Data(source.utf8))
    var parser = COSParser(file: file)
    let result = try parser.parseIndirectObject(at: 0)
    let range = try fileRange(of: result.object)
    #expect(file.bytes(in: range) == Data("ABC".utf8))
    #expect(hasStreamLengthMismatchWarning(parser.warnings))
  }

  @Test func indirectLengthWithoutResolverFallsBackToScan() throws {
    let body = Data("BT ET".utf8)
    let fixture = PDFFixtureBuilder(
      pageCount: 1, contentStream: .init(body: body, lengthStyle: .indirect)
    ).build()
    let file = MappedFile(data: fixture.data)
    var parser = COSParser(file: file)
    let offset = try #require(fixture.objectOffsets[4])
    let result = try parser.parseIndirectObject(at: offset)
    let range = try fileRange(of: result.object)
    #expect(file.bytes(in: range) == body)
    #expect(hasStreamLengthMismatchWarning(parser.warnings))
  }

  @Test func indirectLengthWithResolverProducesNoWarnings() throws {
    let body = Data("BT ET".utf8)
    let fixture = PDFFixtureBuilder(
      pageCount: 1, contentStream: .init(body: body, lengthStyle: .indirect)
    ).build()
    let file = MappedFile(data: fixture.data)
    let expectedLength = body.count
    var parser = COSParser(file: file) { _ in expectedLength }
    let offset = try #require(fixture.objectOffsets[4])
    let result = try parser.parseIndirectObject(at: offset)
    let range = try fileRange(of: result.object)
    #expect(file.bytes(in: range) == body)
    #expect(parser.warnings.isEmpty)
  }

  @Test func resolverThrowSurfacesAsLengthResolutionFailed() throws {
    struct ResolverFailure: Error {}
    let body = Data("BT ET".utf8)
    let fixture = PDFFixtureBuilder(
      pageCount: 1, contentStream: .init(body: body, lengthStyle: .indirect)
    ).build()
    let file = MappedFile(data: fixture.data)
    var parser = COSParser(file: file) { _ in throw ResolverFailure() }
    let offset = try #require(fixture.objectOffsets[4])
    do {
      _ = try parser.parseIndirectObject(at: offset)
      Issue.record("resolver throw는 lengthResolutionFailed여야 함")
    } catch {
      #expect(error.code == .lengthResolutionFailed)
    }
  }

  // MARK: P8 — payload는 위치만

  @Test func streamPayloadIsLocationOnlyNotDecoded() throws {
    let body = Data("BT ET".utf8)
    let fixture = PDFFixtureBuilder(
      pageCount: 1, contentStream: .init(body: body, encodings: [.flate])
    ).build()
    let file = MappedFile(data: fixture.data)
    var parser = COSParser(file: file)
    let offset = try #require(fixture.objectOffsets[4])
    let result = try parser.parseIndirectObject(at: offset)
    let range = try fileRange(of: result.object)
    let storedBytes = try #require(file.bytes(in: range))
    #expect(storedBytes == PDFFilterEncoders.flate(body))
    #expect(storedBytes != body)
  }

  // MARK: P9 — parseObject(at:) 단독 값

  @Test func parseObjectHandlesStandaloneValues() throws {
    #expect(try parseValue("<< /Size 10 /Root 1 0 R >>") == .dictionary(COSDictionary([
      COSName("Size"): .integer(10),
      COSName("Root"): .reference(ObjectID(number: 1, generation: 0))
    ])))
    #expect(try parseValue("[1 2 3]") == .array([.integer(1), .integer(2), .integer(3)]))
    #expect(try parseValue("/Name") == .name(COSName("Name")))
    #expect(try parseValue("42") == .integer(42))
  }

  // MARK: P10 — 손상 내성

  @Test(.timeLimit(.minutes(1)))
  func truncatedFixtureBytesFailGracefullyWithoutHanging() throws {
    let fixture = PDFFixtureBuilder(
      pageCount: 3, contentStream: .init(body: Data("BT ET".utf8), encodings: [.flate])
    ).build()
    let offset = try #require(fixture.objectOffsets[4])
    let step = max(1, (fixture.data.count - offset) / 20)
    var cut = offset
    while cut < fixture.data.count {
      let truncated = Data(fixture.data.prefix(cut))
      let file = MappedFile(data: truncated)
      var parser = COSParser(file: file)
      do {
        _ = try parser.parseIndirectObject(at: offset)
      } catch {
        // 에러 반환은 기대된 결과 — 크래시·행이 없으면 통과.
      }
      cut += step
    }
  }

  // MARK: P11 — 스모크 퍼징

  @Test func fuzzedRandomBytesNeverCrashParser() {
    var generator = SeededGenerator(seed: 20_260_722)
    for _ in 0..<32 {
      var bytes = [UInt8](repeating: 0, count: 1_024)
      for index in bytes.indices {
        bytes[index] = UInt8.random(in: 0...255, using: &generator)
      }
      let file = MappedFile(data: Data(bytes))
      var parser = COSParser(file: file)
      do {
        _ = try parser.parseObject(at: 0)
      } catch {
        // 에러 반환은 기대된 결과 — 크래시가 없으면 통과.
      }
    }
  }
}
