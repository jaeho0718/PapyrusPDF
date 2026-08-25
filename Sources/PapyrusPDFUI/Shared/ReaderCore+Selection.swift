import CoreGraphics
import PapyrusPDFCore

/// `ReaderSelectionEventSink` 구현 + 선택 반영 로직.
///
/// `ReaderCore.swift`의 몸통과 파일만 분리한 확장이다.
extension ReaderCore: ReaderSelectionEventSink {
  /// 콘텐츠 공간 점을 페이지 표시 공간 점으로 분해한다.
  ///
  /// 간격 위는 다음 페이지 귀속, 범위 밖은 클램프가 레이아웃 엔진의 계약이다.
  /// - Parameter point: 콘텐츠 공간 점.
  /// - Returns: 분해된 페이지 점, 빈 문서면 `nil`.
  func pagePoint(forContentPoint point: CGPoint) -> PagePoint? {
    guard let pageIndex = self.layout.pageIndex(forContentY: point.y),
      let frame = self.layout.pageFrame(at: pageIndex)
    else {
      return nil
    }
    let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    return PagePoint(pageIndex: pageIndex, point: local)
  }

  // MARK: - ReaderSelectionEventSink

  /// 드래그(롱프레스·마우스 다운)가 시작됐다.
  /// - Parameters:
  ///   - point: 콘텐츠 공간의 시작 점.
  ///   - granularity: 시작 정밀도.
  package func hostSelectionDragBegan(
    atContentPoint point: CGPoint, granularity: SelectionGranularity
  ) {
    guard let pagePoint = self.pagePoint(forContentPoint: point) else {
      return
    }
    self.selectionController?.dragBegan(at: pagePoint, granularity: granularity)
  }

  /// 드래그가 진행 중이다.
  /// - Parameter point: 콘텐츠 공간의 현재 점.
  package func hostSelectionDragChanged(toContentPoint point: CGPoint) {
    guard let pagePoint = self.pagePoint(forContentPoint: point) else {
      return
    }
    self.selectionController?.dragChanged(to: pagePoint)
  }

  /// 드래그가 정상 종료됐다.
  package func hostSelectionDragEnded() {
    self.selectionController?.dragEnded()
  }

  /// 드래그가 취소됐다.
  package func hostSelectionDragCancelled() {
    self.selectionController?.dragCancelled()
  }

  /// 점이 핸들 터치 타깃 안이면 해당 핸들을 반환한다.
  /// - Parameter point: 콘텐츠 공간의 점.
  /// - Returns: 히트된 핸들, 없으면 `nil`.
  package func hostSelectionHandleTest(atContentPoint point: CGPoint) -> SelectionHandle? {
    guard let pagePoint = self.pagePoint(forContentPoint: point) else {
      return nil
    }
    let radius = SelectionStyle.handleTouchTargetRadius / max(self.host?.zoomScale ?? 1, 0.001)
    return self.selectionController?.handleHit(at: pagePoint, radius: radius)
  }

  /// 핸들 드래그가 시작됐다.
  /// - Parameters:
  ///   - handle: 시작된 핸들.
  ///   - point: 콘텐츠 공간의 시작 점.
  package func hostSelectionHandleDragBegan(
    _ handle: SelectionHandle, atContentPoint point: CGPoint
  ) {
    guard let pagePoint = self.pagePoint(forContentPoint: point) else {
      return
    }
    self.selectionController?.handleDragBegan(handle, at: pagePoint)
  }

  /// 탭/클릭 — 영역 히트 판정 후 선택/해제한다 (§3 전이표 T4′/T20′/T27).
  /// - Parameter point: 콘텐츠 공간의 탭 점.
  package func hostTap(atContentPoint point: CGPoint) {
    guard let pagePoint = self.pagePoint(forContentPoint: point) else {
      return
    }
    self.selectionController?.tap(at: pagePoint)
  }

  /// ⌘C·메뉴 복사.
  package func hostCopyCommand() {
    Task { [weak self] in
      await self?.copySelectionToPasteboard()
    }
  }

  /// 활성 선택(텍스트 또는 영역) 존재 여부.
  /// - Returns: 활성 선택이 있으면 `true`.
  package func hostHasSelection() -> Bool {
    self.selectionController?.activeSelection != nil
  }

  /// 복사 가능 여부 (⌘C·Copy validate 전용) — 텍스트 선택 존재. 영역 선택은 복사할
  /// 텍스트가 없어 `false`다.
  /// - Returns: 복사 가능하면 `true`.
  package func hostCanCopy() -> Bool {
    self.selectionController?.selection != nil
  }

  /// 우클릭 지점의 컨텍스트 메뉴 항목 (선택 밖·선택 없음이면 빈 배열) — macOS pull 표면.
  ///
  /// ① 텍스트 선택이 있고 우클릭 점이 그 quad 안이면 텍스트 컨텍스트를 반환한다.
  /// ② 텍스트 미히트면 그 점의 영역 히트를 질의한다 — 히트하면 그 영역을 선택(오버레이
  /// 표시)한 뒤 영역 컨텍스트를 반환한다(우클릭도 선택하는 macOS 관례). 이 경로는
  /// `onMenuRequest`를 발화하지 않는다 — 반환 메뉴를 호출측(`menu(for:)`)이 곧장
  /// 표시하므로 push 경로와 겹치면 메뉴가 2회 뜬다. ③ 둘 다 미히트면 빈 배열이다.
  ///
  /// 텍스트 해소 문자열은 프리페치 캐시(§4.5)에서 동기로 얻는다: 캐시 적중 시 그 값,
  /// 미스면 캐시 전용 재조립 폴백, 그래도 실패하면 빈 문자열로 진행한다.
  /// - Parameter point: 콘텐츠 공간의 우클릭 점.
  /// - Returns: 해소된 메뉴 항목 목록.
  package func hostContextMenuItems(atContentPoint point: CGPoint) -> [ResolvedMenuItem] {
    guard let selectionController, let pagePoint = self.pagePoint(forContentPoint: point) else {
      return []
    }
    if let selection = selectionController.selection {
      let quads = selectionController.displayQuads(forPage: pagePoint.pageIndex)
      if quads.contains(where: { $0.boundingRect.contains(pagePoint.point) }) {
        let text = self.cachedMenuText(for: selection)
        let context = SelectionContext.text(
          TextSelectionContext(selection: selection, selectedText: text)
        )
        return SelectionMenuResolver.resolve(context: context, builder: self.selectionMenuBuilder)
      }
    }
    guard let region = selectionController.selectRegionForContextMenu(at: pagePoint) else {
      return []
    }
    let context = SelectionContext.region(region)
    return SelectionMenuResolver.resolve(context: context, builder: self.selectionMenuBuilder)
  }
}

extension ReaderCore {
  /// 페이지 하나에 현재 선택 표시를 반영한다 (`applyHighlights` 전례).
  /// - Parameter pageIndex: 반영할 페이지 인덱스.
  func applySelection(toPage pageIndex: Int) {
    guard let controller = self.controllers[pageIndex] else {
      return
    }
    guard let selectionController else {
      return
    }
    let quads = selectionController.displayQuads(forPage: pageIndex)
    let handles = selectionController.handlePlacement(forPage: pageIndex)
    let scale = 1 / max(self.host?.zoomScale ?? 1, 0.001)
    if quads.isEmpty, handles == nil {
      controller.clearSelection()
    } else {
      controller.setSelection(quads, handles: handles, handleScale: scale)
    }
  }

  /// 확정 선택(텍스트 또는 영역) 주변에 해소된 메뉴를 표시한다 (push 표면 — iOS는
  /// 텍스트·영역 모두, macOS는 영역만) — 문자열 해소 중 선택이 바뀌면(드래그 재시작·
  /// 해제·프로그램 select·다른 영역 탭) 표시를 중단한다(스테일 메뉴 방지).
  /// - Parameter anchorPage: 메뉴 앵커 기준 페이지.
  func presentResolvedMenu(anchorPage: Int) async {
    guard let selectionController, let active = selectionController.activeSelection else {
      return
    }
    let context: SelectionContext
    switch active {
    case let .text(selection):
      let text = await self.menuText(for: selection)
      guard selectionController.selection == selection else { // 기존 스테일 검사.
        return
      }
      context = .text(TextSelectionContext(selection: selection, selectedText: text))
    case let .region(region):
      // await 없는 경로지만 onMenuRequest → Task 사이 상태 변화(연속 탭)를 방어한다.
      let key = RegionKey(pageIndex: region.pageIndex, id: region.id)
      guard selectionController.isRegionSelected(key) else {
        return
      }
      context = .region(region)
    }
    let items = SelectionMenuResolver.resolve(
      context: context, builder: self.selectionMenuBuilder
    )
    guard !items.isEmpty,
      let anchorRect = selectionController.menuAnchorRect(forPage: anchorPage),
      let frame = self.layout.pageFrame(at: anchorPage)
    else {
      return
    }
    self.menuPresenting?.presentSelectionMenu(
      items, around: anchorRect.offsetBy(dx: frame.minX, dy: frame.minY)
    )
  }

  /// 현재 선택 문자열을 페이스트보드에 쓴다 (선택 없으면 no-op).
  ///
  /// ⌘C(`hostCopyCommand`)의 진실 원천 — 메뉴 컨텍스트가 없어 매번 전량 재해소한다
  /// (프리페치 캐시를 거치지 않는다).
  func copySelectionToPasteboard() async {
    guard let text = await self.selectedString() else {
      return
    }
    PlatformPasteboard.setString(text)
  }

  // MARK: - 메뉴 문자열 프리페치 캐시 (§4.5)

  /// 확정 선택 변경에 맞춰 메뉴 문자열 프리페치 캐시를 갱신한다.
  ///
  /// macOS 동기 pull 표면(`hostContextMenuItems`)이 표시 시점에 `await`할 수 없어,
  /// 선택 확정 시점에 미리 조립해 둔다. 선택이 해제되면 진행 중 태스크를 취소하고
  /// 캐시를 비운다.
  /// - Parameter selection: 새로 확정된 선택 (해제되면 `nil`).
  func updateMenuTextCache(for selection: TextSelection?) {
    self.menuTextPrefetchTask?.cancel()
    guard let selection else {
      self.menuTextPrefetchTask = nil
      self.menuTextCache = nil
      return
    }
    guard let selectionController else {
      return
    }
    self.menuTextPrefetchTask = Task { [weak self] in
      let text = await selectionController.selectedString()
      guard let self, selectionController.selection == selection else {
        return
      }
      self.menuTextCache = (selection, text ?? "")
    }
  }

  /// iOS push 경로용 문자열 해소 — 캐시 적중 시 즉시 반환, 미스면 직접 재해소한다.
  /// - Parameter selection: 대상 선택.
  /// - Returns: 해소된 선택 문자열.
  func menuText(for selection: TextSelection) async -> String {
    if let cache = self.menuTextCache, cache.selection == selection {
      return cache.text
    }
    return await self.selectionController?.selectedString() ?? ""
  }

  /// macOS pull 경로용 동기 문자열 해소.
  ///
  /// ① 캐시 적중 → 그 값. ② 미스(프리페치 미완) → 캐시 전용 재조립 폴백
  /// (`selectedStringFromCache()`). ③ 그래도 실패 → 빈 문자열 (메뉴는 뜨되
  /// `selectedText`가 비어 있을 수 있다 — §4.5 문서화된 동작).
  /// - Parameter selection: 대상 선택.
  /// - Returns: 해소된 선택 문자열 (실패해도 빈 문자열).
  func cachedMenuText(for selection: TextSelection) -> String {
    if let cache = self.menuTextCache, cache.selection == selection {
      return cache.text
    }
    return self.selectionController?.selectedStringFromCache() ?? ""
  }

  // MARK: - 모델 위임

  /// 선택을 해제한다.
  package func clearSelection() {
    self.selectionController?.clear()
  }

  /// 프로그램적으로 선택한다.
  /// - Parameter selection: 채택할 선택.
  package func select(_ selection: TextSelection) {
    self.selectionController?.select(selection)
  }

  /// 현재 선택의 문자열이다 (선택이 없거나 미배선이면 `nil`).
  /// - Returns: 조립된 선택 문자열.
  package func selectedString() async -> String? {
    guard let selectionController else {
      return nil
    }
    return await selectionController.selectedString()
  }

  /// 페이지의 선택 가능 영역 등록을 대체한다.
  /// - Parameters:
  ///   - regions: 위생 처리된 등록 목록.
  ///   - pageIndex: 등록 대상 페이지.
  package func setSelectableRegions(_ regions: [SelectableRegion], forPage pageIndex: Int) {
    self.selectionController?.setRegions(regions, forPage: pageIndex)
  }

  /// 모든 페이지의 선택 가능 영역 등록을 해제한다.
  package func clearSelectableRegions() {
    self.selectionController?.clearAllRegions()
  }

  /// 선택된 영역의 리더 뷰 좌표 앵커 사각형 — 선택 통지 시점의 스냅숏 계산.
  ///
  /// 표시 quad(`menuAnchorRect` — 영역 선택 상태에서는 변환된 영역 quad)를 페이지
  /// 프레임으로 콘텐츠 공간에 올린 뒤, 호스트의 가시 원점·줌으로 뷰 좌표로 내린다.
  /// 컨트롤러 상태가 이 영역의 `regionSelected`인 통지 경로 안에서만 부른다 —
  /// 모든 `notifyRegion` 발화 지점이 상태 전이 **뒤**라는 기존 불변식에 기댄다.
  /// - Parameter region: 통지된 영역 (해제 통지면 `nil`).
  /// - Returns: 리더 뷰 좌표 앵커, 해제·미부착·변환 미보유면 `nil`.
  func regionAnchorRect(for region: SelectableRegion?) -> CGRect? {
    guard let region, let host = self.host,
      let displayRect = self.selectionController?.menuAnchorRect(forPage: region.pageIndex),
      let frame = self.layout.pageFrame(at: region.pageIndex)
    else {
      return nil
    }
    let contentRect = displayRect.offsetBy(dx: frame.minX, dy: frame.minY)
    let zoom = host.zoomScale
    let visibleOrigin = host.visibleContentRect.origin
    return CGRect(
      x: (contentRect.minX - visibleOrigin.x) * zoom,
      y: (contentRect.minY - visibleOrigin.y) * zoom,
      width: contentRect.width * zoom,
      height: contentRect.height * zoom
    )
  }

  /// 현재 선택된 영역 스냅숏 (attach 직후 모델 동기화용).
  /// - Returns: 활성 영역 선택, 없으면 `nil`.
  package func selectedRegionSnapshot() -> SelectableRegion? {
    guard let active = self.selectionController?.activeSelection, case let .region(region) = active
    else {
      return nil
    }
    return region
  }
}
