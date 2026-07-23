/// 클래식 `xref` 테이블 파서. 20바이트 고정폭을 강제하지 않는 관용 행 스캐너다
/// (19/21바이트 허용).
package struct XRefTableParser: Sendable {
  /// 파싱 대상 바이트 소스.
  private let file: MappedFile

  /// 파서를 생성한다.
  /// - Parameter file: 파싱 대상 바이트 소스.
  package init(file: MappedFile) {
    self.file = file
  }

  /// `xref` 키워드가 시작하는 오프셋에서 서브섹션들과 trailer 딕셔너리를 파싱한다.
  /// - Parameter offset: `xref` 키워드가 시작하는 절대 바이트 오프셋.
  /// - Returns: 파싱된 섹션 + 축적 경고.
  /// - Throws: 구조 복원이 불가능하면 ``XRefError``.
  package func parseSection(
    at offset: Int
  ) throws(XRefError) -> (section: XRefSection, warnings: [CoreOpenWarning]) {
    var lexer = COSLexer(file: self.file, offset: offset)
    guard let keywordToken = Self.nextTokenOrNil(&lexer), case .keyword(.xref) = keywordToken.token
    else {
      throw XRefError(code: .notAnXRefSection, offset: offset)
    }

    var entries: [Int: XRefEntry] = [:]
    var warnings: [CoreOpenWarning] = []
    var totalEntryCount = 0

    while let header = try Self.parseSubsectionHeader(lexer: &lexer) {
      totalEntryCount += header.count
      guard totalEntryCount <= CoreLimits.maxXRefEntries else {
        throw XRefError(code: .entryCountTooLarge, offset: lexer.offset)
      }
      try self.scanSubsection(
        start: header.start, count: header.count, lexer: &lexer, entries: &entries,
        warnings: &warnings
      )
    }

    let trailerDict = try self.parseTrailer(at: lexer.offset, warnings: &warnings)
    let section = XRefSection(
      entries: entries, trailer: trailerDict,
      previousOffset: trailerDict.integer(for: .prev),
      xrefStreamOffset: trailerDict.integer(for: .xRefStm)
    )
    return (section, warnings)
  }

  /// 다음 서브섹션 헤더(`"start count"`)를 읽는다. `trailer` 키워드를 만나면 `nil`(종료 신호).
  private static func parseSubsectionHeader(
    lexer: inout COSLexer
  ) throws(XRefError) -> (start: Int, count: Int)? {
    guard let peeked = Self.nextTokenOrNil(&lexer) else {
      throw XRefError(code: .missingTrailer, offset: lexer.offset)
    }
    if case .keyword(.trailer) = peeked.token {
      return nil
    }
    guard case let .integer(start) = peeked.token else {
      throw XRefError(code: .missingTrailer, offset: peeked.range.lowerBound)
    }
    guard let countToken = Self.nextTokenOrNil(&lexer), case let .integer(count) = countToken.token
    else {
      throw XRefError(code: .invalidSubsectionHeader, offset: lexer.offset)
    }
    guard start >= 0, count >= 0 else {
      throw XRefError(code: .invalidSubsectionHeader, offset: peeked.range.lowerBound)
    }
    let (_, overflowed) = start.addingReportingOverflow(count)
    guard !overflowed else {
      throw XRefError(code: .invalidSubsectionHeader, offset: peeked.range.lowerBound)
    }
    return (start, count)
  }

  /// 서브섹션의 `count`개 행을 관용 스캐너로 읽어 `entries`를 채운다.
  private func scanSubsection(
    start: Int, count: Int, lexer: inout COSLexer,
    entries: inout [Int: XRefEntry], warnings: inout [CoreOpenWarning]
  ) throws(XRefError) {
    var cursor = lexer.offset
    for relativeIndex in 0..<count {
      let objectNumber = start + relativeIndex
      let row = try self.scanRow(objectNumber: objectNumber, cursor: &cursor)
      if row.rowWidth != 20 {
        warnings.append(.malformedXRefRow(offset: row.rowStart))
      }
      if let entry = row.entry {
        entries[objectNumber] = entry
      }
    }
    lexer.seek(to: cursor)
  }

  /// `trailer` 키워드 직후 오프셋에서 트레일러 딕셔너리를 파싱한다.
  private func parseTrailer(
    at offset: Int, warnings: inout [CoreOpenWarning]
  ) throws(XRefError) -> COSDictionary {
    var parser = COSParser(file: self.file)
    let parsed: COSObject
    do {
      parsed = try parser.parseObject(at: offset)
    } catch {
      throw XRefError(code: .missingTrailer, offset: offset)
    }
    warnings.append(contentsOf: parser.warnings.map(CoreOpenWarning.parse))
    guard case let .dictionary(dictionary) = parsed else {
      throw XRefError(code: .missingTrailer, offset: offset)
    }
    return dictionary
  }

  /// 다음 토큰을 시도한다. 렉싱 에러는 `nil`로 뭉갠다 — 호출부가 문맥에 맞는
  /// ``XRefError`` 코드로 승격한다.
  private static func nextTokenOrNil(_ lexer: inout COSLexer) -> COSScannedToken? {
    (try? lexer.nextToken()) ?? nil
  }
}

// MARK: - 관용 행 스캐너

extension XRefTableParser {
  /// 관용 행 스캐너 한 줄의 결과.
  private struct RowScanResult {
    /// 파싱된 엔트리 (객체 0 헤드는 `nil`).
    let entry: XRefEntry?
    /// 행의 시작 오프셋 (선행 공백 스킵 후).
    let rowStart: Int
    /// 행의 실측 폭 (경고 판정용).
    let rowWidth: Int
  }

  /// 엔트리 한 줄을 관용적으로 스캔한다 (19/20/21바이트 대응).
  /// - Parameters:
  ///   - objectNumber: 이 행이 속한 객체 번호.
  ///   - cursor: 스캔 시작 오프셋(입력) / 스캔 종료 오프셋(출력, in-out).
  /// - Throws: 구조 복원 불가 시 ``XRefError/Code/malformedEntry``.
  private func scanRow(
    objectNumber: Int, cursor: inout Int
  ) throws(XRefError) -> RowScanResult {
    cursor = self.skipWhitespace(from: cursor)
    let rowStart = cursor
    guard let (offsetValue, afterOffset) = self.scanDigitRun(from: cursor),
      afterOffset - rowStart <= 10
    else {
      throw XRefError(code: .malformedEntry, offset: rowStart)
    }
    cursor = self.skipWhitespace(from: afterOffset)
    guard let (generationValue, afterGeneration) = self.scanDigitRun(from: cursor) else {
      throw XRefError(code: .malformedEntry, offset: rowStart)
    }
    cursor = self.skipWhitespace(from: afterGeneration)
    guard let typeByte = self.file.byte(at: cursor),
      typeByte == UInt8(ascii: "n") || typeByte == UInt8(ascii: "f")
    else {
      throw XRefError(code: .malformedEntry, offset: rowStart)
    }
    let rowEnd = self.skipWhitespace(from: cursor + 1)
    let entry: XRefEntry? = objectNumber == 0
      ? nil
      : (typeByte == UInt8(ascii: "n")
        ? .uncompressed(offset: offsetValue, generation: generationValue)
        : .free)
    cursor = rowEnd
    return RowScanResult(entry: entry, rowStart: rowStart, rowWidth: rowEnd - rowStart)
  }

  /// PDF 화이트스페이스 바이트 런을 건너뛴 위치를 반환한다.
  private func skipWhitespace(from start: Int) -> Int {
    var cursor = start
    while let byte = self.file.byte(at: cursor), COSLexer.isWhitespace(byte) {
      cursor += 1
    }
    return cursor
  }

  /// 십진 자릿수 런을 스캔한다. 자릿수 0개면 `nil`.
  private func scanDigitRun(from start: Int) -> (value: Int, next: Int)? {
    var cursor = start
    var value = 0
    var digitCount = 0
    while let byte = self.file.byte(at: cursor), (0x30...0x39).contains(byte) {
      value = value * 10 + Int(byte - 0x30)
      cursor += 1
      digitCount += 1
    }
    guard digitCount > 0 else {
      return nil
    }
    return (value, cursor)
  }
}
