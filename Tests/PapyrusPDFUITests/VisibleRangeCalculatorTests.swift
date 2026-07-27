import CoreGraphics
import PapyrusPDFRendering
import PapyrusPDFUI
import Testing

/// ``VisibleRangeCalculator``의 파생 계산을 검증한다 (설계 §6 VR1-VR3).
struct VisibleRangeCalculatorTests {
  // MARK: VR1 — materializedRange

  /// VR1: 중앙 ±2, 문서 양끝 클램프, pageCount < 5 전체.
  @Test func materializedRangeExpandsByMarginAndClampsAtDocumentEdges() {
    let calc = VisibleRangeCalculator.self
    #expect(calc.materializedRange(visible: 10..<15, pageCount: 100) == 8..<17)
    #expect(calc.materializedRange(visible: 0..<3, pageCount: 100) == 0..<5)
    #expect(calc.materializedRange(visible: 97..<100, pageCount: 100) == 95..<100)
    // pageCount < 5 → 전체 문서가 실체화 범위에 포함된다.
    #expect(calc.materializedRange(visible: 0..<3, pageCount: 3) == 0..<3)
    #expect(calc.materializedRange(visible: 0..<0, pageCount: 100) == 0..<0)
    #expect(calc.materializedRange(visible: 0..<3, pageCount: 0) == 0..<0)
  }

  // MARK: VR2 — renderViewport

  /// VR2: 저줌 다페이지 가시 시 pages 배열(문서 순서·각 visibleRect), scaleBucket·
  /// viewportSize 전달 정확.
  @Test func renderViewportAssemblesPagesInDocumentOrderWithTranslatedRects() {
    let engine = ReaderLayoutEngine(pageSizes: [
      CGSize(width: 200, height: 200),
      CGSize(width: 200, height: 200),
      CGSize(width: 200, height: 200)
    ])
    // contentWidth = 200 + 24 = 224. page0=(12,12,200,200) page1=(12,224,200,200).
    let rect = CGRect(x: 0, y: 0, width: 224, height: 300)
    let bucket = ScaleBucket(exponent: 2)
    let viewportSize = CGSize(width: 224, height: 300)

    let viewport = VisibleRangeCalculator.renderViewport(
      layout: engine, visibleContentRect: rect, scaleBucket: bucket, viewportSize: viewportSize
    )

    #expect(viewport.scaleBucket == bucket)
    #expect(viewport.viewportSize == viewportSize)
    #expect(viewport.pages.map(\.pageIndex) == [0, 1])
    #expect(viewport.pages[0].visibleRect == CGRect(x: 0, y: 0, width: 200, height: 200))
    #expect(viewport.pages[1].visibleRect == CGRect(x: 0, y: 0, width: 200, height: 76))
  }

  // MARK: VR3 — currentPageIndex

  /// VR3: 뷰포트 중앙 기준, 경계 프레임에서 이웃 페이지로 안정 전이.
  @Test func currentPageIndexUsesViewportCenterAndTransitionsAtBoundary() {
    let engine = ReaderLayoutEngine(pageSizes: [
      CGSize(width: 200, height: 200),
      CGSize(width: 200, height: 200)
    ])
    // page0 y[12,212], page1 y[224,424].

    let calc = VisibleRangeCalculator.self

    // 중앙이 page0 내부.
    let rectInside = CGRect(x: 0, y: 0, width: 224, height: 200) // mid=100
    #expect(calc.currentPageIndex(layout: engine, visibleContentRect: rectInside) == 0)

    // 중앙이 정확히 page1 상단 경계.
    let rectAtBoundary = CGRect(x: 0, y: 24, width: 224, height: 400) // mid=224
    #expect(calc.currentPageIndex(layout: engine, visibleContentRect: rectAtBoundary) == 1)

    // 중앙이 간격 위 → 다음 페이지로 안정 전이.
    let rectInGap = CGRect(x: 0, y: 216, width: 224, height: 4) // mid=218 (간격)
    #expect(calc.currentPageIndex(layout: engine, visibleContentRect: rectInGap) == 1)

    let empty = ReaderLayoutEngine(pageSizes: [])
    #expect(calc.currentPageIndex(layout: empty, visibleContentRect: .zero) == nil)
  }
}
