import Foundation
@testable import PapyrusCore
import Testing

/// ``COSLexer``의 상태 전이를 골든 케이스로 검증한다 (설계 §3.1, §5.2).
struct COSLexerGoldenTests {
  // MARK: L-NUM — 숫자 리터럴

  @Test(arguments: [
    NumberCase(input: "123", expected: .integer(123)),
    NumberCase(input: "+17", expected: .integer(17)),
    NumberCase(input: "-98", expected: .integer(-98)),
    NumberCase(input: "0", expected: .integer(0)),
    NumberCase(input: "00987", expected: .integer(987)),
    NumberCase(input: "34.5", expected: .real(34.5)),
    NumberCase(input: "-3.62", expected: .real(-3.62)),
    NumberCase(input: "+123.6", expected: .real(123.6)),
    NumberCase(input: "4.", expected: .real(4.0)),
    NumberCase(input: "-.002", expected: .real(-0.002)),
    NumberCase(input: ".0", expected: .real(0.0)),
    NumberCase(
      input: "9999999999999999999999",
      expected: .real(Self.doubleFromDigits("9999999999999999999999"))
    )
  ])
  func numberLiteralsScanToExpectedToken(_ testCase: NumberCase) throws {
    #expect(try Self.scanAll(testCase.input) == [testCase.expected])
  }

  // MARK: L-NUM-ERR — 숫자 문법 위반

  @Test(arguments: [
    LexErrorCase(input: "+", expectedCode: .invalidNumber, expectedOffset: 0),
    LexErrorCase(input: ".", expectedCode: .invalidNumber, expectedOffset: 0),
    LexErrorCase(input: "--1", expectedCode: .invalidNumber, expectedOffset: 0),
    LexErrorCase(input: "1.2.3", expectedCode: .invalidNumber, expectedOffset: 0),
    LexErrorCase(input: "1e5", expectedCode: .invalidNumber, expectedOffset: 0)
  ])
  func malformedNumbersThrowInvalidNumber(_ testCase: LexErrorCase) {
    Self.expectError(testCase)
  }

  // MARK: L-STR — 리터럴 문자열

  @Test(arguments: [
    LiteralStringCase(input: "(simple)", expectedBytes: Array("simple".utf8), label: "simple"),
    LiteralStringCase(input: "(())", expectedBytes: Array("()".utf8), label: "nested-balance"),
    LiteralStringCase(input: "(\\n)", expectedBytes: [0x0A], label: "escape-n"),
    LiteralStringCase(input: "(\\r)", expectedBytes: [0x0D], label: "escape-r"),
    LiteralStringCase(input: "(\\t)", expectedBytes: [0x09], label: "escape-t"),
    LiteralStringCase(input: "(\\b)", expectedBytes: [0x08], label: "escape-b"),
    LiteralStringCase(input: "(\\f)", expectedBytes: [0x0C], label: "escape-f"),
    LiteralStringCase(input: "(\\()", expectedBytes: [0x28], label: "escape-openparen"),
    LiteralStringCase(input: "(\\))", expectedBytes: [0x29], label: "escape-closeparen"),
    LiteralStringCase(input: "(\\\\)", expectedBytes: [0x5C], label: "escape-backslash"),
    LiteralStringCase(input: "(\\053)", expectedBytes: [0x2B], label: "octal-3digit-plus"),
    LiteralStringCase(input: "(\\53)", expectedBytes: [0x2B], label: "octal-2digit-plus"),
    LiteralStringCase(input: "(\\400)", expectedBytes: [0x00], label: "octal-overflow-mod256"),
    LiteralStringCase(input: "(\\\r)", expectedBytes: [], label: "line-continuation-cr"),
    LiteralStringCase(input: "(\\\n)", expectedBytes: [], label: "line-continuation-lf"),
    LiteralStringCase(input: "(\\\r\n)", expectedBytes: [], label: "line-continuation-crlf"),
    LiteralStringCase(input: "(\r)", expectedBytes: [0x0A], label: "bare-cr-normalized"),
    LiteralStringCase(input: "(\n)", expectedBytes: [0x0A], label: "bare-lf-normalized"),
    LiteralStringCase(input: "(\r\n)", expectedBytes: [0x0A], label: "bare-crlf-normalized"),
    LiteralStringCase(input: "(\\q)", expectedBytes: [0x71], label: "unknown-escape-literal"),
    LiteralStringCase(input: "()", expectedBytes: [], label: "empty")
  ])
  func literalStringsDecodeExpectedBytes(_ testCase: LiteralStringCase) throws {
    let tokens = try Self.scanAll(testCase.input)
    #expect(tokens == [.string(testCase.expectedBytes)])
  }

  // MARK: L-STR-ERR — 미종결 문자열

  @Test func unterminatedLiteralStringThrowsUnbalancedString() {
    Self.expectError(
      LexErrorCase(input: "(abc", expectedCode: .unbalancedString, expectedOffset: 0)
    )
  }

  // MARK: L-HEX — hex 문자열

  @Test(arguments: [
    LiteralStringCase(input: "<901FA3>", expectedBytes: [0x90, 0x1F, 0xA3], label: "even"),
    LiteralStringCase(input: "<901FA>", expectedBytes: [0x90, 0x1F, 0xA0], label: "odd-padded"),
    LiteralStringCase(
      input: "<90 1F\nA3>", expectedBytes: [0x90, 0x1F, 0xA3], label: "whitespace-ignored"
    ),
    LiteralStringCase(input: "<>", expectedBytes: [], label: "empty")
  ])
  func hexStringsDecodeExpectedBytes(_ testCase: LiteralStringCase) throws {
    let tokens = try Self.scanAll(testCase.input)
    #expect(tokens == [.string(testCase.expectedBytes)])
  }

  // MARK: L-HEX-ERR — hex 알파벳 밖 문자

  @Test func invalidHexCharacterThrows() {
    Self.expectError(
      LexErrorCase(input: "<9G>", expectedCode: .invalidHexCharacter, expectedOffset: 2)
    )
  }

  // MARK: L-NAME — 이름

  @Test(arguments: [
    NameCase(input: "/Name1", expected: "Name1"),
    NameCase(input: "/A;Name_With-Various***Chars?", expected: "A;Name_With-Various***Chars?"),
    NameCase(input: "/1.2", expected: "1.2"),
    NameCase(input: "/$$", expected: "$$"),
    NameCase(input: "/@pattern", expected: "@pattern"),
    NameCase(input: "/.notdef", expected: ".notdef"),
    NameCase(input: "/lime#20Green", expected: "lime Green"),
    NameCase(input: "/paired#28#29parentheses", expected: "paired()parentheses"),
    NameCase(input: "/#41", expected: "A"),
    NameCase(input: "/", expected: ""),
    NameCase(input: "/Bad#zz", expected: "Bad#zz")
  ])
  func namesDecodeExpectedRawValue(_ testCase: NameCase) throws {
    let tokens = try Self.scanAll(testCase.input)
    #expect(tokens == [.name(COSName(testCase.expected))])
  }

  // MARK: L-STRUCT — 구조 토큰

  @Test func structuralTokensScanIndividually() throws {
    #expect(try Self.scanAll("[") == [.arrayOpen])
    #expect(try Self.scanAll("]") == [.arrayClose])
    #expect(try Self.scanAll("<<") == [.dictionaryOpen])
    #expect(try Self.scanAll(">>") == [.dictionaryClose])
  }

  @Test func structuralTokensScanAsFullSequence() throws {
    let tokens = try Self.scanAll("<< /A [1 2] >>")
    #expect(tokens == [
      .dictionaryOpen, .name(COSName("A")), .arrayOpen, .integer(1), .integer(2),
      .arrayClose, .dictionaryClose
    ])
  }

  // MARK: L-KW — bare 키워드

  @Test func bareKeywordsScanToExpectedTokens() throws {
    let tokens = try Self.scanAll(
      "true false null obj endobj stream endstream R xref trailer startxref frobnicate"
    )
    #expect(tokens == [
      .boolean(true), .boolean(false), .null,
      .keyword(.obj), .keyword(.endobj), .keyword(.stream), .keyword(.endstream), .keyword(.r),
      .keyword(.xref), .keyword(.trailer), .keyword(.startxref), .keyword(.other("frobnicate"))
    ])
  }

  // MARK: L-WS-EOL — 공백·주석 처리

  @Test(arguments: [
    WhitespaceCase(input: "1\r2", label: "cr-separator"),
    WhitespaceCase(input: "1\n2", label: "lf-separator"),
    WhitespaceCase(input: "1\r\n2", label: "crlf-separator"),
    WhitespaceCase(input: "1\u{00}2", label: "nul-separator"),
    WhitespaceCase(input: "1\u{0C}2", label: "ff-separator"),
    WhitespaceCase(input: "1\t2", label: "tab-separator"),
    WhitespaceCase(input: "1 2", label: "space-separator")
  ])
  func whitespaceBytesSeparateTokens(_ testCase: WhitespaceCase) throws {
    #expect(try Self.scanAll(testCase.input) == [.integer(1), .integer(2)])
  }

  @Test(arguments: [
    "%comment\r\n123", "%comment\n123", "%comment\r123"
  ])
  func commentsAreSkippedRegardlessOfEOLStyle(_ input: String) throws {
    #expect(try Self.scanAll(input) == [.integer(123)])
  }

  @Test func commentOnlyInputProducesNoTokens() throws {
    #expect(try Self.scanAll("%%EOF") == [])
  }

  @Test func commentAtEndOfFileWithoutEOLIsConsumedSafely() throws {
    #expect(try Self.scanAll("123%no eol at end") == [.integer(123)])
  }

  // MARK: L-ERR — 고아 구분자·빈 입력

  @Test(arguments: [
    LexErrorCase(input: ")", expectedCode: .unexpectedDelimiter, expectedOffset: 0),
    LexErrorCase(input: ">", expectedCode: .unexpectedDelimiter, expectedOffset: 0),
    LexErrorCase(input: "{", expectedCode: .unexpectedDelimiter, expectedOffset: 0),
    LexErrorCase(input: "}", expectedCode: .unexpectedDelimiter, expectedOffset: 0)
  ])
  func orphanDelimitersThrowUnexpectedDelimiter(_ testCase: LexErrorCase) {
    Self.expectError(testCase)
  }

  @Test func emptyAndWhitespaceOnlyInputProduceNoTokens() throws {
    #expect(try Self.scanAll("") == [])
    #expect(try Self.scanAll("   ") == [])
  }

  // MARK: L-OFFSET — 토큰 구간 정합성

  @Test func scannedTokenRangesMatchSourcePositions() throws {
    let source = " 12 (ab) /N "
    let file = MappedFile(data: Data(source.utf8))
    var lexer = COSLexer(file: file)

    let first = try #require(try lexer.nextToken())
    #expect(first.token == .integer(12))
    #expect(first.range == 1..<3)

    let second = try #require(try lexer.nextToken())
    #expect(second.token == .string(Array("ab".utf8)))
    #expect(second.range == 4..<8)

    let third = try #require(try lexer.nextToken())
    #expect(third.token == .name(COSName("N")))
    #expect(third.range == 9..<11)

    #expect(try lexer.nextToken() == nil)
  }
}

// MARK: - 테스트 케이스 타입 · 헬퍼

/// 단일 숫자 리터럴 → 기대 토큰.
struct NumberCase: Sendable, CustomTestStringConvertible {
  let input: String
  let expected: COSToken
  var testDescription: String { self.input }
}

/// 렉싱 에러 케이스 (입력 → 기대 코드·오프셋).
struct LexErrorCase: Sendable, CustomTestStringConvertible {
  let input: String
  let expectedCode: COSParseError.Code
  let expectedOffset: Int
  var testDescription: String { self.input }
}

/// 리터럴/hex 문자열 → 기대 디코딩 바이트.
struct LiteralStringCase: Sendable, CustomTestStringConvertible {
  let input: String
  let expectedBytes: [UInt8]
  let label: String
  var testDescription: String { self.label }
}

/// 이름 → 기대 raw value.
struct NameCase: Sendable, CustomTestStringConvertible {
  let input: String
  let expected: String
  var testDescription: String { self.input }
}

/// 화이트스페이스 구분자 케이스.
struct WhitespaceCase: Sendable, CustomTestStringConvertible {
  let input: String
  let label: String
  var testDescription: String { self.label }
}

extension COSLexerGoldenTests {
  /// 입력 바이트열 전체를 토큰화한다.
  fileprivate static func scanAll(_ input: String) throws(COSParseError) -> [COSToken] {
    let file = MappedFile(data: Data(input.utf8))
    var lexer = COSLexer(file: file)
    var tokens: [COSToken] = []
    while let scanned = try lexer.nextToken() {
      tokens.append(scanned.token)
    }
    return tokens
  }

  /// 렉서 에러 케이스가 정확한 코드·오프셋으로 실패하는지 검증한다.
  fileprivate static func expectError(_ testCase: LexErrorCase) {
    do {
      _ = try Self.scanAll(testCase.input)
      Issue.record("예상한 에러가 발생하지 않음: \(testCase.input)")
    } catch {
      #expect(error.code == testCase.expectedCode)
      #expect(error.offset == testCase.expectedOffset)
    }
  }

  /// Int64 오버플로 폴백 검증용: 부호 없는 십진 자릿수만 Double로 누산한다
  /// (렉서의 폴백 알고리즘과 동일한 IEEE754 연산 순서 — 결정적으로 같은 비트 패턴이 나온다).
  fileprivate static func doubleFromDigits(_ digits: String) -> Double {
    var value = 0.0
    for character in digits {
      guard let digit = character.wholeNumberValue else {
        continue
      }
      value = value * 10 + Double(digit)
    }
    return value
  }
}
