import CoreGraphics
import PapyrusCore

// 이 파일은 `ReaderSelectionController`의 도착 이벤트 처리(T7·T16·T23)·점→위치 해석·
// 선택 재계산·차분 무효화를 담는다 — 상태·이벤트 진입·통지는 `ReaderSelectionController.swift`,
// quad/핸들/문자열 조회는 `+Query.swift` 참조. 설계 §5 한도 초과 시 파일 분할 허용에 따른 분리.

extension ReaderSelectionController {
  // MARK: - 도착 이벤트 (§2.2 T7·T16·T23)

  /// 스토어에 페이지 콘텐츠가 도착했다 (`store.onContentReady` 배선 대상).
  /// - Parameter pageIndex: 도착한 페이지 인덱스.
  func contentArrived(_ pageIndex: Int) {
    // 상태와 무관하게 항상 발화한다 — idle 조기 return에 걸려도 지속 하이라이트만
    // 있는 페이지(선택 없음)가 재반영에서 누락되지 않아야 한다.
    self.onPageContentReady?(pageIndex)
    switch self.state {
    case .idle: // T7
      return
    case var .dragging(session):
      self.applyContentArrived(pageIndex, toDraggingSession: &session)
    case var .selected(selected):
      self.applyContentArrived(pageIndex, toSelectedState: &selected)
    case let .regionSelected(region): // T33 — 창 재진입 시 오버레이 복원.
      guard pageIndex == region.pageIndex else {
        return
      }
      self.onOverlayInvalidate?(pageIndex)
    }
  }

  /// T16: 드래그 중 도착 처리 — 앵커·포커스 중 해당 원입력 페이지를 재해석한다.
  private func applyContentArrived(
    _ pageIndex: Int, toDraggingSession session: inout DragSession
  ) {
    var refined = false
    if session.anchorPoint.pageIndex == pageIndex, session.anchorResolved.provisional {
      session.anchorResolved = self.resolve(
        point: session.anchorPoint, granularity: session.granularity, direction: .forward
      )
      refined = true
    }
    if session.focusPoint.pageIndex == pageIndex, session.focusResolved.provisional {
      let direction = Self.clampDirection(
        anchorPageIndex: session.anchorPoint.pageIndex,
        pointPageIndex: session.focusPoint.pageIndex
      )
      session.focusResolved = self.resolve(
        point: session.focusPoint, granularity: session.granularity, direction: direction
      )
      refined = true
    }
    if refined {
      self.recomputeAndApply(session: &session)
      self.state = .dragging(session)
      return
    }
    let currentRange = Self.computeSelection(
      anchor: session.anchorResolved, focus: session.focusResolved
    ).pageRange
    if currentRange.contains(pageIndex) {
      self.onOverlayInvalidate?(pageIndex)
    }
  }

  /// T23: 확정 선택 상태에서 도착 처리 — 대기 정련 해소 또는 창 재진입 오버레이 복원.
  private func applyContentArrived(
    _ pageIndex: Int, toSelectedState selected: inout SelectedState
  ) {
    guard var refinement = selected.pendingRefinement, refinement.token == self.dragToken else {
      if selected.selection.pageRange.contains(pageIndex) {
        self.onOverlayInvalidate?(pageIndex)
      }
      return
    }

    if let anchorPoint = refinement.anchorPoint, anchorPoint.pageIndex == pageIndex {
      refinement.confirmedAnchor = self.resolve(
        point: anchorPoint, granularity: refinement.granularity, direction: .forward
      )
      refinement.anchorPoint = nil
    }
    if let focusPoint = refinement.focusPoint, focusPoint.pageIndex == pageIndex {
      let anchorPageIndex = refinement.confirmedAnchor?.position.pageIndex ?? focusPoint.pageIndex
      let direction = Self.clampDirection(
        anchorPageIndex: anchorPageIndex, pointPageIndex: focusPoint.pageIndex
      )
      refinement.confirmedFocus = self.resolve(
        point: focusPoint, granularity: refinement.granularity, direction: direction
      )
      refinement.focusPoint = nil
    }

    guard let confirmedAnchor = refinement.confirmedAnchor,
      let confirmedFocus = refinement.confirmedFocus
    else {
      selected.pendingRefinement = refinement
      self.state = .selected(selected)
      return
    }

    let previousRange = selected.selection.pageRange
    guard let newSelection = Self.normalizedSelection(
      Self.computeSelection(anchor: confirmedAnchor, focus: confirmedFocus)
    ) else {
      self.state = .idle
      self.notifyIfChanged(nil)
      _ = self.diffInvalidate(newRange: nil, previous: previousRange)
      return
    }
    selected.selection = newSelection
    selected.pendingRefinement = nil
    self.state = .selected(selected)
    self.notifyIfChanged(newSelection)
    _ = self.diffInvalidate(newRange: newSelection.pageRange, previous: previousRange)
  }

  // MARK: - 끝점 해석 (§2.4 — 순수 함수, 최초 해석·재해석에 공용)

  /// 표시 공간 점을 문서 위치로 해석한다 (미보유 지오메트리는 잠정 클램프로 대체한다).
  /// - Parameters:
  ///   - point: 해석할 페이지 점.
  ///   - granularity: 시작 정밀도.
  ///   - direction: 앵커 대비 클램프 방향.
  /// - Returns: 해석 결과.
  func resolve(
    point: PagePoint, granularity: SelectionGranularity, direction: ClampDirection
  ) -> ResolvedEnd {
    guard let geometry = self.store.geometry(forPage: point.pageIndex) else {
      self.store.requestPage(point.pageIndex)
      return Self.provisionalResolvedEnd(pageIndex: point.pageIndex, direction: direction)
    }
    guard !geometry.isEmpty else {
      return ResolvedEnd(
        position: TextPosition(pageIndex: point.pageIndex, utf16Offset: 0), unitRange: nil,
        provisional: false
      )
    }
    let offset = geometry.textOffset(at: point.point)
    let position = TextPosition(pageIndex: point.pageIndex, utf16Offset: offset)
    let unitRange: Range<Int>?
    switch granularity {
    case .character:
      unitRange = nil
    case .word:
      unitRange = geometry.wordRange(around: offset)
    case .line:
      unitRange = geometry.lineTextRange(containing: offset)
    }
    return ResolvedEnd(position: position, unitRange: unitRange, provisional: false)
  }

  /// 잠정 클램프: 전진이면 `(k, 0)`, 후진이면 `(k+1, 0)`.
  /// - Parameters:
  ///   - pageIndex: 미보유 페이지 인덱스.
  ///   - direction: 클램프 방향.
  /// - Returns: 잠정 해석 결과.
  static func provisionalResolvedEnd(pageIndex: Int, direction: ClampDirection) -> ResolvedEnd {
    switch direction {
    case .forward:
      return ResolvedEnd(
        position: TextPosition(pageIndex: pageIndex, utf16Offset: 0), unitRange: nil,
        provisional: true
      )
    case .backward:
      return ResolvedEnd(
        position: TextPosition(pageIndex: pageIndex + 1, utf16Offset: 0), unitRange: nil,
        provisional: true
      )
    }
  }

  /// 앵커 페이지 대비 점 페이지의 클램프 방향 (`k >= 앵커` → 전진).
  /// - Parameters:
  ///   - anchorPageIndex: 앵커의 원입력 페이지 인덱스.
  ///   - pointPageIndex: 판정할 점의 페이지 인덱스.
  /// - Returns: 클램프 방향.
  static func clampDirection(anchorPageIndex: Int, pointPageIndex: Int) -> ClampDirection {
    pointPageIndex >= anchorPageIndex ? .forward : .backward
  }

  /// 확정된 위치(`TextPosition`)의 quad 중점을 근사한 `PagePoint`를 합성한다
  /// (핸들 드래그 시작 시 앵커의 원입력 점이 필요해 T19가 요구하는 합성).
  /// - Parameter position: 합성 기준 위치.
  /// - Returns: 근사 페이지 점 (지오메트리 미보유면 페이지 원점).
  func syntheticPoint(for position: TextPosition) -> PagePoint {
    guard let geometry = self.store.geometry(forPage: position.pageIndex) else {
      return PagePoint(pageIndex: position.pageIndex, point: .zero)
    }
    let length = geometry.content.string.utf16.count
    let upper = min(position.utf16Offset + 1, length)
    let lower = min(position.utf16Offset, upper)
    guard let quad = geometry.displayQuads(forRange: lower..<upper).first else {
      return PagePoint(pageIndex: position.pageIndex, point: .zero)
    }
    let center = CGPoint(
      x: (quad.bottomLeft.x + quad.bottomRight.x + quad.topLeft.x + quad.topRight.x) / 4,
      y: (quad.bottomLeft.y + quad.bottomRight.y + quad.topLeft.y + quad.topRight.y) / 4
    )
    return PagePoint(pageIndex: position.pageIndex, point: center)
  }

  // MARK: - 선택 재계산 (§2.3)

  /// 빈 선택(`start == end`)을 "선택 없음"으로 정규화한다.
  /// - Parameter selection: 원 선택.
  /// - Returns: 비어 있지 않으면 그대로, 비어 있으면 `nil`.
  static func normalizedSelection(_ selection: TextSelection) -> TextSelection? {
    selection.isEmpty ? nil : selection
  }

  /// 앵커·포커스 해석 결과를 병합해 선택을 재계산한다.
  /// - Parameters:
  ///   - anchor: 앵커 해석 결과.
  ///   - focus: 포커스 해석 결과.
  /// - Returns: 재계산된 선택 (정규화 전 — 비어 있을 수 있다).
  static func computeSelection(anchor: ResolvedEnd, focus: ResolvedEnd) -> TextSelection {
    let anchorRange = Self.endpointRange(anchor)
    let focusRange = Self.endpointRange(focus)
    let start = min(anchorRange.start, focusRange.start)
    let end = max(anchorRange.end, focusRange.end)
    return TextSelection(start: start, end: end)
  }

  /// 끝점 하나가 선택에 기여하는 (시작, 끝) 위치 쌍 (`unitRange` 있으면 그 구간,
  /// 없으면 위치 1점).
  /// - Parameter end: 대상 끝점.
  /// - Returns: 기여 (시작, 끝) 위치 쌍.
  private static func endpointRange(
    _ end: ResolvedEnd
  ) -> (start: TextPosition, end: TextPosition) {
    guard let unitRange = end.unitRange else {
      return (end.position, end.position)
    }
    let pageIndex = end.position.pageIndex
    return (
      TextPosition(pageIndex: pageIndex, utf16Offset: unitRange.lowerBound),
      TextPosition(pageIndex: pageIndex, utf16Offset: unitRange.upperBound)
    )
  }

  // MARK: - 차분 무효화 (§2.3)

  /// 새 범위와 직전 무효화 범위의 대칭차 + 새 범위 양 끝 페이지만 통지한다.
  /// - Parameters:
  ///   - newRange: 새로 계산된 선택의 페이지 범위 (선택 없음이면 `nil`).
  ///   - previous: 직전에 무효화 통지한 페이지 범위.
  /// - Returns: 다음 호출의 `previous`로 쓸 `newRange` (그대로 반환).
  func diffInvalidate(
    newRange: ClosedRange<Int>?, previous: ClosedRange<Int>?
  ) -> ClosedRange<Int>? {
    var pages: Set<Int> = []
    if let newRange {
      pages.insert(newRange.lowerBound)
      pages.insert(newRange.upperBound)
    }
    switch (previous, newRange) {
    case (nil, nil):
      break
    case let (nil, .some(new)):
      pages.formUnion(new)
    case let (.some(old), nil):
      pages.formUnion(old)
    case let (.some(old), .some(new)):
      for range in Self.subtractRange(old, minus: new) {
        pages.formUnion(range)
      }
      for range in Self.subtractRange(new, minus: old) {
        pages.formUnion(range)
      }
    }
    for page in pages.sorted() {
      self.onOverlayInvalidate?(page)
    }
    return newRange
  }

  /// `range`에서 `other`와 겹치지 않는 부분을 구간(최대 2개)으로 반환한다 (구간 연산 —
  /// 큰 범위를 원소 단위로 순회하지 않아 O(1) 비용).
  /// - Parameters:
  ///   - range: 차감 대상 범위.
  ///   - other: 차감할 범위.
  /// - Returns: `range \ other`를 이루는 구간 목록.
  private static func subtractRange(
    _ range: ClosedRange<Int>, minus other: ClosedRange<Int>
  ) -> [ClosedRange<Int>] {
    guard range.overlaps(other) else {
      return [range]
    }
    var result: [ClosedRange<Int>] = []
    if range.lowerBound < other.lowerBound {
      result.append(range.lowerBound...(other.lowerBound - 1))
    }
    if range.upperBound > other.upperBound {
      result.append((other.upperBound + 1)...range.upperBound)
    }
    return result
  }
}
