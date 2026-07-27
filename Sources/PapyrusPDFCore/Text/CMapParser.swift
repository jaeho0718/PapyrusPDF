import Foundation

/// ToUnicode 매핑. 개별 항목 dict + 미전개 bfrange 목록의 이중 구조
/// (거대 range의 전개 폭탄 방지 — lo..hi를 dict로 펼치지 않는다).
package struct ToUnicodeMap: Sendable {
  /// `bfrange`의 문자열-목적지 형(오프셋 증분 규칙) — 미전개.
  struct RangeEntry: Sendable {
    let lo: UInt32
    let hi: UInt32
    let baseUTF16: [UInt16]
  }

  /// `bfchar` + 배열형 `bfrange`가 전개되어 들어간 개별 항목.
  private let singles: [UInt32: String]

  /// 문자열형 `bfrange` (미전개, 조회 시 오프셋 계산).
  private let ranges: [RangeEntry]

  /// 매핑을 생성한다.
  init(singles: [UInt32: String], ranges: [RangeEntry]) {
    self.singles = singles
    self.ranges = ranges
  }

  /// 코드에 대응하는 유니코드 문자열을 조회한다.
  /// - Parameter code: 원본 코드 값.
  /// - Returns: 매핑된 유니코드 문자열, 매핑 없으면 `nil`.
  package func unicode(for code: UInt32) -> String? {
    if let single = self.singles[code] {
      return single
    }
    for range in self.ranges where (range.lo...range.hi).contains(code) {
      guard let last = range.baseUTF16.last else {
        continue
      }
      var units = range.baseUTF16
      units[units.count - 1] = last &+ UInt16(truncatingIfNeeded: code - range.lo)
      return String(decoding: units, as: UTF16.self)
    }
    return nil
  }
}

/// 임베디드 CID CMap 해석 결과 (codespace + cid 매핑).
package struct EmbeddedCIDMap: Sendable {
  /// 코드스페이스 구간 하나 (고정 바이트 길이 클래스).
  fileprivate struct Codespace: Sendable {
    let byteLength: Int
    let lo: UInt32
    let hi: UInt32
  }

  /// `cidrange` 구간 하나.
  fileprivate struct CIDRangeEntry: Sendable {
    let byteLength: Int
    let lo: UInt32
    let hi: UInt32
    let cidLo: UInt32
  }

  /// `/WMode 1`(수직 쓰기) 여부.
  package let vertical: Bool

  private let codespaces: [Codespace]
  private let cidRanges: [CIDRangeEntry]
  private let cidSingles: [UInt32: UInt32]

  /// 임베디드 CID CMap을 생성한다.
  fileprivate init(
    vertical: Bool, codespaces: [Codespace], cidRanges: [CIDRangeEntry],
    cidSingles: [UInt32: UInt32]
  ) {
    self.vertical = vertical
    self.codespaces = codespaces
    self.cidRanges = cidRanges
    self.cidSingles = cidSingles
  }

  /// 커서 위치에서 코드스페이스에 부합하는 바이트 길이를 판정한다 (1~4바이트 순 시도).
  /// - Parameter bytes: 커서부터의 남은 바이트열.
  /// - Returns: 매칭된 바이트 길이, 부합하는 코드스페이스가 없으면 `nil`.
  package func matchByteLength(startingAt bytes: ArraySlice<UInt8>) -> Int? {
    for length in 1...4 {
      guard bytes.count >= length else {
        continue
      }
      let value = Self.bigEndianValue(bytes.prefix(length))
      let matches = self.codespaces.contains {
        $0.byteLength == length && ($0.lo...$0.hi).contains(value)
      }
      if matches {
        return length
      }
    }
    return nil
  }

  /// 코드(+원본 바이트 길이)에 대응하는 CID를 조회한다.
  /// - Parameters:
  ///   - code: 원본 코드 값.
  ///   - byteLength: 코드의 원본 바이트 길이 (`cidrange` 구간 매칭에 사용).
  /// - Returns: 매핑된 CID, 매핑 없으면 `nil`.
  package func cid(for code: UInt32, byteLength: Int) -> UInt32? {
    if let direct = self.cidSingles[code] {
      return direct
    }
    for range in self.cidRanges
    where range.byteLength == byteLength && (range.lo...range.hi).contains(code) {
      return range.cidLo + (code - range.lo)
    }
    return nil
  }

  private static func bigEndianValue(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }
}

/// CMap 텍스트(PostScript 유사 구문) 파서. COSLexer를 토크나이저로 재사용한다
/// (hex 문자열 `<..>`은 렉서가 바이트 배열로 반환 — 바이트 길이가 곧 코드 길이).
package enum CMapParser {
  /// ToUnicode CMap을 관용 파싱한다 — 어떤 입력에도 throw하지 않는다
  /// (오류 구간은 스킵, 엔트리 상한 `CoreLimits.maxCMapEntries` 도달 시 중단).
  /// - Parameter data: CMap 스트림 원문.
  /// - Returns: 파싱된 ToUnicode 매핑 (부분 결과 허용).
  package static func parseToUnicode(_ data: Data) -> ToUnicodeMap {
    var lexer = COSLexer(file: MappedFile(data: data))
    var singles: [UInt32: String] = [:]
    var ranges: [ToUnicodeMap.RangeEntry] = []
    var entryCount = 0

    while entryCount < CoreLimits.maxCMapEntries, let token = Self.nextResyncing(&lexer) {
      guard case let .keyword(.other(word)) = token.token else {
        continue
      }
      switch word {
      case "beginbfchar":
        Self.parseBFChar(&lexer, singles: &singles, entryCount: &entryCount)
      case "beginbfrange":
        Self.parseBFRange(&lexer, singles: &singles, ranges: &ranges, entryCount: &entryCount)
      default:
        continue
      }
    }
    return ToUnicodeMap(singles: singles, ranges: ranges)
  }

  /// 임베디드 CID CMap을 관용 파싱한다. codespace가 하나도 없으면 `nil`.
  /// - Parameter data: CMap 스트림 원문.
  /// - Returns: 파싱된 CID 매핑, codespace 부재 시 `nil`.
  package static func parseCIDMap(_ data: Data) -> EmbeddedCIDMap? {
    var lexer = COSLexer(file: MappedFile(data: data))
    var codespaces: [EmbeddedCIDMap.Codespace] = []
    var cidRanges: [EmbeddedCIDMap.CIDRangeEntry] = []
    var cidSingles: [UInt32: UInt32] = [:]
    var vertical = false
    var entryCount = 0

    while entryCount < CoreLimits.maxCMapEntries, let token = Self.nextResyncing(&lexer) {
      switch token.token {
      case .keyword(.other("begincodespacerange")):
        Self.parseCodespaceRange(&lexer, codespaces: &codespaces)
      case .keyword(.other("begincidrange")):
        Self.parseCIDRange(&lexer, cidRanges: &cidRanges, entryCount: &entryCount)
      case .keyword(.other("begincidchar")):
        Self.parseCIDChar(&lexer, cidSingles: &cidSingles, entryCount: &entryCount)
      case let .name(name) where name == .wMode:
        if let next = Self.nextResyncing(&lexer), case let .integer(value) = next.token {
          vertical = value == 1
        }
      default:
        continue
      }
    }
    guard !codespaces.isEmpty else {
      return nil
    }
    return EmbeddedCIDMap(
      vertical: vertical, codespaces: codespaces, cidRanges: cidRanges, cidSingles: cidSingles
    )
  }
}

// MARK: - 섹션 파서 (bfchar/bfrange/codespacerange/cidrange/cidchar)

extension CMapParser {
  private static func parseBFChar(
    _ lexer: inout COSLexer, singles: inout [UInt32: String], entryCount: inout Int
  ) {
    while entryCount < CoreLimits.maxCMapEntries, let token = Self.nextResyncing(&lexer) {
      if case .keyword(.other("endbfchar")) = token.token {
        return
      }
      guard case let .string(srcBytes) = token.token,
        let dstToken = Self.nextResyncing(&lexer), case let .string(dstBytes) = dstToken.token
      else {
        continue
      }
      let unicode = String(decoding: Self.bytesToUTF16(dstBytes), as: UTF16.self)
      singles[Self.bytesToCode(srcBytes)] = unicode
      entryCount += 1
    }
  }

  private static func parseBFRange(
    _ lexer: inout COSLexer, singles: inout [UInt32: String],
    ranges: inout [ToUnicodeMap.RangeEntry], entryCount: inout Int
  ) {
    while entryCount < CoreLimits.maxCMapEntries, let token = Self.nextResyncing(&lexer) {
      if case .keyword(.other("endbfrange")) = token.token {
        return
      }
      guard case let .string(loBytes) = token.token,
        let hiToken = Self.nextResyncing(&lexer), case let .string(hiBytes) = hiToken.token,
        let dstToken = Self.nextResyncing(&lexer)
      else {
        continue
      }
      let lo = Self.bytesToCode(loBytes)
      let hi = Self.bytesToCode(hiBytes)
      switch dstToken.token {
      case let .string(dstBytes):
        // 역전된 범위(lo > hi)는 손상·적대적 입력이다 — ClosedRange 생성 크래시를 피하기
        // 위해 항목 자체를 스킵한다(가정 4의 "손상 세그먼트는 스킵" 관용 규칙 연장).
        guard lo <= hi else {
          continue
        }
        let entry = ToUnicodeMap.RangeEntry(lo: lo, hi: hi, baseUTF16: Self.bytesToUTF16(dstBytes))
        ranges.append(entry)
        entryCount += 1
      case .arrayOpen:
        Self.parseBFRangeArray(&lexer, lo: lo, singles: &singles, entryCount: &entryCount)
      default:
        continue
      }
    }
  }

  /// `[<d0> <d1> ...]` 배열형 목적지 — 원소 개수만큼 이미 file에 기재되어 있으므로 전개해도
  /// 폭탄이 아니다.
  private static func parseBFRangeArray(
    _ lexer: inout COSLexer, lo: UInt32, singles: inout [UInt32: String], entryCount: inout Int
  ) {
    var code = lo
    while entryCount < CoreLimits.maxCMapEntries, let token = Self.nextResyncing(&lexer) {
      if case .arrayClose = token.token {
        return
      }
      guard case let .string(elementBytes) = token.token else {
        continue
      }
      singles[code] = String(decoding: Self.bytesToUTF16(elementBytes), as: UTF16.self)
      entryCount += 1
      code += 1
    }
  }

  private static func parseCodespaceRange(
    _ lexer: inout COSLexer, codespaces: inout [EmbeddedCIDMap.Codespace]
  ) {
    while let token = Self.nextResyncing(&lexer) {
      if case .keyword(.other("endcodespacerange")) = token.token {
        return
      }
      guard case let .string(loBytes) = token.token,
        let hiToken = Self.nextResyncing(&lexer), case let .string(hiBytes) = hiToken.token
      else {
        continue
      }
      let lo = Self.bytesToCode(loBytes)
      let hi = Self.bytesToCode(hiBytes)
      // 역전된 범위는 손상·적대적 입력 — ClosedRange 생성 크래시를 피하기 위해 스킵.
      guard lo <= hi else {
        continue
      }
      codespaces.append(EmbeddedCIDMap.Codespace(byteLength: loBytes.count, lo: lo, hi: hi))
    }
  }

  private static func parseCIDRange(
    _ lexer: inout COSLexer, cidRanges: inout [EmbeddedCIDMap.CIDRangeEntry], entryCount: inout Int
  ) {
    while entryCount < CoreLimits.maxCMapEntries, let token = Self.nextResyncing(&lexer) {
      if case .keyword(.other("endcidrange")) = token.token {
        return
      }
      guard case let .string(loBytes) = token.token,
        let hiToken = Self.nextResyncing(&lexer), case let .string(hiBytes) = hiToken.token,
        let cidToken = Self.nextResyncing(&lexer), case let .integer(cidValue) = cidToken.token,
        cidValue >= 0
      else {
        continue
      }
      let lo = Self.bytesToCode(loBytes)
      let hi = Self.bytesToCode(hiBytes)
      // 역전된 범위는 손상·적대적 입력 — ClosedRange 생성 크래시를 피하기 위해 스킵.
      guard lo <= hi else {
        continue
      }
      cidRanges.append(EmbeddedCIDMap.CIDRangeEntry(
        byteLength: loBytes.count, lo: lo, hi: hi, cidLo: UInt32(cidValue)
      ))
      entryCount += 1
    }
  }

  private static func parseCIDChar(
    _ lexer: inout COSLexer, cidSingles: inout [UInt32: UInt32], entryCount: inout Int
  ) {
    while entryCount < CoreLimits.maxCMapEntries, let token = Self.nextResyncing(&lexer) {
      if case .keyword(.other("endcidchar")) = token.token {
        return
      }
      guard case let .string(codeBytes) = token.token,
        let cidToken = Self.nextResyncing(&lexer), case let .integer(cidValue) = cidToken.token,
        cidValue >= 0
      else {
        continue
      }
      cidSingles[Self.bytesToCode(codeBytes)] = UInt32(cidValue)
      entryCount += 1
    }
  }
}

// MARK: - 공용 헬퍼 (토큰 재동기화, 바이트 변환)

extension CMapParser {
  /// 렉서 에러를 1바이트 전진으로 재동기화하며 다음 토큰을 얻는다 (커서 단조 증가 —
  /// 종료 보장). EOF면 `nil`.
  private static func nextResyncing(_ lexer: inout COSLexer) -> COSScannedToken? {
    while true {
      do {
        return try lexer.nextToken()
      } catch {
        lexer.seek(to: lexer.offset + 1)
      }
    }
  }

  /// 바이트열을 빅엔디언 정수로 해석한다 (코드값·CID 공용).
  private static func bytesToCode(_ bytes: [UInt8]) -> UInt32 {
    bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  /// 바이트열을 UTF-16BE 코드유닛 배열로 해석한다 (홀수 꼬리 바이트는 관용적으로 하위
  /// 바이트 단독 유닛으로 취급).
  private static func bytesToUTF16(_ bytes: [UInt8]) -> [UInt16] {
    var units: [UInt16] = []
    var index = 0
    while index + 1 < bytes.count {
      units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
      index += 2
    }
    if index < bytes.count {
      units.append(UInt16(bytes[index]))
    }
    return units.isEmpty ? [0xFFFD] : units
  }
}
