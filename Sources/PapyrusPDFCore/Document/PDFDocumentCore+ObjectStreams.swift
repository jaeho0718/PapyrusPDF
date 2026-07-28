import Foundation

// `PDFDocumentCore`의 ObjStm 컨테이너 해소 경로. 파일 분리는 설계(§2.7)가 명시한 구조다.

extension PDFDocumentCore {
  /// 컨테이너 번호로 디코딩된 ObjStm을 가져온다. 캐시 히트 → in-flight 합류 → 준비(동기) →
  /// `@concurrent` 디코딩 순으로 진행하며, 준비 단계까지는 `await`가 전혀 없어 다른 태스크가
  /// 끼어들 수 없다 — 같은 컨테이너의 이중 디코딩이 구조적으로 불가능하다.
  /// - Parameter number: 컨테이너 객체 번호.
  /// - Throws: `COSParseError`(컨테이너 헤더 구문 오류), `FilterError`·`XRefError`(디코딩 실패).
  /// - Returns: 디코딩된 컨테이너.
  func decodedContainer(number: Int) async throws -> DecodedObjectStream {
    if let cached = self.objectStreamCache.container(number: number) {
      return cached
    }
    if let existingTask = self.inflightContainers[number] {
      return try await existingTask.value
    }

    guard case let .uncompressed(offset, generation) = self.xref.entry(for: number) else {
      throw XRefError(code: .parseFailed, offset: 0)
    }
    var parser = COSParser(file: self.file)
    let indirect = try parser.parseIndirectObject(at: offset)
    guard case let .stream(stream) = indirect.object, case let .fileRange(range) = stream.payload,
      let raw = self.file.bytes(in: range)
    else {
      throw XRefError(code: .parseFailed, offset: offset)
    }
    let dictionary = self.resolvedContainerDictionarySync(stream.dictionary)
    let securityHandler = self.securityHandler

    let task = Task<DecodedObjectStream, Error> {
      try await Self.decodeContainer(
        raw: raw, dictionary: dictionary, containerNumber: number, generation: generation,
        securityHandler: securityHandler
      )
    }
    self.inflightContainers[number] = task
    defer {
      self.inflightContainers[number] = nil
    }

    let decoded = try await task.value
    self.containerDecodeCount += 1
    self.objectStreamCache.insert(decoded, number: number)
    return decoded
  }

  /// ObjStm 컨테이너 압축 해제 — 액터 밖(글로벌 풀)에서 실행된다.
  /// - Parameters:
  ///   - raw: 컨테이너 스트림의 인코딩된(암호화된) 페이로드.
  ///   - dictionary: 컨테이너 스트림 딕셔너리 (간접 참조 사전 해소 완료).
  ///   - containerNumber: 컨테이너 객체 번호 (복호화 키 유도·경고 진단용).
  ///   - generation: 컨테이너 객체 세대 번호.
  ///   - securityHandler: 스트림 복호화 심 (v1은 항등).
  /// - Throws: `FilterError`·`XRefError`.
  /// - Returns: 디코딩된 컨테이너.
  @concurrent
  private static func decodeContainer(
    raw: Data, dictionary: COSDictionary, containerNumber: Int, generation: Int,
    securityHandler: any SecurityHandler
  ) async throws -> DecodedObjectStream {
    let objectID = ObjectID(number: containerNumber, generation: generation)
    let decrypted = try securityHandler.decryptStream(raw, objectID: objectID)
    let (container, _) = try ObjectStreamDecoder.decode(
      raw: decrypted, dictionary: dictionary, containerNumber: containerNumber
    )
    return container
  }

  /// 컨테이너 딕셔너리의 /Filter·/DecodeParms를 동기적으로 해소한다 (준비 단계 전용 — 이
  /// 단계 전체에 `await`가 없어야 in-flight dedupe의 원자성이 보장된다). 해소 대상이
  /// compressed 엔트리면(재귀 벡터) `.null` 취급한다.
  private func resolvedContainerDictionarySync(_ dictionary: COSDictionary) -> COSDictionary {
    var updated = dictionary
    if let filterValue = dictionary[.filter] {
      updated[.filter] = self.resolveContainerFilterValueSync(filterValue)
    }
    for key in [COSName.decodeParms, COSName.dp] {
      if let value = dictionary[key] {
        updated[key] = self.resolveContainerFilterValueSync(value)
      }
    }
    return updated
  }

  /// 값 자체 혹은(배열이면) 그 원소들을 동기적으로 해소한다. compressed 참조는 `.null`.
  private func resolveContainerFilterValueSync(_ value: COSObject) -> COSObject {
    switch value {
    case let .reference(id):
      guard case let .uncompressed(offset, _) = self.xref.entry(for: id.number) else {
        return .null
      }
      var parser = COSParser(file: self.file)
      return (try? parser.parseIndirectObject(at: offset))?.object ?? .null
    case let .array(elements):
      return .array(elements.map(self.resolveContainerFilterValueSync))
    default:
      return value
    }
  }
}
