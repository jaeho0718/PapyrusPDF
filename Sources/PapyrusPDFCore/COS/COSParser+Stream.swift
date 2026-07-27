// COSParser의 스트림 조립 로직. 파일 분리는 순수 조직적 이유(파일 길이 제한)이며
// 타입·의미는 `COSParser.swift`와 동일하다.

// MARK: - 스트림 조립

extension COSParser {
  /// `endstream` 키워드 바이트열.
  private static let endstreamKeyword: [UInt8] = Array("endstream".utf8)

  /// PDF 화이트스페이스 바이트(NUL·TAB·LF·FF·CR·SP) 여부.
  private static func isStreamWhitespace(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20:
      return true
    default:
      return false
    }
  }

  /// 파싱된 값이 딕셔너리이고 직후 `stream` 키워드가 있으면 스트림으로 승격한다.
  /// 없으면 lookahead를 복원하고 원래 값을 그대로 반환한다.
  ///
  /// `COSParser.swift`(다른 파일)의 `parseIndirectObject`가 호출하므로 `internal`이다.
  mutating func attachStreamIfPresent(
    value: COSObject, id: ObjectID, lexer: inout COSLexer
  ) throws(COSParseError) -> COSObject {
    guard case let .dictionary(dictionary) = value else {
      return value
    }
    let checkpoint = lexer
    guard
      let scanned = (try? lexer.nextToken()) ?? nil, case .keyword(.stream) = scanned.token
    else {
      lexer = checkpoint
      return value
    }
    let stream = try self.makeStream(
      dictionary: dictionary, id: id, streamKeywordRange: scanned.range, lexer: &lexer
    )
    return .stream(stream)
  }

  /// `stream` 키워드 이후 EOL·`/Length`·`endstream`을 처리해 페이로드 위치를 확정한다.
  private mutating func makeStream(
    dictionary: COSDictionary, id: ObjectID, streamKeywordRange: Range<Int>, lexer: inout COSLexer
  ) throws(COSParseError) -> COSStream {
    let dataStart = self.consumeStreamEOL(from: streamKeywordRange.upperBound)
    let declared = try self.declaredLength(dictionary: dictionary, fallbackOffset: dataStart)

    // declared는 신뢰할 수 없는 외부 입력(/Length)이라 Int.max급 값이 올 수 있다 —
    // overflow-checked 덧셈으로 계산하고, 오버플로하면 선언을 무시하고 스캔 폴백으로
    // 떨어뜨린다("크래시 금지" 원칙; 아래 6줄부터의 폴백 경로가 그대로 이를 처리한다).
    if let declared, declared >= 0 {
      let (candidateEnd, overflowed) = dataStart.addingReportingOverflow(declared)
      if !overflowed, candidateEnd <= self.file.count, self.matchesEndstream(after: candidateEnd) {
        lexer.seek(to: self.endstreamKeywordEnd(after: candidateEnd))
        return COSStream(dictionary: dictionary, payload: .fileRange(dataStart..<candidateEnd))
      }
    }

    guard let found = self.scanForEndstream(from: dataStart) else {
      throw COSParseError(code: .missingEndstream, offset: dataStart)
    }
    self.warnings.append(
      .streamLengthMismatch(id: id, declared: declared, actual: found.payloadEnd - dataStart)
    )
    lexer.seek(to: found.keywordEnd)
    return COSStream(dictionary: dictionary, payload: .fileRange(dataStart..<found.payloadEnd))
  }

  /// `stream` 키워드 직후 EOL을 소비한다. CRLF·LF는 표준, CR 단독·EOL 부재는 경고와
  /// 함께 수용한다(둘 다 `nonstandardStreamEOL`로 보고 — 손상 파일에서 관찰 가능한
  /// 신호를 남겨야 한다는 것 외에 세부 코드를 구분할 실익이 없다).
  private mutating func consumeStreamEOL(from eolStart: Int) -> Int {
    switch (self.file.byte(at: eolStart), self.file.byte(at: eolStart + 1)) {
    case (0x0D, 0x0A):
      return eolStart + 2
    case (0x0A, _):
      return eolStart + 1
    case (0x0D, _):
      self.warnings.append(.nonstandardStreamEOL(offset: eolStart))
      return eolStart + 1
    default:
      self.warnings.append(.nonstandardStreamEOL(offset: eolStart))
      return eolStart
    }
  }

  /// `/Length` 값을 결정한다. 정수면 그대로, 간접 참조면 resolver로 해소한다.
  private func declaredLength(
    dictionary: COSDictionary, fallbackOffset: Int
  ) throws(COSParseError) -> Int? {
    guard let lengthObject = dictionary[.length] else {
      return nil
    }
    switch lengthObject {
    case let .integer(value):
      return value
    case let .reference(id):
      guard let resolver = self.lengthResolver else {
        return nil
      }
      do {
        return try resolver(id)
      } catch {
        throw COSParseError(code: .lengthResolutionFailed, offset: fallbackOffset)
      }
    default:
      return nil
    }
  }

  /// `position`에서 화이트스페이스를 건너뛴 뒤 `endstream` 키워드가 나타나는지 확인한다.
  private func matchesEndstream(after position: Int) -> Bool {
    self.hasEndstreamKeyword(at: self.skipStreamWhitespace(from: position))
  }

  /// `position`에서 화이트스페이스를 건너뛴 `endstream` 키워드 직후 오프셋.
  private func endstreamKeywordEnd(after position: Int) -> Int {
    self.skipStreamWhitespace(from: position) + Self.endstreamKeyword.count
  }

  /// 지정 위치에 `endstream` 바이트열이 정확히 놓여 있는지 검사한다.
  private func hasEndstreamKeyword(at position: Int) -> Bool {
    let range = position..<(position + Self.endstreamKeyword.count)
    guard let bytes = self.file.bytes(in: range) else {
      return false
    }
    return Array(bytes) == Self.endstreamKeyword
  }

  /// PDF 화이트스페이스 바이트 런을 건너뛴 위치를 반환한다.
  private func skipStreamWhitespace(from position: Int) -> Int {
    var cursor = position
    while let byte = self.file.byte(at: cursor), Self.isStreamWhitespace(byte) {
      cursor += 1
    }
    return cursor
  }

  /// `dataStart`부터 `endstream` 최초 출현을 전방 선형 탐색한다 (상한 = 파일 끝).
  /// - Returns: 발견 시 (후행 EOL 제거된 페이로드 끝, 키워드 직후 오프셋). 미발견이면 `nil`.
  private func scanForEndstream(from dataStart: Int) -> (payloadEnd: Int, keywordEnd: Int)? {
    let limit = self.file.count - Self.endstreamKeyword.count
    var cursor = dataStart
    while cursor <= limit {
      if self.hasEndstreamKeyword(at: cursor) {
        let keywordEnd = cursor + Self.endstreamKeyword.count
        let payloadEnd = self.trimTrailingEOL(before: cursor, from: dataStart)
        return (payloadEnd, keywordEnd)
      }
      cursor += 1
    }
    return nil
  }

  /// `endstream` 직전의 후행 EOL(CRLF|LF|CR) 1개를 제거한 위치를 반환한다.
  private func trimTrailingEOL(before endstreamStart: Int, from dataStart: Int) -> Int {
    guard endstreamStart > dataStart else {
      return endstreamStart
    }
    let last = endstreamStart - 1
    if self.file.byte(at: last) == 0x0A {
      if last > dataStart, self.file.byte(at: last - 1) == 0x0D {
        return last - 1
      }
      return last
    }
    if self.file.byte(at: last) == 0x0D {
      return last
    }
    return endstreamStart
  }

  /// `endobj` 키워드를 소비한다. 없으면 lookahead를 복원하고 경고만 남긴다.
  ///
  /// `COSParser.swift`(다른 파일)의 `parseIndirectObject`가 호출하므로 `internal`이다.
  mutating func consumeEndobj(id: ObjectID, lexer: inout COSLexer) {
    let checkpoint = lexer
    guard
      let scanned = (try? lexer.nextToken()) ?? nil, case .keyword(.endobj) = scanned.token
    else {
      lexer = checkpoint
      self.warnings.append(.missingEndobj(id: id))
      return
    }
  }
}
