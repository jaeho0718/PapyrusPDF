import CoreGraphics

/// 이동·줌: 뷰포트 변화 대응 + 공개 탐색·줌 진입점 + 단일 실행 경로 `perform`
/// (설계 `_workspace/36_architect_reader-readiness-zoom.md` §3.2~§3.4, ARCHITECTURE 확정
/// — M5 `TileRenderQueue`+확장 파일 분리와 동일 패턴으로 `ReaderCore.swift` 본체에서
/// 분리한다).
extension ReaderCore {
  /// 뷰포트 크기가 바뀌었다 (회전·창 리사이즈) — 줌 한계 재계산 + 진행 중 이동 목표
  /// 재해석(#20) 또는 현재 위치 보존.
  package func hostViewportSizeDidChange() {
    guard let host else {
      return
    }
    let fit = self.clampedFitScale(forViewportWidth: host.viewportSize.width)
    host.setZoomLimits(minimum: fit, maximum: ReaderLayoutMetrics.maxZoomScale)
    if let inFlight = self.inFlightNavigation {
      // 목표로 확정 점프 — 중간 오프셋 포착 대신 심볼릭 목표를 새 지오메트리에서
      // 재해석한다. `perform`이 래치를 nil로 되돌린다.
      self.perform(inFlight, animated: false)
    } else if let position = self.capturePosition() {
      self.perform(
        ReaderNavigationIntent(destination: .position(position), zoom: .scale(position.zoomScale)),
        animated: false
      )
    } else {
      self.hostViewportDidChange()
    }
  }

  /// 프로그램적 애니메이션 이동이 완료됐다 — 인플라이트 래치를 해제하고 버킷을
  /// 착지 배율로 재스냅한다 (#20).
  package func hostScrollAnimationDidEnd() {
    guard self.inFlightNavigation != nil else {
      return // 핀치 종료 등 이동과 무관한 호출은 무시.
    }
    self.inFlightNavigation = nil
    self.hostZoomInteractionDidEnd()
  }

  /// 사용자 스크롤·줌 제스처가 시작됐다 — 진행 중 프로그램 이동의 목표를 폐기한다.
  package func hostScrollInteractionWillBegin() {
    self.inFlightNavigation = nil
  }

  // MARK: - 탐색·줌 (§4.6, 전부 `perform`으로 수렴)

  /// 페이지 상단으로 스크롤 (인덱스 클램프, 빈 문서 무시).
  /// - Parameters:
  ///   - index: 이동할 페이지 인덱스.
  ///   - animated: 애니메이션 여부.
  package func goToPage(_ index: Int, animated: Bool) {
    self.perform(
      ReaderNavigationIntent(destination: .pageTop(index), zoom: .keep), animated: animated
    )
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
    self.perform(
      ReaderNavigationIntent(destination: .position(position), zoom: .scale(position.zoomScale)),
      animated: animated
    )
  }

  /// 줌 배율을 설정한다 (뷰포트 상단 위치 보존, [fit, max] 클램프).
  /// - Parameters:
  ///   - scale: 목표 줌 배율.
  ///   - animated: 애니메이션 여부.
  package func setZoom(_ scale: CGFloat, animated: Bool) {
    let destination = self.inFlightNavigation?.destination ?? .current
    self.perform(
      ReaderNavigationIntent(destination: destination, zoom: .scale(scale)), animated: animated
    )
  }

  /// fit-width 배율로 맞춘다 (뷰포트 상단 위치 보존).
  /// - Parameter animated: 애니메이션 여부.
  package func fitWidth(animated: Bool) {
    let destination = self.inFlightNavigation?.destination ?? .current
    self.perform(
      ReaderNavigationIntent(destination: destination, zoom: .fitWidth), animated: animated
    )
  }

  /// 모든 이동·줌의 단일 실행 경로 (해석 → scrollTo → 래치/재스냅).
  ///
  /// 병합 규칙: 이동 진입점(`.keep`)은 진행 중 이동의 심볼릭 줌을 상속하고(줌
  /// 애니메이션 중 `goToPage`가 목표 줌을 버리지 않는다), 줌 진입점은 진행 중 이동의
  /// destination을 상속한다(호출부 — `setZoom`/`fitWidth`가 담당, 목표 위치로 줌이
  /// 적용된다).
  /// - Parameters:
  ///   - intent: 실행할 의도.
  ///   - animated: 애니메이션 여부.
  private func perform(_ intent: ReaderNavigationIntent, animated: Bool) {
    guard let host else {
      return // 모델 게이트가 있어 정상 경로에선 불도달.
    }
    var intent = intent
    if case .keep = intent.zoom, let inFlight = self.inFlightNavigation {
      intent = ReaderNavigationIntent(destination: intent.destination, zoom: inFlight.zoom)
    }
    guard let destination = self.resolveDestination(intent.destination) else {
      return
    }
    let fit = self.clampedFitScale(forViewportWidth: host.viewportSize.width)
    let zoomScale = self.resolvedZoomScale(
      for: intent.zoom, fit: fit, currentZoomScale: host.zoomScale
    )
    guard let contentY = self.resolvedContentY(for: destination) else {
      return // resolveDestination이 만든 destination이라 사실상 불도달.
    }
    // 래치를 scrollTo *이전*에 확정 — macOS 호스트가 scrollTo 안에서 동기로
    // hostScrollAnimationDidEnd()를 부르는 재진입 순서에 안전해야 한다.
    self.hasNavigatedSinceAttach = true
    self.inFlightNavigation =
      animated ? ReaderNavigationIntent(destination: destination, zoom: intent.zoom) : nil
    host.scrollTo(contentY: contentY, zoomScale: zoomScale, animated: animated)
    if !animated {
      self.hostZoomInteractionDidEnd() // 기존 restore와 동일한 즉시 재스냅.
    }
  }

  /// 목표 줌을 실행 시점 배율로 해석한다 (`.keep`은 fit 하한 보정만, `.scale`은
  /// 위생·클램프, `.fitWidth`는 그 시점 fit).
  /// - Parameters:
  ///   - zoom: 해석할 목표 줌.
  ///   - fit: 그 시점 fit-width 배율(위생 처리됨).
  ///   - currentZoomScale: 호스트의 현재 줌 배율.
  /// - Returns: 적용할 줌 배율, `.keep`이 이미 하한 이상이면 `nil`(유지).
  private func resolvedZoomScale(
    for zoom: ReaderNavigationIntent.Zoom, fit: CGFloat, currentZoomScale: CGFloat
  ) -> CGFloat? {
    switch zoom {
    case .keep:
      return currentZoomScale < fit ? fit : nil
    case .scale(let raw):
      let sane = raw.isFinite ? raw : 0 // 비유한값 → 하한 클램프(위생).
      return min(max(sane, fit), ReaderLayoutMetrics.maxZoomScale)
    case .fitWidth:
      return fit
    }
  }

  /// 구체화된 목표 지점을 콘텐츠 공간 Y로 해석한다.
  /// - Parameter destination: 구체화된(클램프·`.current` 해소 완료) 목표 지점.
  /// - Returns: 콘텐츠 공간 Y, 해석 불가면 `nil`.
  private func resolvedContentY(for destination: ReaderNavigationIntent.Destination) -> CGFloat? {
    switch destination {
    case .pageTop(let index):
      guard let frame = self.layout.pageFrame(at: index) else {
        return nil
      }
      return max(0, frame.minY - ReaderLayoutMetrics.pageSpacing / 2)
    case .position(let position):
      return self.layout.contentY(for: position)
    case .current:
      return nil // resolveDestination이 항상 제거하므로 불도달.
    }
  }

  /// 목표 지점을 실행 시점 값으로 구체화한다 (`.current` → 현재 위치, `.pageTop`
  /// 인덱스 클램프). 빈 문서 등으로 구체화 불가면 `nil`.
  /// - Parameter destination: 구체화할 목표 지점.
  /// - Returns: 구체화된 목표 지점, 실패 시 `nil`.
  private func resolveDestination(
    _ destination: ReaderNavigationIntent.Destination
  ) -> ReaderNavigationIntent.Destination? {
    switch destination {
    case .pageTop(let index):
      guard self.layout.pageCount > 0 else {
        return nil
      }
      return .pageTop(min(max(index, 0), self.layout.pageCount - 1))
    case .position:
      return destination
    case .current:
      guard let position = self.capturePosition() else {
        return nil
      }
      return .position(position)
    }
  }

  /// fit-width 배율을 `[매우 작은 값, maxZoomScale]`로 위생 처리해 돌려준다
  /// (병적으로 좁은 콘텐츠 × 넓은 뷰포트에서 fit이 max를 넘는 것을 방지).
  /// - Parameter width: 뷰포트 폭 (pt).
  /// - Returns: 위생 처리된 fit-width 배율.
  func clampedFitScale(forViewportWidth width: CGFloat) -> CGFloat {
    min(self.layout.fitWidthScale(forViewportWidth: width), ReaderLayoutMetrics.maxZoomScale)
  }
}
