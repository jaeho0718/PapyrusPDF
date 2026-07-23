import CoreGraphics
import Foundation
import PapyrusCore

/// 검색 상태 기계·매치 탐색·스크롤 (§3.5~3.6).
///
/// `ReaderCore.swift`의 몸통과 파일만 분리한 확장이다 (M5/M6과 동일한 조직 원칙).
extension ReaderCore {
  // MARK: - 공개 진입점

  /// 검색을 시작한다 (빈 query면 `clearSearch`와 동일).
  /// - Parameters:
  ///   - query: 검색어.
  ///   - options: 검색 옵션.
  package func beginSearch(_ query: String, options: SearchOptions) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      self.clearSearch()
      return
    }
    self.searchCoordinator?.start(query: trimmed, options: options)
  }

  /// 검색 상태 전부 해제 + 실체화된 컨트롤러의 오버레이 클리어.
  package func clearSearch() {
    self.searchCoordinator?.cancel()
    self.searchHighlights.removeAll()
    self.searchMatchIndex.removeAll()
    self.currentMatchFlatIndex = nil
    for controller in self.controllers.values {
      controller.clearSearchHighlights()
    }
    self.notifySearchState(query: "", phase: .idle, matchCount: 0, currentMatchIndex: nil)
  }

  /// 다음/이전 매치로 이동 (랩어라운드, 매치 없으면 무시).
  /// - Parameter delta: 이동량 (+1이면 다음, -1이면 이전).
  package func advanceMatch(by delta: Int) {
    let count = self.searchMatchIndex.count
    guard count > 0 else {
      return
    }
    let previousFlatIndex = self.currentMatchFlatIndex
    let baseIndex = previousFlatIndex ?? 0
    let newFlatIndex = ((baseIndex + delta) % count + count) % count
    self.currentMatchFlatIndex = newFlatIndex

    let previousPage = previousFlatIndex.flatMap { self.searchMatchIndex[$0].pageIndex }
    let newPage = self.searchMatchIndex[newFlatIndex].pageIndex
    if let previousPage, previousPage != newPage, let controller = self.controllers[previousPage] {
      self.applyHighlights(to: controller, pageIndex: previousPage)
    }
    if let controller = self.controllers[newPage] {
      self.applyHighlights(to: controller, pageIndex: newPage)
    }
    self.scrollToCurrentMatch(animated: true)
    self.notifySearchState(
      query: self.currentSearchState.query, phase: self.currentSearchState.phase,
      matchCount: count, currentMatchIndex: newFlatIndex
    )
  }

  // MARK: - 내부: 검색 상태 기계 (§3.5)

  /// 코디네이터 이벤트를 적용한다.
  /// - Parameter event: 적용할 검색 이벤트.
  func handleSearchEvent(_ event: SearchEvent) {
    switch event {
    case let .began(query):
      self.handleSearchBegan(query)
    case let .pageResults(pageIndex, highlights):
      self.handleSearchPageResults(pageIndex: pageIndex, highlights: highlights)
    case .finished:
      self.notifySearchState(
        query: self.currentSearchState.query, phase: .completed,
        matchCount: self.searchMatchIndex.count, currentMatchIndex: self.currentMatchFlatIndex
      )
    case let .failed(error):
      self.handleSearchFailed(error)
    }
  }

  /// `.began` 이벤트 처리: 이전 검색 상태 전부 무효화.
  /// - Parameter query: 새로 시작된 검색어.
  private func handleSearchBegan(_ query: String) {
    self.searchHighlights.removeAll()
    self.searchMatchIndex.removeAll()
    self.currentMatchFlatIndex = nil
    for controller in self.controllers.values {
      controller.clearSearchHighlights()
    }
    self.notifySearchState(query: query, phase: .searching, matchCount: 0, currentMatchIndex: nil)
  }

  /// `.pageResults` 이벤트 처리: 평탄 색인 갱신, 첫 매치 자동 포커스, 실체화 페이지 반영.
  /// - Parameters:
  ///   - pageIndex: 결과가 도착한 페이지.
  ///   - highlights: 그 페이지의 표시 공간 매치들.
  private func handleSearchPageResults(pageIndex: Int, highlights: PageSearchHighlights) {
    self.searchHighlights[pageIndex] = highlights
    let wasEmpty = self.searchMatchIndex.isEmpty
    for ordinal in highlights.matches.indices {
      self.searchMatchIndex.append((pageIndex: pageIndex, ordinal: ordinal))
    }
    let becameFirstMatch = wasEmpty && !self.searchMatchIndex.isEmpty
    if becameFirstMatch {
      self.currentMatchFlatIndex = 0
    }
    if let controller = self.controllers[pageIndex] {
      self.applyHighlights(to: controller, pageIndex: pageIndex)
    }
    self.notifySearchState(
      query: self.currentSearchState.query, phase: .searching,
      matchCount: self.searchMatchIndex.count, currentMatchIndex: self.currentMatchFlatIndex
    )
    if becameFirstMatch {
      self.scrollToCurrentMatch(animated: true)
    }
  }

  /// `.failed` 이벤트 처리: 검색 상태 리셋 (뷰어 본체는 계속 동작).
  /// - Parameter error: 문서 수준 검색 실패.
  private func handleSearchFailed(_ error: PapyrusError) {
    self.searchHighlights.removeAll()
    self.searchMatchIndex.removeAll()
    self.currentMatchFlatIndex = nil
    for controller in self.controllers.values {
      controller.clearSearchHighlights()
    }
    self.notifySearchState(
      query: self.currentSearchState.query, phase: .failed(error), matchCount: 0,
      currentMatchIndex: nil
    )
  }

  /// 검색 상태를 조립·저장하고 구독자에게 통지한다.
  /// - Parameters:
  ///   - query: 현재 질의.
  ///   - phase: 진행 단계.
  ///   - matchCount: 지금까지 발견한 매치 수.
  ///   - currentMatchIndex: 현재 매치의 평탄 순번.
  private func notifySearchState(
    query: String, phase: ReaderSearchState.Phase, matchCount: Int, currentMatchIndex: Int?
  ) {
    let state = ReaderSearchState(
      query: query, phase: phase, matchCount: matchCount, currentMatchIndex: currentMatchIndex
    )
    self.currentSearchState = state
    self.onSearchStateChange?(state)
  }

  // MARK: - 내부: 하이라이트 반영

  /// 실체화된 컨트롤러 하나에 현재 하이라이트 상태를 반영한다.
  /// - Parameters:
  ///   - controller: 반영할 컨트롤러.
  ///   - pageIndex: 그 컨트롤러가 담당하는 페이지 인덱스.
  func applyHighlights(to controller: PageLayerController, pageIndex: Int) {
    guard let highlights = self.searchHighlights[pageIndex] else {
      controller.clearSearchHighlights()
      return
    }
    var currentOrdinal: Int?
    if let flatIndex = self.currentMatchFlatIndex,
      self.searchMatchIndex.indices.contains(flatIndex),
      self.searchMatchIndex[flatIndex].pageIndex == pageIndex {
      currentOrdinal = self.searchMatchIndex[flatIndex].ordinal
    }
    controller.setSearchHighlights(highlights, currentOrdinal: currentOrdinal)
  }

  // MARK: - 내부: 매치 스크롤 (§3.6)

  /// 현재 매치가 화면 중앙에 오도록 스크롤한다. 매치 quad가 빈 경우(공백 매치)
  /// 페이지 상단으로 폴백한다.
  /// - Parameter animated: 애니메이션 여부.
  func scrollToCurrentMatch(animated: Bool) {
    guard let host, let flatIndex = self.currentMatchFlatIndex,
      self.searchMatchIndex.indices.contains(flatIndex)
    else {
      return
    }
    let (pageIndex, ordinal) = self.searchMatchIndex[flatIndex]
    guard let highlights = self.searchHighlights[pageIndex],
      highlights.matches.indices.contains(ordinal),
      let frame = self.layout.pageFrame(at: pageIndex)
    else {
      return
    }
    let quads = highlights.matches[ordinal]
    guard let boundingRect = Self.boundingRect(of: quads) else {
      self.goToPage(pageIndex, animated: animated)
      return
    }
    let targetY = frame.minY + boundingRect.midY - host.visibleContentRect.height / 2
    let maxY = max(0, self.layout.contentSize.height - host.visibleContentRect.height)
    let clampedY = min(max(targetY, 0), maxY)
    host.scrollTo(contentY: clampedY, zoomScale: nil, animated: animated)
  }

  /// quad 목록의 합집합 boundingRect (빈 배열이면 `nil`).
  /// - Parameter quads: 대상 quad 목록.
  /// - Returns: 합집합 사각형, 빈 배열이면 `nil`.
  private static func boundingRect(of quads: [Quad]) -> CGRect? {
    guard let first = quads.first else {
      return nil
    }
    return quads.dropFirst().reduce(first.boundingRect) { partial, quad in
      partial.union(quad.boundingRect)
    }
  }
}
