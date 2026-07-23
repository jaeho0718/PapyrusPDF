import CoreGraphics
import Foundation

/// 문서 열기 중 관용 복구가 개입했음을 알리는 경고 (열기는 성공했다).
///
/// struct + 대분류 enum 구조 — 세부는 `message`가 담는다. 대분류는 추가될 일이
/// 없는 안정 집합이라 공개 enum의 진화 문제를 피한다.
public struct OpenWarning: Sendable, Equatable, CustomStringConvertible {
  /// 경고 대분류.
  public enum Kind: Sendable, Equatable {
    /// 헤더/버전/%%EOF 이상.
    case header
    /// xref 체인/행/엔트리 이상 (편이 보정 포함).
    case crossReference
    /// 전역 복구 스캔 개입 (문서 구조를 재구성했다).
    case recovery
    /// 객체 스트림(ObjStm) 컨테이너 이상.
    case objectStream
    /// COS 구문 관용 처리.
    case parsing
  }

  /// 경고 대분류.
  public let kind: Kind

  /// 진단용 영문 상세 메시지.
  public let message: String

  /// `message`를 그대로 반환한다.
  public var description: String {
    self.message
  }
}

/// 문서 메타데이터 스냅숏 (/Info 우선, XMP 보충 병합 결과).
public struct DocumentMetadata: Sendable, Equatable {
  /// 문서 제목.
  public let title: String?

  /// 저자.
  public let author: String?

  /// 주제.
  public let subject: String?

  /// 키워드 (원문 문자열 그대로 — 분리하지 않는다).
  public let keywords: String?

  /// 문서를 만든 응용 프로그램.
  public let creator: String?

  /// PDF 변환기(프로듀서).
  public let producer: String?

  /// 생성 시각.
  public let creationDate: Date?

  /// 수정 시각.
  public let modificationDate: Date?

  /// PDF 버전 문자열 (예: "1.7"). 헤더와 카탈로그 /Version 중 큰 쪽.
  public let pdfVersion: String

  // 내부 생성은 자동 합성된 memberwise init을 그대로 쓴다 (internal 접근 수준이라
  // missing_docs 대상이 아니다 — SwiftLint unneeded_synthesized_initializer 준수).
}

/// 페이지 회전 (/Rotate 정규화 값, 시계 방향).
public enum PageRotation: Int, Sendable, Equatable, CaseIterable {
  /// 회전 없음.
  case degrees0 = 0
  /// 시계 방향 90도.
  case degrees90 = 90
  /// 180도.
  case degrees180 = 180
  /// 시계 방향 270도.
  case degrees270 = 270

  /// 90/270 여부 — 표시 크기의 가로·세로가 뒤집히는 회전인가.
  public var isQuarterTurn: Bool {
    self == .degrees90 || self == .degrees270
  }
}

/// 페이지 하나의 기하 정보 (상속 해소 완료 스냅숏).
public struct PageInfo: Sendable, Equatable {
  /// 페이지 인덱스 (0 기반).
  public let index: Int

  /// /MediaBox (PDF 포인트, 정규화 완료).
  public let mediaBox: CGRect

  /// /CropBox (MediaBox와 교집합·기본값 처리 완료) — 표시 기준 박스.
  public let cropBox: CGRect

  /// 페이지 회전.
  public let rotation: PageRotation

  /// 회전을 반영한 표시 크기 (cropBox 기준) — M6 레이아웃 엔진의 입력.
  public var displaySize: CGSize {
    let size = self.cropBox.size
    return self.rotation.isQuarterTurn
      ? CGSize(width: size.height, height: size.width) : size
  }

  /// 페이지 정보를 생성한다.
  /// - Parameters:
  ///   - index: 페이지 인덱스 (0 기반).
  ///   - mediaBox: /MediaBox (정규화 완료).
  ///   - cropBox: /CropBox (교집합·기본값 처리 완료).
  ///   - rotation: 페이지 회전.
  init(index: Int, mediaBox: CGRect, cropBox: CGRect, rotation: PageRotation) {
    self.index = index
    self.mediaBox = mediaBox
    self.cropBox = cropBox
    self.rotation = rotation
  }
}

/// 목차 항목 목적지. v1은 페이지 인덱스만 담는다 (좌표·배율은 추후 필드 추가 — 가정 5).
public struct OutlineDestination: Sendable, Equatable {
  /// 이동 대상 페이지 인덱스 (0 기반, 항상 `0..<pageCount` 안).
  public let pageIndex: Int

  // 내부 생성은 자동 합성된 memberwise init을 그대로 쓴다 (unneeded_synthesized_initializer).
}

/// 목차(북마크) 항목. 값 타입 트리.
public struct OutlineItem: Sendable, Equatable {
  /// 제목 (텍스트 문자열 디코딩 완료. /Title 부재 시 빈 문자열).
  public let title: String

  /// 해소된 목적지 (해소 실패·비-GoTo 액션이면 `nil` — 항목 자체는 유지된다).
  public let destination: OutlineDestination?

  /// 하위 항목.
  public let children: [OutlineItem]

  // 내부 생성은 자동 합성된 memberwise init을 그대로 쓴다 (unneeded_synthesized_initializer).
}

// MARK: - 내부 경고 매핑 (§4.2)

extension OpenWarning {
  /// package `CoreOpenWarning`을 공개 경고로 변환한다 (§4.2 대분류 표).
  /// - Parameter core: 변환할 내부 경고.
  init(_ core: CoreOpenWarning) {
    self.kind = Self.kind(for: core)
    self.message = Self.message(for: core)
  }

  /// 내부 경고를 대분류로 매핑한다.
  private static func kind(for core: CoreOpenWarning) -> Kind {
    switch core {
    case .junkBeforeHeader, .malformedVersion, .missingEOFMarker:
      return .header
    case .invalidStartxref, .xrefOffsetsBiased, .malformedXRefRow, .entryOutOfBounds,
      .xrefChainCycle, .xrefChainTruncated, .xrefSectionUnreadable, .xrefStreamTruncated:
      return .crossReference
    case .rebuiltViaRecoveryScan, .rootFoundBySignatureScan:
      return .recovery
    case .objectStreamMissingType, .objectStreamMemberOutOfBounds:
      return .objectStream
    case .parse:
      return .parsing
    }
  }

  /// 내부 경고를 사람이 읽을 수 있는 영문 메시지로 변환한다.
  private static func message(for core: CoreOpenWarning) -> String {
    switch core {
    case .junkBeforeHeader, .malformedVersion, .missingEOFMarker, .invalidStartxref,
      .xrefOffsetsBiased, .malformedXRefRow, .entryOutOfBounds, .xrefChainCycle,
      .xrefChainTruncated, .xrefSectionUnreadable, .xrefStreamTruncated:
      return Self.headerOrXRefMessage(for: core)
    case .rebuiltViaRecoveryScan, .rootFoundBySignatureScan, .objectStreamMissingType,
      .objectStreamMemberOutOfBounds, .parse:
      return Self.recoveryOrObjectStreamMessage(for: core)
    }
  }

  /// 헤더/xref 대분류 경고의 메시지 — 세부 그룹으로 한 번 더 나눈다(복잡도 관리).
  private static func headerOrXRefMessage(for core: CoreOpenWarning) -> String {
    switch core {
    case .junkBeforeHeader, .malformedVersion, .missingEOFMarker, .invalidStartxref:
      return Self.headerMessage(for: core)
    default:
      return Self.xrefMessage(for: core)
    }
  }

  /// 헤더 대분류 경고의 메시지.
  private static func headerMessage(for core: CoreOpenWarning) -> String {
    switch core {
    case let .junkBeforeHeader(byteCount):
      return "\(byteCount) junk bytes before %PDF header."
    case .malformedVersion:
      return "Malformed PDF version in header; fell back to 1.4."
    case .missingEOFMarker:
      return "Missing %%EOF marker."
    case .invalidStartxref:
      return "Invalid or missing startxref; fell back to recovery scan."
    default:
      return "" // 도달 불가 — 호출부가 이미 이 카테고리로 분기했다.
    }
  }

  /// xref 대분류 경고의 메시지.
  private static func xrefMessage(for core: CoreOpenWarning) -> String {
    switch core {
    case let .xrefOffsetsBiased(by):
      return "XRef offsets were biased by \(by) bytes and corrected."
    case let .malformedXRefRow(offset):
      return "Malformed classic xref row at offset \(offset); recovered."
    case let .entryOutOfBounds(objectNumber):
      return "XRef entry for object \(objectNumber) was out of file bounds; discarded."
    case let .xrefChainCycle(offset):
      return "XRef /Prev chain cycle detected at offset \(offset); chain truncated."
    case .xrefChainTruncated:
      return "XRef /Prev chain exceeded the maximum section count; truncated."
    case let .xrefSectionUnreadable(offset):
      return "XRef section at offset \(offset) was unreadable; chain truncated there."
    case let .xrefStreamTruncated(offset):
      return "XRef stream at offset \(offset) was shorter than declared; rows truncated."
    default:
      return "" // 도달 불가 — 호출부가 이미 이 카테고리로 분기했다.
    }
  }

  /// 복구/ObjStm/파싱 대분류 경고의 메시지.
  private static func recoveryOrObjectStreamMessage(for core: CoreOpenWarning) -> String {
    switch core {
    case .rebuiltViaRecoveryScan:
      return "Document structure was rebuilt via a full recovery scan."
    case .rootFoundBySignatureScan:
      return "Trailer was not found; /Root was located via a /Type /Catalog signature scan."
    case let .objectStreamMissingType(containerNumber):
      return "Object stream \(containerNumber) is missing /Type /ObjStm; accepted anyway."
    case let .objectStreamMemberOutOfBounds(containerNumber, objectNumber):
      return "Object \(objectNumber) in object stream \(containerNumber) was out of bounds; " +
        "discarded."
    case let .parse(warning):
      return "COS parsing tolerance: \(warning)."
    default:
      return "" // 도달 불가 — 호출부가 이미 이 카테고리로 분기했다.
    }
  }
}
