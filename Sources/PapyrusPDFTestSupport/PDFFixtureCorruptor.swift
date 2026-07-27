import Foundation

// `Mode.RowWidth`의 2단 중첩은 설계 문서(§2.9c)가 명시한 구조(`PDFFixtureCorruptor.Mode.RowWidth`)
// 그대로다 — SwiftLint 기본 `nesting`(최대 1단) 규칙과 충돌하므로 이 파일 범위에서만 끈다.
// swiftlint:disable nesting

/// 완성된 픽스처에 의도적 손상을 가하는 후처리기. 각 모드는 결정적이다.
///
/// `PapyrusPDFTestSupport`는 `PapyrusPDFCore`에 의존하지 않으므로(설계 원칙), 이 파일의 xref
/// 관용 스캐너는 `PapyrusPDFCore/XRef/XRefTableParser`와 별개의 자체 구현이다 — 의도된 중복.
package enum PDFFixtureCorruptor {
  /// 손상 모드.
  package enum Mode: Sendable {
    /// `startxref` 뒤 숫자를 `"999999999"`로 치환 (파일 범위 밖 오프셋).
    case bogusStartxref
    /// `startxref`~`%%EOF` 블록 제거 (startxref 부재).
    case removeStartxref
    /// 파일 끝 `byteCount` 바이트 절단.
    case truncateTail(byteCount: Int)
    /// 헤더 앞에 정크 `byteCount` 바이트 삽입 — xref 오프셋들이 전부 편이되는
    /// 실세계 케이스 재현 (+bias 보정 경로 검증).
    case junkPrefix(byteCount: Int)
    /// `%%EOF` 제거.
    case removeEOFMarker
    /// 클래식 xref 특정 객체 행의 오프셋 숫자에 delta를 더해 훼손.
    case brokenEntryOffset(objectNumber: Int, delta: Int)
    /// 클래식 xref 행 전체를 19바이트(단일 LF EOL) 또는 21바이트(공백 추가) 폭으로 재기록.
    case malformedRowWidth(RowWidth)
    /// 마지막 섹션 트레일러의 `/Prev`를 자기 자신 오프셋으로 치환 (순환).
    case cyclicPrevChain

    /// 클래식 xref 행 폭 변형.
    package enum RowWidth: Sendable {
      /// 19바이트 (단일 LF EOL).
      case nineteen
      /// 21바이트 (공백 추가).
      case twentyOne
    }
  }

  /// 모드들을 순서대로 적용한 새 픽스처를 반환한다. `objectOffsets`/`xrefOffset`은
  /// 삽입·절단으로 무의미해질 수 있다 — 손상 픽스처의 메타데이터는 참고용일 뿐,
  /// 테스트는 열기 결과로만 검증한다.
  ///
  /// `.brokenEntryOffset`·`.malformedRowWidth`·`.cyclicPrevChain`은 클래식 테이블 전용 —
  /// 스트림 방식 픽스처(클래식 `xref` 섹션이 전혀 없는 픽스처)에 적용하면 `precondition` 실패.
  /// - Parameters:
  ///   - modes: 순서대로 적용할 손상 모드 목록.
  ///   - fixture: 손상시킬 원본 픽스처.
  /// - Returns: 손상이 적용된 새 픽스처.
  package static func apply(_ modes: [Mode], to fixture: PDFFixture) -> PDFFixture {
    modes.reduce(fixture) { partial, mode in
      Self.apply(mode, to: partial)
    }
  }

  /// 모드 하나를 적용한다.
  private static func apply(_ mode: Mode, to fixture: PDFFixture) -> PDFFixture {
    switch mode {
    case .bogusStartxref:
      return Self.applyBogusStartxref(to: fixture)
    case .removeStartxref:
      return Self.applyRemoveStartxref(to: fixture)
    case let .truncateTail(byteCount):
      return Self.applyTruncateTail(byteCount, to: fixture)
    case let .junkPrefix(byteCount):
      return Self.applyJunkPrefix(byteCount, to: fixture)
    case .removeEOFMarker:
      return Self.applyRemoveEOFMarker(to: fixture)
    case let .brokenEntryOffset(objectNumber, delta):
      return Self.applyBrokenEntryOffset(objectNumber: objectNumber, delta: delta, to: fixture)
    case let .malformedRowWidth(width):
      return Self.applyMalformedRowWidth(width, to: fixture)
    case .cyclicPrevChain:
      return Self.applyCyclicPrevChain(to: fixture)
    }
  }
}

// MARK: - 단순 바이트 조작 모드

extension PDFFixtureCorruptor {
  /// 원본 메타데이터를 그대로 보존한 새 픽스처를 만든다 (손상 후 메타데이터는 참고용).
  private static func rebuilt(data: Data, from fixture: PDFFixture) -> PDFFixture {
    PDFFixture(
      data: data, objectOffsets: fixture.objectOffsets, xrefOffset: fixture.xrefOffset,
      sectionOffsets: fixture.sectionOffsets
    )
  }

  private static func applyBogusStartxref(to fixture: PDFFixture) -> PDFFixture {
    var bytes = [UInt8](fixture.data)
    guard let keywordRange = Self.lastRange(of: "startxref", in: bytes) else {
      return fixture
    }
    var cursor = Self.skipWhitespace(bytes, from: keywordRange.upperBound)
    let digitStart = cursor
    while cursor < bytes.count, Self.isDigitByte(bytes[cursor]) {
      cursor += 1
    }
    bytes.replaceSubrange(digitStart..<cursor, with: Array("999999999".utf8))
    return Self.rebuilt(data: Data(bytes), from: fixture)
  }

  private static func applyRemoveStartxref(to fixture: PDFFixture) -> PDFFixture {
    let bytes = [UInt8](fixture.data)
    guard let keywordRange = Self.lastRange(of: "startxref", in: bytes) else {
      return fixture
    }
    return Self.rebuilt(data: Data(bytes[0..<keywordRange.lowerBound]), from: fixture)
  }

  private static func applyTruncateTail(_ byteCount: Int, to fixture: PDFFixture) -> PDFFixture {
    let bytes = [UInt8](fixture.data)
    let newCount = max(0, bytes.count - byteCount)
    return Self.rebuilt(data: Data(bytes.prefix(newCount)), from: fixture)
  }

  private static func applyJunkPrefix(_ byteCount: Int, to fixture: PDFFixture) -> PDFFixture {
    guard byteCount > 0 else {
      return fixture
    }
    let junk = Data(repeating: UInt8(ascii: "X"), count: byteCount)
    return Self.rebuilt(data: junk + fixture.data, from: fixture)
  }

  private static func applyRemoveEOFMarker(to fixture: PDFFixture) -> PDFFixture {
    var bytes = [UInt8](fixture.data)
    guard let range = Self.lastRange(of: "%%EOF", in: bytes) else {
      return fixture
    }
    bytes.removeSubrange(range)
    return Self.rebuilt(data: Data(bytes), from: fixture)
  }
}

// MARK: - 클래식 xref 손상 모드

extension PDFFixtureCorruptor {
  private static func applyBrokenEntryOffset(
    objectNumber: Int, delta: Int, to fixture: PDFFixture
  ) -> PDFFixture {
    var bytes = [UInt8](fixture.data)
    let sections = Self.parseAllClassicSections(in: bytes)
    precondition(!sections.isEmpty, "brokenEntryOffset는 클래식 xref 섹션이 있는 픽스처 전용이다.")
    guard
      let section = sections.last(where: { $0.rows.contains { $0.objectNumber == objectNumber } }),
      let row = section.rows.last(where: { $0.objectNumber == objectNumber })
    else {
      return fixture
    }
    let newOffset = row.offset + delta
    bytes.replaceSubrange(row.offsetFieldRange, with: Array(String(newOffset).utf8))
    return Self.rebuilt(data: Data(bytes), from: fixture)
  }

  private static func applyMalformedRowWidth(
    _ width: Mode.RowWidth, to fixture: PDFFixture
  ) -> PDFFixture {
    var bytes = [UInt8](fixture.data)
    let sections = Self.parseAllClassicSections(in: bytes)
    precondition(!sections.isEmpty, "malformedRowWidth는 클래식 xref 섹션이 있는 픽스처 전용이다.")
    guard let section = sections.last else {
      return fixture
    }
    for row in section.rows.reversed() {
      let newRowBytes = Self.formatRow(
        offset: row.offset, generation: row.generation, type: row.type, width: width
      )
      bytes.replaceSubrange(row.rowStart..<row.rowEnd, with: newRowBytes)
    }
    return Self.rebuilt(data: Data(bytes), from: fixture)
  }

  private static func applyCyclicPrevChain(to fixture: PDFFixture) -> PDFFixture {
    var bytes = [UInt8](fixture.data)
    let sections = Self.parseAllClassicSections(in: bytes)
    precondition(!sections.isEmpty, "cyclicPrevChain는 클래식 xref 섹션이 있는 픽스처 전용이다.")
    guard let lastSection = sections.last,
      let trailerKeywordRange = Self.firstRange(
        of: "trailer", in: bytes, from: lastSection.rowAreaEnd
      )
    else {
      return fixture
    }
    let selfOffset = lastSection.keywordStart
    if let prevValueRange = Self.findPrevValueRange(
      in: bytes, from: trailerKeywordRange.upperBound
    ) {
      bytes.replaceSubrange(prevValueRange, with: Array(String(selfOffset).utf8))
    } else if let dictOpen = Self.firstRange(
      of: "<<", in: bytes, from: trailerKeywordRange.upperBound
    ) {
      bytes.insert(contentsOf: Array(" /Prev \(selfOffset)".utf8), at: dictOpen.upperBound)
    }
    return Self.rebuilt(data: Data(bytes), from: fixture)
  }

  /// 값을 유지한 채 지정 폭으로 행을 재기록한다.
  private static func formatRow(
    offset: Int, generation: Int, type: UInt8, width: Mode.RowWidth
  ) -> [UInt8] {
    let offsetText = String(format: "%010d", offset)
    let generationText = String(format: "%05d", generation)
    let typeText = String(UnicodeScalar(type))
    let base = "\(offsetText) \(generationText) \(typeText)"
    switch width {
    case .nineteen:
      return Array((base + "\n").utf8)
    case .twentyOne:
      return Array((base + " \r\n").utf8)
    }
  }
}

// MARK: - 클래식 xref 관용 스캐너 (자체 구현, PapyrusPDFCore 비의존)

extension PDFFixtureCorruptor {
  /// 클래식 xref 행 하나의 위치·값.
  private struct ClassicRow {
    let objectNumber: Int
    let rowStart: Int
    let rowEnd: Int
    let offsetFieldRange: Range<Int>
    let offset: Int
    let generation: Int
    let type: UInt8
  }

  /// 클래식 xref 섹션 하나의 파싱 결과.
  private struct ClassicSection {
    let keywordStart: Int
    let rows: [ClassicRow]
    let rowAreaEnd: Int
  }

  private static func isWhitespaceByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20:
      return true
    default:
      return false
    }
  }

  private static func isDigitByte(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte)
  }

  private static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
    var cursor = start
    while cursor < bytes.count, Self.isWhitespaceByte(bytes[cursor]) {
      cursor += 1
    }
    return cursor
  }

  private static func scanDigits(_ bytes: [UInt8], from start: Int) -> (value: Int, next: Int)? {
    var cursor = start
    var value = 0
    var count = 0
    while cursor < bytes.count, Self.isDigitByte(bytes[cursor]) {
      value = value * 10 + Int(bytes[cursor] - 0x30)
      cursor += 1
      count += 1
    }
    guard count > 0 else {
      return nil
    }
    return (value, cursor)
  }

  private static func findAllXRefKeywordStarts(in bytes: [UInt8]) -> [Int] {
    let pattern = Array("xref".utf8)
    var starts: [Int] = []
    var index = 0
    while index + pattern.count <= bytes.count {
      if Array(bytes[index..<(index + pattern.count)]) == pattern {
        let before = index == 0 || bytes[index - 1] == 0x0A
        let afterIndex = index + pattern.count
        let after = afterIndex < bytes.count
          && (bytes[afterIndex] == 0x0A || bytes[afterIndex] == 0x0D)
        if before, after {
          starts.append(index)
        }
      }
      index += 1
    }
    return starts
  }

  private static func parseAllClassicSections(in bytes: [UInt8]) -> [ClassicSection] {
    Self.findAllXRefKeywordStarts(in: bytes).compactMap {
      Self.parseClassicSection(bytes: bytes, keywordStart: $0)
    }
  }

  private static func parseClassicSection(bytes: [UInt8], keywordStart: Int) -> ClassicSection? {
    var cursor = Self.skipWhitespace(bytes, from: keywordStart + 4)
    var rows: [ClassicRow] = []
    while true {
      guard let (start, afterStart) = Self.scanDigits(bytes, from: cursor) else {
        break
      }
      let afterSpace = Self.skipWhitespace(bytes, from: afterStart)
      guard let (count, afterCount) = Self.scanDigits(bytes, from: afterSpace), count >= 0 else {
        break
      }
      cursor = Self.skipWhitespace(bytes, from: afterCount)
      for relative in 0..<count {
        guard let row = Self.scanRow(bytes: bytes, objectNumber: start + relative, cursor: &cursor)
        else {
          return nil
        }
        rows.append(row)
      }
    }
    guard !rows.isEmpty else {
      return nil
    }
    return ClassicSection(keywordStart: keywordStart, rows: rows, rowAreaEnd: cursor)
  }

  private static func scanRow(
    bytes: [UInt8], objectNumber: Int, cursor: inout Int
  ) -> ClassicRow? {
    let rowStart = Self.skipWhitespace(bytes, from: cursor)
    guard let (offset, afterOffset) = Self.scanDigits(bytes, from: rowStart) else {
      return nil
    }
    let afterSpace1 = Self.skipWhitespace(bytes, from: afterOffset)
    guard let (generation, afterGeneration) = Self.scanDigits(bytes, from: afterSpace1) else {
      return nil
    }
    let afterSpace2 = Self.skipWhitespace(bytes, from: afterGeneration)
    guard afterSpace2 < bytes.count else {
      return nil
    }
    let type = bytes[afterSpace2]
    guard type == UInt8(ascii: "n") || type == UInt8(ascii: "f") else {
      return nil
    }
    let rowEnd = Self.skipWhitespace(bytes, from: afterSpace2 + 1)
    cursor = rowEnd
    return ClassicRow(
      objectNumber: objectNumber, rowStart: rowStart, rowEnd: rowEnd,
      offsetFieldRange: rowStart..<afterOffset, offset: offset, generation: generation, type: type
    )
  }

  private static func findPrevValueRange(in bytes: [UInt8], from start: Int) -> Range<Int>? {
    guard let prevKeywordRange = Self.firstRange(of: "/Prev", in: bytes, from: start) else {
      return nil
    }
    let digitStart = Self.skipWhitespace(bytes, from: prevKeywordRange.upperBound)
    var cursor = digitStart
    while cursor < bytes.count, Self.isDigitByte(bytes[cursor]) {
      cursor += 1
    }
    guard cursor > digitStart else {
      return nil
    }
    return digitStart..<cursor
  }

  private static func firstRange(
    of pattern: String, in bytes: [UInt8], from start: Int
  ) -> Range<Int>? {
    let patternBytes = Array(pattern.utf8)
    guard !patternBytes.isEmpty, start >= 0 else {
      return nil
    }
    var index = start
    while index + patternBytes.count <= bytes.count {
      if Array(bytes[index..<(index + patternBytes.count)]) == patternBytes {
        return index..<(index + patternBytes.count)
      }
      index += 1
    }
    return nil
  }

  private static func lastRange(of pattern: String, in bytes: [UInt8]) -> Range<Int>? {
    let patternBytes = Array(pattern.utf8)
    guard !patternBytes.isEmpty, bytes.count >= patternBytes.count else {
      return nil
    }
    var index = bytes.count - patternBytes.count
    while index >= 0 {
      if Array(bytes[index..<(index + patternBytes.count)]) == patternBytes {
        return index..<(index + patternBytes.count)
      }
      index -= 1
    }
    return nil
  }
}

// swiftlint:enable nesting
