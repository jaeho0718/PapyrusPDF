import Foundation

/// v1에서 디코딩을 지원하는 스트림 필터. LZW는 M4에서 케이스 추가.
package enum FilterKind: Sendable, Equatable {
  /// `/FlateDecode`, `/Fl`.
  case flate

  /// `/ASCIIHexDecode`, `/AHx`.
  case asciiHex

  /// `/ASCII85Decode`, `/A85`.
  case ascii85

  /// `/RunLengthDecode`, `/RL`.
  case runLength

  /// 표준명·축약명으로부터 매핑한다. 미지원/이미지 필터는 `nil`.
  /// - Parameter name: `/Filter` 배열·값에 등장하는 필터 이름.
  package init?(name: COSName) {
    switch name.rawValue {
    case "FlateDecode", "Fl":
      self = .flate
    case "ASCIIHexDecode", "AHx":
      self = .asciiHex
    case "ASCII85Decode", "A85":
      self = .ascii85
    case "RunLengthDecode", "RL":
      self = .runLength
    default:
      return nil
    }
  }

  /// 필터 1개를 디코딩한다. flate는 파라미터의 `/Predictor`까지 내부 적용한다.
  /// - Parameters:
  ///   - data: 인코딩된 바이트.
  ///   - parameters: 이 필터 단계의 `/DecodeParms`.
  ///   - maxDecodedSize: 방출 바이트 상한 (압축 폭탄 가드).
  /// - Throws: 디코딩 실패 시 ``FilterError``.
  package func decode(
    _ data: Data, parameters: COSDictionary?, maxDecodedSize: Int
  ) throws(FilterError) -> Data {
    switch self {
    case .flate:
      let decoded = try FlateDecode.decode(data, maxDecodedSize: maxDecodedSize)
      guard let configuration = PredictorDecode.Configuration(parameters: parameters) else {
        return decoded
      }
      return try PredictorDecode.apply(to: decoded, configuration: configuration)
    case .asciiHex:
      return try ASCIIHexDecode.decode(data)
    case .ascii85:
      return try ASCII85Decode.decode(data)
    case .runLength:
      return try RunLengthDecode.decode(data, maxDecodedSize: maxDecodedSize)
    }
  }
}
