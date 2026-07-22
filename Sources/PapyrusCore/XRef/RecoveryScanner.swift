import Foundation

/// xref가 신뢰 불가할 때 파일 전역을 선형 스캔해 테이블을 재구성하는 최후 폴백.
package struct RecoveryScanner: Sendable {
  /// 스캔 대상 바이트 소스.
  private let file: MappedFile

  /// 스캐너를 생성한다.
  /// - Parameter file: 스캔 대상 바이트 소스.
  package init(file: MappedFile) {
    self.file = file
  }

  /// `N G obj` 헤더·`trailer` 딕셔너리를 전방 스캔으로 수집해 테이블을 재구성한다.
  /// /Type /ObjStm 컨테이너는 압축 해제해 type-2 엔트리로 확장한다.
  ///
  /// 같은 객체 번호가 여러 번 나오면 **나중 오프셋이 승리**한다 (증분 업데이트는 뒤에
  /// 덧붙으므로 뒤쪽이 최신).
  /// - Returns: 재구성 테이블 (+트레일러 후보 병합 결과) + 경고. /Root 후보조차 없으면 `nil`.
  package func rebuild() -> (table: XRefTable, warnings: [OpenWarning])? {
    let scan = self.scanForCandidatesAndTrailers()
    guard !scan.candidates.isEmpty else {
      return nil
    }

    var warnings: [OpenWarning] = [.rebuiltViaRecoveryScan]
    var table = XRefTable()
    var topLevelEntries: [Int: XRefEntry] = [:]
    for (number, offset) in scan.candidates {
      topLevelEntries[number] = .uncompressed(offset: offset, generation: 0)
    }
    table.mergeSection(XRefSection(entries: topLevelEntries))

    let mergedTrailer = self.mergeTrailerCandidates(at: scan.trailerOffsets)
    table.mergeSection(XRefSection(trailer: mergedTrailer))

    self.expandObjectStreams(candidates: scan.candidates, table: &table)

    if table.trailer[.root] == nil {
      guard let root = self.findRootBySignatureScan(table: table) else {
        return nil
      }
      table.mergeSection(XRefSection(trailer: COSDictionary([.root: .reference(root)])))
      warnings.append(.rootFoundBySignatureScan)
    }

    return (table, warnings)
  }
}

// MARK: - 전방 단일 패스 스캔

extension RecoveryScanner {
  /// 전방 단일 패스로 `obj` 후보와 `trailer` 출현 오프셋을 수집한다.
  private func scanForCandidatesAndTrailers() -> (candidates: [Int: Int], trailerOffsets: [Int]) {
    var candidates: [Int: Int] = [:]
    var trailerOffsets: [Int] = []
    let trailerKeyword: [UInt8] = Array("trailer".utf8)

    self.file.withUnsafeBytes { buffer in
      guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
        return
      }
      let count = buffer.count
      var index = 0
      while index < count {
        let byte = base[index]
        if byte == UInt8(ascii: "o"), index + 3 <= count,
          base[index + 1] == UInt8(ascii: "b"), base[index + 2] == UInt8(ascii: "j") {
          if let candidate = Self.reconstructObjectHeader(base: base, objStart: index),
            candidates[candidate.number] != nil || candidates.count < CoreLimits.maxXRefEntries {
            candidates[candidate.number] = candidate.headerOffset
          }
        } else if byte == UInt8(ascii: "t"), index + trailerKeyword.count <= count,
          Self.matchesKeyword(base: base, at: index, keyword: trailerKeyword) {
          trailerOffsets.append(index)
        }
        index += 1
      }
    }
    return (candidates, trailerOffsets)
  }

  /// `objStart`("obj"의 'o' 위치)에서 역방향으로 `N G obj` 헤더를 재구성한다.
  /// 역탐 상한은 32바이트 — 종료를 보장한다.
  private static func reconstructObjectHeader(
    base: UnsafePointer<UInt8>, objStart: Int
  ) -> (number: Int, headerOffset: Int)? {
    let backtrackLimit = max(0, objStart - 32)
    var cursor = objStart - 1

    guard Self.consumeRequiredWhitespace(base: base, cursor: &cursor, limit: backtrackLimit) else {
      return nil
    }
    guard let generation = Self.consumeDigitRun(
      base: base, cursor: &cursor, limit: backtrackLimit, maxDigits: 5
    ) else {
      return nil
    }
    guard Self.consumeRequiredWhitespace(base: base, cursor: &cursor, limit: backtrackLimit) else {
      return nil
    }
    guard let number = Self.consumeDigitRun(
      base: base, cursor: &cursor, limit: backtrackLimit, maxDigits: 10
    ) else {
      return nil
    }
    let numberStart = cursor + 1
    guard Self.hasValidNumberBoundary(base: base, numberStart: numberStart) else {
      return nil
    }
    guard number > 0, generation <= 65_535 else {
      return nil
    }
    return (number, numberStart)
  }

  /// 공백 런이 하나 이상 있으면 소비하고 `true`, 없으면 `false`.
  private static func consumeRequiredWhitespace(
    base: UnsafePointer<UInt8>, cursor: inout Int, limit: Int
  ) -> Bool {
    guard cursor >= limit, Self.isWhitespaceByte(base[cursor]) else {
      return false
    }
    while cursor >= limit, Self.isWhitespaceByte(base[cursor]) {
      cursor -= 1
    }
    return true
  }

  /// 숫자 런을 역방향으로 소비해 정수로 변환한다. 자릿수가 0개거나 `maxDigits` 초과면 `nil`.
  private static func consumeDigitRun(
    base: UnsafePointer<UInt8>, cursor: inout Int, limit: Int, maxDigits: Int
  ) -> Int? {
    let end = cursor + 1
    var digitCount = 0
    while cursor >= limit, Self.isDigitByte(base[cursor]) {
      cursor -= 1
      digitCount += 1
    }
    guard digitCount > 0, digitCount <= maxDigits else {
      return nil
    }
    return Self.parseDigits(base: base, from: cursor + 1, to: end)
  }

  /// `N` 직전 바이트가 파일 시작이거나 공백·구분자인지 검사한다.
  private static func hasValidNumberBoundary(
    base: UnsafePointer<UInt8>, numberStart: Int
  ) -> Bool {
    guard numberStart > 0 else {
      return true
    }
    let before = base[numberStart - 1]
    return Self.isWhitespaceByte(before) || Self.isDelimiterByte(before)
  }

  /// PDF 화이트스페이스 바이트 여부.
  private static func isWhitespaceByte(_ byte: UInt8) -> Bool {
    COSLexer.isWhitespace(byte)
  }

  /// ASCII 숫자 바이트 여부.
  private static func isDigitByte(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte)
  }

  /// PDF 구분자 바이트 여부 (`N` 직전 바이트 검증용).
  private static func isDelimiterByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
      UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
      UInt8(ascii: "/"), UInt8(ascii: "%"):
      return true
    default:
      return false
    }
  }

  /// `[from, to)` 구간의 ASCII 숫자를 정수로 누산한다.
  private static func parseDigits(
    base: UnsafePointer<UInt8>, from start: Int, to end: Int
  ) -> Int {
    var value = 0
    var index = start
    while index < end {
      value = value * 10 + Int(base[index] - 0x30)
      index += 1
    }
    return value
  }

  /// `index`에 `keyword` 바이트열이 정확히 놓여 있는지 검사한다 (범위는 호출부가 보장).
  private static func matchesKeyword(
    base: UnsafePointer<UInt8>, at index: Int, keyword: [UInt8]
  ) -> Bool {
    for offset in 0..<keyword.count where base[index + offset] != keyword[offset] {
      return false
    }
    return true
  }
}

// MARK: - 트레일러 재구성

extension RecoveryScanner {
  /// `trailer` 출현들 뒤의 딕셔너리를 파싱해, 파일 순서상 뒤가 이기도록 병합한다.
  private func mergeTrailerCandidates(at offsets: [Int]) -> COSDictionary {
    var merged = COSDictionary()
    for offset in offsets.reversed() {
      var parser = COSParser(file: self.file)
      guard let parsed = try? parser.parseObject(at: offset + 7),
        case let .dictionary(dict) = parsed
      else {
        continue
      }
      for key in dict.keys where merged[key] == nil {
        merged[key] = dict[key]
      }
    }
    return merged
  }
}

// MARK: - ObjStm 확장

extension RecoveryScanner {
  /// 각 후보를 파싱해 `/Type /ObjStm` 스트림이면 멤버를 확장한다. 테이블에 이미 정의된
  /// 번호는 최상위 정의를 우선한다.
  ///
  /// 후보는 객체 번호 오름차순으로 정렬해 순회한다 — `Dictionary`의 순회 순서는 해시
  /// 시드에 따라 실행마다 달라질 수 있어, 서로 다른 두 컨테이너가 (둘 다 최상위 정의
  /// 없이) 같은 멤버 번호를 압축 객체로 주장하는 병적 입력에서 어느 쪽이 이기는지가
  /// 비결정적이 되는 것을 막는다.
  private func expandObjectStreams(candidates: [Int: Int], table: inout XRefTable) {
    let file = self.file
    let lengthResolver: COSParser.LengthResolver = { id in
      guard let offset = candidates[id.number] else {
        return nil
      }
      var parser = COSParser(file: file)
      return (try? parser.parseIndirectObject(at: offset))?.object.integerValue
    }

    for (number, offset) in candidates.sorted(by: { $0.key < $1.key }) {
      var parser = COSParser(file: file, lengthResolver: lengthResolver)
      guard let indirect = try? parser.parseIndirectObject(at: offset),
        case let .stream(stream) = indirect.object,
        stream.dictionary.name(for: .type)?.rawValue == "ObjStm",
        case let .fileRange(range) = stream.payload,
        let raw = file.bytes(in: range),
        let decoded = try? ObjectStreamDecoder.decode(
          raw: raw, dictionary: stream.dictionary, containerNumber: number
        )
      else {
        continue
      }
      var newEntries: [Int: XRefEntry] = [:]
      for (index, member) in decoded.container.members.enumerated()
      where table.entry(for: member.objectNumber) == nil {
        newEntries[member.objectNumber] = .compressed(
          containerNumber: number, indexInContainer: index
        )
      }
      table.mergeSection(XRefSection(entries: newEntries))
    }
  }
}

// MARK: - /Root 시그니처 스캔

extension RecoveryScanner {
  /// 병합 트레일러에 `/Root`가 없을 때, 후보 객체들을 **파일 오프셋 내림차순**으로
  /// 파싱해 `/Type /Catalog` 딕셔너리를 탐색한다 ("뒤에서부터" = 나중 기록 = 최신,
  /// 나중-오프셋 승리 규칙(1단계)과 동일 원리 — r2 명확화).
  private func findRootBySignatureScan(table: XRefTable) -> ObjectID? {
    let orderedNumbers = table.entries.keys.sorted { lhs, rhs in
      let lhsOffset = self.signatureScanSortOffset(for: lhs, table: table)
      let rhsOffset = self.signatureScanSortOffset(for: rhs, table: table)
      guard lhsOffset == rhsOffset else {
        return lhsOffset > rhsOffset
      }
      return lhs > rhs
    }
    for number in orderedNumbers {
      guard
        case let .dictionary(dictionary) = self.resolveGeneric(objectNumber: number, table: table),
        dictionary.name(for: .type)?.rawValue == "Catalog"
      else {
        continue
      }
      return ObjectID(number: number, generation: 0)
    }
    return nil
  }

  /// 시그니처 스캔 정렬 키: `.uncompressed`는 엔트리 오프셋, `.compressed`는 소속
  /// 컨테이너(`.uncompressed`여야 함)의 오프셋. 컨테이너 오프셋을 알 수 없으면(컨테이너가
  /// `.uncompressed`가 아니거나 부재) 가장 낮은 값으로 취급해 후순위로 민다.
  private func signatureScanSortOffset(for objectNumber: Int, table: XRefTable) -> Int {
    switch table.entry(for: objectNumber) {
    case let .uncompressed(offset, _):
      return offset
    case let .compressed(containerNumber, _):
      guard case let .uncompressed(containerOffset, _) = table.entry(for: containerNumber) else {
        return Int.min
      }
      return containerOffset
    case .free, nil:
      return Int.min
    }
  }

  /// 압축·비압축을 모두 지원하는 1회성 객체 해소 (캐시 없음, 복구 스캔 전용).
  private func resolveGeneric(objectNumber: Int, table: XRefTable) -> COSObject? {
    switch table.entry(for: objectNumber) {
    case let .uncompressed(offset, _):
      var parser = COSParser(file: self.file)
      return (try? parser.parseIndirectObject(at: offset))?.object
    case let .compressed(containerNumber, indexInContainer):
      return self.resolveCompressed(
        containerNumber: containerNumber, indexInContainer: indexInContainer,
        objectNumber: objectNumber, table: table
      )
    case .free, nil:
      return nil
    }
  }

  /// ObjStm 컨테이너를 1회성으로 디코딩해 압축 멤버를 해소한다.
  private func resolveCompressed(
    containerNumber: Int, indexInContainer: Int, objectNumber: Int, table: XRefTable
  ) -> COSObject? {
    guard case let .uncompressed(containerOffset, _) = table.entry(for: containerNumber) else {
      return nil
    }
    var containerParser = COSParser(file: self.file)
    guard let containerIndirect = try? containerParser.parseIndirectObject(at: containerOffset),
      case let .stream(containerStream) = containerIndirect.object,
      case let .fileRange(range) = containerStream.payload,
      let raw = self.file.bytes(in: range),
      let decoded = try? ObjectStreamDecoder.decode(
        raw: raw, dictionary: containerStream.dictionary, containerNumber: containerNumber
      ),
      indexInContainer >= 0, indexInContainer < decoded.container.members.count
    else {
      return nil
    }
    let member = decoded.container.members[indexInContainer]
    guard member.objectNumber == objectNumber else {
      return nil
    }
    var memberParser = COSParser(file: MappedFile(data: decoded.container.payload))
    return try? memberParser.parseObject(at: member.offset)
  }
}
