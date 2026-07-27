import Foundation

/// `/ASCIIHexDecode` (`/AHx`) 디코더.
package enum ASCIIHexDecode {
  /// hex 문자열을 바이트로 디코딩한다.
  ///
  /// 공백은 무시하고, `>` EOD에서 종료한다. EOD 없이 입력이 소진되면 관용적으로
  /// 수용한다(실파일 다수가 EOD를 생략한다). 홀수 니블이면 마지막 니블에 0을 패딩한다.
  /// - Parameter data: 인코딩된 바이트.
  /// - Throws: hex 알파벳 밖 문자가 있으면 ``FilterError/Code/invalidCharacter``.
  package static func decode(_ data: Data) throws(FilterError) -> Data {
    var nibbles: [UInt8] = []
    nibbles.reserveCapacity(data.count)
    for byte in data {
      if byte == UInt8(ascii: ">") {
        break
      }
      if Self.isWhitespace(byte) {
        continue
      }
      guard let nibble = Self.hexNibble(byte) else {
        throw FilterError(code: .invalidCharacter)
      }
      nibbles.append(nibble)
    }

    var out = [UInt8]()
    out.reserveCapacity((nibbles.count + 1) / 2)
    var index = 0
    while index < nibbles.count {
      let high = nibbles[index]
      let low = index + 1 < nibbles.count ? nibbles[index + 1] : 0
      out.append(high << 4 | low)
      index += 2
    }
    return Data(out)
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20:
      return true
    default:
      return false
    }
  }

  private static func hexNibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39:
      return byte - 0x30
    case 0x41...0x46:
      return byte - 0x41 + 10
    case 0x61...0x66:
      return byte - 0x61 + 10
    default:
      return nil
    }
  }
}
