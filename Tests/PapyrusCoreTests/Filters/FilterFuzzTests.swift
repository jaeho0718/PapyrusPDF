import Foundation
@testable import PapyrusCore
import PapyrusTestSupport
import Testing

/// 필터 디코더 마이크로 퍼즈 — 문서 문맥 없이 디코더 단독에 임의/오염 바이트를 넣어
/// 크래시·무한 루프 없음을 검증한다 (설계 §3.6, 테스트 포인트 9).
///
/// 판정 기준: 정상 반환 또는 `FilterError` throw는 전부 합격이다 — typed throws가 그 외
/// 이탈을 컴파일 타임에 봉쇄하므로, 여기서 실질적으로 검증하는 건 "크래시 없음"이다
/// (크래시는 프로세스 사망으로 별도 검출됨, 설계 가정 2). CI 상시(결정적, <5초) 티어라
/// 별도 타임아웃 가드는 두지 않는다 — 디코더 자체가 이미 입력 비례 상한을 갖는다.
@Suite("필터 퍼즈", .timeLimit(.minutes(2)))
struct FilterFuzzTests {
  /// 시도할 임의 바이트 길이.
  private static let lengths = [0, 1, 15, 64, 1_024, 64 * 1_024]

  /// 방출 상한 (압축 폭탄 가드용 매개변수 — 디코더 시그니처가 요구하는 값).
  private static let maxDecodedSize = 8 << 20

  // MARK: 임의 바이트 × 디코더 6종

  @Test(arguments: FilterFuzzTests.lengths)
  func flateSurvivesRandomBytes(length: Int) {
    let data = Self.randomBytes(length: length, seed: 1)
    _ = try? FlateDecode.decode(data, maxDecodedSize: Self.maxDecodedSize)
  }

  @Test(arguments: FilterFuzzTests.lengths, [true, false])
  func lzwSurvivesRandomBytes(length: Int, earlyChange: Bool) {
    let data = Self.randomBytes(length: length, seed: 2)
    _ = try? LZWDecode.decode(data, earlyChange: earlyChange, maxDecodedSize: Self.maxDecodedSize)
  }

  @Test(arguments: FilterFuzzTests.lengths)
  func asciiHexSurvivesRandomBytes(length: Int) {
    let data = Self.randomBytes(length: length, seed: 3)
    _ = try? ASCIIHexDecode.decode(data)
  }

  @Test(arguments: FilterFuzzTests.lengths)
  func ascii85SurvivesRandomBytes(length: Int) {
    let data = Self.randomBytes(length: length, seed: 4)
    _ = try? ASCII85Decode.decode(data)
  }

  @Test(arguments: FilterFuzzTests.lengths)
  func runLengthSurvivesRandomBytes(length: Int) {
    let data = Self.randomBytes(length: length, seed: 5)
    _ = try? RunLengthDecode.decode(data, maxDecodedSize: Self.maxDecodedSize)
  }

  // MARK: Predictor — columns/colors/bpc 경계값 {0, 1, 255, 극대값}

  /// 경계값 조합 64개(4³) 전부가 `invalidPredictorLayout`(또는 정상 반환)으로 안전하게
  /// 실패하는지 확인한다 — 유효성 검사가 오버플로·병적 레이아웃을 막는지가 관심사다.
  @Test func predictorSurvivesBoundaryParameters() {
    let boundaryValues = [0, 1, 255, 2_000_000_000]
    let data = Self.randomBytes(length: 256, seed: 6)
    for columns in boundaryValues {
      for colors in boundaryValues {
        for bitsPerComponent in boundaryValues {
          let parameters = COSDictionary([
            .predictor: .integer(12), .columns: .integer(columns), .colors: .integer(colors),
            .bitsPerComponent: .integer(bitsPerComponent)
          ])
          guard let configuration = PredictorDecode.Configuration(parameters: parameters) else {
            continue
          }
          _ = try? PredictorDecode.apply(to: data, configuration: configuration)
        }
      }
    }
  }

  // MARK: 유효 인코딩 산출물의 꼬리 절단·1바이트 오염

  /// 기존 `PDFFilterEncoders`로 만든 유효 산출물을 절단(0/절반/1바이트 부족)하거나
  /// 1바이트 오염시켜 각 디코더에 넣는다.
  @Test func encodedOutputsSurviveTailTruncationAndByteCorruption() {
    let payload = Self.randomBytes(length: 512, seed: 7)
    let variants: [(name: String, data: Data)] = [
      ("flate", PDFFilterEncoders.flate(payload)),
      ("lzw", PDFFilterEncoders.lzw(payload)),
      ("asciiHex", PDFFilterEncoders.asciiHex(payload)),
      ("ascii85", PDFFilterEncoders.ascii85(payload)),
      ("runLength", PDFFilterEncoders.runLength(payload))
    ]
    var rng = SplitMix64(seed: 8)
    for variant in variants {
      for truncatedLength in [0, variant.data.count / 2, max(0, variant.data.count - 1)] {
        Self.decodeVariant(variant.name, variant.data.prefix(truncatedLength))
      }
      Self.decodeVariant(variant.name, Self.corruptedByOneByte(variant.data, rng: &rng))
    }
  }

  /// `data`의 임의 1바이트를 XOR 0xFF로 오염시킨 새 복사본 (빈 데이터는 그대로).
  private static func corruptedByOneByte(_ data: Data, rng: inout SplitMix64) -> Data {
    guard !data.isEmpty else {
      return data
    }
    var bytes = [UInt8](data)
    let index = Int.random(in: 0..<bytes.count, using: &rng)
    bytes[index] ^= 0xFF
    return Data(bytes)
  }

  /// 필터 이름으로 해당 디코더를 호출한다 (결과는 버림 — 크래시 없음만이 관심사).
  private static func decodeVariant(_ name: String, _ data: Data) {
    switch name {
    case "flate":
      _ = try? FlateDecode.decode(data, maxDecodedSize: Self.maxDecodedSize)
    case "lzw":
      _ = try? LZWDecode.decode(data, earlyChange: true, maxDecodedSize: Self.maxDecodedSize)
    case "asciiHex":
      _ = try? ASCIIHexDecode.decode(data)
    case "ascii85":
      _ = try? ASCII85Decode.decode(data)
    case "runLength":
      _ = try? RunLengthDecode.decode(data, maxDecodedSize: Self.maxDecodedSize)
    default:
      break
    }
  }

  /// `SplitMix64` 고정 시드로 임의 바이트를 채운다 (결정적 — CI 플레이키 없음).
  private static func randomBytes(length: Int, seed: UInt64) -> Data {
    var rng = SplitMix64(seed: seed)
    var bytes = [UInt8](repeating: 0, count: length)
    for index in 0..<length {
      bytes[index] = UInt8(truncatingIfNeeded: rng.next())
    }
    return Data(bytes)
  }
}
