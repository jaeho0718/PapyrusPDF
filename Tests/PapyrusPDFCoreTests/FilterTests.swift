import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// 필터 디코더(hex/85/RL/flate)와 파이프라인·종단 골든 테스트 (설계 §3.3, §5.4).
struct FilterTests {
  // MARK: F-HEX

  @Test(arguments: [
    HexGoldenCase(input: "901FA3>", expected: [0x90, 0x1F, 0xA3], label: "even-with-eod"),
    HexGoldenCase(input: "901FA>", expected: [0x90, 0x1F, 0xA0], label: "odd-padded-with-eod"),
    HexGoldenCase(input: "901FA3", expected: [0x90, 0x1F, 0xA3], label: "eod-omitted"),
    HexGoldenCase(input: "90 1F\nA3>", expected: [0x90, 0x1F, 0xA3], label: "whitespace-mixed")
  ])
  func hexDecodeGoldenVectors(_ testCase: HexGoldenCase) throws {
    let decoded = try ASCIIHexDecode.decode(Data(testCase.input.utf8))
    #expect(Array(decoded) == testCase.expected)
  }

  @Test func hexDecodeRejectsInvalidCharacter() {
    do {
      _ = try ASCIIHexDecode.decode(Data("9G>".utf8))
      Issue.record("invalidCharacter 기대")
    } catch {
      #expect(error.code == .invalidCharacter)
    }
  }

  @Test(arguments: [0, 1, 3, 64, 4_096])
  func hexRoundTripsRandomData(size: Int) throws {
    var generator = SeededGenerator(seed: UInt64(size) &+ 1)
    let original = randomData(count: size, using: &generator)
    let decoded = try ASCIIHexDecode.decode(PDFFilterEncoders.asciiHex(original))
    #expect(decoded == original)
  }

  // MARK: F-A85

  @Test func a85DecodeGoldenVectors() throws {
    #expect(Array(try ASCII85Decode.decode(Data("!!!!!".utf8))) == [0x00, 0x00, 0x00, 0x00])
    #expect(Array(try ASCII85Decode.decode(Data("!!!!\"".utf8))) == [0x00, 0x00, 0x00, 0x01])
  }

  @Test func a85DecodeExpandsZShortcutOnlyAtGroupStart() throws {
    #expect(Array(try ASCII85Decode.decode(Data("z".utf8))) == [0, 0, 0, 0])
    #expect(Array(try ASCII85Decode.decode(Data("zz".utf8))) == [0, 0, 0, 0, 0, 0, 0, 0])
  }

  @Test func a85DecodeRejectsZInMiddleOfGroup() {
    do {
      _ = try ASCII85Decode.decode(Data("!z".utf8))
      Issue.record("그룹 중간 z는 invalidCharacter여야 함")
    } catch {
      #expect(error.code == .invalidCharacter)
    }
  }

  @Test func a85DecodeRejectsSingleCharacterResidualGroup() {
    do {
      _ = try ASCII85Decode.decode(Data("!".utf8))
      Issue.record("잔여 1문자는 truncatedData여야 함")
    } catch {
      #expect(error.code == .truncatedData)
    }
  }

  @Test func a85DecodeRejectsOverflowingGroup() {
    do {
      _ = try ASCII85Decode.decode(Data("uuuuu".utf8))
      Issue.record("32비트 초과 그룹은 corruptedData여야 함")
    } catch {
      #expect(error.code == .corruptedData)
    }
  }

  @Test func a85DecodeToleratesLeadingHeaderAndMissingEOD() throws {
    #expect(Array(try ASCII85Decode.decode(Data("<~!!!!!".utf8))) == [0, 0, 0, 0])
    #expect(Array(try ASCII85Decode.decode(Data("!!!!!~>".utf8))) == [0, 0, 0, 0])
    #expect(Array(try ASCII85Decode.decode(Data("!!!!!".utf8))) == [0, 0, 0, 0])
  }

  /// S2 회귀: `~` 직후 바이트가 `>`인지는 검증하지 않는다(문서화된 관용 동작) — `~` 하나만
  /// 보면 그 자리에서 EOD로 간주하고, 뒤따르는 바이트(쓰레기 포함)는 전부 무시한다.
  @Test func a85DecodeDoesNotValidateByteAfterTilde() throws {
    #expect(Array(try ASCII85Decode.decode(Data("!!!!!~X".utf8))) == [0, 0, 0, 0])
    #expect(Array(try ASCII85Decode.decode(Data("!!!!!~".utf8))) == [0, 0, 0, 0])
  }

  @Test(arguments: [0, 1, 2, 3, 4, 5, 63, 64, 65, 4_096])
  func a85RoundTripsRandomData(size: Int) throws {
    var generator = SeededGenerator(seed: UInt64(size) &+ 100)
    let original = randomData(count: size, using: &generator)
    let decoded = try ASCII85Decode.decode(PDFFilterEncoders.ascii85(original))
    #expect(decoded == original)
  }

  // MARK: F-RL

  @Test func runLengthDecodeGoldenVectors() throws {
    // 리터럴 3바이트 [1,2,3] + EOD.
    #expect(Array(try RunLengthDecode.decode(
      Data([2, 1, 2, 3, 128]), maxDecodedSize: 1_024
    )) == [1, 2, 3])
    // 반복 5회 0xAA + EOD.
    #expect(Array(try RunLengthDecode.decode(
      Data([UInt8(257 - 5), 0xAA, 128]), maxDecodedSize: 1_024
    )) == [0xAA, 0xAA, 0xAA, 0xAA, 0xAA])
    // 리터럴 + 반복 혼합 + EOD.
    #expect(Array(try RunLengthDecode.decode(
      Data([1, 0x01, 0x02, UInt8(257 - 3), 0x09, 128]), maxDecodedSize: 1_024
    )) == [0x01, 0x02, 0x09, 0x09, 0x09])
    // EOD만 있는 빈 입력.
    #expect(Array(try RunLengthDecode.decode(Data([128]), maxDecodedSize: 1_024)) == [])
  }

  @Test func runLengthDecodeRejectsTruncatedInput() {
    do {
      _ = try RunLengthDecode.decode(Data([5, 1, 2]), maxDecodedSize: 1_024)
      Issue.record("절단 입력은 truncatedData여야 함")
    } catch {
      #expect(error.code == .truncatedData)
    }
    do {
      _ = try RunLengthDecode.decode(Data(), maxDecodedSize: 1_024)
      Issue.record("EOD 없는 빈 입력은 truncatedData여야 함")
    } catch {
      #expect(error.code == .truncatedData)
    }
  }

  @Test(arguments: [0, 1, 5, 500, 4_096])
  func runLengthRoundTripsRandomData(size: Int) throws {
    var generator = SeededGenerator(seed: UInt64(size) &+ 200)
    let original = randomData(count: size, using: &generator)
    let decoded = try RunLengthDecode.decode(
      PDFFilterEncoders.runLength(original), maxDecodedSize: CoreLimits.maxDecodedStreamBytes
    )
    #expect(decoded == original)
  }

  @Test func runLengthRoundTripsHighlyRepetitiveData() throws {
    let original = Data(repeating: 0x5A, count: 10_000)
    let decoded = try RunLengthDecode.decode(
      PDFFilterEncoders.runLength(original), maxDecodedSize: CoreLimits.maxDecodedStreamBytes
    )
    #expect(decoded == original)
  }
}

/// Flate·필터 파이프라인·픽스처 종단 골든 테스트 (설계 §3.3, §5.4). `FilterTests`와 분리한
/// 이유는 순수 조직적(타입 길이 제한)이며, 같은 설계 절 F-FLATE/F-PIPE/F-E2E를 다룬다.
struct FilterPipelineTests {
  // MARK: F-FLATE

  @Test(arguments: [0, 1, 1_024, 1_048_576])
  func flateRoundTripsVariousSizes(size: Int) throws {
    var generator = SeededGenerator(seed: UInt64(size) &+ 300)
    let original = size == 1_048_576
      ? Data(repeating: 0x7A, count: size)
      : randomData(count: size, using: &generator)
    let decoded = try FlateDecode.decode(
      PDFFilterEncoders.flate(original), maxDecodedSize: CoreLimits.maxDecodedStreamBytes
    )
    #expect(decoded == original)
  }

  @Test func flateDecodeEmptyInputProducesEmptyOutput() throws {
    #expect(try FlateDecode.decode(Data(), maxDecodedSize: 1_024) == Data())
  }

  @Test func flateDecodeFallsBackToRawDeflateWhenHeaderMissing() throws {
    // BFINAL=1, BTYPE=00(stored), LEN=4, NLEN=~LEN, 원문 "TEST" — zlib 헤더가 아니다.
    let rawStoredBlock = Data([0x01, 0x04, 0x00, 0xFB, 0xFF] + Array("TEST".utf8))
    let decoded = try FlateDecode.decode(rawStoredBlock, maxDecodedSize: 1_024)
    #expect(decoded == Data("TEST".utf8))
  }

  @Test func flateDecodeRejectsPresetDictionaryBit() {
    // CMF=0x78, FLG=0x20 — CM=8, 체크섬 정합, FDICT 비트 설정.
    do {
      _ = try FlateDecode.decode(Data([0x78, 0x20, 0x00]), maxDecodedSize: 1_024)
      Issue.record("FDICT 비트는 corruptedData여야 함")
    } catch {
      #expect(error.code == .corruptedData)
    }
  }

  @Test func flateDecodeRejectsTruncatedStream() {
    let original = Data(repeating: 0x11, count: 4_096)
    let encoded = PDFFilterEncoders.flate(original)
    let truncated = encoded.prefix(encoded.count / 2)
    do {
      _ = try FlateDecode.decode(Data(truncated), maxDecodedSize: CoreLimits.maxDecodedStreamBytes)
      Issue.record("절단된 flate 스트림은 실패해야 함")
    } catch {
      #expect(error.code == .truncatedData || error.code == .corruptedData)
    }
  }

  @Test func flateDecodeTruncatesLeadingWhitespaceLeniently() throws {
    let original = Data("hello world".utf8)
    let withLeadingEOL = Data([0x0A, 0x0A]) + PDFFilterEncoders.flate(original)
    let decoded = try FlateDecode.decode(withLeadingEOL, maxDecodedSize: 1_024)
    #expect(decoded == original)
  }

  @Test func flateDecodeEnforcesOutputLimit() {
    let original = Data(repeating: 0x42, count: 10 * 1_024)
    let encoded = PDFFilterEncoders.flate(original)
    do {
      _ = try FlateDecode.decode(encoded, maxDecodedSize: 1_024)
      Issue.record("outputLimitExceeded 기대")
    } catch {
      #expect(error.code == .outputLimitExceeded)
    }
  }

  // MARK: F-PIPE

  @Test func pipelineResolvesSingleNamedFilter() throws {
    let dictionary = COSDictionary([.filter: .name("FlateDecode")])
    let stages = try FilterPipeline.stages(from: dictionary)
    #expect(stages.map(\.kind) == [.flate])
  }

  @Test func pipelineChainMatchesReverseEncodingOrder() throws {
    let body = Data("BT ET".utf8)
    let encoded = PDFFilterEncoders.ascii85(PDFFilterEncoders.flate(body))
    let dictionary = COSDictionary([
      .filter: .array([.name("ASCII85Decode"), .name("FlateDecode")])
    ])
    let stages = try FilterPipeline.stages(from: dictionary)
    #expect(stages.map(\.kind) == [.ascii85, .flate])
    #expect(try FilterPipeline.decode(raw: encoded, dictionary: dictionary) == body)
  }

  @Test(arguments: [
    ("Fl", FilterKind.flate), ("AHx", .asciiHex), ("A85", .ascii85), ("RL", .runLength)
  ])
  func pipelineResolvesAbbreviatedFilterNames(_ pair: (String, FilterKind)) throws {
    let resolved = try #require(FilterKind(name: COSName(pair.0)))
    #expect(resolved == pair.1)
  }

  @Test func pipelineResolvesDecodeParmsVariants() throws {
    let single = COSDictionary([
      .filter: .name("FlateDecode"),
      .decodeParms: .dictionary(COSDictionary([.predictor: .integer(12)]))
    ])
    let singleStages = try FilterPipeline.stages(from: single)
    #expect(singleStages.first?.parameters?.integer(for: .predictor) == 12)

    let arrayed = COSDictionary([
      .filter: .array([.name("ASCII85Decode"), .name("FlateDecode")]),
      .decodeParms: .array([.null, .dictionary(COSDictionary([.predictor: .integer(2)]))])
    ])
    let arrayedStages = try FilterPipeline.stages(from: arrayed)
    #expect(arrayedStages[0].parameters == nil)
    #expect(arrayedStages[1].parameters?.integer(for: .predictor) == 2)
  }

  @Test func pipelineWithoutFilterIsIdentity() throws {
    let raw = Data("raw bytes".utf8)
    #expect(try FilterPipeline.decode(raw: raw, dictionary: COSDictionary()) == raw)
  }

  @Test func pipelineReportsUnsupportedImageFilter() {
    let dictionary = COSDictionary([.filter: .name("DCTDecode")])
    do {
      _ = try FilterPipeline.decode(raw: Data([0x01]), dictionary: dictionary)
      Issue.record("unsupportedFilter 기대")
    } catch {
      guard case .unsupportedFilter = error.code else {
        Issue.record("예상치 못한 에러 코드: \(error.code)")
        return
      }
    }
  }

  @Test func pipelineRejectsIndirectFilterReference() {
    let dictionary = COSDictionary([.filter: .reference(ObjectID(number: 12, generation: 0))])
    do {
      _ = try FilterPipeline.stages(from: dictionary)
      Issue.record("indirectParameter 기대")
    } catch {
      #expect(error.code == .indirectParameter)
    }
  }

  // MARK: F-E2E — 픽스처 종단

  @Test(arguments: [
    PDFFixtureBuilder.ContentStreamSpec.Encoding.flate,
    .asciiHex, .ascii85, .runLength
  ])
  func endToEndDecodesFixtureContentStream(
    encoding: PDFFixtureBuilder.ContentStreamSpec.Encoding
  ) throws {
    let lengthStyles: [PDFFixtureBuilder.ContentStreamSpec.LengthStyle] = [
      .direct, .indirect, .directWrong(delta: 3)
    ]
    let body = Data("BT ET".utf8)
    for lengthStyle in lengthStyles {
      let fixture = PDFFixtureBuilder(
        pageCount: 1,
        contentStream: .init(body: body, encodings: [encoding], lengthStyle: lengthStyle)
      ).build()
      let file = MappedFile(data: fixture.data)
      var parser = COSParser(file: file)
      let offset = try #require(fixture.objectOffsets[4])
      let result = try parser.parseIndirectObject(at: offset)

      guard case let .stream(stream) = result.object, case let .fileRange(range) = stream.payload
      else {
        Issue.record("스트림 객체가 아님")
        continue
      }
      let raw = try #require(file.bytes(in: range))
      let decoded = try FilterPipeline.decode(raw: raw, dictionary: stream.dictionary)
      #expect(decoded == body)
    }
  }
}

// MARK: - 테스트 케이스 타입 · 헬퍼

/// ASCIIHex 골든 케이스.
struct HexGoldenCase: Sendable, CustomTestStringConvertible {
  let input: String
  let expected: [UInt8]
  let label: String
  var testDescription: String { self.label }
}

/// 시드 PRNG로 결정적 랜덤 바이트를 생성한다 (`FilterTests`·`FilterPipelineTests` 공용).
func randomData(count: Int, using generator: inout SeededGenerator) -> Data {
  var bytes = [UInt8](repeating: 0, count: count)
  for index in bytes.indices {
    bytes[index] = UInt8.random(in: 0...255, using: &generator)
  }
  return Data(bytes)
}
