import Foundation

/// xref 스트림 (/Type /XRef) 파서. PDF 1.5+.
package struct XRefStreamParser: Sendable {
  /// 파싱 대상 바이트 소스.
  private let file: MappedFile

  /// 파서를 생성한다.
  /// - Parameter file: 파싱 대상 바이트 소스.
  package init(file: MappedFile) {
    self.file = file
  }

  /// 오프셋의 간접 객체를 xref 스트림으로 파싱·디코딩해 섹션으로 변환한다.
  ///
  /// /Length는 스펙상 직접 정수여야 한다 — 간접이면 endstream 스캔 폴백(M1 파서 내장)에
  /// 의존한다 (xref 로딩 전이라 LengthResolver를 줄 수 없는 부트스트랩 단계이기 때문).
  /// - Parameter offset: 대상 간접 객체 헤더가 시작하는 절대 바이트 오프셋.
  /// - Returns: 파싱된 섹션 + 축적 경고.
  /// - Throws: 스트림 딕셔너리·디코딩·레이아웃 위반 시 ``XRefError``.
  package func parseSection(
    at offset: Int
  ) throws(XRefError) -> (section: XRefSection, warnings: [OpenWarning]) {
    var parser = COSParser(file: self.file)
    let indirect: IndirectObject
    do {
      indirect = try parser.parseIndirectObject(at: offset)
    } catch {
      // 객체 헤더(`N G obj`) 자체를 인식 못 했다면 "이 오프셋은 어떤 객체도 아님" —
      // notAnXRefSection으로 취급해 TrailerResolver의 bias 재시도 게이트가 작동하게 한다.
      // 그 외 파싱 실패(헤더는 인식했으나 본문이 깨짐)는 진짜 구조 손상이므로 parseFailed.
      throw XRefError(
        code: error.code == .invalidObjectHeader ? .notAnXRefSection : .parseFailed, offset: offset
      )
    }
    guard case let .stream(stream) = indirect.object else {
      throw XRefError(code: .notAnXRefSection, offset: offset)
    }
    let dictionary = stream.dictionary
    try Self.validateType(dictionary: dictionary, offset: offset)

    let widths = try Self.parseFieldWidths(dictionary: dictionary, offset: offset)
    let size = try Self.parseSize(dictionary: dictionary, offset: offset)
    let indexPairs = try Self.parseIndex(dictionary: dictionary, size: size, offset: offset)
    let rowWidth = widths.type + widths.field2 + widths.field3
    guard rowWidth > 0 else {
      throw XRefError(code: .invalidStreamDictionary, offset: offset)
    }

    guard case let .fileRange(range) = stream.payload, let raw = self.file.bytes(in: range) else {
      throw XRefError(code: .parseFailed, offset: offset)
    }
    let decoded = try Self.decodePayload(
      raw: raw, dictionary: dictionary, rowWidth: rowWidth, offset: offset
    )

    let expectedRowCount = indexPairs.reduce(0) { $0 + $1.count }
    let availableRowCount = decoded.count / rowWidth
    let result = Self.readEntries(
      decoded: Array(decoded), widths: widths, rowWidth: rowWidth,
      indexPairs: indexPairs, availableRowCount: availableRowCount
    )

    var warnings: [OpenWarning] = parser.warnings.map(OpenWarning.parse)
    if availableRowCount < expectedRowCount {
      warnings.append(.xrefStreamTruncated(offset: offset))
    }
    warnings.append(contentsOf: result.warnings)

    let section = XRefSection(
      entries: result.entries, trailer: dictionary,
      previousOffset: dictionary.integer(for: .prev), xrefStreamOffset: nil
    )
    return (section, warnings)
  }

  /// 필터 체인으로 원시 페이로드를 디코딩한다 (`maxXRefEntries × rowWidth` 상한 적용).
  private static func decodePayload(
    raw: Data, dictionary: COSDictionary, rowWidth: Int, offset: Int
  ) throws(XRefError) -> Data {
    let (rawMaxDecoded, overflowed) = CoreLimits.maxXRefEntries.multipliedReportingOverflow(
      by: rowWidth
    )
    let maxDecodedSize = overflowed
      ? CoreLimits.maxDecodedStreamBytes : min(CoreLimits.maxDecodedStreamBytes, rawMaxDecoded)
    do {
      return try FilterPipeline.decode(
        raw: raw, dictionary: dictionary, maxDecodedSize: maxDecodedSize
      )
    } catch {
      throw XRefError(code: .decodeFailed, offset: offset)
    }
  }
}

// MARK: - 딕셔너리 검증

extension XRefStreamParser {
  /// 필드 폭 3개.
  private struct FieldWidths {
    /// type 필드 폭 (raw, 0 허용).
    let type: Int
    /// field2 폭 (offset 또는 containerNumber).
    let field2: Int
    /// field3 폭 (generation 또는 indexInContainer).
    let field3: Int
  }

  /// `/Type`이 있으면 `/XRef`여야 하고, 없으면 `/W`가 있어야 관용 수용한다.
  private static func validateType(
    dictionary: COSDictionary, offset: Int
  ) throws(XRefError) {
    if let typeName = dictionary.name(for: .type) {
      guard typeName.rawValue == "XRef" else {
        throw XRefError(code: .notAnXRefSection, offset: offset)
      }
    } else {
      guard dictionary[.wKey] != nil else {
        throw XRefError(code: .notAnXRefSection, offset: offset)
      }
    }
  }

  /// `/W` 배열(길이 3, 각 원소 0...maxXRefFieldWidth)을 검증한다. w1==0은 유효(타입 기본값 1).
  private static func parseFieldWidths(
    dictionary: COSDictionary, offset: Int
  ) throws(XRefError) -> FieldWidths {
    guard let wArray = dictionary.array(for: .wKey), wArray.count == 3 else {
      throw XRefError(code: .invalidStreamDictionary, offset: offset)
    }
    var widths: [Int] = []
    widths.reserveCapacity(3)
    for element in wArray {
      guard let value = element.integerValue, value >= 0 else {
        throw XRefError(code: .invalidStreamDictionary, offset: offset)
      }
      guard value <= CoreLimits.maxXRefFieldWidth else {
        throw XRefError(code: .fieldWidthTooLarge, offset: offset)
      }
      widths.append(value)
    }
    return FieldWidths(type: widths[0], field2: widths[1], field3: widths[2])
  }

  /// `/Size`(양의 정수) 값을 읽는다.
  private static func parseSize(
    dictionary: COSDictionary, offset: Int
  ) throws(XRefError) -> Int {
    guard let size = dictionary.integer(for: .size), size > 0 else {
      throw XRefError(code: .invalidStreamDictionary, offset: offset)
    }
    return size
  }

  /// `/Index`(짝수 길이 정수 배열, 기본 `[0, Size]`)를 (start, count) 쌍 목록으로 변환한다.
  private static func parseIndex(
    dictionary: COSDictionary, size: Int, offset: Int
  ) throws(XRefError) -> [(start: Int, count: Int)] {
    guard let indexArray = dictionary.array(for: .index) else {
      return [(start: 0, count: size)]
    }
    guard indexArray.count.isMultiple(of: 2) else {
      throw XRefError(code: .invalidStreamDictionary, offset: offset)
    }
    var pairs: [(start: Int, count: Int)] = []
    pairs.reserveCapacity(indexArray.count / 2)
    var index = 0
    while index < indexArray.count {
      guard let start = indexArray[index].integerValue, start >= 0,
        let count = indexArray[index + 1].integerValue, count >= 0
      else {
        throw XRefError(code: .invalidStreamDictionary, offset: offset)
      }
      pairs.append((start: start, count: count))
      index += 2
    }
    return pairs
  }
}

// MARK: - 행 디코딩

extension XRefStreamParser {
  /// `UInt64` 값을 안전하게 `Int`로 변환한다 (`Int.max` 초과면 `nil`).
  private static func safeInt(_ value: UInt64) -> Int? {
    guard value <= UInt64(Int.max) else {
      return nil
    }
    return Int(value)
  }

  /// `width` 바이트를 빅엔디언 무부호 정수로 누산한다 (`width <= 8`이므로 `UInt64` 안전).
  private static func readBigEndian(_ bytes: [UInt8], at start: Int, width: Int) -> UInt64 {
    var value: UInt64 = 0
    for offset in 0..<width {
      value = (value << 8) | UInt64(bytes[start + offset])
    }
    return value
  }

  /// 디코딩된 페이로드에서 사용 가능한 행만큼 엔트리를 조립한다.
  private static func readEntries(
    decoded: [UInt8], widths: FieldWidths, rowWidth: Int,
    indexPairs: [(start: Int, count: Int)], availableRowCount: Int
  ) -> (entries: [Int: XRefEntry], warnings: [OpenWarning]) {
    var entries: [Int: XRefEntry] = [:]
    var warnings: [OpenWarning] = []
    var rowCursor = 0
    var consumedRows = 0

    // 중첩 함수로 두어(§클로저 캡처) 최상위 함수의 매개변수 수를 늘리지 않는다.
    func readRow(objectNumber: Int) {
      let typeValue = widths.type == 0
        ? 1 : Int(Self.readBigEndian(decoded, at: rowCursor, width: widths.type))
      let field2Raw = Self.readBigEndian(
        decoded, at: rowCursor + widths.type, width: widths.field2
      )
      let field3Raw = Self.readBigEndian(
        decoded, at: rowCursor + widths.type + widths.field2, width: widths.field3
      )
      guard let field2 = Self.safeInt(field2Raw), let field3 = Self.safeInt(field3Raw) else {
        warnings.append(.entryOutOfBounds(objectNumber: objectNumber))
        return
      }
      switch typeValue {
      case 0:
        entries[objectNumber] = .free
      case 1:
        entries[objectNumber] = .uncompressed(offset: field2, generation: field3)
      case 2:
        entries[objectNumber] = .compressed(containerNumber: field2, indexInContainer: field3)
      default:
        break
      }
    }

    outer: for pair in indexPairs {
      for relative in 0..<pair.count {
        guard consumedRows < availableRowCount else {
          break outer
        }
        readRow(objectNumber: pair.start + relative)
        rowCursor += rowWidth
        consumedRows += 1
      }
    }
    return (entries, warnings)
  }
}
