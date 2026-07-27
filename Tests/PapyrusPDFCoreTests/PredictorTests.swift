import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// PNG(10–15)·TIFF(2) predictor 역적용 검증 (설계 §3.3, §5.4 F-PRED).
struct PredictorTests {
  // MARK: PNG predictor — 태그별 라운드트립

  /// 작은 2행×4열(colors=1) 행렬에서 태그 0–4 각각을 순방향 필터링한 뒤 역적용해
  /// 원본을 복원한다.
  @Test(arguments: [UInt8(0), 1, 2, 3, 4])
  func pngPredictorRoundTripsForEachTagColors1(tag: UInt8) throws {
    let raw = Data([10, 20, 30, 40, 15, 25, 35, 45])
    let encoded = PDFFilterEncoders.pngPredictor(
      raw, filterType: tag, colors: 1, bitsPerComponent: 8, columns: 4
    )
    let configuration = try #require(Self.configuration(predictor: 12, colors: 1, columns: 4))
    #expect(try PredictorDecode.apply(to: encoded, configuration: configuration) == raw)
  }

  /// 작은 2행×2픽셀(colors=3) 행렬에서 태그 0–4 각각을 검증한다.
  @Test(arguments: [UInt8(0), 1, 2, 3, 4])
  func pngPredictorRoundTripsForEachTagColors3(tag: UInt8) throws {
    let raw = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
    let encoded = PDFFilterEncoders.pngPredictor(
      raw, filterType: tag, colors: 3, bitsPerComponent: 8, columns: 2
    )
    let configuration = try #require(Self.configuration(predictor: 15, colors: 3, columns: 2))
    #expect(try PredictorDecode.apply(to: encoded, configuration: configuration) == raw)
  }

  /// 수계산 골든 벡터: 태그 0(None)은 태그 바이트만 붙이고 데이터는 그대로다.
  @Test func pngNoneFilterGoldenVector() throws {
    let raw = Data([1, 2, 3, 4])
    let encoded = Data([0, 1, 2, 3, 4])
    let configuration = try #require(Self.configuration(predictor: 10, colors: 1, columns: 4))
    #expect(try PredictorDecode.apply(to: encoded, configuration: configuration) == raw)
  }

  @Test func pngPredictorRejectsUnknownTag() throws {
    let configuration = try #require(Self.configuration(predictor: 10, colors: 1, columns: 4))
    do {
      _ = try PredictorDecode.apply(to: Data([5, 1, 2, 3, 4]), configuration: configuration)
      Issue.record("태그 5는 corruptedData여야 함")
    } catch {
      #expect(error.code == .corruptedData)
    }
  }

  @Test func pngPredictorRejectsRowBoundaryMismatch() throws {
    let configuration = try #require(Self.configuration(predictor: 10, colors: 1, columns: 4))
    do {
      // rowBytes=4 → stride=5, 4바이트 입력은 배수가 아니다.
      _ = try PredictorDecode.apply(to: Data([0, 1, 2, 3]), configuration: configuration)
      Issue.record("행 경계 불일치는 invalidPredictorLayout이어야 함")
    } catch {
      #expect(error.code == .invalidPredictorLayout)
    }
  }

  /// B2 회귀: `/Colors`·`/BitsPerComponent`·`/Columns`가 거대해도(곱셈 오버플로 유발 값)
  /// `rowByteCount`의 곱셈 트랩 크래시 없이 `invalidPredictorLayout`으로 실패한다.
  @Test func pngPredictorRejectsOverflowingDimensions() throws {
    let configuration = try #require(PredictorDecode.Configuration(
      parameters: COSDictionary([
        .predictor: .integer(12),
        .colors: .integer(100_000_000_000),
        .bitsPerComponent: .integer(100_000_000_000),
        .columns: .integer(100_000_000_000)
      ])
    ))
    do {
      _ = try PredictorDecode.apply(to: Data([0, 0, 0, 0]), configuration: configuration)
      Issue.record("치수 오버플로는 invalidPredictorLayout이어야 함")
    } catch {
      #expect(error.code == .invalidPredictorLayout)
    }
  }

  /// B2 회귀(TIFF 경로): 동일한 오버플로 치수가 `applyTIFF`에서도 크래시하지 않는다.
  @Test func tiffPredictorRejectsOverflowingDimensions() throws {
    let configuration = try #require(PredictorDecode.Configuration(
      parameters: COSDictionary([
        .predictor: .integer(2),
        .colors: .integer(Int.max),
        .bitsPerComponent: .integer(Int.max),
        .columns: .integer(Int.max)
      ])
    ))
    do {
      _ = try PredictorDecode.apply(to: Data([0, 0, 0, 0]), configuration: configuration)
      Issue.record("치수 오버플로는 invalidPredictorLayout이어야 함")
    } catch {
      #expect(error.code == .invalidPredictorLayout)
    }
  }

  // MARK: TIFF predictor

  /// 수계산 골든: colors=1/bpc=8/columns=4, raw=[10,20,30,40] → 수평 차분 [10,10,10,10].
  @Test func tiffPredictorBpc8GoldenVector() throws {
    let configuration = try #require(Self.configuration(predictor: 2, colors: 1, columns: 4))
    let decoded = try PredictorDecode.apply(
      to: Data([10, 10, 10, 10]), configuration: configuration
    )
    #expect(Array(decoded) == [10, 20, 30, 40])
  }

  /// 수계산 골든: colors=1/bpc=16/columns=2. word0은 그대로, word1은 word0과의 차분.
  @Test func tiffPredictorBpc16GoldenVector() throws {
    let configuration = try #require(
      Self.configuration(predictor: 2, colors: 1, bitsPerComponent: 16, columns: 2)
    )
    let decoded = try PredictorDecode.apply(
      to: Data([0x01, 0x00, 0x02, 0x00]), configuration: configuration
    )
    #expect(Array(decoded) == [0x01, 0x00, 0x03, 0x00])
  }

  @Test func tiffPredictorRejectsSubByteBitsPerComponent() throws {
    let configuration = try #require(
      Self.configuration(predictor: 2, colors: 1, bitsPerComponent: 4, columns: 4)
    )
    do {
      _ = try PredictorDecode.apply(to: Data([0x12, 0x34]), configuration: configuration)
      Issue.record("bpc 4는 invalidPredictorLayout이어야 함")
    } catch {
      #expect(error.code == .invalidPredictorLayout)
    }
  }

  // MARK: Predictor 1 항등 · xref 스트림 실전형

  @Test func predictorOneIsIdentity() {
    #expect(Self.configuration(predictor: 1, colors: 1, columns: 1) == nil)
  }

  /// Predictor 12/Columns 5/Colors 1 — M2 xref 스트림이 실제로 만나는 조합.
  @Test func xrefStreamStylePredictorRoundTrips() throws {
    let raw = Data([
      0, 1, 0, 100, 0,
      0, 1, 0, 101, 0,
      0, 1, 0, 102, 0
    ])
    let encoded = PDFFilterEncoders.pngPredictor(
      raw, filterType: 2, colors: 1, bitsPerComponent: 8, columns: 5
    )
    let configuration = try #require(Self.configuration(predictor: 12, colors: 1, columns: 5))
    #expect(try PredictorDecode.apply(to: encoded, configuration: configuration) == raw)
  }
}

extension PredictorTests {
  /// `/DecodeParms` 딕셔너리를 조립해 ``PredictorDecode/Configuration`` 을 만든다
  /// (테스트 전용 축약 헬퍼 — 줄 길이를 줄이기 위한 반복 제거).
  fileprivate static func configuration(
    predictor: Int, colors: Int, bitsPerComponent: Int = 8, columns: Int
  ) -> PredictorDecode.Configuration? {
    PredictorDecode.Configuration(parameters: COSDictionary([
      .predictor: .integer(predictor),
      .colors: .integer(colors),
      .bitsPerComponent: .integer(bitsPerComponent),
      .columns: .integer(columns)
    ]))
  }
}
