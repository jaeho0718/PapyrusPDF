import CoreGraphics
import PapyrusRendering

/// 실체화·캐시 동기 채움·가시 페치·뷰포트 푸시 코얼레싱 (§4.3-§4.4, §4.7).
///
/// `ReaderCore.swift`의 몸통과 파일만 분리한 확장이다 (M5 `TileRenderQueue`+확장 파일
/// 분리와 동일 패턴 — SwiftLint 파일·타입 길이 한도 준수 목적, 격리·상태는 동일하다).
extension ReaderCore {
  // MARK: - 내부: 실체화 (§4.3 단계 3)

  /// 실체화 창을 `newRange`로 갱신한다 — 이탈 페이지는 회수, 신규 페이지는 배정한다.
  /// - Parameter newRange: 새 실체화 범위.
  func updateMaterialization(to newRange: Range<Int>) {
    let existing = Set(self.controllers.keys)
    let desired = Set(newRange)
    guard existing != desired else {
      return
    }

    for pageIndex in existing.subtracting(desired) {
      guard let controller = self.controllers.removeValue(forKey: pageIndex) else {
        continue
      }
      self.cancelFetches(forPage: pageIndex)
      controller.containerLayer.removeFromSuperlayer()
      self.pool.release(controller)
    }

    let arriving = desired.subtracting(existing)
    guard !arriving.isEmpty, let host else {
      return
    }
    for pageIndex in arriving.sorted() {
      guard let frame = self.layout.pageFrame(at: pageIndex) else {
        continue
      }
      let controller = self.pool.acquire()
      controller.configure(pageIndex: pageIndex, frame: frame)
      controller.activateBucket(self.currentBucket)
      host.contentLayer.addSublayer(controller.containerLayer)
      self.controllers[pageIndex] = controller
      self.fillCacheHits(forPage: pageIndex, controller: controller, host: host)
      self.applyHighlights(to: controller, pageIndex: pageIndex)
    }
  }

  /// 특정 페이지에 걸린 진행 중 페치 태스크를 전부 취소한다 (이탈 처리).
  /// - Parameter pageIndex: 이탈한 페이지 인덱스.
  func cancelFetches(forPage pageIndex: Int) {
    let keysToCancel = self.visibleFetchTasks.keys.filter { key in
      switch key {
      case let .tile(tileKey):
        return tileKey.pageIndex == pageIndex
      case let .preview(previewPageIndex):
        return previewPageIndex == pageIndex
      }
    }
    for key in keysToCancel {
      self.visibleFetchTasks[key]?.cancel()
      self.visibleFetchTasks[key] = nil
    }
  }

  // MARK: - 내부: 캐시 동기 채움 (§4.4 즉시 경로)

  /// 캐시 히트분을 즉시(동기) 컨트롤러에 채운다 (실체화·버킷 전환 직후).
  /// - Parameters:
  ///   - pageIndex: 대상 페이지.
  ///   - controller: 채울 컨트롤러.
  ///   - host: 가시 사각형 조회용 호스트.
  func fillCacheHits(
    forPage pageIndex: Int, controller: PageLayerController, host: any ReaderScrollHost
  ) {
    if let preview = self.renderQueue.previewCache.preview(forPage: pageIndex) {
      controller.setPreview(preview)
    }
    guard
      let visibleRect = self.layout.pageVisibleRect(
        pageIndex: pageIndex, contentRect: host.visibleContentRect
      )
    else {
      return
    }
    let grid = TileGrid(
      pageSize: self.layout.pageSizes[pageIndex], scaleBucket: self.currentBucket
    )
    for key in grid.tileKeys(intersecting: visibleRect, pageIndex: pageIndex)
    where !controller.hasTile(for: key) {
      if let tile = self.renderQueue.tileCache.tile(for: key) {
        controller.setTile(tile)
      }
    }
  }

  // MARK: - 내부: 가시 페치 (§4.4 비동기 경로, §4.3 단계 4)

  /// 가시 페이지들의 필요 요청 집합을 다시 계산하고 진행 중 태스크와 diff한다.
  /// - Parameters:
  ///   - visible: 현재 가시 페이지 범위.
  ///   - rect: 뷰포트의 콘텐츠 공간 가시 사각형.
  func updateFetches(visible: Range<Int>, rect: CGRect) {
    guard !self.renderingUnavailable else {
      return
    }
    var needed: Set<RenderRequestKey> = []
    for pageIndex in visible {
      guard let controller = self.controllers[pageIndex] else {
        continue
      }
      // 영구 실패 확인된 페이지(§5.2 pageUnavailable)는 재요청하지 않는다 — 그렇지
      // 않으면 이 페이지가 화면에 머무는 동안 매 뷰포트 변화마다 동일 실패가 반복된다.
      guard !self.unavailablePages.contains(pageIndex) else {
        continue
      }
      if self.renderQueue.previewCache.preview(forPage: pageIndex) == nil {
        needed.insert(.preview(pageIndex: pageIndex))
      }
      guard
        let visibleRect = self.layout.pageVisibleRect(pageIndex: pageIndex, contentRect: rect)
      else {
        continue
      }
      let grid = TileGrid(
        pageSize: self.layout.pageSizes[pageIndex], scaleBucket: self.currentBucket
      )
      for key in grid.tileKeys(intersecting: visibleRect, pageIndex: pageIndex)
      where !controller.hasTile(for: key) {
        needed.insert(.tile(key))
      }
    }

    let existingKeys = Set(self.visibleFetchTasks.keys)
    for key in existingKeys.subtracting(needed) {
      self.visibleFetchTasks[key]?.cancel()
      self.visibleFetchTasks[key] = nil
    }
    for key in needed.subtracting(existingKeys) {
      self.spawnFetchTask(for: key)
    }
  }

  /// 캐시 미스 키 하나의 페치 태스크를 스폰한다 (visible 등급, M5 가정 7).
  /// - Parameter key: 페치할 요청 키.
  func spawnFetchTask(for key: RenderRequestKey) {
    self.visibleFetchTasks[key] = Task { [weak self] in
      guard let self else {
        return
      }
      do {
        switch key {
        case let .tile(tileKey):
          let tile = try await self.renderQueue.tile(for: tileKey)
          self.applyFetchedTile(tile, key: key)
        case let .preview(pageIndex):
          let preview = try await self.renderQueue.preview(forPage: pageIndex)
          self.applyFetchedPreview(preview, key: key)
        }
      } catch {
        if let renderError = error as? RenderError {
          self.handleFetchError(renderError)
        }
      }
      self.visibleFetchTasks[key] = nil
    }
  }

  /// 페치된 타일을 관련성 재검사 후 컨트롤러에 반영한다.
  /// - Parameters:
  ///   - tile: 도착한 타일.
  ///   - key: 원 요청 키 (취소 여부 조회용).
  func applyFetchedTile(_ tile: RenderedTile, key: RenderRequestKey) {
    guard !Task.isCancelled, self.visibleFetchTasks[key] != nil else {
      return
    }
    guard let controller = self.controllers[tile.key.pageIndex] else {
      return
    }
    controller.setTile(tile)
    if self.isVisibleTileSetComplete(forPage: tile.key.pageIndex, controller: controller) {
      controller.removeStaleTiles()
    }
  }

  /// 페치된 프리뷰를 관련성 재검사 후 컨트롤러에 반영한다.
  /// - Parameters:
  ///   - preview: 도착한 프리뷰.
  ///   - key: 원 요청 키 (취소 여부 조회용).
  func applyFetchedPreview(_ preview: RenderedPreview, key: RenderRequestKey) {
    guard !Task.isCancelled, self.visibleFetchTasks[key] != nil else {
      return
    }
    guard let controller = self.controllers[preview.pageIndex] else {
      return
    }
    controller.setPreview(preview)
  }

  /// 현재 가시 사각형 기준 필요한 타일 키가 컨트롤러에 전부 갖춰졌는지 확인한다.
  /// - Parameters:
  ///   - pageIndex: 대상 페이지.
  ///   - controller: 조회할 컨트롤러.
  /// - Returns: 전부 갖췄으면 `true`.
  func isVisibleTileSetComplete(
    forPage pageIndex: Int, controller: PageLayerController
  ) -> Bool {
    guard let host else {
      return false
    }
    guard
      let visibleRect = self.layout.pageVisibleRect(
        pageIndex: pageIndex, contentRect: host.visibleContentRect
      )
    else {
      return true
    }
    let grid = TileGrid(
      pageSize: self.layout.pageSizes[pageIndex], scaleBucket: self.currentBucket
    )
    return grid.tileKeys(intersecting: visibleRect, pageIndex: pageIndex)
      .allSatisfy { controller.hasTile(for: $0) }
  }

  /// 페치 에러를 §5.2 표대로 처리한다.
  ///
  /// `documentUnavailable`은 문서 전체 래치, `pageUnavailable`은 해당 페이지만 래치해
  /// 영구 실패 재시도를 막는다(둘 다 M5가 영구 실패로 정의). `imageCreationFailed`는
  /// 일시적 실패이므로 아무 조치 없이 다음 뷰포트 변화에서 자연 재요청되도록 둔다
  /// (M5 비메모이즈와 정합). `cancelled`는 정상 취소 경로라 무시한다.
  /// - Parameter error: 발생한 에러.
  func handleFetchError(_ error: RenderError) {
    switch error {
    case .documentUnavailable:
      self.renderingUnavailable = true
    case let .pageUnavailable(pageIndex):
      self.unavailablePages.insert(pageIndex)
    case .imageCreationFailed, .cancelled:
      break
    }
  }

  // MARK: - 내부: 뷰포트 푸시 코얼레싱 (§4.7)

  /// 최신 뷰포트를 M5에 밀어넣는다. 동일 뷰포트는 스킵하고, 소화 속도를 넘는
  /// 프레임은 `pendingViewport` 덮어쓰기로 뭉갠다.
  /// - Parameter viewport: 최신 뷰포트 스냅숏.
  func pushViewport(_ viewport: RenderViewport) {
    guard viewport != self.lastPushedViewport else {
      return
    }
    self.pendingViewport = viewport
    guard self.viewportPushTask == nil else {
      return
    }
    self.viewportPushTask = Task { [weak self] in
      while let next = self?.takePendingViewport() {
        self?.lastPushedViewport = next
        await self?.renderQueue.updateViewport(next)
      }
      self?.viewportPushTask = nil
    }
  }

  /// 대기 중인 뷰포트를 꺼내고 비운다.
  /// - Returns: 대기 중이던 뷰포트, 없으면 `nil`.
  func takePendingViewport() -> RenderViewport? {
    defer { self.pendingViewport = nil }
    return self.pendingViewport
  }
}
