import CoreGraphics
import Foundation
import PapyrusPDFUI
import Testing

/// ``ReaderLayoutEngine``의 순수 수학을 검증한다 (설계 §6 LE1-LE7).
struct ReaderLayoutEngineTests {
  /// 혼합 크기 3페이지 고정 픽스처 (LE1-LE6 공통).
  private static let mixedSizes = [
    CGSize(width: 100, height: 200),
    CGSize(width: 300, height: 100),
    CGSize(width: 150, height: 400)
  ]

  // MARK: LE1 — yOffsets·pageFrame·contentSize 해석적 일치

  /// LE1: 혼합 크기 3페이지의 누적 오프셋·중앙정렬 프레임·contentSize가 손으로 계산한
  /// 값과 정확히 일치한다.
  @Test func mixedSizesProduceAnalyticallyExactFramesAndContentSize() {
    let engine = ReaderLayoutEngine(pageSizes: Self.mixedSizes)

    // contentWidth = max(100,300,150) + 2*12 = 324. contentHeight = 736 + 12 = 748.
    #expect(engine.contentSize == CGSize(width: 324, height: 748))
    #expect(engine.pageCount == 3)

    #expect(engine.pageFrame(at: 0) == CGRect(x: 112, y: 12, width: 100, height: 200))
    #expect(engine.pageFrame(at: 1) == CGRect(x: 12, y: 224, width: 300, height: 100))
    #expect(engine.pageFrame(at: 2) == CGRect(x: 87, y: 336, width: 150, height: 400))
    #expect(engine.pageFrame(at: 3) == nil)
    #expect(engine.pageFrame(at: -1) == nil)
  }

  // MARK: LE2 — pageIndex(forContentY:)

  /// LE2: 페이지 내부·경계·간격 위(다음 페이지 귀속)·상하 범위 밖 클램프·빈 문서 nil.
  @Test func pageIndexForContentYCoversInteriorBoundaryGapAndClamping() {
    let engine = ReaderLayoutEngine(pageSizes: Self.mixedSizes)

    #expect(engine.pageIndex(forContentY: 100) == 0) // page0 내부
    #expect(engine.pageIndex(forContentY: 12) == 0) // page0 상단 경계
    #expect(engine.pageIndex(forContentY: 212) == 0) // page0 하단 경계
    #expect(engine.pageIndex(forContentY: 218) == 1) // 간격 위 → 다음 페이지
    #expect(engine.pageIndex(forContentY: 224) == 1) // page1 상단 경계
    #expect(engine.pageIndex(forContentY: -50) == 0) // 상단 범위 밖 → 클램프
    #expect(engine.pageIndex(forContentY: 10_000) == 2) // 하단 범위 밖 → 클램프

    let empty = ReaderLayoutEngine(pageSizes: [])
    #expect(empty.pageIndex(forContentY: 0) == nil)
  }

  // MARK: LE3 — visiblePageRange(in:)

  /// LE3: 걸침 2페이지, 간격만 걸친 rect, 문서 밖 rect, 단일 페이지 전체 확대.
  @Test func visiblePageRangeCoversOverlapGapOutsideAndFullPage() {
    let engine = ReaderLayoutEngine(pageSizes: Self.mixedSizes)

    // page0[12,212], page1[224,324] 걸침.
    #expect(engine.visiblePageRange(in: CGRect(x: 0, y: 100, width: 10, height: 150)) == 0..<2)

    // 간격[212,224]만 걸친 rect → 가장 가까운 페이지 1개(다음 페이지 귀속).
    #expect(engine.visiblePageRange(in: CGRect(x: 0, y: 214, width: 10, height: 6)) == 1..<2)

    // 문서 위 rect.
    #expect(engine.visiblePageRange(in: CGRect(x: 0, y: -100, width: 10, height: 50)) == 0..<1)
    // 문서 아래 rect.
    #expect(engine.visiblePageRange(in: CGRect(x: 0, y: 2_000, width: 10, height: 50)) == 2..<3)

    // page1 전체를 정확히 덮는 rect.
    #expect(engine.visiblePageRange(in: CGRect(x: 12, y: 224, width: 300, height: 100)) == 1..<2)

    let empty = ReaderLayoutEngine(pageSizes: [])
    #expect(empty.visiblePageRange(in: CGRect(x: 0, y: 0, width: 10, height: 10)) == 0..<0)
  }

  // MARK: LE4 — pageVisibleRect

  /// LE4: 페이지 상단이 뷰포트 위로 잘린 경우의 페이지 공간 사각형 (평행이동 검증),
  /// 비교차 nil.
  @Test func pageVisibleRectTranslatesIntersectionIntoPageSpace() {
    let engine = ReaderLayoutEngine(pageSizes: Self.mixedSizes)

    // page1 frame = (12, 224, 300, 100). 뷰포트가 250부터 시작해 상단 26pt가 잘린다.
    let contentRect = CGRect(x: 0, y: 250, width: 400, height: 200)
    let visible = engine.pageVisibleRect(pageIndex: 1, contentRect: contentRect)
    #expect(visible == CGRect(x: 0, y: 26, width: 300, height: 74))

    // 교차 없음.
    let farRect = CGRect(x: 0, y: 5_000, width: 10, height: 10)
    #expect(engine.pageVisibleRect(pageIndex: 1, contentRect: farRect) == nil)
    // 인덱스 밖.
    #expect(engine.pageVisibleRect(pageIndex: 99, contentRect: contentRect) == nil)
  }

  // MARK: LE5 — 퇴화 입력 위생 처리

  /// LE5: 크기 0·음수·1e9 클램프 후 전 조회 무크래시, `fitWidthScale` 유한.
  @Test func degenerateSizesAreClampedAndAllQueriesStaySafe() {
    let engine = ReaderLayoutEngine(pageSizes: [
      CGSize(width: 0, height: 0),
      CGSize(width: -50, height: -50),
      CGSize(width: 1e9, height: 1e9)
    ])

    #expect(engine.pageSizes[0] == CGSize(width: 1, height: 1))
    #expect(engine.pageSizes[1] == CGSize(width: 1, height: 1))
    #expect(engine.pageSizes[2] == CGSize(width: 50_000, height: 50_000))

    // 전 조회가 무크래시로 응답한다.
    #expect(engine.pageFrame(at: 0) != nil)
    #expect(engine.pageIndex(forContentY: 0) != nil)
    #expect(engine.visiblePageRange(in: CGRect(x: 0, y: 0, width: 10, height: 10)) == 0..<1)

    #expect(engine.fitWidthScale(forViewportWidth: 100).isFinite)
    #expect(engine.fitWidthScale(forViewportWidth: 0).isFinite)
    #expect(engine.fitWidthScale(forViewportWidth: -10).isFinite)
  }

  // MARK: LE6 — 위치 왕복 + 비정상 클램프

  /// LE6: `capturePosition` → `contentY(for:)` 오차 < 0.5pt (여러 줌·페이지),
  /// 비정상 position 클램프.
  @Test func positionRoundTripsWithinHalfPointAndClampsAbnormalInput() {
    let engine = ReaderLayoutEngine(pageSizes: Self.mixedSizes)

    let samples: [(y: CGFloat, zoom: CGFloat)] = [
      (50, 1), (12, 0.5), (212, 2), (270, 8), (500, 1.339)
    ]
    for sample in samples {
      let captured = engine.capturePosition(viewportTopY: sample.y, zoomScale: sample.zoom)
      guard let position = captured else {
        Issue.record("capturePosition unexpectedly returned nil for non-empty layout")
        continue
      }
      let restored = engine.contentY(for: position)
      #expect(abs(restored - sample.y) < 0.5)
    }

    // 비정상 위치값 — 필드별 클램프 (음수 인덱스 → 0, 초과 오프셋 → 1).
    let abnormal = ReaderPosition(pageIndex: -5, normalizedOffset: 5, zoomScale: 100)
    let clampedY = engine.contentY(for: abnormal)
    guard let page0Frame = engine.pageFrame(at: 0), let lastFrame = engine.pageFrame(at: 2) else {
      Issue.record("expected page frames to exist")
      return
    }
    #expect(clampedY == page0Frame.minY + page0Frame.height)

    let tooFar = ReaderPosition(pageIndex: 999, normalizedOffset: -5, zoomScale: 1)
    let clampedY2 = engine.contentY(for: tooFar)
    #expect(clampedY2 == lastFrame.minY)

    let empty = ReaderLayoutEngine(pageSizes: [])
    #expect(empty.capturePosition(viewportTopY: 0, zoomScale: 1) == nil)
  }

  // MARK: LE7 — 성능 게이트 (env 플래그 게이트)

  /// LE7: 5,000페이지 생성 < 10ms, 조회 10⁴회 < 5ms. `PAPYRUSPDF_PERF=1`에서만 실행.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PAPYRUSPDF_PERF"] == "1"))
  func fiveThousandPagesConstructAndQueryWithinBudget() {
    let sizes = (0..<5_000).map { index in
      CGSize(width: 400 + CGFloat(index % 7) * 10, height: 600 + CGFloat(index % 5) * 10)
    }

    let clock = ContinuousClock()
    let constructStart = clock.now
    let engine = ReaderLayoutEngine(pageSizes: sizes)
    let constructElapsed = clock.now - constructStart
    #expect(constructElapsed < .milliseconds(10))

    let queryStart = clock.now
    for index in 0..<10_000 {
      let y = CGFloat(index % 5_000) * 3
      _ = engine.pageIndex(forContentY: y)
    }
    let queryElapsed = clock.now - queryStart
    #expect(queryElapsed < .milliseconds(5))
  }
}
