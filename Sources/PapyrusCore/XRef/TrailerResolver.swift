/// 문서 열기의 xref 단계 전체를 지휘한다: 헤더 검증 → startxref 탐색 → /Prev 체인 로드
/// → 병합 → 검증 → 실패 시 ``RecoveryScanner`` 폴백.
///
/// 순수 동기 타입 — 액터 밖(열기 태스크)에서 실행되고, 결과는 불변 값으로 액터에 주입된다.
package struct TrailerResolver: Sendable {
  /// 열기 단계의 최종 산출물.
  package struct Resolution: Sendable {
    /// 병합 완료된 xref 테이블 (+병합 트레일러).
    package let table: XRefTable
    /// 헤더에서 읽은 버전 (형식 위반 시 1.4 폴백 + 경고).
    package let version: PDFVersion
    /// 헤더 앞 정크 바이트 수 (== 파일 내 `%PDF` 시작 오프셋). 오프셋 보정에 사용됨.
    package let headerOffset: Int
    /// 축적된 열기 경고. 복구 스캔이 개입했다면 그 사실이 반드시 포함된다.
    package let warnings: [OpenWarning]

    /// 산출물을 생성한다.
    /// - Parameters:
    ///   - table: 병합 완료된 xref 테이블.
    ///   - version: 헤더에서 읽은 버전.
    ///   - headerOffset: 헤더 앞 정크 바이트 수.
    ///   - warnings: 축적된 열기 경고.
    package init(
      table: XRefTable, version: PDFVersion, headerOffset: Int, warnings: [OpenWarning]
    ) {
      self.table = table
      self.version = version
      self.headerOffset = headerOffset
      self.warnings = warnings
    }
  }

  /// 파싱 대상 바이트 소스.
  private let file: MappedFile

  /// 리졸버를 생성한다.
  /// - Parameter file: 파싱 대상 바이트 소스.
  package init(file: MappedFile) {
    self.file = file
  }

  /// 열기 플로우를 수행한다. "경고하되 실패하지 않는" 자세 — 복구 스캔까지 전부 실패해
  /// /Root를 확정할 수 없을 때만 throw.
  ///
  /// `/Encrypt` 검사는 여기서 하지 않는다 — 호출자(`PDFDocumentCore.open`)의 소관 (§3.6).
  /// - Throws: ``DocumentOpenError`` (`notAPDF` / `damagedBeyondRecovery`).
  /// - Returns: 열기 단계의 최종 산출물.
  package func resolve() throws(DocumentOpenError) -> Resolution {
    var warnings: [OpenWarning] = []

    guard let headerOffset = Self.locateHeader(file: self.file) else {
      throw DocumentOpenError.notAPDF
    }
    if headerOffset > 0 {
      warnings.append(.junkBeforeHeader(byteCount: headerOffset))
    }
    let version = Self.parseVersion(
      file: self.file, headerOffset: headerOffset, warnings: &warnings
    )

    if !Self.hasEOFMarker(file: self.file) {
      warnings.append(.missingEOFMarker)
    }

    guard let startxrefValue = Self.findStartxrefValue(file: self.file) else {
      warnings.append(.invalidStartxref)
      return try Self.recover(
        file: self.file, version: version, headerOffset: headerOffset, priorWarnings: warnings
      )
    }

    let chain = Self.loadChain(
      startOffset: startxrefValue, file: self.file, headerOffset: headerOffset
    )
    warnings.append(contentsOf: chain.warnings)

    let rootValidated = Self.validateRoot(table: chain.table, file: self.file)
    guard !chain.table.entries.isEmpty, rootValidated else {
      return try Self.recover(
        file: self.file, version: version, headerOffset: headerOffset, priorWarnings: warnings
      )
    }

    return Resolution(
      table: chain.table, version: version, headerOffset: headerOffset, warnings: warnings
    )
  }

  /// 복구 스캔으로 폴백한다. 실패하면 `.damagedBeyondRecovery`.
  private static func recover(
    file: MappedFile, version: PDFVersion, headerOffset: Int, priorWarnings: [OpenWarning]
  ) throws(DocumentOpenError) -> Resolution {
    guard let rebuild = RecoveryScanner(file: file).rebuild() else {
      throw DocumentOpenError.damagedBeyondRecovery
    }
    var warnings = priorWarnings
    warnings.append(contentsOf: rebuild.warnings)
    return Resolution(
      table: rebuild.table, version: version, headerOffset: headerOffset, warnings: warnings
    )
  }
}

// MARK: - 헤더 파싱

extension TrailerResolver {
  /// 앞 ``CoreLimits/headerScanWindow`` 바이트에서 `%PDF-` 바이트열을 탐색한다.
  private static func locateHeader(file: MappedFile) -> Int? {
    let pattern = Array("%PDF-".utf8)
    let searchLimit = min(file.count, CoreLimits.headerScanWindow)
    guard searchLimit >= pattern.count else {
      return nil
    }
    for offset in 0...(searchLimit - pattern.count)
    where Self.matches(file: file, pattern: pattern, at: offset) {
      return offset
    }
    return nil
  }

  /// `%PDF-M.N` 버전을 파싱한다. 위반 시 1.4로 폴백하고 경고를 남긴다.
  private static func parseVersion(
    file: MappedFile, headerOffset: Int, warnings: inout [OpenWarning]
  ) -> PDFVersion {
    let start = headerOffset + 5
    guard let (major, afterMajor) = Self.scanShortDigitRun(file: file, from: start),
      file.byte(at: afterMajor) == UInt8(ascii: "."),
      let (minor, _) = Self.scanShortDigitRun(file: file, from: afterMajor + 1)
    else {
      warnings.append(.malformedVersion)
      return PDFVersion(major: 1, minor: 4)
    }
    return PDFVersion(major: major, minor: minor)
  }

  /// 1~2자리 십진 자릿수 런을 스캔한다. 자릿수가 0개거나 3개 이상이면 `nil`.
  private static func scanShortDigitRun(
    file: MappedFile, from start: Int
  ) -> (value: Int, next: Int)? {
    var cursor = start
    var value = 0
    var count = 0
    while let byte = file.byte(at: cursor), (0x30...0x39).contains(byte) {
      value = value * 10 + Int(byte - 0x30)
      cursor += 1
      count += 1
    }
    guard (1...2).contains(count) else {
      return nil
    }
    return (value, cursor)
  }

  /// 파일 말미 ``CoreLimits/startxrefScanWindow`` 바이트 안에 `%%EOF`가 있는지 확인한다.
  private static func hasEOFMarker(file: MappedFile) -> Bool {
    let pattern = Array("%%EOF".utf8)
    let windowStart = max(0, file.count - CoreLimits.startxrefScanWindow)
    var offset = file.count - pattern.count
    while offset >= windowStart {
      if Self.matches(file: file, pattern: pattern, at: offset) {
        return true
      }
      offset -= 1
    }
    return false
  }

  /// 파일 말미 ``CoreLimits/startxrefScanWindow`` 바이트를 역방향 스캔해 `startxref`
  /// 최후 출현 뒤의 정수를 읽는다. 부재/정수 아님/음수면 `nil`.
  private static func findStartxrefValue(file: MappedFile) -> Int? {
    let pattern = Array("startxref".utf8)
    let windowStart = max(0, file.count - CoreLimits.startxrefScanWindow)
    var offset = file.count - pattern.count
    while offset >= windowStart {
      if Self.matches(file: file, pattern: pattern, at: offset) {
        return Self.readTrailingInteger(file: file, after: offset + pattern.count)
      }
      offset -= 1
    }
    return nil
  }

  /// `position`부터 공백을 건너뛰고 정수 토큰 하나를 읽는다. 실패·음수면 `nil`.
  private static func readTrailingInteger(file: MappedFile, after position: Int) -> Int? {
    var lexer = COSLexer(file: file, offset: position)
    guard let token = (try? lexer.nextToken()) ?? nil, case let .integer(value) = token.token,
      value >= 0
    else {
      return nil
    }
    return value
  }

  /// `offset`에 `pattern` 바이트열이 정확히 놓여 있는지 검사한다.
  private static func matches(file: MappedFile, pattern: [UInt8], at offset: Int) -> Bool {
    guard let bytes = file.bytes(in: offset..<(offset + pattern.count)) else {
      return false
    }
    return Array(bytes) == pattern
  }
}

// MARK: - /Prev 체인 로드

extension TrailerResolver {
  /// 섹션 파싱 시도 결과 (bias 재시도 게이팅용).
  private enum SectionAttempt {
    /// 성공.
    case success(section: XRefSection, warnings: [OpenWarning])
    /// 두 파서 모두 "xref 섹션 자체가 아님"으로 실패 — bias 재시도 대상.
    case notRecognized
    /// 섹션으로 인식은 됐으나 내부 구조가 깨짐 — bias 재시도 무의미.
    case malformed
  }

  /// 오프셋 bias 발견 상태 (§3.2.1). 원 오프셋 실패 시 `+headerOffset` 1회 재시도로 확정된다.
  private struct BiasState {
    /// 확정된 bias 값 (기본 0 — 미발견).
    var value = 0
    /// bias가 이미 확정되었는지 여부 (확정 후에는 재시도하지 않는다).
    var applied = false
  }

  /// `/Prev` 체인을 순회하며 로드한다. 순환·상한·중간 실패를 부분 수용 규칙으로 처리한다.
  private static func loadChain(
    startOffset: Int, file: MappedFile, headerOffset: Int
  ) -> (table: XRefTable, warnings: [OpenWarning]) {
    var visited: Set<Int> = []
    var biasState = BiasState()
    var sectionsProcessed = 0
    var warnings: [OpenWarning] = []
    var collectedSections: [XRefSection] = []
    var pending: Int? = startOffset
    var recoveryNeeded = false

    while let rawOffset = pending {
      sectionsProcessed += 1
      guard sectionsProcessed <= CoreLimits.maxXRefSections else {
        warnings.append(.xrefChainTruncated)
        break
      }
      guard !visited.contains(rawOffset) else {
        warnings.append(.xrefChainCycle(offset: rawOffset))
        break
      }
      visited.insert(rawOffset)

      guard let parsed = Self.parseSectionWithBias(
        rawOffset: rawOffset, file: file, headerOffset: headerOffset,
        biasState: &biasState, warnings: &warnings
      ) else {
        if collectedSections.isEmpty {
          recoveryNeeded = true
        } else {
          warnings.append(.xrefSectionUnreadable(offset: rawOffset))
        }
        break
      }

      switch Self.hybridStreamOutcome(
        for: parsed, bias: biasState.value, visited: &visited, file: file
      ) {
      case .none:
        break
      case let .found(streamSection, streamWarnings):
        collectedSections.append(streamSection)
        warnings.append(contentsOf: streamWarnings)
      case let .unreadable(warning):
        warnings.append(warning)
      }

      collectedSections.append(parsed)
      pending = parsed.previousOffset
    }

    guard !recoveryNeeded else {
      return (XRefTable(), warnings)
    }
    let table = Self.mergeAllSections(
      collectedSections, bias: biasState.value, fileCount: file.count, warnings: &warnings
    )
    return (table, warnings)
  }

  /// 하이브리드 짝 `/XRefStm` 처리 결과.
  private enum HybridStreamOutcome {
    /// `/XRefStm` 없음 또는 이미 방문함.
    case none
    /// 파싱 성공 — 클래식보다 먼저 병합 순서에 넣어야 한다.
    case found(section: XRefSection, warnings: [OpenWarning])
    /// 파싱 실패 — 클래식 쪽이 있으므로 치명적이지 않다.
    case unreadable(warning: OpenWarning)
  }

  /// 하이브리드 짝의 `/XRefStm`을 시도한다 (클래식 섹션보다 먼저 병합해야 하므로 분리 처리).
  private static func hybridStreamOutcome(
    for section: XRefSection, bias: Int, visited: inout Set<Int>, file: MappedFile
  ) -> HybridStreamOutcome {
    guard let rawStreamOffset = section.xrefStreamOffset, !visited.contains(rawStreamOffset) else {
      return .none
    }
    visited.insert(rawStreamOffset)
    let actualStreamOffset = rawStreamOffset + bias
    guard case let .success(streamSection, streamWarnings) = Self.parseAnySection(
      at: actualStreamOffset, file: file
    ) else {
      return .unreadable(warning: .xrefSectionUnreadable(offset: actualStreamOffset))
    }
    return .found(section: streamSection, warnings: streamWarnings)
  }

  /// 수집된 섹션들을 최신 → 과거 순으로 병합해 최종 테이블을 만든다.
  private static func mergeAllSections(
    _ sections: [XRefSection], bias: Int, fileCount: Int, warnings: inout [OpenWarning]
  ) -> XRefTable {
    var table = XRefTable()
    for section in sections {
      let validated = Self.biasedAndValidated(
        section, bias: bias, fileCount: fileCount, warnings: &warnings
      )
      table.mergeSection(validated)
    }
    return table
  }

  /// 원 오프셋으로 먼저 시도하고, "섹션이 아님"으로 실패했으며 아직 bias가 미적용이면
  /// `+headerOffset`으로 1회 재시도한다 (§3.2.1).
  private static func parseSectionWithBias(
    rawOffset: Int, file: MappedFile, headerOffset: Int,
    biasState: inout BiasState, warnings: inout [OpenWarning]
  ) -> XRefSection? {
    let primaryAttempt = Self.parseAnySection(at: rawOffset + biasState.value, file: file)
    if case let .success(section, sectionWarnings) = primaryAttempt {
      warnings.append(contentsOf: sectionWarnings)
      return section
    }
    guard case .notRecognized = primaryAttempt, !biasState.applied, headerOffset > 0 else {
      return nil
    }
    guard case let .success(section, sectionWarnings) = Self.parseAnySection(
      at: rawOffset + headerOffset, file: file
    ) else {
      return nil
    }
    biasState.value = headerOffset
    biasState.applied = true
    warnings.append(.xrefOffsetsBiased(by: headerOffset))
    warnings.append(contentsOf: sectionWarnings)
    return section
  }

  /// 클래식 테이블 파서를 먼저 시도하고, "섹션이 아님"으로 실패하면 스트림 파서를 시도한다.
  private static func parseAnySection(at offset: Int, file: MappedFile) -> SectionAttempt {
    do {
      let result = try XRefTableParser(file: file).parseSection(at: offset)
      return .success(section: result.section, warnings: result.warnings)
    } catch {
      guard error.code == .notAnXRefSection else {
        return .malformed
      }
    }
    do {
      let result = try XRefStreamParser(file: file).parseSection(at: offset)
      return .success(section: result.section, warnings: result.warnings)
    } catch {
      return error.code == .notAnXRefSection ? .notRecognized : .malformed
    }
  }

  /// 섹션의 `.uncompressed` 엔트리에 최종 bias를 반영하고, 파일 범위 밖 오프셋을 폐기한다.
  private static func biasedAndValidated(
    _ section: XRefSection, bias: Int, fileCount: Int, warnings: inout [OpenWarning]
  ) -> XRefSection {
    var validated: [Int: XRefEntry] = [:]
    validated.reserveCapacity(section.entries.count)
    for (number, entry) in section.entries {
      guard case let .uncompressed(offset, generation) = entry else {
        validated[number] = entry
        continue
      }
      let actualOffset = offset + bias
      guard actualOffset >= 0, actualOffset < fileCount else {
        warnings.append(.entryOutOfBounds(objectNumber: number))
        continue
      }
      validated[number] = .uncompressed(offset: actualOffset, generation: generation)
    }
    var updated = section
    updated.entries = validated
    return updated
  }
}
