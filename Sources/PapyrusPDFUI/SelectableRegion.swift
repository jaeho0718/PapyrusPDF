import PapyrusPDFCore

/// 개발자 정의 선택 가능 영역입니다. 탭(클릭) 시 선택 상태가 되고 선택 메뉴가 표시됩니다.
///
/// 영역은 ``PapyrusPDFReaderModel/setSelectableRegions(_:forPage:)``로 페이지 단위 등록하며,
/// 탭으로 선택되면 ``SelectionContext/region(_:)`` 컨텍스트로 선택 메뉴 빌더에 전달됩니다.
/// 텍스트 선택과 상호 배타입니다 — 영역을 선택하면 텍스트 선택이 해제되고, 반대도
/// 동일합니다.
///
/// `metadata`는 임의 `Sendable` 값입니다. 메뉴 액션에서 등록 시 넣은 타입으로 캐스팅해
/// 사용합니다:
///
/// ```swift
/// struct FigureInfo: Sendable { let caption: String }
///
/// model.setSelectableRegions(
///   [SelectableRegion(id: "figure-1", pageIndex: 3,
///                     quad: Quad(rect: figureRect),
///                     metadata: FigureInfo(caption: "그림 1"))],
///   forPage: 3
/// )
///
/// // 메뉴 빌더에서:
/// if case let .region(region) = context,
///    let info = region.metadata as? FigureInfo { … }
/// ```
public struct SelectableRegion: Identifiable, Sendable {
  /// 영역 식별자입니다 (개발자 지정 — 같은 페이지 안에서 유일해야 합니다).
  public let id: String
  /// 페이지 인덱스입니다 (0 기반).
  public let pageIndex: Int
  /// 영역 사변형입니다 (PDF 페이지 공간 — 축 정렬 사각형은 `Quad(rect:)` 편의를
  /// 사용할 수 있습니다). 볼록 사변형을 전제합니다.
  public let quad: Quad
  /// 개발자 정의 메타데이터입니다 (메뉴 액션에서 등록 시 타입으로 캐스팅해 사용합니다).
  public let metadata: (any Sendable)?

  /// 영역을 생성합니다.
  /// - Parameters:
  ///   - id: 영역 식별자입니다 (같은 페이지 안에서 유일해야 합니다).
  ///   - pageIndex: 페이지 인덱스입니다 (0 기반).
  ///   - quad: 영역 사변형입니다 (PDF 페이지 공간).
  ///   - metadata: 개발자 정의 메타데이터입니다.
  public init(id: String, pageIndex: Int, quad: Quad, metadata: (any Sendable)? = nil) {
    self.id = id
    self.pageIndex = pageIndex
    self.quad = quad
    self.metadata = metadata
  }
}
