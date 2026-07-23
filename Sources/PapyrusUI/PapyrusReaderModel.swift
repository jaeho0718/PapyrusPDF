import CoreGraphics
import Observation
import PapyrusCore

/// 읽던 위치 스냅숏 (저장·복원용, Codable — ARCHITECTURE 127행).
public struct ReaderPosition: Sendable, Codable, Equatable {
  /// 뷰포트 상단이 걸친 페이지 인덱스 (0 기반).
  public let pageIndex: Int
  /// 페이지 안 정규화 세로 오프셋 (0 = 페이지 상단, 1 = 하단; [0,1] 클램프).
  /// 정규화 이유: 다른 창 크기·기기에서 복원해도 같은 내용 위치를 가리킨다.
  public let normalizedOffset: CGFloat
  /// 줌 배율. 복원 시 그 시점 유효 범위 [fitWidth, max]로 클램프된다.
  public let zoomScale: CGFloat

  /// 위치 스냅숏을 생성한다 (외부에서 직접 조립·역직렬화 가능해야 하므로 public init).
  /// - Parameters:
  ///   - pageIndex: 뷰포트 상단이 걸친 페이지 인덱스.
  ///   - normalizedOffset: 페이지 안 정규화 세로 오프셋 ([0,1]).
  ///   - zoomScale: 줌 배율.
  public init(pageIndex: Int, normalizedOffset: CGFloat, zoomScale: CGFloat) {
    self.pageIndex = pageIndex
    self.normalizedOffset = normalizedOffset
    self.zoomScale = zoomScale
  }
}

/// 뷰어 적재 상태.
public enum ReaderLoadState: Sendable, Equatable {
  /// 렌더 서비스 조립 중 (페이지 트리 접근).
  case loading
  /// 표시 중.
  case ready
  /// 열기·페이지 트리 실패 (문서 자체가 표시 불가).
  case failed(PapyrusError)
}

/// 연결 전에 접수된 탐색 명령 (연결 직후 1회 재생 — §4.1).
enum PendingReaderCommand {
  /// 보류된 `goToPage` 호출.
  case goToPage(index: Int, animated: Bool)
  /// 보류된 `restore` 호출.
  case restore(ReaderPosition)
}

/// 검색 요약 상태 (모델 관찰용 — ARCHITECTURE 132행 searchState).
public struct ReaderSearchState: Sendable, Equatable {
  /// 진행 단계.
  public enum Phase: Sendable, Equatable {
    /// 검색 없음.
    case idle
    /// 스트림 소비 중 (부분 결과 사용 가능).
    case searching
    /// 완료 (matchCount 확정).
    case completed
    /// 문서 수준 실패.
    case failed(PapyrusError)
  }

  /// 현재 질의 (idle이면 빈 문자열).
  public let query: String
  /// 진행 단계.
  public let phase: Phase
  /// 지금까지 발견한 매치 수 (searching 중엔 증가).
  public let matchCount: Int
  /// 현재 매치 순번 (0 기반, 매치 없으면 `nil`).
  public let currentMatchIndex: Int?

  /// idle 초기값.
  public static let idle = ReaderSearchState(
    query: "", phase: .idle, matchCount: 0, currentMatchIndex: nil
  )
}

/// 뷰어 관찰·제어 모델 (ARCHITECTURE 129행).
///
/// 생성 → `PapyrusReader(document:model:)`에 전달 → 뷰가 내부에서 코어와 연결.
/// 연결 전 호출된 탐색 명령은 보류했다가 연결 직후 1회 재생한다 (§4.1 —
/// "열자마자 goToPage" 사용 패턴이 자연스럽게 동작해야 한다).
@MainActor
@Observable
public final class PapyrusReaderModel {
  /// 적재 상태.
  public private(set) var loadState: ReaderLoadState = .loading
  /// 페이지 수 (적재 전 0).
  public private(set) var pageCount = 0
  /// 현재 페이지 인덱스 (뷰포트 중앙 기준, 적재 전 0).
  public private(set) var currentPageIndex = 0
  /// 가시 페이지 범위 (적재 전 0..<0).
  public private(set) var visiblePageRange: Range<Int> = 0..<0
  /// 현재 줌 배율 (적재 전 1).
  public private(set) var zoomScale: CGFloat = 1

  /// 검색 상태 (기본 `.idle`).
  public private(set) var searchState: ReaderSearchState = .idle

  /// 연결된 코어 (연결 전 `nil`).
  private var core: ReaderCore?

  /// 연결 전 접수되어 연결 직후 재생될 탐색 명령 (최신 것만 유지).
  private var pendingCommand: PendingReaderCommand?

  /// 연결 전 접수되어 연결 직후 재생될 검색 (최신 것만 유지 — 탐색 명령과 별도 슬롯이라
  /// 서로를 밀어내지 않는다).
  private var pendingSearch: (query: String, options: SearchOptions)?

  /// 모델을 만든다.
  public init() {}

  /// 페이지 상단으로 이동한다 (범위 밖은 클램프).
  /// - Parameters:
  ///   - index: 이동할 페이지 인덱스.
  ///   - animated: 애니메이션 여부.
  public func goToPage(_ index: Int, animated: Bool = true) {
    guard let core else {
      self.pendingCommand = .goToPage(index: index, animated: animated)
      return
    }
    core.goToPage(index, animated: animated)
  }

  /// 목차 목적지로 이동한다 (`OutlineDestination.pageIndex` — v1 목적지는 페이지 단위).
  /// - Parameters:
  ///   - destination: 이동할 목차 목적지.
  ///   - animated: 애니메이션 여부.
  public func go(to destination: OutlineDestination, animated: Bool = true) {
    self.goToPage(destination.pageIndex, animated: animated)
  }

  /// 현재 위치 스냅숏 (적재 전 nil).
  /// - Returns: 현재 위치 스냅숏, 미연결이면 `nil`.
  public func capturePosition() -> ReaderPosition? {
    self.core?.capturePosition()
  }

  /// 위치를 복원한다 (적재 전 호출 시 보류 후 적재 직후 적용).
  /// - Parameter position: 복원할 위치 스냅숏.
  public func restore(_ position: ReaderPosition) {
    guard let core else {
      self.pendingCommand = .restore(position)
      return
    }
    core.restore(position, animated: true)
  }

  /// 검색을 시작한다. 빈(공백뿐) query는 `clearSearch()`와 동일하다. 연결 전 호출은
  /// 보류 후 연결 직후 재생된다. 디바운스는 하지 않는다 — 호출 즉시 이전 검색을
  /// 취소하고 새 검색을 시작한다 (타이핑 디바운스는 호출측 책임).
  /// - Parameters:
  ///   - query: 검색어.
  ///   - options: 검색 옵션 (기본값 — 대소문자·발음 부호 무시).
  public func search(_ query: String, options: SearchOptions = SearchOptions()) {
    guard let core else {
      self.pendingSearch = (query, options)
      return
    }
    core.beginSearch(query, options: options)
  }

  /// 검색을 해제한다 (하이라이트·매치 상태 전부 초기화).
  public func clearSearch() {
    self.pendingSearch = nil
    self.core?.clearSearch()
  }

  /// 다음 매치로 이동한다 (랩어라운드, 매치 없으면 무시). 이동 후 해당 매치가
  /// 화면 중앙에 오도록 스크롤한다.
  public func nextMatch() {
    self.core?.advanceMatch(by: 1)
  }

  /// 이전 매치로 이동한다 (랩어라운드, 매치 없으면 무시). 이동 후 해당 매치가
  /// 화면 중앙에 오도록 스크롤한다.
  public func previousMatch() {
    self.core?.advanceMatch(by: -1)
  }

  /// 새 조립 시작을 반영한다 (`ReaderSession` 전용 — 문서 교체 시 이전 코어 연결 해제).
  func beginLoading() {
    self.core?.onStateChange = nil
    self.core?.onSearchStateChange = nil
    self.core = nil
    self.loadState = .loading
    self.pageCount = 0
    self.currentPageIndex = 0
    self.visiblePageRange = 0..<0
    self.zoomScale = 1
    self.searchState = .idle
    self.pendingSearch = nil
  }

  /// 코어에 연결하고 보류된 명령·검색을 1회 재생한다 (`ReaderSession` 전용).
  /// - Parameter core: 연결할 코어.
  func attach(core: ReaderCore) {
    self.core = core
    self.pageCount = core.layout.pageCount
    core.onStateChange = { [weak self] state in
      self?.applyState(state)
    }
    core.onSearchStateChange = { [weak self] state in
      self?.searchState = state
    }
    self.loadState = .ready
    self.replayPendingCommand()
    self.replayPendingSearch()
  }

  /// 코어와의 연결을 해제한다 (`ReaderSession` 전용).
  func detachCore() {
    self.core?.onStateChange = nil
    self.core?.onSearchStateChange = nil
    self.core = nil
  }

  /// 적재 실패를 반영한다 (`ReaderSession` 전용).
  /// - Parameter error: 발생한 에러.
  func applyFailure(_ error: PapyrusError) {
    self.loadState = .failed(error)
  }

  /// 코어 상태 변경을 모델 프로퍼티에 반영한다.
  /// - Parameter state: 코어가 통지한 상태.
  private func applyState(_ state: ReaderViewState) {
    self.currentPageIndex = state.currentPageIndex
    self.visiblePageRange = state.visiblePageRange
    self.zoomScale = state.zoomScale
  }

  /// 연결 전 접수된 탐색 명령을 1회 재생한다.
  private func replayPendingCommand() {
    guard let command = self.pendingCommand else {
      return
    }
    self.pendingCommand = nil
    switch command {
    case let .goToPage(index, animated):
      self.goToPage(index, animated: animated)
    case let .restore(position):
      self.restore(position)
    }
  }

  /// 연결 전 접수된 검색을 1회 재생한다.
  private func replayPendingSearch() {
    guard let pending = self.pendingSearch else {
      return
    }
    self.pendingSearch = nil
    self.search(pending.query, options: pending.options)
  }
}
