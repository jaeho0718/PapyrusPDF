import CoreGraphics
import PapyrusRendering

/// 가시 범위 파생 계산 (상태 없는 순수 함수 모음 — 집중 테스트 대상).
package enum VisibleRangeCalculator {
  /// 실체화 범위: `visible`을 ±`materializationMargin` 확장 후 `[0, pageCount)`로 클램프.
  /// - Parameters:
  ///   - visible: 현재 가시 페이지 범위.
  ///   - pageCount: 문서 전체 페이지 수.
  /// - Returns: 실체화할 페이지 범위.
  package static func materializedRange(visible: Range<Int>, pageCount: Int) -> Range<Int> {
    guard pageCount > 0, !visible.isEmpty else {
      return 0..<0
    }
    let margin = ReaderLayoutMetrics.materializationMargin
    let lower = max(0, visible.lowerBound - margin)
    let upper = min(pageCount, visible.upperBound + margin)
    return lower..<upper
  }

  /// M5에 넘길 뷰포트 스냅숏을 조립한다.
  /// `pages`는 가시 페이지들의 (인덱스, 페이지 공간 가시 사각형) — `pageVisibleRect` 사용.
  /// - Parameters:
  ///   - layout: 레이아웃 엔진.
  ///   - visibleContentRect: 뷰포트의 콘텐츠 공간 사각형 (줌 미적용 좌표).
  ///   - scaleBucket: 현재 스냅된 버킷 (가정 3 — 제스처 중이 아닌 확정값).
  ///   - viewportSize: 화면 뷰포트 크기 (pt) — M5 프리페치 확장 기준.
  /// - Returns: M5 `TileRenderQueue.updateViewport(_:)`에 넘길 스냅숏.
  package static func renderViewport(
    layout: ReaderLayoutEngine, visibleContentRect: CGRect,
    scaleBucket: ScaleBucket, viewportSize: CGSize
  ) -> RenderViewport {
    let visible = layout.visiblePageRange(in: visibleContentRect)
    let pages = visible.compactMap { index -> RenderViewport.PageViewport? in
      guard
        let visibleRect = layout.pageVisibleRect(
          pageIndex: index, contentRect: visibleContentRect
        )
      else {
        return nil
      }
      return RenderViewport.PageViewport(pageIndex: index, visibleRect: visibleRect)
    }
    return RenderViewport(pages: pages, scaleBucket: scaleBucket, viewportSize: viewportSize)
  }

  /// 현재 페이지 인덱스: 뷰포트 세로 중앙이 속한 페이지 (직관·안정 기준).
  /// - Parameters:
  ///   - layout: 레이아웃 엔진.
  ///   - visibleContentRect: 뷰포트의 콘텐츠 공간 사각형.
  /// - Returns: 현재 페이지 인덱스, 빈 문서면 `nil`.
  package static func currentPageIndex(
    layout: ReaderLayoutEngine, visibleContentRect: CGRect
  ) -> Int? {
    layout.pageIndex(forContentY: visibleContentRect.midY)
  }
}
