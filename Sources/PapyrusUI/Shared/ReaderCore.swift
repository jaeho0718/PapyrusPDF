import CoreGraphics
import PapyrusCore
import PapyrusRendering
import QuartzCore

/// 뷰어 상태 스냅숏 (모델 통지용).
package struct ReaderViewState: Sendable, Equatable {
  /// 현재 페이지 (뷰포트 중앙 기준).
  package let currentPageIndex: Int
  /// 가시 페이지 범위.
  package let visiblePageRange: Range<Int>
  /// 현재 줌 배율.
  package let zoomScale: CGFloat
}

/// 레이아웃·가상화·렌더 요청·탐색의 수렴점. 플랫폼 공유 ~85%의 몸통이다
/// (ARCHITECTURE 123행). 호스트 1개에 부착되어 contentLayer를 소유·관리한다.
@MainActor
package final class ReaderCore: ReaderHostEventSink {
  /// 레이아웃 엔진 (불변).
  package let layout: ReaderLayoutEngine

  /// 렌더 서비스 (M5 계약의 유일 소비자).
  package let renderQueue: TileRenderQueue

  /// 화면 배율 (픽셀 밀도) — `renderQueue`(액터)와 동일 값을 동기 접근용으로 보관한다.
  /// 하이라이트 `contentsScale` 계산(§2.4)에 쓰인다.
  package let pixelScale: CGFloat

  /// 상태 변경 통지 (모델이 구독. 값이 실제로 바뀔 때만 호출).
  package var onStateChange: ((ReaderViewState) -> Void)?

  /// 부착된 호스트 (미부착이면 `nil`).
  ///
  /// 내부 상태는 `ReaderCore+Fetching.swift` 확장(같은 모듈)도 참조하므로 `private`가
  /// 아니라 모듈 스코프로 둔다 (M5 `TileRenderQueue`+확장 파일 분리와 동일 패턴).
  weak var host: (any ReaderScrollHost)?

  /// 실체화된 페이지 (인덱스 → 컨트롤러).
  var controllers: [Int: PageLayerController] = [:]

  /// 유휴 컨트롤러 재활용 풀.
  let pool = PageLayerPool()

  /// 현재 스냅된 스케일 버킷 (가정 3의 확정 버킷).
  var currentBucket: ScaleBucket

  /// 가시 페치 진행 중 태스크 (요청 키 → 태스크).
  var visibleFetchTasks: [RenderRequestKey: Task<Void, Never>] = [:]

  /// 마지막으로 M5에 밀어넣은 뷰포트 (Equatable 스킵용).
  var lastPushedViewport: RenderViewport?

  /// 코얼레싱 대기 중인 최신 뷰포트 (§4.7).
  var pendingViewport: RenderViewport?

  /// 뷰포트 푸시 루프 태스크.
  var viewportPushTask: Task<Void, Never>?

  /// 마지막으로 통지한 상태 (변화 감지용).
  private var lastState: ReaderViewState?

  /// 검색 코디네이터 (검색 미사용 조립이면 `nil` — 기존 테스트 영향 없음).
  let searchCoordinator: ReaderSearchCoordinator?

  /// 페이지 → 표시 공간 하이라이트 (검색 세션 동안 전량 보관 — 캡은 `CoreLimits`로 유계).
  var searchHighlights: [Int: PageSearchHighlights] = [:]

  /// 평탄 매치 색인: 순번 → (페이지, 페이지 내 순번). next/prev·카운트의 진실 원천.
  var searchMatchIndex: [(pageIndex: Int, ordinal: Int)] = []

  /// 현재 매치의 평탄 순번 (없으면 `nil`).
  var currentMatchFlatIndex: Int?

  /// 검색 요약 상태 통지 (모델이 구독).
  package var onSearchStateChange: ((ReaderSearchState) -> Void)?

  /// 마지막으로 통지한 검색 상태 (query·phase 보존용 — `advanceMatch`가 재사용한다).
  var currentSearchState: ReaderSearchState = .idle

  /// 선택 컨트롤러 (선택 미사용 조립이면 `nil` — 기존 테스트 영향 없음).
  let selectionController: ReaderSelectionController?

  /// 선택 변경 통지 (모델이 구독).
  package var onSelectionChange: ((TextSelection?) -> Void)?

  /// 영역 선택 변경 통지 (모델이 구독).
  package var onRegionSelectionChange: ((SelectableRegion?) -> Void)?

  /// 공개 선택 메뉴 빌더 (`View.papyrusSelectionMenu(_:)` → Environment 전파 종점).
  ///
  /// 환경 변화 → body 재평가 → 대입으로 반영된다. 표시 중인 메뉴에는 소급 적용하지
  /// 않는다 — 다음 선택 확정부터 새 빌더가 쓰인다.
  package var selectionMenuBuilder: SelectionMenuItemsBuilder?

  /// 부착된 호스트의 메뉴 표시 표면 (`attach(to:)`가 캐스팅해 채우고 `detach()`가 비운다).
  ///
  /// `ReaderCore+Selection.swift`도 참조하므로 모듈 스코프로 둔다 (M5 관례).
  weak var menuPresenting: (any ReaderMenuPresenting)?

  /// 확정 선택의 해소 문자열 프리페치 캐시 (선택 값 → 문자열). macOS 동기 pull 표면의
  /// 소비용 — 선택 변경 시 무효화된다 (§4.5).
  ///
  /// `ReaderCore+Selection.swift`도 참조하므로 모듈 스코프로 둔다.
  var menuTextCache: (selection: TextSelection, text: String)?

  /// 메뉴 문자열 프리페치 진행 중 태스크 (선택 변경마다 취소·재시작).
  var menuTextPrefetchTask: Task<Void, Never>?

  /// 확정 선택 메뉴 표시(iOS push) 진행 중 태스크 (새 요청·dismiss 시 직전 것을 취소).
  var menuPresentationTask: Task<Void, Never>?

  /// `documentUnavailable` 래치 — 이후 페치 태스크 스폰을 중단한다.
  var renderingUnavailable = false

  /// `pageUnavailable`로 확인된 페이지의 영구 실패 래치 (§5.2 — 파서 페이지 수가
  /// CGPDFDocument 페이지 수를 넘는 손상 문서). 한 번 실패한 페이지는 이후
  /// `updateFetches`의 필요 집합에서 제외해 프레임마다 재요청이 스폰되는 것을 막는다.
  /// `documentUnavailable`과 달리 페이지 단위이며, 실패가 문서 구조에서 기인해
  /// 재열지 않는 한 바뀌지 않으므로 세션 내내 유지해도 안전하다.
  var unavailablePages: Set<Int> = []

  /// 코어를 만든다. 이 시점엔 호스트가 없다 (SwiftUI 조립 순서 — §4.1).
  /// - Parameters:
  ///   - layout: 레이아웃 엔진.
  ///   - renderQueue: 렌더 서비스.
  ///   - pixelScale: 화면 배율 (`renderQueue`와 동일 값 — 기본 2, `RenderConfiguration`
  ///     기본값과 정합).
  ///   - searchCoordinator: 검색 코디네이터 (기본 `nil` — 검색 미사용 조립).
  ///   - selectionController: 선택 컨트롤러 (기본 `nil` — 선택 미사용 조립).
  package init(
    layout: ReaderLayoutEngine, renderQueue: TileRenderQueue, pixelScale: CGFloat = 2,
    searchCoordinator: ReaderSearchCoordinator? = nil,
    selectionController: ReaderSelectionController? = nil
  ) {
    self.layout = layout
    self.renderQueue = renderQueue
    self.pixelScale = pixelScale
    self.currentBucket = ScaleBucket(exponent: 0)
    self.searchCoordinator = searchCoordinator
    self.selectionController = selectionController
    searchCoordinator?.onEvent = { [weak self] event in
      self?.handleSearchEvent(event)
    }
    selectionController?.onSelectionChange = { [weak self] selection in
      self?.onSelectionChange?(selection)
      self?.updateMenuTextCache(for: selection)
    }
    selectionController?.onRegionSelectionChange = { [weak self] region in
      self?.onRegionSelectionChange?(region)
    }
    selectionController?.onOverlayInvalidate = { [weak self] pageIndex in
      self?.applySelection(toPage: pageIndex)
    }
    selectionController?.onMenuRequest = { [weak self] anchorPage in
      self?.menuPresentationTask?.cancel()
      self?.menuPresentationTask = Task { [weak self] in
        await self?.presentResolvedMenu(anchorPage: anchorPage)
      }
    }
    selectionController?.onMenuDismiss = { [weak self] in
      self?.menuPresentationTask?.cancel()
      self?.menuPresentationTask = nil
      self?.menuPresenting?.dismissSelectionMenu()
    }
  }

  /// 호스트에 부착: contentSize·줌 한계 설정, 초기 fit-width 줌, 첫 실체화.
  /// - Parameter host: 부착할 스크롤 호스트.
  package func attach(to host: any ReaderScrollHost) {
    self.host = host
    self.menuPresenting = host as? ReaderMenuPresenting
    host.setContentSize(self.layout.contentSize)
    let fit = self.layout.fitWidthScale(forViewportWidth: host.viewportSize.width)
    host.setZoomLimits(minimum: fit, maximum: ReaderLayoutMetrics.maxZoomScale)
    host.scrollTo(contentY: 0, zoomScale: fit, animated: false)
    self.currentBucket = ScaleBucket(snapping: fit)
    self.hostViewportDidChange()
  }

  /// 분리: 진행 중 요청 태스크 전부 취소, 레이어 철거.
  package func detach() {
    for task in self.visibleFetchTasks.values {
      task.cancel()
    }
    self.visibleFetchTasks.removeAll()
    self.viewportPushTask?.cancel()
    self.viewportPushTask = nil
    self.pendingViewport = nil
    for controller in self.controllers.values {
      controller.containerLayer.removeFromSuperlayer()
      self.pool.release(controller)
    }
    self.controllers.removeAll()
    self.host = nil
    self.menuPresenting = nil

    self.searchCoordinator?.cancel()
    self.searchHighlights.removeAll()
    self.searchMatchIndex.removeAll()
    self.currentMatchFlatIndex = nil

    self.selectionController?.teardown()
    self.menuTextPrefetchTask?.cancel()
    self.menuTextPrefetchTask = nil
    self.menuPresentationTask?.cancel()
    self.menuPresentationTask = nil
    self.menuTextCache = nil
  }

  // MARK: - ReaderHostEventSink

  /// 스크롤·줌 진행으로 가시 영역이 바뀌었다 (§4.3 파이프라인).
  package func hostViewportDidChange() {
    guard let host else {
      return
    }
    let rect = host.visibleContentRect
    let zoom = host.zoomScale
    let visible = self.layout.visiblePageRange(in: rect)
    let current =
      VisibleRangeCalculator.currentPageIndex(layout: self.layout, visibleContentRect: rect) ?? 0
    let state = ReaderViewState(
      currentPageIndex: current, visiblePageRange: visible, zoomScale: zoom
    )
    if state != self.lastState {
      self.lastState = state
      self.onStateChange?(state)
    }

    let materialized = VisibleRangeCalculator.materializedRange(
      visible: visible, pageCount: self.layout.pageCount
    )
    self.updateMaterialization(to: materialized)
    self.updateFetches(visible: visible, rect: rect)
    self.selectionController?.prefetch(range: materialized)

    let viewport = VisibleRangeCalculator.renderViewport(
      layout: self.layout, visibleContentRect: rect, scaleBucket: self.currentBucket,
      viewportSize: host.viewportSize
    )
    self.pushViewport(viewport)
  }

  /// 줌 제스처가 끝났다 — 버킷 재스냅 (§4.5).
  package func hostZoomInteractionDidEnd() {
    guard let host else {
      return
    }
    let newBucket = ScaleBucket(snapping: host.zoomScale)
    guard newBucket != self.currentBucket else {
      return
    }
    self.currentBucket = newBucket
    for (pageIndex, controller) in self.controllers {
      controller.activateBucket(newBucket)
      controller.updateOverlayContentsScale(
        screenScale: self.pixelScale, bucketScale: newBucket.scale
      )
      // 핸들 치수는 화면 고정(1/zoom)이라 줌 종료 시 재계산해 재적용한다 (§0.2-5).
      self.applySelection(toPage: pageIndex)
    }
    for (pageIndex, controller) in self.controllers {
      self.fillCacheHits(forPage: pageIndex, controller: controller, host: host)
    }
    self.hostViewportDidChange()
  }

  /// 뷰포트 크기가 바뀌었다 (회전·창 리사이즈) — 줌 한계 재계산 + 위치 보존.
  package func hostViewportSizeDidChange() {
    guard let host else {
      return
    }
    let position = self.capturePosition()
    let fit = self.layout.fitWidthScale(forViewportWidth: host.viewportSize.width)
    host.setZoomLimits(minimum: fit, maximum: ReaderLayoutMetrics.maxZoomScale)
    if let position {
      self.restore(position, animated: false)
    } else {
      self.hostViewportDidChange()
    }
  }

  // MARK: - 탐색 (§4.6)

  /// 페이지 상단으로 스크롤 (인덱스 클램프, 빈 문서 무시).
  /// - Parameters:
  ///   - index: 이동할 페이지 인덱스.
  ///   - animated: 애니메이션 여부.
  package func goToPage(_ index: Int, animated: Bool) {
    guard self.layout.pageCount > 0, let host else {
      return
    }
    let clamped = min(max(index, 0), self.layout.pageCount - 1)
    guard let frame = self.layout.pageFrame(at: clamped) else {
      return
    }
    let y = max(0, frame.minY - ReaderLayoutMetrics.pageSpacing / 2)
    host.scrollTo(contentY: y, zoomScale: nil, animated: animated)
  }

  /// 현재 위치 포착 (빈 문서·미부착이면 nil).
  /// - Returns: 현재 위치 스냅숏.
  package func capturePosition() -> ReaderPosition? {
    guard let host else {
      return nil
    }
    return self.layout.capturePosition(
      viewportTopY: host.visibleContentRect.minY, zoomScale: host.zoomScale
    )
  }

  /// 위치 복원 (줌 → 오프셋 순서로 적용, 전부 클램프).
  /// - Parameters:
  ///   - position: 복원할 위치 스냅숏.
  ///   - animated: 애니메이션 여부.
  package func restore(_ position: ReaderPosition, animated: Bool) {
    guard let host else {
      return
    }
    let fit = self.layout.fitWidthScale(forViewportWidth: host.viewportSize.width)
    let zoom = min(max(position.zoomScale, fit), ReaderLayoutMetrics.maxZoomScale)
    let y = self.layout.contentY(for: position)
    host.scrollTo(contentY: y, zoomScale: zoom, animated: animated)
    self.hostZoomInteractionDidEnd()
  }

  // MARK: - 테스트 관찰

  /// 실체화된 페이지 인덱스 집합.
  package var materializedPageIndices: Set<Int> {
    Set(self.controllers.keys)
  }
}
