import Foundation

/// PapyrusPDF의 유일한 공개 에러 도메인입니다. 모든 공개 API는 `throws(PapyrusPDFError)`입니다.
public enum PapyrusPDFError: Error, Sendable, Equatable {
  /// 입력이 PDF가 아닙니다 (선두 1KB에 `%PDF-` 헤더 없음).
  case notAPDF

  /// 파일 열기/매핑 I/O 실패입니다. `message`는 진단용 설명입니다.
  case ioError(message: String)

  /// 암호화 문서입니다 — 아직 지원하지 않습니다. `filterName`은 /Encrypt /Filter 진단값입니다.
  case encryptedDocument(filterName: String?)

  /// 구조 손상으로 복구 불능이거나, 필수 구조(페이지 트리 루트 등) 해소가 불가능합니다.
  case damagedDocument

  /// 페이지 인덱스가 `0..<pageCount` 밖입니다.
  case pageOutOfRange(index: Int, pageCount: Int)

  /// 지원하지 않는 스트림 필터입니다. 페이지 텍스트 추출(``PapyrusPDFDocument/text(forPage:)``) 중
  /// 콘텐츠 스트림이 미지원 필터를 쓸 때 발생합니다.
  case unsupportedFilter(name: String)

  /// 호출 태스크가 취소되어 작업이 중단되었습니다. ``PapyrusPDFDocument/search(_:options:)``처럼
  /// `Task` 취소로 조기 종료될 수 있는 작업에서 발생합니다.
  case cancelled
}

extension PapyrusPDFError: LocalizedError {
  /// 사람이 읽을 수 있는 영문 설명입니다.
  public var errorDescription: String? {
    switch self {
    case .notAPDF:
      return "The input is not a PDF file (missing %PDF- header)."
    case let .ioError(message):
      return "I/O error while opening the document: \(message)"
    case let .encryptedDocument(filterName):
      let name = filterName ?? "unknown"
      return "The document is encrypted (filter: \(name)) and encrypted documents are not " +
        "supported."
    case .damagedDocument:
      return "The document structure is damaged beyond recovery."
    case let .pageOutOfRange(index, pageCount):
      return "Page index \(index) is out of range (document has \(pageCount) pages)."
    case let .unsupportedFilter(name):
      return "Unsupported stream filter: \(name)."
    case .cancelled:
      return "The operation was cancelled."
    }
  }
}

// MARK: - 내부 에러 매핑 (§4.2)

extension PapyrusPDFError {
  /// 내부 에러를 공개 에러로 매핑한다 (§4.2 표). 미지의 에러는 `.damagedDocument`.
  /// - Parameter error: 매핑할 내부 에러.
  init(mapping error: any Error) {
    switch error {
    case let openError as DocumentOpenError:
      self = Self.mapOpenError(openError)
    case is CancellationError:
      self = .cancelled
    case let filterError as FilterError:
      self = Self.mapFilterError(filterError)
    default:
      self = .damagedDocument
    }
  }

  /// `DocumentOpenError` 케이스를 공개 에러로 매핑한다.
  private static func mapOpenError(_ error: DocumentOpenError) -> PapyrusPDFError {
    switch error {
    case .notAPDF:
      return .notAPDF
    case let .ioError(underlying):
      return .ioError(message: String(describing: underlying))
    case let .encryptedDocument(filterName):
      return .encryptedDocument(filterName: filterName)
    case .damagedBeyondRecovery:
      return .damagedDocument
    }
  }

  /// `FilterError` 케이스를 공개 에러로 매핑한다 (미지원 필터는 그대로 전달, 나머지는 손상).
  private static func mapFilterError(_ error: FilterError) -> PapyrusPDFError {
    guard case let .unsupportedFilter(name) = error.code else {
      return .damagedDocument
    }
    return .unsupportedFilter(name: name.rawValue)
  }
}
