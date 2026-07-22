import Foundation

/// 커서 기반 바이트 렉서. 전체 토큰화 없이 현재 위치에서 다음 토큰 하나만 스캔한다.
///
/// 값 타입 — 복사가 곧 상태 스냅숏이므로 파서의 백트래킹이 "복사 후 복원"으로 끝난다.
/// 인스턴스를 여러 태스크가 공유할 설계가 아니다 (`mutating` API를 통해서만 전진한다).
package struct COSLexer: Sendable {
  /// 스캔 대상 바이트 소스.
  private let file: MappedFile

  /// 다음 스캔이 시작될 절대 오프셋.
  package private(set) var offset: Int

  /// 렉서를 생성한다.
  /// - Parameters:
  ///   - file: 스캔 대상 바이트 소스.
  ///   - offset: 시작 오프셋 (기본 0).
  package init(file: MappedFile, offset: Int = 0) {
    self.file = file
    self.offset = offset
  }

  /// 다음 토큰을 스캔한다. EOF면 `nil`.
  ///
  /// 에러가 발생하면 커서는 토큰 시작 위치에 머문다 (전진하지 않음) — 호출부가
  /// 에러 처리 후 어디서부터 재시도할지 스스로 결정할 수 있게 한다.
  /// - Throws: 구문 위반 시 ``COSParseError`` (오프셋 포함).
  package mutating func nextToken() throws(COSParseError) -> COSScannedToken? {
    self.skipWhitespaceAndComments()
    guard let firstByte = self.file.byte(at: self.offset) else {
      return nil
    }
    let start = self.offset
    let scanned = try self.scanToken(firstByte: firstByte, start: start)
    self.offset = scanned.range.upperBound
    return scanned
  }

  /// 커서를 임의 오프셋으로 이동한다 (스트림 페이로드 건너뛰기, xref 점프용).
  /// - Parameter offset: 이동할 절대 오프셋.
  package mutating func seek(to offset: Int) {
    self.offset = offset
  }

  /// 현재 위치에서 공백·주석만 건너뛴다 (`stream` 직후 EOL 처리는 파서가 직접 수행).
  ///
  /// 종료성: 매 반복은 오프셋을 최소 1바이트 전진시키거나 루프를 벗어난다 —
  /// EOF 또는 공백·`%` 아닌 바이트를 만나면 즉시 종료한다.
  package mutating func skipWhitespaceAndComments() {
    while let byte = self.file.byte(at: self.offset) {
      if Self.isWhitespace(byte) {
        self.offset += 1
      } else if byte == UInt8(ascii: "%") {
        self.skipComment()
      } else {
        break
      }
    }
  }

  /// `%` 직후부터 EOL(LF|CR|CRLF) 또는 EOF까지 소비한다.
  private mutating func skipComment() {
    self.offset += 1
    while let byte = self.file.byte(at: self.offset), byte != 0x0A, byte != 0x0D {
      self.offset += 1
    }
    if self.file.byte(at: self.offset) == 0x0D {
      self.offset += 1
      if self.file.byte(at: self.offset) == 0x0A {
        self.offset += 1
      }
    } else if self.file.byte(at: self.offset) == 0x0A {
      self.offset += 1
    }
  }
}

// MARK: - 토큰 스캔

extension COSLexer {
  /// 선행 공백 스킵 이후 첫 바이트를 보고 스캔 함수로 디스패치한다.
  private func scanToken(firstByte: UInt8, start: Int) throws(COSParseError) -> COSScannedToken {
    switch firstByte {
    case 0x30...0x39, UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."):
      return try self.scanNumber(start: start)
    case UInt8(ascii: "/"):
      return self.scanName(start: start)
    case UInt8(ascii: "("):
      return try self.scanLiteralString(start: start)
    case UInt8(ascii: "<"):
      return try self.scanLessThan(start: start)
    case UInt8(ascii: ">"):
      return try self.scanGreaterThan(start: start)
    case UInt8(ascii: "["):
      return COSScannedToken(token: .arrayOpen, range: start..<(start + 1))
    case UInt8(ascii: "]"):
      return COSScannedToken(token: .arrayClose, range: start..<(start + 1))
    case UInt8(ascii: ")"), UInt8(ascii: "{"), UInt8(ascii: "}"):
      throw COSParseError(code: .unexpectedDelimiter, offset: start)
    default:
      return self.scanKeyword(start: start)
    }
  }

  /// `<` 디스패치: `<<`면 dictionaryOpen, 아니면 hex 문자열 시작.
  private func scanLessThan(start: Int) throws(COSParseError) -> COSScannedToken {
    if self.file.byte(at: start + 1) == UInt8(ascii: "<") {
      return COSScannedToken(token: .dictionaryOpen, range: start..<(start + 2))
    }
    return try self.scanHexString(start: start)
  }

  /// `>` 디스패치: `>>`면 dictionaryClose, 아니면 고아 `>`로 에러.
  private func scanGreaterThan(start: Int) throws(COSParseError) -> COSScannedToken {
    if self.file.byte(at: start + 1) == UInt8(ascii: ">") {
      return COSScannedToken(token: .dictionaryClose, range: start..<(start + 2))
    }
    throw COSParseError(code: .unexpectedDelimiter, offset: start)
  }

  /// 숫자 문법 `[+-]? digits? ('.' digits?)?`를 스캔한다.
  ///
  /// 종료성: 토큰 경계(공백/구분자)까지 바이트 런을 소비한 뒤 검증하므로,
  /// 매 반복 최소 1바이트 전진하거나 EOF/구분자에서 멈춘다.
  private func scanNumber(start: Int) throws(COSParseError) -> COSScannedToken {
    var end = start
    var runBytes: [UInt8] = []
    while let byte = self.file.byte(at: end), Self.isRegular(byte) {
      runBytes.append(byte)
      end += 1
    }
    switch Self.parseNumber(runBytes) {
    case let .integer(value):
      return COSScannedToken(token: .integer(value), range: start..<end)
    case let .real(value):
      return COSScannedToken(token: .real(value), range: start..<end)
    case .invalid:
      throw COSParseError(code: .invalidNumber, offset: start)
    }
  }

  /// `/` 이후 이름을 스캔한다. `#xy` 이스케이프를 해소하고, `#` 뒤가 유효 hex가
  /// 아니면 리터럴 `#`로 관용 처리한다.
  private func scanName(start: Int) -> COSScannedToken {
    var cursor = start + 1
    var out: [UInt8] = []
    while let byte = self.file.byte(at: cursor), Self.isRegular(byte) {
      if byte == UInt8(ascii: "#"),
        let high = self.file.byte(at: cursor + 1), let highNibble = Self.hexNibble(high),
        let low = self.file.byte(at: cursor + 2), let lowNibble = Self.hexNibble(low) {
        out.append(highNibble << 4 | lowNibble)
        cursor += 3
      } else {
        out.append(byte)
        cursor += 1
      }
    }
    return COSScannedToken(token: .name(COSName(Self.decodeName(out))), range: start..<cursor)
  }

  /// `(` 이후 리터럴 문자열을 스캔한다 (재귀 없는 괄호 깊이 카운터).
  ///
  /// 종료성: 매 반복 최소 1바이트를 소비하고, EOF에서 즉시 throw한다.
  private func scanLiteralString(start: Int) throws(COSParseError) -> COSScannedToken {
    var cursor = start + 1
    var depth = 1
    var out: [UInt8] = []
    while true {
      guard let byte = self.file.byte(at: cursor) else {
        throw COSParseError(code: .unbalancedString, offset: start)
      }
      switch byte {
      case 0x28:
        depth += 1
        out.append(byte)
        cursor += 1
      case 0x29:
        depth -= 1
        cursor += 1
        if depth == 0 {
          return COSScannedToken(token: .string(out), range: start..<cursor)
        }
        out.append(byte)
      case 0x5C:
        guard let escapeByte = self.file.byte(at: cursor + 1) else {
          throw COSParseError(code: .unbalancedString, offset: start)
        }
        cursor = self.consumeEscape(escapeByte, at: cursor + 1, out: &out)
      case 0x0D:
        out.append(0x0A)
        cursor += 1
        if self.file.byte(at: cursor) == 0x0A {
          cursor += 1
        }
      default:
        out.append(byte)
        cursor += 1
      }
    }
  }

  /// 리터럴 문자열 내 `\` 이스케이프 하나를 해소한다.
  /// - Parameters:
  ///   - escapeByte: `\` 직후 바이트.
  ///   - position: `escapeByte`의 절대 오프셋.
  ///   - out: 누적 출력 버퍼.
  /// - Returns: 이스케이프 소비 완료 후 다음 커서 위치.
  private func consumeEscape(_ escapeByte: UInt8, at position: Int, out: inout [UInt8]) -> Int {
    switch escapeByte {
    case UInt8(ascii: "n"):
      out.append(0x0A)
      return position + 1
    case UInt8(ascii: "r"):
      out.append(0x0D)
      return position + 1
    case UInt8(ascii: "t"):
      out.append(0x09)
      return position + 1
    case UInt8(ascii: "b"):
      out.append(0x08)
      return position + 1
    case UInt8(ascii: "f"):
      out.append(0x0C)
      return position + 1
    case 0x28, 0x29, 0x5C:
      out.append(escapeByte)
      return position + 1
    case 0x30...0x37:
      return self.consumeOctalEscape(firstDigit: escapeByte, at: position, out: &out)
    case 0x0D:
      let next = position + 1
      return self.file.byte(at: next) == 0x0A ? next + 1 : next
    case 0x0A:
      return position + 1
    default:
      out.append(escapeByte)
      return position + 1
    }
  }

  /// 최대 3자리 8진수 이스케이프를 누산해 `& 0xFF` 값 하나를 출력한다.
  private func consumeOctalEscape(firstDigit: UInt8, at position: Int, out: inout [UInt8]) -> Int {
    var value = Int(firstDigit - 0x30)
    var cursor = position + 1
    var digitCount = 1
    while digitCount < 3, let digit = self.file.byte(at: cursor), (0x30...0x37).contains(digit) {
      value = value * 8 + Int(digit - 0x30)
      cursor += 1
      digitCount += 1
    }
    out.append(UInt8(value & 0xFF))
    return cursor
  }

  /// `<` 이후 hex 문자열을 스캔한다. 공백 무시, 홀수 니블은 0 패딩.
  private func scanHexString(start: Int) throws(COSParseError) -> COSScannedToken {
    var cursor = start + 1
    var nibbles: [UInt8] = []
    while true {
      guard let byte = self.file.byte(at: cursor) else {
        throw COSParseError(code: .unexpectedEndOfFile, offset: cursor)
      }
      if byte == UInt8(ascii: ">") {
        cursor += 1
        break
      }
      if Self.isWhitespace(byte) {
        cursor += 1
        continue
      }
      guard let nibble = Self.hexNibble(byte) else {
        throw COSParseError(code: .invalidHexCharacter, offset: cursor)
      }
      nibbles.append(nibble)
      cursor += 1
    }
    var out: [UInt8] = []
    out.reserveCapacity((nibbles.count + 1) / 2)
    var index = 0
    while index < nibbles.count {
      let high = nibbles[index]
      let low = index + 1 < nibbles.count ? nibbles[index + 1] : 0
      out.append(high << 4 | low)
      index += 2
    }
    return COSScannedToken(token: .string(out), range: start..<cursor)
  }

  /// bare 키워드를 스캔한다. `true`/`false`/`null`은 값 토큰으로 즉시 변환한다.
  private func scanKeyword(start: Int) -> COSScannedToken {
    var end = start
    var runBytes: [UInt8] = []
    while let byte = self.file.byte(at: end), Self.isRegular(byte) {
      runBytes.append(byte)
      end += 1
    }
    let token = Self.keywordToken(for: Self.decodeName(runBytes))
    return COSScannedToken(token: token, range: start..<end)
  }
}
