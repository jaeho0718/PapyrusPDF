import PapyrusCore

/// 지속 하이라이트 공개 API(등록·제거·조회·선택 변환) + 재생·통지 내부 로직.
///
/// `PapyrusReaderModel.swift`의 몸통과 파일만 분리한 확장이다 (파일 길이 한도 —
/// `ReaderCore+Search` 전례와 동일 패턴).
extension PapyrusReaderModel {
  /// 하이라이트를 등록합니다 (같은 `id`는 기존 항목을 대체합니다).
  ///
  /// 좌표가 유한하지 않은 quad는 제외되며(전부 제외되면 항목 자체가 제외),
  /// 페이지당 등록 수는 내부 상한에서 잘립니다. 적재 전 호출해도 안전합니다 —
  /// 적재 완료 시 자동 반영됩니다. 렌더 반영 비용은 변경된 페이지 수에
  /// 비례합니다 — 수만 건 일괄 등록도 실체화된 페이지만 실제 레이어 작업을 합니다.
  /// - Parameter highlights: 등록할 하이라이트 목록입니다.
  public func addHighlights(_ highlights: [Highlight]) {
    let changedPages = self.highlightRegistry.add(highlights)
    self.notifyCore(changedPages: changedPages)
  }

  /// 하이라이트 하나를 등록합니다 (``addHighlights(_:)`` 위임).
  /// - Parameter highlight: 등록할 하이라이트입니다.
  public func addHighlight(_ highlight: Highlight) {
    self.addHighlights([highlight])
  }

  /// id의 하이라이트를 제거합니다 (미보유 id는 무시합니다).
  /// - Parameter id: 제거할 하이라이트의 식별자입니다.
  public func removeHighlight(id: String) {
    let changedPages = self.highlightRegistry.remove(id: id)
    self.notifyCore(changedPages: changedPages)
  }

  /// 모든 하이라이트를 제거합니다.
  public func removeAllHighlights() {
    let changedPages = self.highlightRegistry.removeAll()
    self.notifyCore(changedPages: changedPages)
  }

  /// 페이지의 하이라이트입니다 (등록 순서 — 위생 적용 후 실제 활성 목록).
  /// - Parameter pageIndex: 조회할 페이지 인덱스입니다.
  /// - Returns: 등록 순서의 하이라이트 목록입니다 (없으면 빈 배열입니다).
  public func highlights(forPage pageIndex: Int) -> [Highlight] {
    self.highlightRegistry.highlights(forPage: pageIndex)
  }

  /// 전체 하이라이트 스냅숏입니다 (직렬화·복원용 — 페이지 오름차순).
  ///
  /// 전체 항목 수에 비례하는 비용이 듭니다 — 페이지 단위 접근에는
  /// ``highlights(forPage:)``를 사용하세요.
  public var allHighlights: [Highlight] {
    self.highlightRegistry.all
  }

  /// 선택 범위에서 하이라이트를 만듭니다 (페이지별 1개, 표시와 동일한 라인 병합
  /// quad — 등록은 하지 않으므로 ``addHighlights(_:)``를 이어서 호출합니다).
  ///
  /// 비동기인 이유: 선택 중간 페이지의 텍스트가 아직 캐시에 없을 수 있습니다.
  /// 적재 전이거나 선택이 비어 있으면 빈 배열입니다.
  /// - Parameters:
  ///   - selection: 변환할 선택입니다.
  ///   - color: 만들어질 하이라이트의 색입니다.
  /// - Returns: 페이지별 하이라이트 목록입니다 (등록은 하지 않습니다).
  public func makeHighlights(
    from selection: TextSelection, color: HighlightColor
  ) async -> [Highlight] {
    guard let core else {
      return []
    }
    return await core.makeHighlights(from: selection, color: color)
  }

  /// 등록부 전 페이지를 코어에 재생한다 (attach 직후 1회 — 적재 전 등록 지원).
  func replayHighlights() {
    guard let core else {
      return
    }
    let pages = Set(self.highlightRegistry.all.map(\.pageIndex))
    for pageIndex in pages {
      core.setHighlights(self.highlightRegistry.highlights(forPage: pageIndex), forPage: pageIndex)
    }
  }

  /// 변경 페이지들의 현행 목록을 코어에 통지한다 (오름차순 순회 — 결정성).
  /// - Parameter changedPages: 통지할 변경 페이지 집합.
  private func notifyCore(changedPages: Set<Int>) {
    guard let core else {
      return
    }
    for page in changedPages.sorted() {
      core.setHighlights(self.highlightRegistry.highlights(forPage: page), forPage: page)
    }
  }
}
