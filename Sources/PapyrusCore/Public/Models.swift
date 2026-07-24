import CoreGraphics
import Foundation

/// 문서 열기 중 관용 복구가 개입했음을 알리는 경고입니다 (열기는 성공했습니다).
///
/// struct + 대분류 enum 구조입니다 — 세부는 `message`가 담습니다. 대분류는 추가될 일이
/// 없는 안정 집합이라 공개 enum의 진화 문제를 피합니다.
public struct OpenWarning: Sendable, Equatable, CustomStringConvertible {
  /// 경고 대분류입니다.
  public enum Kind: Sendable, Equatable {
    /// 헤더/버전/%%EOF 이상입니다.
    case header
    /// xref 체인/행/엔트리 이상입니다 (편이 보정 포함).
    case crossReference
    /// 전역 복구 스캔 개입입니다 (문서 구조를 재구성했습니다).
    case recovery
    /// 객체 스트림(ObjStm) 컨테이너 이상입니다.
    case objectStream
    /// COS 구문 관용 처리입니다.
    case parsing
  }

  /// 경고 대분류입니다.
  public let kind: Kind

  /// 진단용 영문 상세 메시지입니다.
  public let message: String

  /// `message`를 그대로 반환합니다.
  public var description: String {
    self.message
  }
}

/// 문서 메타데이터 스냅숏입니다 (/Info 우선, XMP 보충 병합 결과).
public struct DocumentMetadata: Sendable, Equatable {
  /// 문서 제목입니다.
  public let title: String?

  /// 저자입니다.
  public let author: String?

  /// 주제입니다.
  public let subject: String?

  /// 키워드입니다 (원문 문자열 그대로 — 분리하지 않습니다).
  public let keywords: String?

  /// 문서를 만든 응용 프로그램입니다.
  public let creator: String?

  /// PDF 변환기(프로듀서)입니다.
  public let producer: String?

  /// 생성 시각입니다.
  public let creationDate: Date?

  /// 수정 시각입니다.
  public let modificationDate: Date?

  /// PDF 버전 문자열입니다 (예: "1.7"). 헤더와 카탈로그 /Version 중 큰 쪽입니다.
  public let pdfVersion: String

  // 내부 생성은 자동 합성된 memberwise init을 그대로 쓴다 (internal 접근 수준이라
  // missing_docs 대상이 아니다 — SwiftLint unneeded_synthesized_initializer 준수).
}

/// 페이지 회전입니다 (/Rotate 정규화 값, 시계 방향).
public enum PageRotation: Int, Sendable, Equatable, CaseIterable {
  /// 회전 없음입니다.
  case degrees0 = 0
  /// 시계 방향 90도입니다.
  case degrees90 = 90
  /// 180도입니다.
  case degrees180 = 180
  /// 시계 방향 270도입니다.
  case degrees270 = 270

  /// 90/270 여부 — 표시 크기의 가로·세로가 뒤집히는 회전입니까?
  public var isQuarterTurn: Bool {
    self == .degrees90 || self == .degrees270
  }
}

/// 페이지 하나의 기하 정보입니다 (상속 해소 완료 스냅숏).
public struct PageInfo: Sendable, Equatable {
  /// 페이지 인덱스입니다 (0 기반).
  public let index: Int

  /// /MediaBox입니다 (PDF 포인트, 정규화 완료).
  public let mediaBox: CGRect

  /// /CropBox (MediaBox와 교집합·기본값 처리 완료) — 표시 기준 박스입니다.
  public let cropBox: CGRect

  /// 페이지 회전입니다.
  public let rotation: PageRotation

  /// 회전을 반영한 표시 크기입니다 (cropBox 기준) — 뷰어 레이아웃 계산의 입력값입니다.
  public var displaySize: CGSize {
    PageGeometry.displaySize(
      cropBoxSize: self.cropBox.size, normalizedRotationDegrees: self.rotation.rawValue
    )
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

/// 목차 항목 목적지입니다. v1은 페이지 인덱스만 담습니다 (좌표·배율은 추후 필드 추가 — 가정 5).
public struct OutlineDestination: Sendable, Equatable {
  /// 이동 대상 페이지 인덱스입니다 (0 기반, 항상 `0..<pageCount` 안).
  public let pageIndex: Int

  // 내부 생성은 자동 합성된 memberwise init을 그대로 쓴다 (unneeded_synthesized_initializer).
}

/// 목차(북마크) 항목입니다. 값 타입 트리입니다.
public struct OutlineItem: Sendable, Equatable {
  /// 제목입니다 (텍스트 문자열 디코딩 완료. /Title 부재 시 빈 문자열).
  public let title: String

  /// 해소된 목적지입니다 (해소 실패·비-GoTo 액션이면 `nil` — 항목 자체는 유지됩니다).
  public let destination: OutlineDestination?

  /// 하위 항목입니다.
  public let children: [OutlineItem]

  // 내부 생성은 자동 합성된 memberwise init을 그대로 쓴다 (unneeded_synthesized_initializer).
}

/// PDF 페이지 공간의 사변형입니다 (회전·기울임 텍스트를 표현하는 4점).
///
/// 꼭짓점 순서는 베이스라인 기준: 시작-아래(bottomLeft) → 끝-아래(bottomRight) →
/// 끝-위(topRight) → 시작-위(topLeft)입니다. 축 정렬이 아닐 수 있습니다.
public struct Quad: Sendable, Equatable {
  /// 베이스라인 시작 쪽 아래 꼭짓점입니다.
  public let bottomLeft: CGPoint
  /// 베이스라인 끝 쪽 아래 꼭짓점입니다.
  public let bottomRight: CGPoint
  /// 베이스라인 끝 쪽 위 꼭짓점입니다.
  public let topRight: CGPoint
  /// 베이스라인 시작 쪽 위 꼭짓점입니다.
  public let topLeft: CGPoint

  /// 사변형을 생성합니다.
  /// - Parameters:
  ///   - bottomLeft: 베이스라인 시작 쪽 아래 꼭짓점입니다.
  ///   - bottomRight: 베이스라인 끝 쪽 아래 꼭짓점입니다.
  ///   - topRight: 베이스라인 끝 쪽 위 꼭짓점입니다.
  ///   - topLeft: 베이스라인 시작 쪽 위 꼭짓점입니다.
  public init(bottomLeft: CGPoint, bottomRight: CGPoint, topRight: CGPoint, topLeft: CGPoint) {
    self.bottomLeft = bottomLeft
    self.bottomRight = bottomRight
    self.topRight = topRight
    self.topLeft = topLeft
  }

  /// 4점을 모두 포함하는 축 정렬 최소 사각형입니다.
  public var boundingRect: CGRect {
    let xs = [self.bottomLeft.x, self.bottomRight.x, self.topRight.x, self.topLeft.x]
    let ys = [self.bottomLeft.y, self.bottomRight.y, self.topRight.y, self.topLeft.y]
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
      return .zero
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}

/// 직렬화를 지원합니다. 형식: `{"bottomLeft": [x, y], "bottomRight": …}` — 꼭짓점별
/// 키에 좌표 2원소 배열입니다.
extension Quad: Codable {}

extension Quad {
  /// 축 정렬 사각형을 quad로 변환합니다 (PDF 페이지 공간 y-위 기준 —
  /// `bottomLeft = (minX, minY)`). 영역 등록·OCR 박스 공급 편의입니다.
  ///
  /// 음수 크기 rect는 표준화되며, 비유한 좌표가 섞인 rect는 영점 quad가 됩니다.
  /// - Parameter rect: 변환할 축 정렬 사각형입니다 (PDF 페이지 공간).
  public init(rect: CGRect) {
    let standardized = rect.standardized
    guard standardized.minX.isFinite, standardized.minY.isFinite, standardized.maxX.isFinite,
      standardized.maxY.isFinite
    else {
      self.init(bottomLeft: .zero, bottomRight: .zero, topRight: .zero, topLeft: .zero)
      return
    }
    self.init(
      bottomLeft: CGPoint(x: standardized.minX, y: standardized.minY),
      bottomRight: CGPoint(x: standardized.maxX, y: standardized.minY),
      topRight: CGPoint(x: standardized.maxX, y: standardized.maxY),
      topLeft: CGPoint(x: standardized.minX, y: standardized.maxY)
    )
  }
}

/// 같은 텍스트 상태로 그려진 연속 글리프 묶음 하나의 스냅숏입니다.
public struct TextRun: Sendable, Equatable {
  /// ``PageTextContent/string`` 안에서 이 run이 차지하는 UTF-16 코드유닛 구간입니다.
  public let range: Range<Int>
  /// 페이지 공간 사변형입니다 (ascent/descent 박스).
  public let quad: Quad
  /// UTF-16 코드유닛당 베이스라인 방향 전진량입니다 (페이지 공간 단위).
  /// `count == range.count`. 다중 유닛 글리프는 첫 유닛에 전액 귀속됩니다.
  public let advances: [CGFloat]
  /// Tr 3(투명 텍스트, OCR 레이어) 여부입니다. 문자열에는 포함되고 표시만 안 된 텍스트입니다.
  public let isInvisible: Bool

  /// run을 생성합니다.
  /// - Parameters:
  ///   - range: ``PageTextContent/string`` 안에서 이 run이 차지하는 UTF-16 코드유닛 구간입니다.
  ///   - quad: 페이지 공간 사변형입니다.
  ///   - advances: UTF-16 코드유닛당 베이스라인 방향 전진량입니다.
  ///   - isInvisible: Tr 3 여부입니다.
  public init(range: Range<Int>, quad: Quad, advances: [CGFloat], isInvisible: Bool) {
    self.range = range
    self.quad = quad
    self.advances = advances
    self.isInvisible = isInvisible
  }
}

extension TextRun {
  /// 문자별 전진량 정보가 없는 소스(OCR 등)를 위한 균등 advance run을 만듭니다.
  ///
  /// quad 보간이 전진량 **비율**만 사용하므로 절대 폭 없이도 부분 하이라이트·히트테스트가
  /// 동작합니다 (문자 폭이 실제와 다르면 글자 경계 정밀도만 낮아집니다).
  /// - Parameters:
  ///   - range: ``PageTextContent/string`` 안에서 이 run이 차지하는 UTF-16 코드유닛 구간입니다.
  ///   - quad: 페이지 공간 사변형입니다.
  ///   - isInvisible: Tr 3 여부입니다 (기본 `false`).
  /// - Returns: 균등 전진량을 갖는 run입니다.
  public static func uniform(range: Range<Int>, quad: Quad, isInvisible: Bool = false) -> TextRun {
    TextRun(
      range: range, quad: quad, advances: Array(repeating: 1, count: range.count),
      isInvisible: isInvisible
    )
  }
}

/// 페이지 하나의 텍스트 추출 결과 스냅숏입니다.
public struct PageTextContent: Sendable, Equatable {
  /// 페이지 인덱스입니다 (0 기반).
  public let pageIndex: Int
  /// 조립된 페이지 문자열입니다 (읽기 순서 휴리스틱 적용, 공백/줄바꿈 삽입 완료).
  public let string: String
  /// run 목록입니다. 삽입된 공백·줄바꿈은 어느 run에도 속하지 않습니다.
  ///
  /// run은 `range.lowerBound` 오름차순입니다 (Papyrus가 생성한 값의 계약이며, 직접
  /// 생성할 때도 이 순서를 권장합니다 — 어긋난 값은 소비 시점에 정렬됩니다).
  public let runs: [TextRun]

  /// 페이지 텍스트 스냅숏을 생성합니다.
  /// - Parameters:
  ///   - pageIndex: 페이지 인덱스입니다 (0 기반).
  ///   - string: 조립된 페이지 문자열입니다.
  ///   - runs: run 목록입니다.
  public init(pageIndex: Int, string: String, runs: [TextRun]) {
    self.pageIndex = pageIndex
    self.string = string
    self.runs = runs
  }
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
