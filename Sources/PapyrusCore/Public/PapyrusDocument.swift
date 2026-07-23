import Foundation

/// 열린 PDF 문서. ``PDFDocumentCore`` 액터를 감싼 Sendable 퍼사드다.
///
/// 모든 getter는 async이며 반환값은 전부 Sendable 스냅숏 값 타입이다 (ARCHITECTURE.md
/// 동시성 모델). 무거운 계산(페이지 트리 평탄화 등)은 첫 접근 시 1회 수행 후 캐시된다.
public final class PapyrusDocument: Sendable {
  /// 내부 코어 액터 (M4~M7 확장이 같은 코어를 소비한다).
  package let core: PDFDocumentCore

  /// 열기 중 축적된 경고 (열기 이후 불변 — 동기 접근 가능).
  public let openWarnings: [OpenWarning]

  /// 완성된 상태로 퍼사드를 생성한다 (열기 플로우 전용).
  private init(core: PDFDocumentCore, openWarnings: [OpenWarning]) {
    self.core = core
    self.openWarnings = openWarnings
  }

  /// 파일 URL로 문서를 연다.
  /// - Parameter url: 열려는 PDF 파일의 위치.
  /// - Throws: ``PapyrusError/notAPDF``, ``PapyrusError/ioError(message:)``,
  ///   ``PapyrusError/encryptedDocument(filterName:)``, ``PapyrusError/damagedDocument``.
  /// - Returns: 열린 문서.
  public static func open(url: URL) async throws(PapyrusError) -> PapyrusDocument {
    do {
      let core = try await PDFDocumentCore.open(url: url)
      return PapyrusDocument(core: core, openWarnings: core.openWarnings.map(OpenWarning.init))
    } catch {
      throw PapyrusError(mapping: error)
    }
  }

  /// 인메모리 바이트로 문서를 연다.
  /// - Parameter data: 열려는 PDF 바이트.
  /// - Throws: ``open(url:)``와 동일 (단 `ioError`는 발생하지 않는다).
  /// - Returns: 열린 문서.
  public static func open(data: Data) async throws(PapyrusError) -> PapyrusDocument {
    do {
      let core = try await PDFDocumentCore.open(data: data)
      return PapyrusDocument(core: core, openWarnings: core.openWarnings.map(OpenWarning.init))
    } catch {
      throw PapyrusError(mapping: error)
    }
  }

  /// 페이지 수 (실측 — /Count 주장값이 아니다). 첫 접근 시 페이지 트리를 평탄화한다.
  public var pageCount: Int {
    get async throws(PapyrusError) {
      try await Self.mapErrors { try await self.core.pageTree().pageCount }
    }
  }

  /// 문서 메타데이터 (첫 접근 시 계산 후 캐시).
  public var metadata: DocumentMetadata {
    get async throws(PapyrusError) {
      try await Self.mapErrors { try await self.core.documentMetadata() }
    }
  }

  /// 목차 (부재 시 빈 배열, 첫 접근 시 계산 후 캐시).
  public var outline: [OutlineItem] {
    get async throws(PapyrusError) {
      try await Self.mapErrors { try await self.core.outlineItems() }
    }
  }

  /// 페이지 기하 정보를 반환한다. 첫 호출이 평탄화를 유발하고 이후는 O(1)이다.
  /// - Parameter index: 조회할 페이지 인덱스 (0 기반).
  /// - Throws: 인덱스 이탈 시 ``PapyrusError/pageOutOfRange(index:pageCount:)``.
  /// - Returns: 해당 페이지의 기하 정보.
  public func page(at index: Int) async throws(PapyrusError) -> PageInfo {
    let snapshot = try await Self.mapErrors { try await self.core.pageTree() }
    guard snapshot.records.indices.contains(index) else {
      throw PapyrusError.pageOutOfRange(index: index, pageCount: snapshot.pageCount)
    }
    let record = snapshot.records[index]
    return PageInfo(
      index: index, mediaBox: record.mediaBox, cropBox: record.cropBox,
      rotation: PageRotation(rawValue: record.rotationDegrees) ?? .degrees0
    )
  }

  /// untyped 내부 에러를 typed 공개 에러로 변환하는 경계 헬퍼.
  private static func mapErrors<Value: Sendable>(
    _ body: () async throws -> Value
  ) async throws(PapyrusError) -> Value {
    do {
      return try await body()
    } catch {
      throw PapyrusError(mapping: error)
    }
  }
}
