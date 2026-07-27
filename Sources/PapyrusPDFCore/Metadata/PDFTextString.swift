/// PDF 텍스트 문자열(스펙 7.9.2.2) 디코더. Info 값·목차 /Title·이름 목적지 키가 소비한다.
package enum PDFTextString {
  /// 바이트열을 유니코드 문자열로 디코딩한다.
  ///
  /// 판별: `FE FF` BOM → UTF-16BE, `EF BB BF` BOM → UTF-8(PDF 2.0 관용 수용),
  /// 그 외 → PDFDocEncoding (Annex D.3 256엔트리 테이블, 미정의 코드는 U+FFFD).
  /// UTF-16BE 홀수 길이는 마지막 바이트 폐기, 손상 서러게이트는 U+FFFD (크래시 금지).
  /// - Parameter bytes: 디코딩할 원시 문자열 바이트.
  /// - Returns: 디코딩된 문자열.
  package static func decode(_ bytes: [UInt8]) -> String {
    if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
      return Self.decodeUTF16BE(Array(bytes.dropFirst(2)))
    }
    if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
      // [UInt8](Data 아님)의 의도적 손상 복구(U+FFFD) 디코딩 — 실패 가능한
      // String(bytes:encoding:)는 복구를 못 한다.
      // swiftlint:disable:next optional_data_string_conversion
      return String(decoding: bytes.dropFirst(3), as: UTF8.self)
    }
    return Self.decodePDFDocEncoding(bytes)
  }

  /// UTF-16BE 바이트열을 디코딩한다. 홀수 길이의 마지막 바이트는 폐기하고, 손상된
  /// 서러게이트 쌍은 Swift 표준 복구 규칙에 따라 U+FFFD로 치환된다 (크래시 없음).
  private static func decodeUTF16BE(_ bytes: [UInt8]) -> String {
    var units: [UInt16] = []
    units.reserveCapacity(bytes.count / 2)
    var index = 0
    while index + 1 < bytes.count {
      units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
      index += 2
    }
    return String(decoding: units, as: UTF16.self)
  }

  /// PDFDocEncoding 256엔트리 테이블로 바이트열을 디코딩한다.
  private static func decodePDFDocEncoding(_ bytes: [UInt8]) -> String {
    var view = String.UnicodeScalarView()
    view.reserveCapacity(bytes.count)
    for byte in bytes {
      view.append(Self.pdfDocEncodingTable[Int(byte)])
    }
    return String(view)
  }

  /// PDF 32000-1:2008 Annex D.3 PDFDocEncoding 테이블. 인덱스 = 바이트 값(0...255).
  /// 미정의 코드(0x7F, 0x9F, 0xAD)는 이미 U+FFFD로 채워져 있다.
  private static let pdfDocEncodingTable: [Unicode.Scalar] = {
    // 0x00...0x17: ASCII 제어 문자와 동일 (항등).
    var table: [UInt32] = Array(0x00...0x17)
    // 0x18...0x1F: 발음 기호 (breve caron circumflex dotaccent hungarumlaut ogonek ring tilde).
    table.append(contentsOf: [0x02D8, 0x02C7, 0x02C6, 0x02D9, 0x02DD, 0x02DB, 0x02DA, 0x02DC])
    // 0x20...0x7E: ASCII 출력 가능 문자와 동일 (항등).
    table.append(contentsOf: Array(0x20...0x7E))
    // 0x7F: 미정의.
    table.append(0xFFFD)
    // 0x80...0x9F: 타이포그래피 특수문자 (bullet dagger ... zcaron), 0x9F는 미정의.
    table.append(contentsOf: [
      0x2022, 0x2020, 0x2021, 0x2026, 0x2014, 0x2013, 0x0192, 0x2044,
      0x2039, 0x203A, 0x2212, 0x2030, 0x201E, 0x201C, 0x201D, 0x2018,
      0x2019, 0x201A, 0x2122, 0xFB01, 0xFB02, 0x0141, 0x0152, 0x0160,
      0x0178, 0x017D, 0x0131, 0x0142, 0x0153, 0x0161, 0x017E, 0xFFFD
    ])
    // 0xA0: 유로 기호.
    table.append(0x20AC)
    // 0xA1...0xAC: Latin-1 보충 문자 항등.
    table.append(contentsOf: Array(0xA1...0xAC))
    // 0xAD: 미정의.
    table.append(0xFFFD)
    // 0xAE...0xFF: Latin-1 보충 문자 항등.
    table.append(contentsOf: Array(0xAE...0xFF))
    return table.map { Unicode.Scalar($0)! }
  }()
}
