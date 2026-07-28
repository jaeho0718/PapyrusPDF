import Foundation

/// 열린 PDF 문서입니다. 내부 문서 코어 액터를 감싼 Sendable 퍼사드입니다.
///
/// 모든 getter는 async이며 반환값은 전부 Sendable 스냅숏 값 타입입니다.
/// 무거운 계산(페이지 트리 평탄화 등)은 첫 접근 시 1회 수행 후 캐시됩니다.
public final class PapyrusPDFDocument: Sendable {
  /// 내부 코어 액터 (M4~M7 확장이 같은 코어를 소비한다).
  package let core: PDFDocumentCore

  /// 열기 중 축적된 경고입니다 (열기 이후 불변 — 동기 접근 가능).
  public let openWarnings: [OpenWarning]

  /// 완성된 상태로 퍼사드를 생성한다 (열기 플로우 전용).
  private init(core: PDFDocumentCore, openWarnings: [OpenWarning]) {
    self.core = core
    self.openWarnings = openWarnings
  }

  /// 파일 URL로 문서를 엽니다.
  /// - Parameter url: 열려는 PDF 파일의 위치입니다.
  /// - Throws: ``PapyrusPDFError/notAPDF``, ``PapyrusPDFError/ioError(message:)``,
  ///   ``PapyrusPDFError/encryptedDocument(filterName:)``, ``PapyrusPDFError/damagedDocument``입니다.
  /// - Returns: 열린 문서입니다.
  public static func open(url: URL) async throws(PapyrusPDFError) -> PapyrusPDFDocument {
    do {
      let core = try await PDFDocumentCore.open(url: url)
      return PapyrusPDFDocument(core: core, openWarnings: core.openWarnings.map(OpenWarning.init))
    } catch {
      throw PapyrusPDFError(mapping: error)
    }
  }

  /// 인메모리 바이트로 문서를 엽니다.
  /// - Parameter data: 열려는 PDF 바이트입니다.
  /// - Throws: ``open(url:)``와 동일합니다 (단 `ioError`는 발생하지 않습니다).
  /// - Returns: 열린 문서입니다.
  public static func open(data: Data) async throws(PapyrusPDFError) -> PapyrusPDFDocument {
    do {
      let core = try await PDFDocumentCore.open(data: data)
      return PapyrusPDFDocument(core: core, openWarnings: core.openWarnings.map(OpenWarning.init))
    } catch {
      throw PapyrusPDFError(mapping: error)
    }
  }

  /// 페이지 수입니다 (실측 — /Count 주장값이 아닙니다). 첫 접근 시 페이지 트리를 평탄화합니다.
  /// - Throws: 페이지 트리 루트(/Root, /Pages)를 해소할 수 없을 정도로 문서가 손상됐다면
  ///   ``PapyrusPDFError/damagedDocument``, 호출이 취소됐다면 ``PapyrusPDFError/cancelled``입니다.
  ///   개별 페이지 노드의 이상은 관용 처리되어 이 프로퍼티를 실패시키지 않습니다.
  public var pageCount: Int {
    get async throws(PapyrusPDFError) {
      try await Self.mapErrors { try await self.core.pageTree().pageCount }
    }
  }

  /// 문서 메타데이터입니다 (첫 접근 시 계산 후 캐시).
  ///
  /// /Info·XMP 수집·병합 과정의 결함은 전부 관용 처리되어(해당 필드만 `nil`) 실질적으로
  /// 실패하지 않습니다.
  /// - Throws: 호출이 취소됐다면 ``PapyrusPDFError/cancelled``입니다.
  public var metadata: DocumentMetadata {
    get async throws(PapyrusPDFError) {
      try await Self.mapErrors { try await self.core.documentMetadata() }
    }
  }

  /// 목차입니다 (부재 시 빈 배열, 첫 접근 시 계산 후 캐시).
  ///
  /// 목차 항목 자체의 순환·손상은 관용 처리(절단)되므로 이 프로퍼티를 실패시키지 않습니다.
  /// - Throws: 내부적으로 페이지 트리를 먼저 확보하므로 ``pageCount``와 동일한 조건 —
  ///   ``PapyrusPDFError/damagedDocument`` 또는 ``PapyrusPDFError/cancelled``입니다.
  public var outline: [OutlineItem] {
    get async throws(PapyrusPDFError) {
      try await Self.mapErrors { try await self.core.outlineItems() }
    }
  }

  /// 페이지 기하 정보를 반환합니다. 첫 호출이 평탄화를 유발하고 이후는 O(1)입니다.
  /// - Parameter index: 조회할 페이지 인덱스입니다 (0 기반).
  /// - Throws: 인덱스 이탈 시 ``PapyrusPDFError/pageOutOfRange(index:pageCount:)``입니다.
  /// - Returns: 해당 페이지의 기하 정보입니다.
  public func page(at index: Int) async throws(PapyrusPDFError) -> PageInfo {
    let snapshot = try await Self.mapErrors { try await self.core.pageTree() }
    guard snapshot.records.indices.contains(index) else {
      throw PapyrusPDFError.pageOutOfRange(index: index, pageCount: snapshot.pageCount)
    }
    let record = snapshot.records[index]
    return PageInfo(
      index: index, mediaBox: record.mediaBox, cropBox: record.cropBox,
      rotation: PageRotation(rawValue: record.rotationDegrees) ?? .degrees0
    )
  }

  /// 페이지 텍스트를 추출합니다. 결과는 문서 전역 바이트 예산 LRU에 캐시되고,
  /// 동시 요청은 페이지별 in-flight dedupe로 합류합니다.
  /// - Parameter index: 페이지 인덱스입니다 (0 기반).
  /// - Throws: 인덱스 이탈 시 ``PapyrusPDFError/pageOutOfRange(index:pageCount:)``,
  ///   콘텐츠 스트림이 미지원 필터를 쓰면 ``PapyrusPDFError/unsupportedFilter(name:)``,
  ///   구조 손상은 ``PapyrusPDFError/damagedDocument``입니다.
  /// - Returns: 페이지 텍스트 스냅숏입니다 (콘텐츠 없는 페이지는 빈 문자열).
  public func text(forPage index: Int) async throws(PapyrusPDFError) -> PageTextContent {
    let snapshot = try await Self.mapErrors { try await self.core.pageTree() }
    guard snapshot.records.indices.contains(index) else {
      throw PapyrusPDFError.pageOutOfRange(index: index, pageCount: snapshot.pageCount)
    }
    return try await Self.mapErrors { try await self.core.pageText(at: index) }
  }

  /// untyped 내부 에러를 typed 공개 에러로 변환하는 경계 헬퍼.
  private static func mapErrors<Value: Sendable>(
    _ body: () async throws -> Value
  ) async throws(PapyrusPDFError) -> Value {
    do {
      return try await body()
    } catch {
      throw PapyrusPDFError(mapping: error)
    }
  }
}
