import CoreGraphics
import PapyrusCore

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

  /// 탭/클릭 — 현재는 선택 해제만 수행한다(영역 히트는 아직 지원하지 않는다).
  /// - Parameter point: 콘텐츠 공간의 탭 점 (현재 구현은 이 값을 사용하지 않는다).
  package func hostTap(atContentPoint point: CGPoint) {
    self.selectionController?.tap()
  }

  /// ⌘C·메뉴 복사.
  package func hostCopyCommand() {
    Task { [weak self] in
      await self?.copySelectionToPasteboard()
    }
  }

  /// 선택 존재 여부.
  /// - Returns: 선택이 있으면 `true`.
  package func hostHasSelection() -> Bool {
    self.selectionController?.selection != nil
  }

  /// 우클릭 지점의 컨텍스트 메뉴 항목 (선택 밖·선택 없음이면 빈 배열) — macOS pull 표면.
  ///
  /// 해소 문자열은 프리페치 캐시(§4.5)에서 동기로 얻는다: 캐시 적중 시 그 값, 미스면
  /// 캐시 전용 재조립 폴백, 그래도 실패하면 빈 문자열로 진행한다.
  /// - Parameter point: 콘텐츠 공간의 우클릭 점.
  /// - Returns: 해소된 메뉴 항목 목록.
  package func hostContextMenuItems(atContentPoint point: CGPoint) -> [ResolvedMenuItem] {
    guard let selectionController, let selection = selectionController.selection,
      let pagePoint = self.pagePoint(forContentPoint: point)
    else {
      return []
    }
    let quads = selectionController.displayQuads(forPage: pagePoint.pageIndex)
    guard quads.contains(where: { $0.boundingRect.contains(pagePoint.point) }) else {
      return []
    }
    let text = self.cachedMenuText(for: selection)
    let context = SelectionContext.text(
      TextSelectionContext(selection: selection, selectedText: text)
    )
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

  /// 확정 선택 주변에 해소된 메뉴를 표시한다 (iOS push 표면) — 문자열 해소 중 선택이
  /// 바뀌면(드래그 재시작·해제·프로그램 select) 표시를 중단한다(스테일 메뉴 방지).
  /// - Parameter anchorPage: 메뉴 앵커 기준 페이지.
  func presentResolvedMenu(anchorPage: Int) async {
    guard let selectionController, let selection = selectionController.selection else {
      return
    }
    let text = await self.menuText(for: selection)
    guard selectionController.selection == selection else {
      return
    }
    let context = SelectionContext.text(
      TextSelectionContext(selection: selection, selectedText: text)
    )
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
}
