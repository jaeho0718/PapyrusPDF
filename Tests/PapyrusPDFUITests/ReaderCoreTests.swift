import CoreGraphics
import PapyrusPDFRendering
@testable import PapyrusPDFUI
import Testing

/// ``ReaderCore``의 실체화·취소·줌·탐색·상태 통지를 검증한다 (설계 §6 RC1-RC5).
///
/// 실 `TileRenderQueue`(픽스처 문서) + 목 호스트를 조합한다. 뷰포트·경합 시나리오는
/// 폴링 대기로 정착을 확인한다 (타이밍 단정 금지 — M5 관례 승계).
@MainActor
struct ReaderCoreTests {
  // MARK: RC1 — 실체화 창 이동·회수

  /// RC1: attach 후 materializedPageIndices == visible ±2; 스크롤 시뮬레이션으로
  /// 실체화 창 이동·회수를 확인한다.
  @Test func attachMaterializesVisibleRangeAndScrollMovesTheWindow() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 30, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)

    core.attach(to: host)

    let visible = core.layout.visiblePageRange(in: host.visibleContentRect)
    let expected = VisibleRangeCalculator.materializedRange(
      visible: visible, pageCount: core.layout.pageCount
    )
    #expect(core.materializedPageIndices == Set(expected))

    // 문서 중앙으로 스크롤 시뮬레이션.
    let midFrame = try #require(core.layout.pageFrame(at: 15))
    host.visibleContentRect = CGRect(x: 0, y: midFrame.minY, width: 300, height: 300)
    core.hostViewportDidChange()

    let visible2 = core.layout.visiblePageRange(in: host.visibleContentRect)
    let expected2 = VisibleRangeCalculator.materializedRange(
      visible: visible2, pageCount: core.layout.pageCount
    )
    #expect(core.materializedPageIndices == Set(expected2))
    #expect(!core.materializedPageIndices.contains(0)) // 이탈한 페이지는 회수된다.
  }

  // MARK: RC2 — 이탈 취소

  /// RC2: 좁은 워커 구성으로 요청을 적체시킨 뒤 스크롤 이탈을 시뮬레이션하면
  /// `droppedBeforeStartCount`가 늘어난다 (폴링 정착).
  @Test func scrollingAwayCancelsBacklogAndDropsBeforeStart() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 20, pageWidth: 600, pageHeight: 600, workerCount: 1
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 624, height: 624)
    let firstFrame = try #require(core.layout.pageFrame(at: 0))
    host.visibleContentRect = CGRect(x: 0, y: firstFrame.minY, width: 624, height: 624)
    core.attach(to: host)

    // 최대 줌으로 전환해 조밀한 타일 격자를 만들고(백로그 형성), workerCount 1로
    // 소화 속도를 늦춘다.
    host.zoomScale = ReaderLayoutMetrics.maxZoomScale
    core.hostZoomInteractionDidEnd()

    // 아직 진행 중인 백로그가 있을 시점에 문서 반대편으로 스크롤 이탈.
    let farFrame = try #require(core.layout.pageFrame(at: 19))
    host.visibleContentRect = CGRect(x: 0, y: farFrame.minY, width: 624, height: 624)
    core.hostViewportDidChange()

    try await UITestSupport.waitUntil {
      (await core.renderQueue.statistics()).droppedBeforeStartCount > 0
    }
  }

  // MARK: RC3 — 줌 버킷 전이

  /// RC3: `hostZoomInteractionDidEnd`로 버킷이 전이되면 신버킷 가시 타일이 캐시에
  /// 도착한다(폴링). 동일 버킷 재스냅은 무작업(통계 불변).
  @Test func zoomInteractionEndSnapsBucketAndSettlesNewTilesInCache() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 3, pageWidth: 600, pageHeight: 600
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 624, height: 624)
    let frame = try #require(core.layout.pageFrame(at: 0))
    host.visibleContentRect = CGRect(x: 0, y: frame.minY, width: 624, height: 624)
    core.attach(to: host)

    host.zoomScale = ReaderLayoutMetrics.maxZoomScale
    core.hostZoomInteractionDidEnd()
    let newBucket = ScaleBucket(snapping: ReaderLayoutMetrics.maxZoomScale)
    let expectedKey = TileKey(pageIndex: 0, scaleBucket: newBucket, col: 0, row: 0)

    try await UITestSupport.waitUntil {
      core.renderQueue.tileCache.tile(for: expectedKey) != nil
    }
    // 남은 프리페치 등 배경 작업이 전부 정착한 뒤에야 "무작업" 비교가 요행 없이 성립한다.
    try await UITestSupport.settle(core.renderQueue)

    // 동일 줌으로 재스냅 — 무작업(통계 변화 없음).
    let statsBefore = await core.renderQueue.statistics()
    core.hostZoomInteractionDidEnd()
    let statsAfter = await core.renderQueue.statistics()
    #expect(statsBefore == statsAfter)
  }

  // MARK: RC4 — 탐색

  /// RC4: `goToPage`가 목 호스트 `scrollTo`를 올바른 인자로 기록하고, `restore`가
  /// 줌·오프셋을 클램프하며, 빈 문서에서 전 탐색이 무크래시로 동작한다.
  @Test func goToPageRecordsScrollAndRestoreClampsAbnormalPosition() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 10, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    host.scrollToCalls.removeAll()

    core.goToPage(5, animated: true)
    let frame = try #require(core.layout.pageFrame(at: 5))
    let call = try #require(host.scrollToCalls.last)
    let expectedY = max(0, frame.minY - ReaderLayoutMetrics.pageSpacing / 2)
    #expect(abs(call.contentY - expectedY) < 0.001)
    #expect(call.zoomScale == nil)
    #expect(call.animated == true)

    // 범위 밖 인덱스는 클램프된다.
    host.scrollToCalls.removeAll()
    core.goToPage(999, animated: false)
    let lastFrame = try #require(core.layout.pageFrame(at: 9))
    let clampedCall = try #require(host.scrollToCalls.last)
    let expectedClampedY = max(0, lastFrame.minY - ReaderLayoutMetrics.pageSpacing / 2)
    #expect(abs(clampedCall.contentY - expectedClampedY) < 0.001)

    // restore의 과도한 줌 배율은 최대값으로 클램프된다.
    host.scrollToCalls.removeAll()
    let position = ReaderPosition(pageIndex: 3, normalizedOffset: 0.5, zoomScale: 1_000)
    core.restore(position, animated: false)
    let restoreCall = try #require(host.scrollToCalls.first)
    #expect(restoreCall.zoomScale == ReaderLayoutMetrics.maxZoomScale)
  }

  /// RC4: 빈 문서에서 탐색 명령 전부가 크래시 없이 무시된다.
  @Test func navigationOnEmptyDocumentDoesNotCrash() async throws {
    let core = try await UITestSupport.makeReaderCore(pageCount: 0)
    let host = MockScrollHost()
    core.attach(to: host)

    core.goToPage(0, animated: false)
    #expect(core.capturePosition() == nil)
    core.restore(ReaderPosition(pageIndex: 0, normalizedOffset: 0, zoomScale: 1), animated: false)
    #expect(core.materializedPageIndices.isEmpty)
  }

  // MARK: RC5 — 상태 통지

  /// RC5: `onStateChange`는 값이 실제로 바뀔 때만 호출된다 (동일 프레임 반복 호출에 1회).
  @Test func onStateChangeFiresOnlyWhenStateActuallyChanges() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 10, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)

    var notifyCount = 0
    core.onStateChange = { _ in notifyCount += 1 }
    core.attach(to: host)
    let countAfterAttach = notifyCount
    #expect(countAfterAttach >= 1)

    // 동일 상태로 반복 호출 — 추가 통지 없음.
    core.hostViewportDidChange()
    core.hostViewportDidChange()
    #expect(notifyCount == countAfterAttach)

    // 실제 변화 — 정확히 1회 추가 통지.
    host.visibleContentRect = CGRect(x: 0, y: 800, width: 300, height: 300)
    core.hostViewportDidChange()
    #expect(notifyCount == countAfterAttach + 1)
  }

  // MARK: §5.2 B1 회귀 — pageUnavailable 영구 래치

  /// B1 회귀: 파서 페이지 수가 CGPDFDocument 페이지 수를 넘는 손상 문서에서, 화면 밖
  /// CG 페이지의 요청은 `pageUnavailable`로 실패하고 해당 페이지가 래치된다. 이후
  /// 동일 뷰포트를 반복 통지해도 새 페치 태스크가 재스폰되지 않는다(요청 스톰 방지).
  @Test func pageUnavailableLatchesPageAndStopsRetryStorm() async throws {
    let core = try await UITestSupport.makeReaderCoreWithPagesBeyondDocument(
      realPageCount: 1, phantomPageCount: 1, pageWidth: 300, pageHeight: 300
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    // 인덱스 1은 레이아웃에만 존재하는 "phantom" 페이지 — 실제 CG 문서에는 없다.
    let phantomFrame = try #require(core.layout.pageFrame(at: 1))
    host.visibleContentRect = CGRect(x: 0, y: phantomFrame.minY, width: 300, height: 300)

    core.attach(to: host)

    // 실패가 정착할 때까지 폴링 — 스폰된 페치 태스크가 전부 자기 제거되어야 한다.
    try await UITestSupport.waitUntil {
      core.visibleFetchTasks.isEmpty
    }
    #expect(core.unavailablePages.contains(1))
    #expect(core.renderingUnavailable == false) // 문서 전체가 아니라 페이지 단위 래치.

    // 동일 뷰포트로 반복 통지 — 래치된 페이지는 필요 집합에서 제외되어 재스폰이 없다.
    core.hostViewportDidChange()
    core.hostViewportDidChange()
    core.hostViewportDidChange()
    #expect(core.visibleFetchTasks.isEmpty)
  }
}
