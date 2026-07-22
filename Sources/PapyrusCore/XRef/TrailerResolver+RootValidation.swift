// `TrailerResolver`의 /Root 검증 경로. 파일 분리는 순수 조직적 이유(파일 길이 제한)이며,
// 타입·의미는 `TrailerResolver.swift`와 동일하다.

extension TrailerResolver {
  /// 병합 트레일러의 /Root가 테이블 엔트리로 해소되어 딕셔너리(관용상 /Type /Catalog)로
  /// 파싱되는지 검증한다. 액터 이전 단계이므로 COSParser로 직접 수행한다.
  static func validateRoot(table: XRefTable, file: MappedFile) -> Bool {
    guard let rootValue = table.trailer[.root], case let .reference(id) = rootValue else {
      return false
    }
    let resolved = Self.resolveForValidation(id: id, table: table, file: file)
    guard case let .dictionary(dictionary) = resolved else {
      return false
    }
    guard let typeName = dictionary.name(for: .type) else {
      return true
    }
    return typeName.rawValue == "Catalog"
  }

  /// 검증 전용 1회성 객체 해소 (비압축·압축 모두 지원, 액터 캐시 없이 직접 파싱).
  private static func resolveForValidation(
    id: ObjectID, table: XRefTable, file: MappedFile
  ) -> COSObject? {
    switch table.entry(for: id.number) {
    case let .uncompressed(offset, _):
      guard offset >= 0, offset < file.count else {
        return nil
      }
      var parser = COSParser(file: file)
      return (try? parser.parseIndirectObject(at: offset))?.object
    case let .compressed(containerNumber, indexInContainer):
      return Self.resolveCompressedForValidation(
        containerNumber: containerNumber, indexInContainer: indexInContainer,
        objectNumber: id.number, table: table, file: file
      )
    case .free, nil:
      return nil
    }
  }

  /// ObjStm 컨테이너를 1회성으로 디코딩해 압축 멤버를 해소한다 (검증 전용, 캐시 없음).
  private static func resolveCompressedForValidation(
    containerNumber: Int, indexInContainer: Int, objectNumber: Int, table: XRefTable,
    file: MappedFile
  ) -> COSObject? {
    guard case let .uncompressed(containerOffset, _) = table.entry(for: containerNumber) else {
      return nil
    }
    var containerParser = COSParser(file: file)
    guard let containerIndirect = try? containerParser.parseIndirectObject(at: containerOffset),
      case let .stream(containerStream) = containerIndirect.object,
      case let .fileRange(range) = containerStream.payload,
      let raw = file.bytes(in: range)
    else {
      return nil
    }
    guard let decoded = try? ObjectStreamDecoder.decode(
      raw: raw, dictionary: containerStream.dictionary, containerNumber: containerNumber
    ) else {
      return nil
    }
    guard indexInContainer >= 0, indexInContainer < decoded.container.members.count else {
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
