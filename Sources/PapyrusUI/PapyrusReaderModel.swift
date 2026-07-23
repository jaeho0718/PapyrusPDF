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

  /// 연결된 코어 (연결 전 `nil`).
  private var core: ReaderCore?

  /// 연결 전 접수되어 연결 직후 재생될 탐색 명령 (최신 것만 유지).
  private var pendingCommand: PendingReaderCommand?

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

  /// 새 조립 시작을 반영한다 (`ReaderSession` 전용 — 문서 교체 시 이전 코어 연결 해제).
  func beginLoading() {
    self.core?.onStateChange = nil
    self.core = nil
    self.loadState = .loading
    self.pageCount = 0
    self.currentPageIndex = 0
    self.visiblePageRange = 0..<0
    self.zoomScale = 1
  }

  /// 코어에 연결하고 보류된 명령을 1회 재생한다 (`ReaderSession` 전용).
  /// - Parameter core: 연결할 코어.
  func attach(core: ReaderCore) {
    self.core = core
    self.pageCount = core.layout.pageCount
    core.onStateChange = { [weak self] state in
      self?.applyState(state)
    }
    self.loadState = .ready
    self.replayPendingCommand()
  }

  /// 코어와의 연결을 해제한다 (`ReaderSession` 전용).
  func detachCore() {
    self.core?.onStateChange = nil
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
}
