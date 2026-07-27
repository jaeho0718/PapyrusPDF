import CoreGraphics
import PapyrusPDFCore

/// 선택 상태 기계의 본체. 파일 4개로 나눈다: 값 타입은 `+Types.swift`, 본체(이 파일) =
/// 상태·이벤트 진입(드래그·핸들·clear·select)·통지, `+Resolution` = 점→위치 해석·선택
/// 재계산·quad/핸들 조회·문자열 조립, `+Region` = 영역 등록부·히트·활성 선택 투영·`tap(at:)`
/// 진입점(본체 길이 한도로 이설).
///
/// 상태: `idle` / `dragging(DragSession)` (kind: `.new`·`.handle`) / `selected(SelectedState)`
/// / `regionSelected(SelectableRegion)`. 활성 선택(텍스트·영역)은 항상 이 네 상태 중
/// 하나로만 표현되며 서로 상호 배타다 (§3 전이표). 불변식: **활성 드래그 세션은 항상
/// 0 또는 1개**이고, 세션은 `dragToken`으로 식별된다. 모든 상태 전이는 메인 액터에서
/// 동기적으로 일어난다 — 전이 중 재진입 없음.
@MainActor
package final class ReaderSelectionController {
  /// 선택 상태.
  ///
  /// 파일 분할 접근을 위해 internal.
  enum State {
    /// 선택 없음.
    case idle
    /// 드래그 진행 중.
    case dragging(DragSession)
    /// 확정 선택.
    case selected(SelectedState)
    /// 선택 가능 영역 확정 선택 (활성 선택 단일 슬롯의 네 번째 상태 — 텍스트와 상호 배타).
    case regionSelected(SelectableRegion)
  }

  /// 확정 선택 변경 (드래그 중 실시간 포함 — 모델 `selection` 반영).
  package var onSelectionChange: ((TextSelection?) -> Void)?
  /// 페이지 오버레이 무효화 (코어가 구독 — 실체화 페이지면 quad·핸들 재적용).
  package var onOverlayInvalidate: ((Int) -> Void)?
  /// 페이지 콘텐츠(지오메트리+변환) 도착 통지 — 선택 상태와 무관하게 매 도착마다
  /// 발화한다 (코어가 구독해 지속 하이라이트를 재반영). 기존 `onOverlayInvalidate`와
  /// 분리한 이유: 그쪽은 "선택 표시가 바뀐 페이지"만 발화하는 선택 전용 계약이다.
  package var onPageContentReady: ((Int) -> Void)?
  /// 메뉴 표시 요청 (iOS 선택 확정 시 — 코어가 구독해 프레젠터 호출).
  package var onMenuRequest: ((_ contentAnchorPage: Int) -> Void)?
  /// 메뉴 닫기 요청 (드래그 시작·해제 시).
  package var onMenuDismiss: (() -> Void)?
  /// 영역 선택 변경 통지 (코어가 구독 — 모델 `selectedRegion` 반영). 전이마다 무조건
  /// 발화한다 — `SelectableRegion`은 Equatable이 아니라 변경 감지를 하지 않는다.
  package var onRegionSelectionChange: ((SelectableRegion?) -> Void)?

  /// 페이지별 등록 영역 (모델이 진실 원천 — attach 시 전량 재생한다. 컨트롤러는 작업
  /// 사본).
  ///
  /// 파일 분할(`+Region.swift`) 접근을 위해 internal.
  var regionsByPage: [Int: [SelectableRegion]] = [:]

  /// 페이지 콘텐츠 스토어 (해석·문자열 조립의 데이터 원천).
  ///
  /// 파일 분할(`+Resolution.swift`) 접근을 위해 internal.
  let store: ReaderSelectablePageStore

  /// 현재 상태.
  ///
  /// 파일 분할 접근을 위해 internal.
  var state: State = .idle

  /// 드래그 세션 토큰 — 세션 시작·폐기마다 증가. 지연 도착 정련의 소속 검사에 쓴다.
  ///
  /// 파일 분할 접근을 위해 internal.
  var dragToken = 0

  /// 마지막으로 통지한 선택 (변경 감지용 — 드래그 중 매 프레임 통지 스팸 방지).
  private var lastNotifiedSelection: TextSelection?

  /// 컨트롤러를 만든다. `store.onContentReady`를 자신에게 배선한다.
  /// - Parameter store: 페이지 콘텐츠 스토어.
  package init(store: ReaderSelectablePageStore) {
    self.store = store
    store.onContentReady = { [weak self] pageIndex in
      self?.contentArrived(pageIndex)
    }
  }

  /// 현재 확정/진행 중 선택 (없으면 `nil`).
  package var selection: TextSelection? {
    switch self.state {
    case .idle:
      return nil
    case let .dragging(session):
      return Self.normalizedSelection(
        Self.computeSelection(anchor: session.anchorResolved, focus: session.focusResolved)
      )
    case let .selected(selected):
      return selected.selection
    case .regionSelected:
      return nil
    }
  }

  // MARK: - 코어 위임 진입점 (§2 상태 기계의 입력)

  /// 드래그가 시작됐다 (T1·T11·T18).
  /// - Parameters:
  ///   - point: 시작 페이지 점.
  ///   - granularity: 시작 정밀도.
  package func dragBegan(at point: PagePoint, granularity: SelectionGranularity) {
    switch self.state {
    case .idle: // T1
      self.onMenuDismiss?() // 방어 — 불변식상 idle에서 메뉴가 열려 있을 수 없지만 명시한다.
      self.startNewSession(at: point, granularity: granularity, carryOverInvalidatedPages: nil)
    case let .dragging(session): // T11 — 재시작. 이전 세션은 토큰 증가로 실효된다.
      self.startNewSession(
        at: point, granularity: granularity,
        carryOverInvalidatedPages: session.lastInvalidatedPages
      )
    case let .selected(selected): // T18
      self.onMenuDismiss?()
      self.startNewSession(
        at: point, granularity: granularity,
        carryOverInvalidatedPages: selected.selection.pageRange
      )
    case let .regionSelected(region): // T28
      self.notifyRegion(nil)
      self.onMenuDismiss?()
      self.startNewSession(
        at: point, granularity: granularity,
        carryOverInvalidatedPages: region.pageIndex...region.pageIndex
      )
    }
  }

  /// 드래그가 진행 중이다 (T8, idle/selected 잔여는 T3/T17로 무시).
  /// - Parameter point: 현재 페이지 점.
  package func dragChanged(to point: PagePoint) {
    guard case var .dragging(session) = self.state else { // T3, T17
      return
    }
    session.focusPoint = point
    let direction = Self.clampDirection(
      anchorPageIndex: session.anchorPoint.pageIndex, pointPageIndex: point.pageIndex
    )
    session.focusResolved = self.resolve(
      point: point, granularity: session.granularity, direction: direction
    )
    self.recomputeAndApply(session: &session)
    self.state = .dragging(session)
  }

  /// 드래그가 정상 종료됐다 (T9, idle/selected 잔여는 T3/T17로 무시).
  package func dragEnded() {
    guard case let .dragging(session) = self.state else { // T3, T17
      return
    }
    let raw = Self.computeSelection(anchor: session.anchorResolved, focus: session.focusResolved)
    guard let selection = Self.normalizedSelection(raw) else {
      self.state = .idle
      self.notifyIfChanged(nil)
      _ = self.diffInvalidate(newRange: nil, previous: session.lastInvalidatedPages)
      return
    }

    let pendingRefinement = self.makePendingRefinement(for: session)
    let selected = SelectedState(selection: selection, pendingRefinement: pendingRefinement)
    self.state = .selected(selected)
    self.notifyIfChanged(selection)
    if SelectionStyle.presentsMenuOnSelectionEnd {
      self.onMenuRequest?(session.focusPoint.pageIndex)
    }
  }

  /// 드래그가 취소됐다 (T10, idle/selected 잔여는 T3/T17로 무시).
  package func dragCancelled() {
    guard case let .dragging(session) = self.state else { // T3, T17
      return
    }
    switch session.kind {
    case .new:
      self.state = .idle
      self.notifyIfChanged(nil)
      _ = self.diffInvalidate(newRange: nil, previous: session.lastInvalidatedPages)
    case .handle:
      guard let restored = session.preDragSelection else {
        self.state = .idle
        self.notifyIfChanged(nil)
        _ = self.diffInvalidate(newRange: nil, previous: session.lastInvalidatedPages)
        return
      }
      self.state = .selected(SelectedState(selection: restored, pendingRefinement: nil))
      self.notifyIfChanged(restored)
      _ = self.diffInvalidate(newRange: restored.pageRange, previous: session.lastInvalidatedPages)
    }
  }

  /// 기존 선택 핸들 드래그가 시작됐다 (T19, idle/dragging은 T2/T12로 무시).
  /// - Parameters:
  ///   - handle: 시작된 핸들.
  ///   - point: 시작 페이지 점.
  package func handleDragBegan(_ handle: SelectionHandle, at point: PagePoint) {
    guard case let .selected(selected) = self.state else { // T2, T12
      return
    }
    self.onMenuDismiss?()
    self.dragToken += 1
    let token = self.dragToken
    let anchorPosition = handle == .start ? selected.selection.end : selected.selection.start
    let anchorResolved = ResolvedEnd(position: anchorPosition, unitRange: nil, provisional: false)
    let anchorPoint = self.syntheticPoint(for: anchorPosition)
    let direction = Self.clampDirection(
      anchorPageIndex: anchorPosition.pageIndex, pointPageIndex: point.pageIndex
    )
    let focusResolved = self.resolve(point: point, granularity: .character, direction: direction)
    var session = DragSession(
      token: token, kind: .handle(handle), granularity: .character,
      anchorPoint: anchorPoint, focusPoint: point,
      anchorResolved: anchorResolved, focusResolved: focusResolved,
      preDragSelection: selected.selection, lastInvalidatedPages: selected.selection.pageRange
    )
    self.state = .dragging(session)
    self.recomputeAndApply(session: &session)
    self.state = .dragging(session)
  }

  /// 선택을 해제한다 (T6·T14·T21·T32).
  package func clear() {
    switch self.state {
    case .idle: // T6
      return
    case let .dragging(session): // T14
      self.dragToken += 1
      self.state = .idle
      self.notifyIfChanged(nil)
      _ = self.diffInvalidate(newRange: nil, previous: session.lastInvalidatedPages)
      self.onMenuDismiss?()
    case let .selected(selected): // T21
      self.state = .idle
      self.notifyIfChanged(nil)
      _ = self.diffInvalidate(newRange: nil, previous: selected.selection.pageRange)
      self.onMenuDismiss?()
    case let .regionSelected(region): // T32
      self.state = .idle
      self.notifyRegion(nil)
      self.onOverlayInvalidate?(region.pageIndex)
      self.onMenuDismiss?()
    }
  }

  /// 프로그램적으로 선택한다 (T5·T15·T22·T31 — 메뉴는 표시하지 않는다).
  /// - Parameter selection: 채택할 선택.
  package func select(_ selection: TextSelection) {
    switch self.state {
    case .idle: // T5
      self.state = .selected(SelectedState(selection: selection, pendingRefinement: nil))
      self.notifyIfChanged(selection)
      _ = self.diffInvalidate(newRange: selection.pageRange, previous: nil)
    case let .dragging(session): // T15 — 드래그 세션 폐기(최종 호출자 승리).
      self.dragToken += 1
      self.state = .selected(SelectedState(selection: selection, pendingRefinement: nil))
      self.notifyIfChanged(selection)
      _ = self.diffInvalidate(
        newRange: selection.pageRange, previous: session.lastInvalidatedPages
      )
    case let .selected(selected): // T22
      self.state = .selected(SelectedState(selection: selection, pendingRefinement: nil))
      self.notifyIfChanged(selection)
      _ = self.diffInvalidate(
        newRange: selection.pageRange, previous: selected.selection.pageRange
      )
    case let .regionSelected(region): // T31
      self.state = .selected(SelectedState(selection: selection, pendingRefinement: nil))
      self.notifyRegion(nil)
      self.onOverlayInvalidate?(region.pageIndex)
      self.notifyIfChanged(selection)
      _ = self.diffInvalidate(newRange: selection.pageRange, previous: nil)
    }
  }

  /// 실체화 창을 추종해 캐시를 갱신한다 (드래그 중이면 앵커·포커스 페이지를 보호).
  /// - Parameter range: 실체화 페이지 범위.
  package func prefetch(range: Range<Int>) {
    let protectedPages: Set<Int>
    if case let .dragging(session) = self.state {
      protectedPages = [session.anchorPoint.pageIndex, session.focusPoint.pageIndex]
    } else {
      protectedPages = []
    }
    self.store.prefetch(range: range, protecting: protectedPages)
  }

  /// teardown 경로 전용: 상태를 idle로 되돌리고(통지 억제) store를 무효화한다 (T26·T39).
  package func teardown() {
    self.state = .idle
    self.lastNotifiedSelection = nil
    self.dragToken += 1
    self.store.invalidateAll()
  }

  // MARK: - 내부: 새 드래그 세션 시작 (T1/T11/T18 공통)

  /// 새 `.new` 드래그 세션을 시작한다 (앵커 = 포커스 = `point`).
  /// - Parameters:
  ///   - point: 시작 페이지 점.
  ///   - granularity: 시작 정밀도.
  ///   - carryOverInvalidatedPages: 직전 상태(드래그 재시작·기존 선택)에서 표시 중이던
  ///     페이지 범위 — 차분 무효화의 기준값으로 이어받아 잔류 오버레이를 정확히 지운다.
  private func startNewSession(
    at point: PagePoint, granularity: SelectionGranularity,
    carryOverInvalidatedPages: ClosedRange<Int>?
  ) {
    self.dragToken += 1
    let token = self.dragToken
    let resolved = self.resolve(point: point, granularity: granularity, direction: .forward)
    var session = DragSession(
      token: token, kind: .new, granularity: granularity,
      anchorPoint: point, focusPoint: point,
      anchorResolved: resolved, focusResolved: resolved,
      preDragSelection: nil, lastInvalidatedPages: carryOverInvalidatedPages
    )
    self.state = .dragging(session)
    self.recomputeAndApply(session: &session)
    self.state = .dragging(session)
  }

  /// 드래그 종료 시점에 잠정 끝이 남아 있으면 지연 정련을 구성한다.
  /// - Parameter session: 종료되는 드래그 세션.
  /// - Returns: 지연 정련, 잠정 끝이 없으면 `nil`.
  private func makePendingRefinement(for session: DragSession) -> PendingRefinement? {
    guard session.anchorResolved.provisional || session.focusResolved.provisional else {
      return nil
    }
    return PendingRefinement(
      token: session.token, granularity: session.granularity,
      anchorPoint: session.anchorResolved.provisional ? session.anchorPoint : nil,
      focusPoint: session.focusResolved.provisional ? session.focusPoint : nil,
      confirmedAnchor: session.anchorResolved.provisional ? nil : session.anchorResolved,
      confirmedFocus: session.focusResolved.provisional ? nil : session.focusResolved
    )
  }

  // MARK: - 내부: 통지·무효화

  /// 재계산 결과를 직전 값과 비교해 변경 시에만 통지한다.
  ///
  /// 파일 분할(`+Resolution.swift`) 접근을 위해 internal.
  /// - Parameter selection: 재계산된 선택 (없으면 `nil`).
  func notifyIfChanged(_ selection: TextSelection?) {
    guard selection != self.lastNotifiedSelection else {
      return
    }
    self.lastNotifiedSelection = selection
    self.onSelectionChange?(selection)
  }

  /// 드래그 세션의 선택을 재계산하고 통지·차분 무효화를 적용한다.
  ///
  /// 파일 분할 접근을 위해 internal.
  /// - Parameter session: 갱신할 드래그 세션 (`lastInvalidatedPages`를 새로 기록한다).
  func recomputeAndApply(session: inout DragSession) {
    let raw = Self.computeSelection(anchor: session.anchorResolved, focus: session.focusResolved)
    let normalized = Self.normalizedSelection(raw)
    self.notifyIfChanged(normalized)
    session.lastInvalidatedPages = self.diffInvalidate(
      newRange: normalized?.pageRange, previous: session.lastInvalidatedPages
    )
  }
}
