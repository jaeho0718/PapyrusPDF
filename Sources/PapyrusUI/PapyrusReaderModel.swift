import CoreGraphics
import Observation
import PapyrusCore

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
  case failed(PapyrusError)
}

/// 연결 전에 접수된 탐색 명령 (연결 직후 1회 재생 — §4.1).
enum PendingReaderCommand {
  /// 보류된 `goToPage` 호출.
  case goToPage(index: Int, animated: Bool)
  /// 보류된 `restore` 호출.
  case restore(ReaderPosition)
}

/// 검색 요약 상태입니다 (``PapyrusReaderModel/searchState``로 관찰합니다).
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
    case failed(PapyrusError)
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

/// 뷰어 관찰·제어 모델입니다.
///
/// 생성 → `PapyrusReader(document:model:)`에 전달 → 뷰가 내부에서 코어와 연결합니다.
/// 연결 전 호출된 탐색 명령은 보류했다가 연결 직후 1회 재생합니다 (§4.1 —
/// "열자마자 goToPage" 사용 패턴이 자연스럽게 동작해야 합니다).
@MainActor
@Observable
public final class PapyrusReaderModel {
  /// 적재 상태입니다.
  public private(set) var loadState: ReaderLoadState = .loading
  /// 페이지 수입니다 (적재 전 0).
  public private(set) var pageCount = 0
  /// 현재 페이지 인덱스입니다 (뷰포트 중앙 기준, 적재 전 0).
  public private(set) var currentPageIndex = 0
  /// 가시 페이지 범위입니다 (적재 전 0..<0).
  public private(set) var visiblePageRange: Range<Int> = 0..<0
  /// 현재 줌 배율입니다 (적재 전 1).
  public private(set) var zoomScale: CGFloat = 1

  /// 검색 상태입니다 (기본 `.idle`).
  public private(set) var searchState: ReaderSearchState = .idle

  /// 현재 텍스트 선택입니다 (없으면 `nil`). 드래그 중에도 실시간으로 갱신됩니다.
  public private(set) var selection: TextSelection?

  /// 현재 선택된 영역입니다 (없으면 `nil`). 탭으로 선택되며, 텍스트 선택과 상호
  /// 배타입니다 — 텍스트 드래그가 시작되면 해제됩니다.
  public private(set) var selectedRegion: SelectableRegion?

  /// 연결된 코어 (연결 전 `nil`). 파일 분할(`+Highlights.swift`) 접근을 위해 internal.
  var core: ReaderCore?

  /// 선택 가능 영역 등록부입니다 (진실 원천 — 컨트롤러는 attach 시 재생되는 작업
  /// 사본을 보관합니다). 같은 문서의 재조립에서는 유지되고, 다른 문서로 바뀔 때만
  /// 리셋됩니다.
  private var regionsByPage: [Int: [SelectableRegion]] = [:]

  /// 하이라이트 등록부입니다 (진실 원천 — 코어는 attach 시 재생되는 작업 사본을
  /// 보관합니다). 같은 문서의 재조립에서는 유지되고, 다른 문서로 바뀔 때만 리셋됩니다.
  /// 파일 분할(`+Highlights.swift`) 접근을 위해 internal.
  var highlightRegistry = HighlightRegistry()

  /// 마지막으로 적재를 시작한 문서의 신원 (문서 교체 판정용).
  private var lastDocumentID: ObjectIdentifier?

  /// 연결 전 접수되어 연결 직후 재생될 탐색 명령 (최신 것만 유지).
  private var pendingCommand: PendingReaderCommand?

  /// 연결 전 접수되어 연결 직후 재생될 검색 (최신 것만 유지 — 탐색 명령과 별도 슬롯이라
  /// 서로를 밀어내지 않는다).
  private var pendingSearch: (query: String, options: SearchOptions)?

  /// 연결 전 접수되어 연결 직후 재생될 선택 (최신 것만 유지 — 탐색·검색과 별도 슬롯이라
  /// 서로를 밀어내지 않는다).
  private var pendingSelection: TextSelection?

  /// 모델을 만듭니다.
  public init() {}

  /// 페이지 상단으로 이동합니다 (범위 밖은 클램프).
  ///
  /// 페이지 번호 입력창이나 커스텀 목차 UI에서 사용자가 특정 페이지를 선택했을 때
  /// 호출합니다. `PapyrusReader`가 아직 적재를 마치지 않은 상태에서 호출해도 안전합니다 —
  /// 요청이 보류됐다가 적재 완료 직후 자동으로 재생됩니다.
  /// - Parameters:
  ///   - index: 이동할 페이지 인덱스입니다.
  ///   - animated: 애니메이션 여부입니다.
  public func goToPage(_ index: Int, animated: Bool = true) {
    guard let core else {
      self.pendingCommand = .goToPage(index: index, animated: animated)
      return
    }
    core.goToPage(index, animated: animated)
  }

  /// 목차 목적지로 이동합니다 (`OutlineDestination.pageIndex` — v1 목적지는 페이지 단위).
  ///
  /// `document.outline`에서 얻은 항목을 사용자가 목차 사이드바에서 선택했을 때 그
  /// `destination`을 그대로 넘기면 됩니다.
  /// - Parameters:
  ///   - destination: 이동할 목차 목적지입니다.
  ///   - animated: 애니메이션 여부입니다.
  public func go(to destination: OutlineDestination, animated: Bool = true) {
    self.goToPage(destination.pageIndex, animated: animated)
  }

  /// 현재 위치 스냅숏입니다 (적재 전 nil).
  ///
  /// 화면이 사라지거나 앱이 백그라운드로 전환되는 시점에 호출해 `Codable`인 반환값을
  /// 영구 저장소(예: `UserDefaults`)에 저장해 두면, 다음에 같은 문서를 열 때
  /// ``restore(_:)``로 이어 볼 수 있습니다.
  /// - Returns: 현재 위치 스냅숏, 미연결이면 `nil`입니다.
  public func capturePosition() -> ReaderPosition? {
    self.core?.capturePosition()
  }

  /// 위치를 복원합니다 (적재 전 호출 시 보류 후 적재 직후 적용).
  ///
  /// 이전에 ``capturePosition()``으로 저장해 둔 위치를 다시 불러올 때 사용합니다.
  /// 모델을 만든 직후, `PapyrusReader`가 화면에 붙어 적재를 마치기 전에 호출해도
  /// 안전합니다 — 적재 완료 시점에 자동으로 적용됩니다.
  /// - Parameter position: 복원할 위치 스냅숏입니다.
  public func restore(_ position: ReaderPosition) {
    guard let core else {
      self.pendingCommand = .restore(position)
      return
    }
    core.restore(position, animated: true)
  }

  /// 검색을 시작합니다. 빈(공백뿐) query는 `clearSearch()`와 동일합니다. 연결 전 호출은
  /// 보류 후 연결 직후 재생됩니다. 디바운스는 하지 않습니다 — 호출 즉시 이전 검색을
  /// 취소하고 새 검색을 시작합니다 (타이핑 디바운스는 호출측 책임).
  /// - Parameters:
  ///   - query: 검색어입니다.
  ///   - options: 검색 옵션입니다 (기본값 — 대소문자·발음 부호 무시).
  public func search(_ query: String, options: SearchOptions = SearchOptions()) {
    guard let core else {
      self.pendingSearch = (query, options)
      return
    }
    core.beginSearch(query, options: options)
  }

  /// 검색을 해제합니다 (하이라이트·매치 상태 전부 초기화).
  public func clearSearch() {
    self.pendingSearch = nil
    self.core?.clearSearch()
  }

  /// 다음 매치로 이동합니다 (랩어라운드, 매치 없으면 무시). 이동 후 해당 매치가
  /// 화면 중앙에 오도록 스크롤합니다.
  public func nextMatch() {
    self.core?.advanceMatch(by: 1)
  }

  /// 이전 매치로 이동합니다 (랩어라운드, 매치 없으면 무시). 이동 후 해당 매치가
  /// 화면 중앙에 오도록 스크롤합니다.
  public func previousMatch() {
    self.core?.advanceMatch(by: -1)
  }

  /// 선택을 해제합니다 (선택 메뉴도 닫힙니다). 영역 선택도 해제됩니다.
  public func clearSelection() {
    self.pendingSelection = nil
    self.core?.clearSelection()
  }

  /// 프로그램적으로 선택합니다. 적재 전 호출은 보류됐다가 적재 완료 직후 적용됩니다.
  /// 범위는 소비 시점에 페이지·문자열 경계로 클램프되므로 안전합니다.
  /// - Parameter selection: 채택할 선택입니다.
  public func select(_ selection: TextSelection) {
    guard let core else {
      self.pendingSelection = selection
      return
    }
    core.select(selection)
  }

  /// 현재 선택의 문자열입니다 (페이지 경계는 개행으로 결합). 선택이 없거나 적재 전이면
  /// `nil`입니다. 매우 긴 선택은 내부 상한에서 잘립니다.
  /// - Returns: 조립된 선택 문자열입니다.
  public func selectedString() async -> String? {
    guard let core else {
      return nil
    }
    return await core.selectedString()
  }

  /// 페이지의 선택 가능 영역을 등록합니다 (그 페이지의 기존 등록을 대체합니다).
  ///
  /// 좌표가 유한하지 않거나 `pageIndex`가 일치하지 않는 항목은 제외되며, 페이지당
  /// 등록 수는 내부 상한에서 잘립니다. 겹치는 영역은 나중에 등록된(배열 뒤쪽) 항목이
  /// 우선합니다. 적재 전 호출해도 안전합니다 — 적재 완료 시 자동 반영됩니다. 빈 배열을
  /// 전달하면 그 페이지의 등록을 해제합니다.
  /// - Parameters:
  ///   - regions: 등록할 영역 목록입니다 (겹침 우선순위 = 배열 순서).
  ///   - pageIndex: 대상 페이지 인덱스입니다 (0 기반).
  public func setSelectableRegions(_ regions: [SelectableRegion], forPage pageIndex: Int) {
    let sanitized = RegionHitTester.sanitized(regions, forPage: pageIndex)
    if sanitized.isEmpty {
      self.regionsByPage.removeValue(forKey: pageIndex)
    } else {
      self.regionsByPage[pageIndex] = sanitized
    }
    self.core?.setSelectableRegions(sanitized, forPage: pageIndex)
  }

  /// 페이지에 등록된 선택 가능 영역입니다 (등록 위생 적용 후 실제 활성 목록).
  /// - Parameter pageIndex: 조회할 페이지 인덱스입니다.
  /// - Returns: 등록 순서의 영역 목록입니다 (없으면 빈 배열).
  public func selectableRegions(forPage pageIndex: Int) -> [SelectableRegion] {
    self.regionsByPage[pageIndex] ?? []
  }

  /// 모든 페이지의 선택 가능 영역 등록을 해제합니다 (선택 중인 영역도 해제됩니다).
  public func clearSelectableRegions() {
    self.regionsByPage.removeAll()
    self.core?.clearSelectableRegions()
  }

  /// 새 조립 시작을 반영한다 (`ReaderSession` 전용 — 문서 교체 시 이전 코어 연결 해제).
  ///
  /// 영역·하이라이트 등록부는 `documentID`가 직전 적재와 같으면(같은 문서 재조립)
  /// 유지되고, 다르면 리셋된다 — `pendingSearch`/`pendingSelection`과 달리 일시 상태가
  /// 아니라 개발자 소유 영속 데이터이기 때문이다. `selectedRegion`은 일시 상태이므로
  /// 항상 `nil`로 리셋된다.
  /// - Parameter documentID: 새로 적재할 문서의 신원.
  func beginLoading(documentID: ObjectIdentifier) {
    self.core?.onStateChange = nil
    self.core?.onSearchStateChange = nil
    self.core?.onSelectionChange = nil
    self.core?.onRegionSelectionChange = nil
    self.core = nil
    self.loadState = .loading
    self.pageCount = 0
    self.currentPageIndex = 0
    self.visiblePageRange = 0..<0
    self.zoomScale = 1
    self.searchState = .idle
    self.selection = nil
    self.selectedRegion = nil
    self.pendingSearch = nil
    self.pendingSelection = nil
    // `lastDocumentID == nil`은 "아직 문서를 적재한 적 없음"이다 — 최초 적재는 비교
    // 대상이 없으므로 문서 "교체"가 아니다. 적재 전에 등록한 영역이 최초 적재에서
    // 지워지면 안 되므로, 리셋은 직전 문서가 실제로 존재하고 다를 때만 수행한다.
    if let lastDocumentID = self.lastDocumentID, lastDocumentID != documentID {
      self.regionsByPage.removeAll()
      self.highlightRegistry = HighlightRegistry()
    }
    self.lastDocumentID = documentID
  }

  /// 코어에 연결하고 등록부·보류된 명령·검색·선택을 1회 재생한다 (`ReaderSession` 전용).
  ///
  /// 영역 등록부 재생을 `replayPendingSelection()`보다 먼저 수행한다 — 프로그램적
  /// `select(_:)`가 재생되기 전에 영역 등록이 끝나 있어야 상호 배타 판정이 결정적이다.
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
    core.onSelectionChange = { [weak self] selection in
      self?.selection = selection
    }
    core.onRegionSelectionChange = { [weak self] region in
      self?.selectedRegion = region
    }
    self.loadState = .ready
    self.replayPendingCommand()
    self.replayPendingSearch()
    self.replayRegions()
    self.replayHighlights()
    self.replayPendingSelection()
  }

  /// 코어와의 연결을 해제한다 (`ReaderSession` 전용).
  func detachCore() {
    self.core?.onStateChange = nil
    self.core?.onSearchStateChange = nil
    self.core?.onSelectionChange = nil
    self.core?.onRegionSelectionChange = nil
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

  /// 연결 전 접수된 선택을 1회 재생한다.
  private func replayPendingSelection() {
    guard let pending = self.pendingSelection else {
      return
    }
    self.pendingSelection = nil
    self.select(pending)
  }

  /// 등록부 전 페이지를 코어에 재생한다 (연결 직후 1회 — 적재 전 등록 지원).
  private func replayRegions() {
    guard let core else {
      return
    }
    for (pageIndex, regions) in self.regionsByPage {
      core.setSelectableRegions(regions, forPage: pageIndex)
    }
  }
}
