import CoreGraphics
import PapyrusCore

/// 지속 하이라이트 mirror 반영 + 색상별 그룹핑 + 선택→하이라이트 변환.
///
/// `ReaderCore.swift`의 몸통과 파일만 분리한 확장이다.
extension ReaderCore {
  /// 페이지의 하이라이트 mirror를 대체하고 실체화돼 있으면 즉시 반영한다
  /// (모델 diff 통지의 수신점 — 빈 배열이면 그 페이지 등록 해제).
  /// - Parameters:
  ///   - highlights: 대체할 하이라이트 목록.
  ///   - pageIndex: 대상 페이지 인덱스.
  package func setHighlights(_ highlights: [Highlight], forPage pageIndex: Int) {
    if highlights.isEmpty {
      self.persistentHighlights.removeValue(forKey: pageIndex)
    } else {
      self.persistentHighlights[pageIndex] = highlights
    }
    self.applyPersistentHighlights(toPage: pageIndex)
  }

  /// 페이지 하나에 현재 하이라이트를 반영한다 (`applyHighlights`/`applySelection` 전례).
  ///
  /// 표시 변환 미보유(store 미로드)면 아무것도 하지 않는다 — 실체화 페이지는
  /// 선택 prefetch가 항상 로드를 걸어 두므로 `onPageContentReady`에서 재시도된다.
  /// - Parameter pageIndex: 반영할 페이지 인덱스.
  func applyPersistentHighlights(toPage pageIndex: Int) {
    guard let controller = self.controllers[pageIndex] else {
      return
    }
    let highlights = self.persistentHighlights[pageIndex] ?? []
    guard !highlights.isEmpty else {
      controller.clearPersistentHighlights()
      return
    }
    guard let transform = self.selectionController?.displayTransform(forPage: pageIndex) else {
      return
    }
    let groups = Self.highlightGroups(for: highlights, transform: transform)
    controller.setPersistentHighlights(groups)
  }

  /// 하이라이트 목록 → 색상별 그룹 (첫 등장 순서 보존, 표시 공간 변환 적용).
  /// 순수 함수 — 유닛 테스트 대상.
  /// - Parameters:
  ///   - highlights: 그룹화할 하이라이트 목록 (등록 순서).
  ///   - transform: PDF 페이지 공간 → 표시 공간 변환.
  /// - Returns: 첫 등장 순서의 색상 그룹 (quad가 전부 스킵된 그룹은 제외).
  nonisolated static func highlightGroups(
    for highlights: [Highlight], transform: CGAffineTransform
  ) -> [PersistentHighlightGroup] {
    var order: [HighlightColor] = []
    var quadsByColor: [HighlightColor: [Quad]] = [:]
    for highlight in highlights {
      if quadsByColor[highlight.color] == nil {
        order.append(highlight.color)
        quadsByColor[highlight.color] = []
      }
      for quad in highlight.quads {
        let displayQuad = PageDisplayTransform.apply(transform, to: quad)
        guard Self.isFinite(displayQuad) else { // 병적 변환 방어 — 등록 위생과 별개.
          continue
        }
        quadsByColor[highlight.color, default: []].append(displayQuad)
      }
    }
    return order.compactMap { color in
      guard let quads = quadsByColor[color], !quads.isEmpty else {
        return nil
      }
      return PersistentHighlightGroup(color: color, quads: quads)
    }
  }

  /// 선택에서 하이라이트 값들을 만든다 (모델 위임 수신점).
  /// - Parameters:
  ///   - selection: 변환할 선택.
  ///   - color: 만들어질 하이라이트의 색.
  /// - Returns: 페이지별 하이라이트 (등록은 하지 않는다 — 호출측이 `addHighlights`로 등록).
  package func makeHighlights(
    from selection: TextSelection, color: HighlightColor
  ) async -> [Highlight] {
    guard let selectionController else {
      return []
    }
    let materials = await selectionController.pageHighlightQuads(for: selection)
    return materials.map { material in
      Highlight(
        pageIndex: material.pageIndex, quads: material.quads, color: color, range: material.range
      )
    }
  }

  /// quad 4점 전부가 유한 좌표인지 확인한다 (병적 변환 방어).
  /// - Parameter quad: 판정할 quad.
  /// - Returns: 전부 유한이면 `true`.
  private nonisolated static func isFinite(_ quad: Quad) -> Bool {
    [quad.bottomLeft, quad.bottomRight, quad.topRight, quad.topLeft].allSatisfy {
      $0.x.isFinite && $0.y.isFinite
    }
  }
}
