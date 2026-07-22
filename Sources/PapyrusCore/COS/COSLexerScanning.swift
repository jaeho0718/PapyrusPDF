import Foundation

/// 숫자 런 파싱 결과 (내부용). `COSLexer.swift`(다른 파일)의 `scanNumber`가 소비하므로
/// 모듈 내부(`internal`)로 노출한다.
enum NumberParseResult {
  /// 정수로 해석됨.
  case integer(Int)

  /// 실수로 해석됨 (소수점 포함, 또는 Int64 오버플로 폴백).
  case real(Double)

  /// 문법 위반.
  case invalid
}

// MARK: - 바이트 분류·숫자 파싱 (상태 없는 정적 헬퍼)

/// ``COSLexer``의 바이트 분류·숫자 파싱 헬퍼. 파일 분리는 순수 조직적 이유(파일 길이 제한)이며
/// 타입·의미는 `COSLexer.swift`와 동일하다.
extension COSLexer {
  /// PDF 화이트스페이스 바이트(NUL·TAB·LF·FF·CR·SP) 여부.
  static func isWhitespace(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20:
      return true
    default:
      return false
    }
  }

  /// PDF 구분자 바이트(`( ) < > [ ] { } / %`) 여부.
  private static func isDelimiter(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
      UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
      UInt8(ascii: "/"), UInt8(ascii: "%"):
      return true
    default:
      return false
    }
  }

  /// 화이트스페이스도 구분자도 아닌 "regular" 바이트 여부.
  static func isRegular(_ byte: UInt8) -> Bool {
    !Self.isWhitespace(byte) && !Self.isDelimiter(byte)
  }

  /// hex 문자 하나를 니블 값으로. 유효하지 않으면 `nil`.
  static func hexNibble(_ byte: UInt8) -> UInt8? {
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

  /// UTF-8 디코딩을 시도하고, 실패하면 라틴-1 폴백(바이트→스칼라 1:1)으로 문자열화한다.
  static func decodeName(_ bytes: [UInt8]) -> String {
    if let utf8 = String(bytes: bytes, encoding: .utf8) {
      return utf8
    }
    return String(bytes.map { Character(UnicodeScalar($0)) })
  }

  /// 값 토큰·구조 키워드로 즉시 변환되는 bare 키워드 표. 조회 실패 시 `.other`로 넘긴다.
  private static let keywordTokens: [String: COSToken] = [
    "true": .boolean(true),
    "false": .boolean(false),
    "null": .null,
    "obj": .keyword(.obj),
    "endobj": .keyword(.endobj),
    "stream": .keyword(.stream),
    "endstream": .keyword(.endstream),
    "R": .keyword(.r),
    "xref": .keyword(.xref),
    "trailer": .keyword(.trailer),
    "startxref": .keyword(.startxref)
  ]

  /// 완결된 키워드 런을 값 토큰 또는 구조 키워드로 변환한다.
  static func keywordToken(for text: String) -> COSToken {
    Self.keywordTokens[text] ?? .keyword(.other(text))
  }

  /// 숫자 런을 정수 또는 실수로 파싱한다. NaN/Inf를 생산하지 않는다.
  ///
  /// 정수부(+소수부)를 Int64로 누산하다 오버플로하면, 같은 자리수를 Double로
  /// 재누산해 실수로 폴백한다 (10자리 초과 오프셋을 쓰는 병적 파일 관용).
  static func parseNumber(_ bytes: [UInt8]) -> NumberParseResult {
    var index = 0
    let end = bytes.count
    let negative = Self.scanSign(bytes, index: &index)

    var mantissa: Int64 = 0
    var overflowed = false
    let intDigitCount = Self.scanDigitRun(
      bytes, index: &index, mantissa: &mantissa, overflowed: &overflowed
    )

    var hasFraction = false
    var fracDigitCount = 0
    if index < end, bytes[index] == UInt8(ascii: ".") {
      hasFraction = true
      index += 1
      fracDigitCount = Self.scanDigitRun(
        bytes, index: &index, mantissa: &mantissa, overflowed: &overflowed
      )
    }

    guard index == end, intDigitCount + fracDigitCount > 0 else {
      return .invalid
    }

    if !hasFraction, !overflowed {
      return .integer(negative ? -Int(mantissa) : Int(mantissa))
    }

    let magnitude = overflowed ? Self.doubleMantissa(bytes) : Double(mantissa)
    let scaled = magnitude / Self.pow10(fracDigitCount)
    return .real(negative ? -scaled : scaled)
  }

  /// 선행 부호(`+`/`-`)를 소비한다. `-`면 `true`(음수)를 반환한다.
  private static func scanSign(_ bytes: [UInt8], index: inout Int) -> Bool {
    guard index < bytes.count else {
      return false
    }
    if bytes[index] == UInt8(ascii: "+") {
      index += 1
      return false
    }
    if bytes[index] == UInt8(ascii: "-") {
      index += 1
      return true
    }
    return false
  }

  /// 십진 자릿수 런을 `mantissa`에 누산하며 소비한다. 소비한 자릿수 개수를 반환한다.
  private static func scanDigitRun(
    _ bytes: [UInt8], index: inout Int, mantissa: inout Int64, overflowed: inout Bool
  ) -> Int {
    var count = 0
    while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
      Self.accumulate(&mantissa, digit: bytes[index], overflowed: &overflowed)
      count += 1
      index += 1
    }
    return count
  }

  /// 오버플로 검사하며 십진 자릿수 하나를 `mantissa`에 누산한다.
  private static func accumulate(_ mantissa: inout Int64, digit: UInt8, overflowed: inout Bool) {
    let value = Int64(digit - 0x30)
    let (multiplied, multiplyOverflowed) = mantissa.multipliedReportingOverflow(by: 10)
    let (added, addOverflowed) = multiplied.addingReportingOverflow(value)
    if multiplyOverflowed || addOverflowed {
      overflowed = true
    } else {
      mantissa = added
    }
  }

  /// Int64 오버플로 폴백용: 부호·소수점을 무시하고 십진 숫자만 Double로 누산한다.
  private static func doubleMantissa(_ bytes: [UInt8]) -> Double {
    var value = 0.0
    for byte in bytes where (0x30...0x39).contains(byte) {
      value = value * 10 + Double(byte - 0x30)
    }
    return value
  }

  /// `10^exponent`를 반복 곱셈으로 계산한다 (로케일·`pow` 의존 없이 정확히 재현 가능).
  private static func pow10(_ exponent: Int) -> Double {
    var result = 1.0
    for _ in 0..<exponent {
      result *= 10
    }
    return result
  }
}
