import CoreGraphics
import PapyrusPDFCore

/// 페이지 키 하이라이트 등록부 (모델 소유의 진실 원천 — 순수 값 타입).
///
/// 모든 변이는 실제로 표시가 바뀌는 페이지 집합을 반환한다 — 호출측(모델)은 그
/// 페이지들만 코어에 재통지한다 (O(변경 페이지), 리스크 7 유계 근거).
package struct HighlightRegistry: Sendable {
  /// 페이지 → 하이라이트 (등록 순서).
  private var highlightsByPage: [Int: [Highlight]] = [:]

  /// id → 소속 페이지 (O(1) 제거·대체용 역맵).
  private var pageByID: [String: Int] = [:]

  /// 빈 등록부를 만든다.
  package init() {}

  /// 등록 (위생 적용 + 동일 id 대체). 반환: 변경 페이지 집합.
  ///
  /// 위생 규칙: pageIndex < 0 폐기, 비유한 quad 폐기(전부 폐기되면 항목
  /// 폐기), 배치 내 동일 id는 마지막 항목 승리, 페이지당 `UILimits.maxHighlightsPerPage`
  /// 초과분 폐기(기존 등록 우선). 대체된 기존 항목의 페이지도 변경 집합에 포함된다.
  /// - Parameter highlights: 등록 요청 목록.
  /// - Returns: 실제로 표시가 바뀐 페이지 집합.
  package mutating func add(_ highlights: [Highlight]) -> Set<Int> {
    let sanitized = Self.sanitizeBatch(highlights)
    var changedPages: Set<Int> = []
    for highlight in sanitized {
      if let oldPage = self.pageByID[highlight.id], oldPage != highlight.pageIndex {
        self.highlightsByPage[oldPage]?.removeAll { $0.id == highlight.id }
        if self.highlightsByPage[oldPage]?.isEmpty == true {
          self.highlightsByPage.removeValue(forKey: oldPage)
        }
        changedPages.insert(oldPage)
      }
      var pageList = self.highlightsByPage[highlight.pageIndex] ?? []
      if let existingIndex = pageList.firstIndex(where: { $0.id == highlight.id }) {
        pageList[existingIndex] = highlight
      } else {
        pageList.append(highlight)
      }
      self.highlightsByPage[highlight.pageIndex] = pageList
      self.pageByID[highlight.id] = highlight.pageIndex
      changedPages.insert(highlight.pageIndex)
    }
    for page in changedPages {
      self.enforceCap(forPage: page)
    }
    return changedPages
  }

  /// id로 제거. 반환: 변경 페이지 집합 (미보유면 빈 집합).
  /// - Parameter id: 제거할 하이라이트의 식별자.
  /// - Returns: 실제로 표시가 바뀐 페이지 집합.
  package mutating func remove(id: String) -> Set<Int> {
    guard let pageIndex = self.pageByID.removeValue(forKey: id) else {
      return []
    }
    self.highlightsByPage[pageIndex]?.removeAll { $0.id == id }
    if self.highlightsByPage[pageIndex]?.isEmpty == true {
      self.highlightsByPage.removeValue(forKey: pageIndex)
    }
    return [pageIndex]
  }

  /// 전량 제거. 반환: 비워진 페이지 집합.
  /// - Returns: 비워진 페이지 집합.
  package mutating func removeAll() -> Set<Int> {
    let pages = Set(self.highlightsByPage.keys)
    self.highlightsByPage.removeAll()
    self.pageByID.removeAll()
    return pages
  }

  /// 페이지의 하이라이트 (등록 순서, 없으면 빈 배열).
  /// - Parameter pageIndex: 조회할 페이지 인덱스.
  /// - Returns: 등록 순서의 하이라이트 목록.
  package func highlights(forPage pageIndex: Int) -> [Highlight] {
    self.highlightsByPage[pageIndex] ?? []
  }

  /// 전체 스냅숏 (페이지 오름차순 → 페이지 안 등록 순서 — 직렬화 결정성).
  /// O(전체 항목 수)다.
  package var all: [Highlight] {
    self.highlightsByPage.keys.sorted().flatMap { self.highlightsByPage[$0] ?? [] }
  }

  /// 배치 안 위생 검사 + 동일 id 마지막 항목 승리 (첫 등장 위치, 마지막 값 유지).
  /// - Parameter highlights: 등록 요청 목록 (순서 보존).
  /// - Returns: 위생 처리·중복 제거된 목록 (첫 등장 순서).
  private static func sanitizeBatch(_ highlights: [Highlight]) -> [Highlight] {
    var order: [String] = []
    var byID: [String: Highlight] = [:]
    for highlight in highlights {
      guard highlight.pageIndex >= 0 else {
        continue
      }
      let finiteQuads = highlight.quads.filter(Self.isFinite)
      guard !finiteQuads.isEmpty else {
        continue
      }
      let sanitizedHighlight = finiteQuads.count == highlight.quads.count
        ? highlight
        : Highlight(
          id: highlight.id, pageIndex: highlight.pageIndex, quads: finiteQuads,
          color: highlight.color, range: highlight.range
        )
      if byID[sanitizedHighlight.id] == nil {
        order.append(sanitizedHighlight.id)
      }
      byID[sanitizedHighlight.id] = sanitizedHighlight
    }
    return order.compactMap { byID[$0] }
  }

  /// 페이지당 상한을 넘는 초과분을 뒤에서부터 폐기한다 (기존 등록 우선).
  /// - Parameter pageIndex: 검사할 페이지 인덱스.
  private mutating func enforceCap(forPage pageIndex: Int) {
    guard var pageList = self.highlightsByPage[pageIndex],
      pageList.count > UILimits.maxHighlightsPerPage
    else {
      return
    }
    for discarded in pageList[UILimits.maxHighlightsPerPage...] {
      self.pageByID.removeValue(forKey: discarded.id)
    }
    pageList.removeLast(pageList.count - UILimits.maxHighlightsPerPage)
    self.highlightsByPage[pageIndex] = pageList
  }

  /// quad 4점 전부가 유한 좌표인지 확인한다.
  /// - Parameter quad: 판정할 quad.
  /// - Returns: 전부 유한이면 `true`.
  private static func isFinite(_ quad: Quad) -> Bool {
    [quad.bottomLeft, quad.bottomRight, quad.topRight, quad.topLeft].allSatisfy {
      $0.x.isFinite && $0.y.isFinite
    }
  }
}
