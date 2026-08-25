import CoreGraphics
import PapyrusPDFCore

// 이 파일은 `PapyrusPDFReaderModel`이 쓰는 값 타입(`ReaderPosition`·`ReaderLoadState`·
// `PendingReaderCommand`·`ReaderSearchState`)을 담는다 — 본체 파일 길이 한도로 이설
// (`ReaderSelectionController+Types.swift` 전례). 모델 본체는
// `PapyrusPDFReaderModel.swift`(+Highlights) 참조.

/// 읽던 위치 스냅숏입니다 (저장·복원용, `Codable`).
public struct ReaderPosition: Sendable, Codable, Equatable {
  /// 뷰포트 상단이 걸친 페이지 인덱스입니다 (0 기반).
  public let pageIndex: Int
  /// 페이지 안 정규화 세로 오프셋입니다 (0 = 페이지 상단, 1 = 하단; [0,1] 클램프).
  /// 정규화 이유: 다른 창 크기·기기에서 복원해도 같은 내용 위치를 가리킵니다.
  public let normalizedOffset: CGFloat
  /// 줌 배율입니다. 복원 시 그 시점 유효 범위 [fitWidth, max]로 클램프됩니다.
  public let zoomScale: CGFloat

  /// 위치 스냅숏을 생성합니다 (외부에서 직접 조립·역직렬화 가능해야 하므로 public init).
  /// - Parameters:
  ///   - pageIndex: 뷰포트 상단이 걸친 페이지 인덱스입니다.
  ///   - normalizedOffset: 페이지 안 정규화 세로 오프셋입니다 ([0,1]).
  ///   - zoomScale: 줌 배율입니다.
  public init(pageIndex: Int, normalizedOffset: CGFloat, zoomScale: CGFloat) {
    self.pageIndex = pageIndex
    self.normalizedOffset = normalizedOffset
    self.zoomScale = zoomScale
  }
}

/// 뷰어 적재 상태입니다.
public enum ReaderLoadState: Sendable, Equatable {
  /// 렌더 서비스 조립 중입니다 (페이지 트리 접근).
  case loading
  /// 표시 중입니다.
  case ready
  /// 열기·페이지 트리 실패입니다 (문서 자체가 표시 불가).
  case failed(PapyrusPDFError)
}

/// 연결 전에 접수된 탐색 명령 (연결 직후 1회 재생 — §4.1).
enum PendingReaderCommand {
  /// 보류된 `goToPage` 호출.
  case goToPage(index: Int, animated: Bool)
  /// 보류된 `restore` 호출.
  case restore(ReaderPosition)
}

/// 검색 요약 상태입니다 (``PapyrusPDFReaderModel/searchState``로 관찰합니다).
public struct ReaderSearchState: Sendable, Equatable {
  /// 진행 단계입니다.
  public enum Phase: Sendable, Equatable {
    /// 검색 없음입니다.
    case idle
    /// 스트림 소비 중입니다 (부분 결과 사용 가능).
    case searching
    /// 완료입니다 (matchCount 확정).
    case completed
    /// 문서 수준 실패입니다.
    case failed(PapyrusPDFError)
  }

  /// 현재 질의입니다 (idle이면 빈 문자열).
  public let query: String
  /// 진행 단계입니다.
  public let phase: Phase
  /// 지금까지 발견한 매치 수입니다 (searching 중엔 증가).
  public let matchCount: Int
  /// 현재 매치 순번입니다 (0 기반, 매치 없으면 `nil`).
  public let currentMatchIndex: Int?

  /// idle 초기값입니다.
  public static let idle = ReaderSearchState(
    query: "", phase: .idle, matchCount: 0, currentMatchIndex: nil
  )
}
