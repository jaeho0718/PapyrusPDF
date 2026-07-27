import Foundation

/// 문서 하나의 파싱 상태 전체를 소유하는 액터. 모든 객체 해소가 여기로 수렴한다.
///
/// 소유물: 맵 파일(불변), xref 테이블(불변), 객체 LRU, ObjStm 컨테이너 LRU,
/// 컨테이너 in-flight 태스크 맵. CPU 무거운 압축 해제는 `@concurrent`로 액터 밖 실행.
package actor PDFDocumentCore {
  /// 맵 파일. 열기 이후 불변. `MappedFile`은 Sendable이므로 격리 완화가 안전하다.
  nonisolated let file: MappedFile

  /// 병합 완료된 xref 테이블. 열기 이후 불변.
  let xref: XRefTable

  /// 객체 LRU 캐시 (객체 번호 키 — 세대 번호는 조회 키에서 무시한다, 가정 5).
  var objectCache: LRUCache<Int, COSObject>

  /// ObjStm 컨테이너 LRU 캐시.
  var objectStreamCache: ObjectStreamCache

  /// 컨테이너 번호별 in-flight 디코딩 태스크 (중복 디코딩 방지).
  var inflightContainers: [Int: Task<DecodedObjectStream, Error>]

  /// 누적 컨테이너 압축 해제 횟수 (캐시 히트면 늘지 않는다 — 테스트 관찰용).
  var containerDecodeCount: Int

  /// 페이지 트리 평탄화의 영구 메모 태스크 (성공·실패 공히 메모, M3 §4.1).
  var pageTreeTask: Task<PageTreeSnapshot, Error>?

  /// 문서 메타데이터 수집의 영구 메모 태스크.
  var metadataTask: Task<DocumentMetadata, Error>?

  /// 목차 구축의 영구 메모 태스크.
  var outlineTask: Task<[OutlineItem], Error>?

  /// 페이지 트리 평탄화가 실제로 실행된 횟수 (dedupe 검증용 — 테스트 관찰용).
  var pageTreeBuildCount: Int

  /// 메타데이터 수집이 실제로 실행된 횟수 (테스트 관찰용).
  var metadataBuildCount: Int

  /// 목차 구축이 실제로 실행된 횟수 (테스트 관찰용).
  var outlineBuildCount: Int

  /// 페이지 텍스트 LRU (비용 = 추정 바이트, 예산 `CoreLimits.maxTextPageCacheBytes`).
  var textPageCache: LRUCache<Int, PageTextContent>

  /// 페이지별 in-flight 추출 태스크.
  var inflightTextPages: [Int: Task<PageTextContent, Error>]

  /// 폰트 캐시 (객체 번호 키, 항목 수 캡).
  var fontCache: LRUCache<Int, LoadedFont>

  /// 폰트별 in-flight 로딩 태스크.
  var inflightFonts: [Int: Task<LoadedFont, Never>]

  /// 텍스트 추출이 실제로 실행된 횟수 (dedupe 검증용 — 테스트 관찰용).
  var textExtractionCount: Int

  /// 폰트 빌드가 실제로 실행된 횟수 (테스트 관찰용).
  var fontBuildCount: Int

  /// 열기 중 축적된 경고. 열기 이후 불변 (가정 4).
  package nonisolated let openWarnings: [CoreOpenWarning]

  /// 헤더 버전.
  package nonisolated let version: PDFVersion

  /// 병합 트레일러 (/Root /Info /ID /Size — /Encrypt 문서는 열기가 실패하므로 없음).
  package nonisolated let trailer: COSDictionary

  /// 문자열·스트림 복호화 심. v1은 항상 ``IdentitySecurityHandler``.
  package nonisolated let securityHandler: any SecurityHandler

  /// 원본 문서 바이트 (렌더링 타겟이 `CGPDFDocument` 생성에 사용).
  ///
  /// 열기 방식(url/data)과 무관하게 항상 매핑/보유된 동일 바이트를 돌려준다.
  package nonisolated var sourceBytes: Data {
    self.file.contents
  }

  /// 완성된 불변 상태로 액터를 생성한다 (열기 플로우 전용 — 외부에는 `open`만 노출한다).
  private init(
    file: MappedFile, xref: XRefTable, version: PDFVersion, warnings: [CoreOpenWarning]
  ) {
    self.file = file
    self.xref = xref
    self.version = version
    self.openWarnings = warnings
    self.trailer = xref.trailer
    self.securityHandler = IdentitySecurityHandler()
    self.objectCache = LRUCache(costBudget: CoreLimits.objectCacheEntryCap)
    self.objectStreamCache = ObjectStreamCache()
    self.inflightContainers = [:]
    self.containerDecodeCount = 0
    self.pageTreeTask = nil
    self.metadataTask = nil
    self.outlineTask = nil
    self.pageTreeBuildCount = 0
    self.metadataBuildCount = 0
    self.outlineBuildCount = 0
    self.textPageCache = LRUCache(costBudget: CoreLimits.maxTextPageCacheBytes)
    self.inflightTextPages = [:]
    self.fontCache = LRUCache(costBudget: CoreLimits.maxLoadedFontEntries)
    self.inflightFonts = [:]
    self.textExtractionCount = 0
    self.fontBuildCount = 0
  }

  /// 파일을 연다. 헤더 검증 → xref 체인 로드 → 복구 폴백 → /Encrypt 감지 → /Root 검증.
  /// - Parameter url: 열려는 PDF 파일의 위치.
  /// - Throws: 헤더가 없으면 ``DocumentOpenError/notAPDF``, I/O 실패는
  ///   ``DocumentOpenError/ioError(_:)``, 암호화 문서는
  ///   ``DocumentOpenError/encryptedDocument(filterName:)``, 복구 불능 손상은
  ///   ``DocumentOpenError/damagedBeyondRecovery``.
  /// - Returns: 열린 문서 액터.
  package static func open(url: URL) async throws(DocumentOpenError) -> PDFDocumentCore {
    let file: MappedFile
    do {
      file = try MappedFile(url: url)
    } catch {
      throw DocumentOpenError.ioError(error)
    }
    return try await Self.openMappedFile(file)
  }

  /// 인메모리 바이트를 연다 (테스트·픽스처 경로).
  /// - Parameter data: 열려는 PDF 바이트.
  /// - Throws: ``open(url:)``와 동일.
  /// - Returns: 열린 문서 액터.
  package static func open(data: Data) async throws(DocumentOpenError) -> PDFDocumentCore {
    try await Self.openMappedFile(MappedFile(data: data))
  }

  /// 공통 열기 플로우: xref 해소 → 암호화 감지 → 액터 생성.
  private static func openMappedFile(
    _ file: MappedFile
  ) async throws(DocumentOpenError) -> PDFDocumentCore {
    let resolution = try TrailerResolver(file: file).resolve()
    switch Self.detectEncryption(table: resolution.table, file: file) {
    case .none:
      break
    case let .detected(filterName):
      throw DocumentOpenError.encryptedDocument(filterName: filterName)
    }
    return PDFDocumentCore(
      file: file, xref: resolution.table, version: resolution.version,
      warnings: resolution.warnings
    )
  }

  /// 간접 객체를 해소한다. free/부재/헤더 불일치는 스펙 관용대로 `.null`.
  /// - Parameter id: 해소할 간접 객체 식별자.
  /// - Throws: `COSParseError`(비압축 객체 구문 오류), `FilterError`·`XRefError`
  ///   (ObjStm 컨테이너 디코딩 실패). untyped — 세 도메인 합류 (가정 2).
  /// - Returns: 해소된 값 (미해소면 `.null`).
  package func object(for id: ObjectID) async throws -> COSObject {
    if let cached = self.objectCache.value(for: id.number) {
      return cached
    }
    let resolved = try await self.resolveUncached(id: id)
    if !resolved.isNull {
      self.objectCache.insert(resolved, cost: 1, for: id.number)
    }
    return resolved
  }

  /// `object(for:)`의 캐시 미스 경로.
  private func resolveUncached(id: ObjectID) async throws -> COSObject {
    switch self.xref.entry(for: id.number) {
    case nil, .free:
      return .null
    case let .uncompressed(offset, _):
      var parser = COSParser(file: self.file, lengthResolver: Self.makeLengthResolver(
        xref: self.xref, file: self.file
      ))
      let indirect = try parser.parseIndirectObject(at: offset)
      guard indirect.id.number == id.number else {
        return .null
      }
      return indirect.object
    case let .compressed(containerNumber, indexInContainer):
      guard case .uncompressed = self.xref.entry(for: containerNumber) else {
        return .null
      }
      let container = try await self.decodedContainer(number: containerNumber)
      guard indexInContainer >= 0, indexInContainer < container.members.count else {
        return .null
      }
      let member = container.members[indexInContainer]
      guard member.objectNumber == id.number else {
        return .null
      }
      var memberParser = COSParser(file: MappedFile(data: container.payload))
      return try memberParser.parseObject(at: member.offset)
    }
  }

  /// 값이 `.reference`면 해소하고, 아니면 그대로 돌려준다 (1단계만 — 재귀 아님).
  /// 참조 사슬(`R`이 `R`을 가리킴)은 `CoreLimits.maxReferenceChainLength`까지 따라간다.
  /// - Parameter object: 해소할 값.
  /// - Throws: ``object(for:)``와 동일.
  /// - Returns: 해소된 값 (사슬 초과 시 `.null`).
  package func resolve(_ object: COSObject) async throws -> COSObject {
    var current = object
    var chainLength = 0
    while case let .reference(id) = current {
      chainLength += 1
      guard chainLength <= CoreLimits.maxReferenceChainLength else {
        return .null
      }
      current = try await self.object(for: id)
    }
    return current
  }

  /// 스트림 객체의 페이로드를 (복호화 →) 필터 체인 적용까지 마쳐 반환한다.
  /// /Filter·/DecodeParms의 간접 참조는 여기서 사전 해소된다
  /// (M1 `FilterError.indirectParameter`는 이 경로에서 구조적으로 소멸).
  /// - Parameter id: 대상 스트림 객체의 식별자.
  /// - Throws: `COSParseError` / `FilterError`; 대상이 스트림이 아니면 `XRefError`(.parseFailed).
  /// - Returns: 디코딩된 스트림 바이트.
  package func decodedStreamData(for id: ObjectID) async throws -> Data {
    let obj = try await self.object(for: id)
    guard case let .stream(stream) = obj else {
      throw XRefError(code: .parseFailed, offset: 0)
    }
    guard case let .fileRange(range) = stream.payload, let raw = self.file.bytes(in: range) else {
      throw XRefError(code: .parseFailed, offset: 0)
    }
    let dictionary = try await self.resolvedFilterDictionary(stream.dictionary)
    let decrypted = try self.securityHandler.decryptStream(raw, objectID: id)
    return try FilterPipeline.decode(raw: decrypted, dictionary: dictionary)
  }

  /// 캐시 상태 스냅숏.
  /// - Returns: 현재 캐시 통계.
  package func cacheStatistics() -> CacheStatistics {
    CacheStatistics(
      objectCacheCount: self.objectCache.count,
      objectStreamCacheBytes: self.objectStreamCache.totalCost,
      objectStreamCacheContainerCount: self.objectStreamCache.count,
      containerDecodeCount: self.containerDecodeCount,
      pageTreeBuildCount: self.pageTreeBuildCount,
      metadataBuildCount: self.metadataBuildCount,
      outlineBuildCount: self.outlineBuildCount,
      textExtractionCount: self.textExtractionCount,
      fontBuildCount: self.fontBuildCount,
      textPageCacheBytes: self.textPageCache.totalCost
    )
  }
}

// MARK: - /Filter·/DecodeParms 사전 해소 (decodedStreamData 전용, 일반 해소 경로)

extension PDFDocumentCore {
  /// /Filter·/DecodeParms의 `.reference`를 `resolve()`로 치환한 사본을 만든다
  /// (배열 내부 원소 포함, 1레벨).
  private func resolvedFilterDictionary(
    _ dictionary: COSDictionary
  ) async throws -> COSDictionary {
    var updated = dictionary
    if let filterValue = dictionary[.filter] {
      updated[.filter] = try await self.resolveShallow(filterValue)
    }
    for key in [COSName.decodeParms, COSName.dp] {
      if let value = dictionary[key] {
        updated[key] = try await self.resolveShallow(value)
      }
    }
    return updated
  }

  /// 값 자체 혹은(배열이면) 그 원소들의 참조만 해소한다 (비참조 값은 그대로).
  private func resolveShallow(_ value: COSObject) async throws -> COSObject {
    if case .reference = value {
      return try await self.resolve(value)
    }
    guard case let .array(elements) = value else {
      return value
    }
    var resolvedElements: [COSObject] = []
    resolvedElements.reserveCapacity(elements.count)
    for element in elements {
      if case .reference = element {
        resolvedElements.append(try await self.resolve(element))
      } else {
        resolvedElements.append(element)
      }
    }
    return .array(resolvedElements)
  }
}

// MARK: - /Length 리졸버, 암호화 감지

extension PDFDocumentCore {
  /// `/Length` 간접 참조 해소 클로저 (`XRefTable`+`MappedFile`만 캡처하는 `@Sendable` 동기 클로저).
  /// resolver 미주입으로 재귀를 구조적으로 차단한다.
  private static func makeLengthResolver(
    xref: XRefTable, file: MappedFile
  ) -> COSParser.LengthResolver {
    { id in
      guard case let .uncompressed(offset, _) = xref.entry(for: id.number) else {
        return nil
      }
      var parser = COSParser(file: file)
      return try parser.parseIndirectObject(at: offset).object.integerValue
    }
  }

  /// 암호화 감지 결과.
  private enum EncryptionDetection {
    /// 트레일러에 `/Encrypt`가 없음.
    case none
    /// `/Encrypt`가 존재함 (진단용 필터 이름, 해소 실패 시 `nil`).
    case detected(filterName: String?)
  }

  /// 병합 트레일러의 `/Encrypt`를 검사한다 (§3.6). xref 스트림·트레일러는 암호화 대상이
  /// 아니므로 이 검사는 `securityHandler`를 경유하지 않는다.
  private static func detectEncryption(table: XRefTable, file: MappedFile) -> EncryptionDetection {
    guard let encryptValue = table.trailer[.encrypt] else {
      return .none
    }
    switch encryptValue {
    case let .dictionary(dictionary):
      return .detected(filterName: dictionary.name(for: .filter)?.rawValue)
    case let .reference(id):
      guard case let .uncompressed(offset, _) = table.entry(for: id.number) else {
        return .detected(filterName: nil)
      }
      var parser = COSParser(file: file)
      guard let indirect = try? parser.parseIndirectObject(at: offset),
        case let .dictionary(dictionary) = indirect.object
      else {
        return .detected(filterName: nil)
      }
      return .detected(filterName: dictionary.name(for: .filter)?.rawValue)
    default:
      return .detected(filterName: nil)
    }
  }
}
