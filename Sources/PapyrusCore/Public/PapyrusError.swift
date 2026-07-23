import Foundation

/// Papyrus의 유일한 공개 에러 도메인. 모든 공개 API는 `throws(PapyrusError)`다.
public enum PapyrusError: Error, Sendable, Equatable {
  /// 입력이 PDF가 아니다 (선두 1KB에 `%PDF-` 헤더 없음).
  case notAPDF

  /// 파일 열기/매핑 I/O 실패. `message`는 진단용 설명이다.
  case ioError(message: String)

  /// 암호화 문서 — v1은 지원하지 않는다. `filterName`은 /Encrypt /Filter 진단값.
  case encryptedDocument(filterName: String?)

  /// 구조 손상으로 복구 불능이거나, 필수 구조(페이지 트리 루트 등) 해소가 불가능하다.
  case damagedDocument

  /// 페이지 인덱스가 `0..<pageCount` 밖이다.
  case pageOutOfRange(index: Int, pageCount: Int)

  /// 지원하지 않는 스트림 필터 (M4 텍스트 추출부터 발화 — v1 케이스는 지금 전부 선언한다).
  case unsupportedFilter(name: String)

  /// 호출 태스크 취소로 중단됨 (M7 검색부터 발화 — v1 케이스는 지금 전부 선언한다).
  case cancelled
}

extension PapyrusError: LocalizedError {
  /// 사람이 읽을 수 있는 영문 설명.
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

extension PapyrusError {
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
  private static func mapOpenError(_ error: DocumentOpenError) -> PapyrusError {
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
  private static func mapFilterError(_ error: FilterError) -> PapyrusError {
    guard case let .unsupportedFilter(name) = error.code else {
      return .damagedDocument
    }
    return .unsupportedFilter(name: name.rawValue)
  }
}
