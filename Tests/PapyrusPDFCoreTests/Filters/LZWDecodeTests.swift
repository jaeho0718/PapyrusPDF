import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// ``LZWDecode``의 골든 벡터·라운드트립·관용 처리를 검증한다 (설계 §5.1 LZ1-LZ10).
struct LZWDecodeTests {
  // MARK: LZ1 — 스펙 예제 골든

  /// LZ1: `-----AAA-BBB` 유형의 11바이트(45×5, 65×3, 66×3) — 표준 LZW 알고리즘을 손으로
  /// 추적해 검증한 정확한 인코딩 바이트(폭 9 고정, clear 선행 + EOD 종결)와의 골든 대조.
  @Test func specExampleGoldenVectorDecodesExactly() throws {
    let plaintext: [UInt8] = [45, 45, 45, 45, 45, 65, 65, 65, 66, 66, 66]
    let encoded = Data([0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x14, 0x85, 0x07, 0x80, 0x80])
    let decoded = try LZWDecode.decode(encoded, earlyChange: true, maxDecodedSize: 1_024)
    #expect(Array(decoded) == plaintext)
  }

  // MARK: LZ2 — 인코더 라운드트립

  @Test(arguments: [0, 1, 2, 5, 50, 500, 2_000], [true, false])
  func encoderRoundTripsRandomData(size: Int, earlyChange: Bool) throws {
    var generator = SeededGenerator(seed: UInt64(size) &+ (earlyChange ? 7 : 13))
    let original = randomData(count: size, using: &generator)
    let encoded = PDFFilterEncoders.lzw(original, earlyChange: earlyChange)
    let decoded = try LZWDecode.decode(
      encoded, earlyChange: earlyChange, maxDecodedSize: 1 << 20
    )
    #expect(decoded == original)
  }

  // MARK: LZ3 — /EarlyChange 0 vs 1, 폭 전환 경계

  /// LZ3: 코드가 258→511/512 부근까지 성장하는 데이터로 두 `earlyChange` 모드 각각의
  /// 폭 전환 경계 처리가 정확한지 확인한다 (인코더·디코더 모두 같은 플래그로 맞물려야 함).
  @Test(arguments: [true, false])
  func earlyChangeBoundaryRoundTrips(earlyChange: Bool) throws {
    // 256값을 3회 반복 나열해 268개 서로 다른 2-byte 조합을 유발, next가 258을 넘어
    // 511/512 부근까지 여러 차례 성장한다.
    var original = [UInt8]()
    for _ in 0..<3 {
      original.append(contentsOf: 0...255)
    }
    let data = Data(original)
    let encoded = PDFFilterEncoders.lzw(data, earlyChange: earlyChange)
    let decoded = try LZWDecode.decode(encoded, earlyChange: earlyChange, maxDecodedSize: 1 << 20)
    #expect(Array(decoded) == original)
  }

  /// LZ3 부가: 한 모드로 인코딩한 스트림을 반대 모드로 디코딩하면(폭 전환 시점 불일치)
  /// 정상적으로 원문과 일치하지 않거나 구조 오류로 실패한다 — 플래그가 실제로 의미
  /// 있음을 방증한다.
  @Test func earlyChangeMismatchDoesNotSilentlyRoundTrip() {
    var original = [UInt8]()
    for _ in 0..<3 {
      original.append(contentsOf: 0...255)
    }
    let data = Data(original)
    let encoded = PDFFilterEncoders.lzw(data, earlyChange: true)
    let decoded = try? LZWDecode.decode(encoded, earlyChange: false, maxDecodedSize: 1 << 20)
    #expect((decoded.map(Array.init) ?? []) != original)
  }

  // MARK: LZ4 — 테이블 포화(4096) 후 clear 없는 스트림

  @Test func tableSaturationContinuesDecodingWithoutError() throws {
    var generator = SeededGenerator(seed: 424_242)
    // 4096 - 258 = 3838개보다 훨씬 많은 신규 부분열이 발생하도록 충분히 큰 무작위 데이터.
    let original = randomData(count: 40_000, using: &generator)
    let encoded = PDFFilterEncoders.lzw(original, earlyChange: true)
    let decoded = try LZWDecode.decode(encoded, earlyChange: true, maxDecodedSize: 4 << 20)
    #expect(decoded == original)
  }

  // MARK: LZ5 — 미등록 코드 참조

  @Test func unregisteredCodeReferenceThrowsCorruptedData() {
    // 코드 300 (>next=258) 단독 — 첫 코드부터 미등록 참조.
    let encoded = Self.pack9([300])
    do {
      _ = try LZWDecode.decode(encoded, earlyChange: true, maxDecodedSize: 1_024)
      Issue.record("corruptedData 기대")
    } catch {
      #expect(error.code == .corruptedData)
    }
  }

  // MARK: LZ6 — EOD 생략 + 꼬리 잔여 비트

  @Test func omittedEODWithTrailingBitsDecodesLeniently() throws {
    let encoded = Self.pack9([69])
    let decoded = try LZWDecode.decode(encoded, earlyChange: true, maxDecodedSize: 1_024)
    #expect(Array(decoded) == [69])
  }

  // MARK: LZ7 — 압축 폭탄

  @Test func compressionBombExceedsOutputLimit() {
    var generator = SeededGenerator(seed: 99)
    _ = generator.next() // 시드 워밍업(사용하지 않음 — 결정적 반복 데이터가 목적).
    let original = Data(repeating: 0x41, count: 20_000)
    let encoded = PDFFilterEncoders.lzw(original, earlyChange: true)
    do {
      _ = try LZWDecode.decode(encoded, earlyChange: true, maxDecodedSize: 100)
      Issue.record("outputLimitExceeded 기대")
    } catch {
      #expect(error.code == .outputLimitExceeded)
    }
  }

  // MARK: LZ8 — KwKwK 케이스

  /// LZ8: `AAAA`(4바이트) — 두 번째 `A`쌍이 아직 등록되지 않은 `next` 코드를 즉시
  /// 재참조하는 KwKwK 케이스를 유발한다.
  @Test func kwkwkCaseDecodesExactly() throws {
    let plaintext: [UInt8] = [65, 65, 65, 65]
    let encoded = Data([0x80, 0x10, 0x60, 0x44, 0x18, 0x08])
    let decoded = try LZWDecode.decode(encoded, earlyChange: true, maxDecodedSize: 1_024)
    #expect(Array(decoded) == plaintext)
  }

  // MARK: LZ9 — LZW + PNG Predictor 조합

  @Test func lzwCombinedWithPNGPredictorRoundTrips() throws {
    let raw = Data([10, 20, 30, 40, 15, 25, 35, 45, 5, 15, 25, 35])
    let predicted = PDFFilterEncoders.pngPredictor(
      raw, filterType: 2, colors: 1, bitsPerComponent: 8, columns: 4
    )
    let encoded = PDFFilterEncoders.lzw(predicted, earlyChange: true)
    let parameters = COSDictionary([
      .predictor: .integer(12), .colors: .integer(1), .bitsPerComponent: .integer(8),
      .columns: .integer(4)
    ])
    let decoded = try FilterKind.lzw.decode(encoded, parameters: parameters, maxDecodedSize: 1_024)
    #expect(decoded == raw)
  }

  // MARK: LZ10 — FilterPipeline 이름·체인

  @Test func pipelineResolvesLZWName() throws {
    let dictionary = COSDictionary([.filter: .name("LZWDecode")])
    let stages = try FilterPipeline.stages(from: dictionary)
    #expect(stages.map(\.kind) == [.lzw])
  }

  @Test func pipelineChainAscii85ThenLZWRoundTrips() throws {
    let body = Data("BT /F1 12 Tf (Hello) Tj ET".utf8)
    let encoded = PDFFilterEncoders.ascii85(PDFFilterEncoders.lzw(body))
    let dictionary = COSDictionary([
      .filter: .array([.name("ASCII85Decode"), .name("LZWDecode")])
    ])
    let stages = try FilterPipeline.stages(from: dictionary)
    #expect(stages.map(\.kind) == [.ascii85, .lzw])
    #expect(try FilterPipeline.decode(raw: encoded, dictionary: dictionary) == body)
  }

  @Test func pipelineResolvesAbbreviatedLZWName() throws {
    let resolved = try #require(FilterKind(name: COSName("LZW")))
    #expect(resolved == .lzw)
  }
}

// MARK: - 테스트 헬퍼

extension LZWDecodeTests {
  /// 정수 코드 배열을 폭 9비트 고정으로 MSB-first 패킹한다 (병적 입력 수제 조립용).
  static func pack9(_ codes: [Int]) -> Data {
    var bitBuffer: UInt32 = 0
    var bitCount = 0
    var out: [UInt8] = []
    for code in codes {
      bitBuffer = (bitBuffer << 9) | UInt32(code)
      bitCount += 9
      while bitCount >= 8 {
        let shift = bitCount - 8
        out.append(UInt8((bitBuffer >> UInt32(shift)) & 0xFF))
        bitCount -= 8
        bitBuffer &= bitCount == 0 ? 0 : (1 << UInt32(bitCount)) - 1
      }
    }
    if bitCount > 0 {
      out.append(UInt8((bitBuffer << UInt32(8 - bitCount)) & 0xFF))
    }
    return Data(out)
  }
}
