@testable import PapyrusCore
import Testing

/// ``PDFTextString``의 인코딩 판별·디코딩을 검증한다 (설계 §5.2 TS1-TS4).
struct PDFTextStringTests {
  // MARK: TS1 — PDFDocEncoding

  /// TS1: ASCII 구간 항등, 스팟 체크(0x80 불릿, 0x84 엠대시), 미정의(0x7F, 0xAD) → U+FFFD.
  @Test func pdfDocEncodingDecodesASCIIIdentityAndSpecialCodes() {
    let ascii = Array("Hello, World! 123".utf8)
    #expect(PDFTextString.decode(ascii) == "Hello, World! 123")

    #expect(PDFTextString.decode([0x80]) == "\u{2022}")
    #expect(PDFTextString.decode([0x84]) == "\u{2014}")
    #expect(PDFTextString.decode([0x7F]) == "\u{FFFD}")
    #expect(PDFTextString.decode([0xAD]) == "\u{FFFD}")
  }

  // MARK: TS2 — UTF-16BE BOM

  /// TS2: UTF-16BE BOM + 한글/이모지(서러게이트 쌍) 정상 디코딩.
  @Test func utf16BEDecodesKoreanAndSurrogatePairs() {
    let text = "안녕😀"
    var bytes: [UInt8] = [0xFE, 0xFF]
    for unit in text.utf16 {
      bytes.append(UInt8(unit >> 8))
      bytes.append(UInt8(unit & 0xFF))
    }
    #expect(PDFTextString.decode(bytes) == text)
  }

  // MARK: TS3 — 손상 UTF-16BE

  /// TS3: 홀수 길이는 마지막 바이트 폐기, 고아 서러게이트는 U+FFFD 흡수, 크래시 없음.
  @Test func utf16BEHandlesOddLengthAndOrphanSurrogates() {
    // "A"(0041) + 마지막 홀 바이트.
    let oddLength: [UInt8] = [0xFE, 0xFF, 0x00, 0x41, 0x00]
    #expect(PDFTextString.decode(oddLength) == "A")

    // 고아 하이 서러게이트(D800) 뒤에 정상 문자(0042="B").
    let orphanSurrogate: [UInt8] = [0xFE, 0xFF, 0xD8, 0x00, 0x00, 0x42]
    let decoded = PDFTextString.decode(orphanSurrogate)
    #expect(decoded.contains("\u{FFFD}"))
    #expect(decoded.contains("B"))
  }

  // MARK: TS4 — UTF-8 BOM / 빈 입력

  /// TS4: UTF-8 BOM 수용; 빈 바이트열 → "".
  @Test func utf8BOMAndEmptyBytesAreHandled() {
    var bytes: [UInt8] = [0xEF, 0xBB, 0xBF]
    bytes.append(contentsOf: Array("café".utf8))
    #expect(PDFTextString.decode(bytes) == "café")

    #expect(PDFTextString.decode([]) == "")
  }
}
