/// PDF name 객체 (`/Type` 등). `#xx` 이스케이프는 렉싱 시점에 해소된 상태로 저장.
package struct COSName: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
  /// 슬래시·이스케이프 해소 후의 이름 문자열 (UTF-8 해석).
  package let rawValue: String

  /// 이름 문자열로부터 생성한다.
  /// - Parameter rawValue: 슬래시 없이, 이스케이프가 이미 해소된 이름.
  package init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  /// 문자열 리터럴로부터 생성한다 (`let name: COSName = "Type"`).
  /// - Parameter value: 이름 문자열.
  package init(stringLiteral value: String) {
    self.rawValue = value
  }

  /// 슬래시를 붙인 표시용 문자열.
  package var description: String {
    "/\(self.rawValue)"
  }
}

/// M1에서 필요한 표준 이름 상수. 마일스톤마다 필요분만 추가한다.
extension COSName {
  /// `/Type`.
  package static let type: COSName = "Type"

  /// `/Length`.
  package static let length: COSName = "Length"

  /// `/Filter`.
  package static let filter: COSName = "Filter"

  /// `/DecodeParms`.
  package static let decodeParms: COSName = "DecodeParms"

  /// `/DP` (`/DecodeParms`의 축약형).
  package static let dp: COSName = "DP"

  /// `/Predictor`.
  package static let predictor: COSName = "Predictor"

  /// `/Columns`.
  package static let columns: COSName = "Columns"

  /// `/Colors`.
  package static let colors: COSName = "Colors"

  /// `/BitsPerComponent`.
  package static let bitsPerComponent: COSName = "BitsPerComponent"
}
