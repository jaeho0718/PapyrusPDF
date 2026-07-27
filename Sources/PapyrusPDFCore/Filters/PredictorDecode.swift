import Foundation

/// PNG(10–15)·TIFF(2) predictor 역적용. Flate(M4부턴 LZW도) 출력 후처리 전용.
package enum PredictorDecode {
  /// predictor 파라미터 묶음.
  package struct Configuration: Sendable, Equatable {
    /// Predictor 값 (2 또는 10...15).
    package let predictor: Int

    /// 픽셀당 색상 성분 수. 기본 1.
    package let colors: Int

    /// 성분당 비트 수. 기본 8.
    package let bitsPerComponent: Int

    /// 행당 픽셀(샘플) 수. 기본 1.
    package let columns: Int

    /// `/DecodeParms` 딕셔너리에서 기본값을 채워 생성한다.
    /// - Parameter parameters: `/DecodeParms` (또는 `/DP`) 딕셔너리.
    /// - Returns: `Predictor <= 1`(적용 불요)이면 `nil`.
    package init?(parameters: COSDictionary?) {
      let predictor = parameters?.integer(for: .predictor) ?? 1
      guard predictor > 1 else {
        return nil
      }
      self.predictor = predictor
      self.colors = parameters?.integer(for: .colors) ?? 1
      self.bitsPerComponent = parameters?.integer(for: .bitsPerComponent) ?? 8
      self.columns = parameters?.integer(for: .columns) ?? 1
    }
  }

  /// predictor를 역적용해 원본 샘플 바이트를 복원한다.
  /// - Parameters:
  ///   - data: predictor가 적용된 상태의 바이트(Flate 등 압축 해제 직후).
  ///   - configuration: predictor 파라미터.
  /// - Throws: 미지 predictor 값이면 ``FilterError/Code/unsupportedPredictor(_:)``,
  ///   행 레이아웃이 성립하지 않으면 `invalidPredictorLayout`,
  ///   PNG 태그가 0–4 밖이면 `corruptedData`.
  package static func apply(
    to data: Data, configuration: Configuration
  ) throws(FilterError) -> Data {
    switch configuration.predictor {
    case 2:
      return try Self.applyTIFF(to: data, configuration: configuration)
    case 10...15:
      return try Self.applyPNG(to: data, configuration: configuration)
    default:
      throw FilterError(code: .unsupportedPredictor(configuration.predictor))
    }
  }

  /// `ceil(colors × bitsPerComponent × columns / 8)`.
  ///
  /// `/DecodeParms`의 `/Colors`·`/BitsPerComponent`·`/Columns`는 신뢰할 수 없는 외부 입력이라
  /// 거대한 값(예: `10^11`)이 실릴 수 있다 — overflow-checked 산술로 계산하고, 오버플로하면
  /// `nil`을 반환해 호출부가 `invalidPredictorLayout`으로 안전하게 실패하도록 한다.
  private static func rowByteCount(_ configuration: Configuration) -> Int? {
    let (colorsTimesBits, overflow1) = configuration.colors.multipliedReportingOverflow(
      by: configuration.bitsPerComponent
    )
    guard !overflow1 else {
      return nil
    }
    let (bitsPerRow, overflow2) = colorsTimesBits.multipliedReportingOverflow(
      by: configuration.columns
    )
    guard !overflow2 else {
      return nil
    }
    let (padded, overflow3) = bitsPerRow.addingReportingOverflow(7)
    guard !overflow3 else {
      return nil
    }
    return padded / 8
  }

  /// `max(1, colors × bitsPerComponent / 8)`. 오버플로하면(``rowByteCount(_:)``가 이미
  /// `nil`로 걸러내는 것과 동일한 입력 범위) 어떤 컬럼 인덱스도 넘지 못할 상한값을 반환해
  /// Sub/Average/Paeth의 "왼쪽" 참조가 항상 안전하게 0으로 취급되게 한다.
  private static func bytesPerPixel(_ configuration: Configuration) -> Int {
    let (colorsTimesBits, overflow) = configuration.colors.multipliedReportingOverflow(
      by: configuration.bitsPerComponent
    )
    guard !overflow else {
      return Int.max
    }
    return max(1, colorsTimesBits / 8)
  }
}

// MARK: - TIFF predictor (2)

extension PredictorDecode {
  /// 행마다 수평 차분을 복원한다. bpc 8은 바이트 단위, bpc 16은 빅엔디언 워드 단위.
  /// bpc 1/2/4는 서브바이트 레이아웃이라 지원하지 않는다.
  private static func applyTIFF(
    to data: Data, configuration: Configuration
  ) throws(FilterError) -> Data {
    guard configuration.colors > 0, configuration.columns > 0 else {
      throw FilterError(code: .invalidPredictorLayout)
    }
    guard configuration.bitsPerComponent == 8 || configuration.bitsPerComponent == 16 else {
      throw FilterError(code: .invalidPredictorLayout)
    }
    guard let rowBytes = Self.rowByteCount(configuration),
      rowBytes > 0, data.count % rowBytes == 0, configuration.colors <= rowBytes
    else {
      throw FilterError(code: .invalidPredictorLayout)
    }

    var bytes = Array(data)
    if configuration.bitsPerComponent == 8 {
      Self.undoTIFF8(&bytes, rowBytes: rowBytes, colors: configuration.colors)
    } else {
      Self.undoTIFF16(&bytes, rowBytes: rowBytes, colors: configuration.colors)
    }
    return Data(bytes)
  }

  private static func undoTIFF8(_ bytes: inout [UInt8], rowBytes: Int, colors: Int) {
    var rowStart = 0
    while rowStart < bytes.count {
      for index in (rowStart + colors)..<(rowStart + rowBytes) {
        bytes[index] = bytes[index] &+ bytes[index - colors]
      }
      rowStart += rowBytes
    }
  }

  private static func undoTIFF16(_ bytes: inout [UInt8], rowBytes: Int, colors: Int) {
    var rowStart = 0
    while rowStart < bytes.count {
      var wordIndex = colors
      while wordIndex * 2 < rowBytes {
        let hi = rowStart + wordIndex * 2
        let lo = hi + 1
        let prevHi = rowStart + (wordIndex - colors) * 2
        let prevLo = prevHi + 1
        let current = UInt16(bytes[hi]) << 8 | UInt16(bytes[lo])
        let previous = UInt16(bytes[prevHi]) << 8 | UInt16(bytes[prevLo])
        let sum = current &+ previous
        bytes[hi] = UInt8(sum >> 8)
        bytes[lo] = UInt8(sum & 0xFF)
        wordIndex += 1
      }
      rowStart += rowBytes
    }
  }
}

// MARK: - PNG predictor (10...15)

extension PredictorDecode {
  /// PNG 행 역필터링에 필요한 불변 문맥 (행마다 반복 전달하는 값 묶음 — 매개변수 수 축소용).
  private struct PNGRowContext {
    /// 전체 predictor 입력 바이트 (모든 행 공통).
    let bytes: [UInt8]
    /// 태그 바이트를 제외한 한 행의 샘플 바이트 수.
    let rowBytes: Int
    /// 픽셀당 바이트 수 (Sub/Average/Paeth의 "왼쪽" 참조 간격).
    let bpp: Int
  }

  /// 행 = 태그 1바이트 + rowBytes. 태그 0–4(None/Sub/Up/Average/Paeth)를 역적용한다.
  private static func applyPNG(
    to data: Data, configuration: Configuration
  ) throws(FilterError) -> Data {
    guard
      configuration.colors > 0, configuration.columns > 0, configuration.bitsPerComponent > 0
    else {
      throw FilterError(code: .invalidPredictorLayout)
    }
    guard let rowBytes = Self.rowByteCount(configuration), rowBytes > 0 else {
      throw FilterError(code: .invalidPredictorLayout)
    }
    let strideLength = rowBytes + 1
    guard data.count % strideLength == 0 else {
      throw FilterError(code: .invalidPredictorLayout)
    }

    let context = PNGRowContext(
      bytes: Array(data), rowBytes: rowBytes, bpp: Self.bytesPerPixel(configuration)
    )
    let rowCount = data.count / strideLength

    var out = [UInt8](repeating: 0, count: rowCount * rowBytes)
    var previousRow = [UInt8](repeating: 0, count: rowBytes)

    for row in 0..<rowCount {
      let rowStart = row * strideLength
      let tag = context.bytes[rowStart]
      guard tag <= 4 else {
        throw FilterError(code: .corruptedData)
      }
      let current = Self.unfilterPNGRow(
        context, rowStart: rowStart, tag: tag, previousRow: previousRow
      )
      for column in 0..<rowBytes {
        out[row * rowBytes + column] = current[column]
      }
      previousRow = current
    }
    return Data(out)
  }

  private static func unfilterPNGRow(
    _ context: PNGRowContext, rowStart: Int, tag: UInt8, previousRow: [UInt8]
  ) -> [UInt8] {
    var current = [UInt8](repeating: 0, count: context.rowBytes)
    for column in 0..<context.rowBytes {
      let raw = context.bytes[rowStart + 1 + column]
      let left = column >= context.bpp ? current[column - context.bpp] : 0
      let up = previousRow[column]
      let upperLeft = column >= context.bpp ? previousRow[column - context.bpp] : 0
      current[column] = Self.unfilterByte(
        raw: raw, tag: tag, left: left, above: up, upperLeft: upperLeft
      )
    }
    return current
  }

  private static func unfilterByte(
    raw: UInt8, tag: UInt8, left: UInt8, above: UInt8, upperLeft: UInt8
  ) -> UInt8 {
    switch tag {
    case 0:
      return raw
    case 1:
      return raw &+ left
    case 2:
      return raw &+ above
    case 3:
      return raw &+ UInt8((Int(left) + Int(above)) / 2)
    default:
      return raw &+ Self.paeth(left: left, above: above, upperLeft: upperLeft)
    }
  }

  /// PNG 스펙 표준 Paeth 예측자.
  private static func paeth(left: UInt8, above: UInt8, upperLeft: UInt8) -> UInt8 {
    let estimate = Int(left) + Int(above) - Int(upperLeft)
    let distanceToLeft = abs(estimate - Int(left))
    let distanceToAbove = abs(estimate - Int(above))
    let distanceToUpperLeft = abs(estimate - Int(upperLeft))
    if distanceToLeft <= distanceToAbove, distanceToLeft <= distanceToUpperLeft {
      return left
    }
    if distanceToAbove <= distanceToUpperLeft {
      return above
    }
    return upperLeft
  }
}
