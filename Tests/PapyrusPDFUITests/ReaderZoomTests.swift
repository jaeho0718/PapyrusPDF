import CoreGraphics
import PapyrusPDFRendering
@testable import PapyrusPDFUI
import Testing

/// 이슈 #20(애니메이션 이동 중 뷰포트 변화가 중간 오프셋 고정)·#21(줌 제어 API 부재)의
/// 수정을 검증한다 — 설계 `_workspace/36_architect_reader-readiness-zoom.md` §5,
/// 케이스 6~9, 11~15.
@MainActor
struct ReaderZoomTests {
  // MARK: #20 — 인플라이트 래치

  /// 케이스 6: 애니메이션 이동 진행 중(완료 통지 없이) 뷰포트가 리사이즈되면, 중간
  /// 오프셋이 아니라 이동 목표(20쪽 상단)로 확정 점프한다.
  @Test func viewportResizeDuringAnimatedMoveJumpsToLatchedTarget() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 30, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)

    core.goToPage(20, animated: true) // 완료 통지 없음 — 애니메이션 "진행 중" 상태.
    // 중간 오프셋을 시뮬레이션 — 리사이즈가 이 값을 포착하면 결함 재현.
    host.visibleContentRect = CGRect(x: 0, y: 500, width: 300, height: 300)

    host.viewportSize = CGSize(width: 250, height: 300)
    core.hostViewportSizeDidChange()

    let frame = try #require(core.layout.pageFrame(at: 20))
    let expectedY = max(0, frame.minY - ReaderLayoutMetrics.pageSpacing / 2)
    let call = try #require(host.scrollToCalls.last)
    #expect(abs(call.contentY - expectedY) < 0.001)
    #expect(call.animated == false)
    #expect(abs(call.contentY - 500) > 1) // 중간 오프셋이 아님을 재확인.
  }

  /// 케이스 7: 애니메이션 완료 통지 후의 리사이즈는 목표 재점프가 아니라 그 시점의
  /// 현재 위치(`visibleContentRect` 기반) 포착 경로로 복원한다.
  @Test func viewportResizeAfterAnimationCompletionCapturesCurrentPosition() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 30, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)

    core.goToPage(20, animated: true)
    core.hostScrollAnimationDidEnd() // 완료 — 래치 해제.

    let midFrame = try #require(core.layout.pageFrame(at: 20))
    host.visibleContentRect = CGRect(x: 0, y: midFrame.minY, width: 300, height: 300)
    let expectedPosition = try #require(core.capturePosition())
    let expectedY = core.layout.contentY(for: expectedPosition)

    host.viewportSize = CGSize(width: 250, height: 300)
    host.scrollToCalls.removeAll()
    core.hostViewportSizeDidChange()

    let call = try #require(host.scrollToCalls.last)
    #expect(abs(call.contentY - expectedY) < 0.001)
    #expect(call.animated == false)
  }

  /// 케이스 8: 애니메이션 이동 진행 중 사용자 스크롤·줌 제스처가 시작되면
  /// (`hostScrollInteractionWillBegin()`) 인플라이트 래치가 폐기되고, 이어지는
  /// 리사이즈는 목표가 아니라 포착 경로로 떨어진다.
  @Test func userInteractionDuringAnimatedMoveDiscardsLatch() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 30, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)

    core.goToPage(20, animated: true)
    core.hostScrollInteractionWillBegin() // 사용자가 조작권을 가져갔다 — 래치 폐기.
    #expect(core.inFlightNavigation == nil)

    host.visibleContentRect = CGRect(x: 0, y: 400, width: 300, height: 300)
    let expectedPosition = try #require(core.capturePosition())
    let expectedY = core.layout.contentY(for: expectedPosition)

    host.viewportSize = CGSize(width: 250, height: 300)
    host.scrollToCalls.removeAll()
    core.hostViewportSizeDidChange()

    let call = try #require(host.scrollToCalls.last)
    #expect(abs(call.contentY - expectedY) < 0.001)

    // 목표(20쪽 상단)로 재점프한 것이 아님을 재확인.
    let frame20 = try #require(core.layout.pageFrame(at: 20))
    let page20Y = max(0, frame20.minY - ReaderLayoutMetrics.pageSpacing / 2)
    #expect(abs(call.contentY - page20Y) > 1)
  }

  /// 케이스 9: 애니메이션 완료 통지가 오기 전에는 버킷이 바뀌지 않고(중간 스냅
  /// 부재), 완료 통지 시점에 착지 배율(4) 기준으로 정확히 재스냅된다.
  @Test func animationCompletionResnapsBucketToLandingZoomNotMidflight() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 5, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)

    let bucketBeforeMove = core.currentBucket
    let position = ReaderPosition(pageIndex: 0, normalizedOffset: 0, zoomScale: 4)
    core.restore(position, animated: true)

    #expect(core.currentBucket == bucketBeforeMove) // 통지 전 — 버킷 무변화.

    core.hostScrollAnimationDidEnd()

    #expect(core.currentBucket == ScaleBucket(snapping: 4))
  }

  // MARK: #21 — 줌 API

  /// 케이스 11: `setZoom`은 비정상 입력을 위생 처리한 뒤 `[fit, max]`로 클램프한다.
  @Test func setZoomClampsToValidRangeAndSanitizesNonFiniteInput() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 10, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    let fit = min(
      core.layout.fitWidthScale(forViewportWidth: 300), ReaderLayoutMetrics.maxZoomScale
    )

    core.setZoom(0, animated: false)
    #expect(try #require(host.scrollToCalls.last).zoomScale == fit)

    core.setZoom(100, animated: false)
    #expect(try #require(host.scrollToCalls.last).zoomScale == ReaderLayoutMetrics.maxZoomScale)

    core.setZoom(.nan, animated: false)
    #expect(try #require(host.scrollToCalls.last).zoomScale == fit)
  }

  /// 케이스 12: `setZoom`은 뷰포트 상단이 걸친 콘텐츠 지점을 보존한다 — 새 배율에서
  /// 같은 정규화 위치의 콘텐츠 Y로 이동한다.
  @Test func setZoomPreservesViewportTopPosition() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 20, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)

    let midFrame = try #require(core.layout.pageFrame(at: 10))
    host.visibleContentRect = CGRect(x: 0, y: midFrame.minY + 5, width: 300, height: 300)
    let position = try #require(core.capturePosition())

    core.setZoom(2, animated: false)

    let expectedY = core.layout.contentY(for: position)
    let call = try #require(host.scrollToCalls.last)
    #expect(abs(call.contentY - expectedY) < 0.001)
    #expect(call.zoomScale == 2)
  }

  /// 케이스 13: `fitWidth`는 심볼릭하게 유지된다 — 완료 전 뷰포트 폭이 바뀌면 최종
  /// 줌은 새 폭의 fit-width 배율이다.
  @Test func fitWidthReinterpretsAtNewViewportWidthAfterResize() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 10, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)

    core.fitWidth(animated: true) // 완료 통지 없음 — 진행 중.

    host.viewportSize = CGSize(width: 450, height: 300)
    core.hostViewportSizeDidChange()

    let newFit = min(
      core.layout.fitWidthScale(forViewportWidth: 450), ReaderLayoutMetrics.maxZoomScale
    )
    let call = try #require(host.scrollToCalls.last)
    #expect(call.zoomScale == newFit)
    #expect(call.animated == false)
  }

  /// 케이스 14: 병합 규칙 — 이동 진행 중 줌은 그 목표 위치를 앵커로 적용되고
  /// (정방향), 줌 진행 중 이동은 그 목표 줌을 유지한 채 적용된다(역방향, `.keep` 상속).
  @Test func mergeRuleCombinesInFlightDestinationAndZoom() async throws {
    let coreA = try await UITestSupport.makeReaderCore(
      pageCount: 20, pageWidth: 200, pageHeight: 200
    )
    let hostA = MockScrollHost()
    hostA.viewportSize = CGSize(width: 300, height: 300)
    hostA.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    coreA.attach(to: hostA)

    coreA.goToPage(9, animated: true)
    coreA.setZoom(3, animated: true)

    let frame9 = try #require(coreA.layout.pageFrame(at: 9))
    let page9Y = max(0, frame9.minY - ReaderLayoutMetrics.pageSpacing / 2)
    let callA = try #require(hostA.scrollToCalls.last)
    #expect(abs(callA.contentY - page9Y) < 0.001)
    #expect(callA.zoomScale == 3)

    let coreB = try await UITestSupport.makeReaderCore(
      pageCount: 20, pageWidth: 200, pageHeight: 200
    )
    let hostB = MockScrollHost()
    hostB.viewportSize = CGSize(width: 300, height: 300)
    hostB.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    coreB.attach(to: hostB)

    coreB.setZoom(3, animated: true)
    coreB.goToPage(9, animated: true)

    let callB = try #require(hostB.scrollToCalls.last)
    #expect(abs(callB.contentY - page9Y) < 0.001)
    #expect(callB.zoomScale == 3)
  }

  /// 케이스 15: 모델의 `zoomRange`는 미부착 시 `1...1`이고, 부착·뷰포트 크기 변경마다
  /// 코어 상태로부터 갱신된다. 상태가 실제로 바뀌지 않은 재통지는 억제된다.
  @Test func zoomRangePropagatesFromCoreAndSuppressesRedundantNotifications() async throws {
    let model = PapyrusPDFReaderModel()
    #expect(model.zoomRange == 1...1)

    let core = try await UITestSupport.makeReaderCore(
      pageCount: 10, pageWidth: 200, pageHeight: 200
    )
    model.attach(core: core)
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    core.attach(to: host)

    let fit = min(
      core.layout.fitWidthScale(forViewportWidth: 300), ReaderLayoutMetrics.maxZoomScale
    )
    #expect(model.zoomRange == fit...ReaderLayoutMetrics.maxZoomScale)

    host.viewportSize = CGSize(width: 600, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 600, height: 300)
    core.hostViewportSizeDidChange()
    let newFit = min(
      core.layout.fitWidthScale(forViewportWidth: 600), ReaderLayoutMetrics.maxZoomScale
    )
    #expect(model.zoomRange == newFit...ReaderLayoutMetrics.maxZoomScale)

    // 무변화 통지 억제 — 모델 배선은 유지한 채 통지 횟수만 가로채 센다.
    var notifyCount = 0
    let modelHandler = core.onStateChange
    core.onStateChange = { state in
      notifyCount += 1
      modelHandler?(state)
    }
    core.hostViewportDidChange()
    core.hostViewportDidChange()
    #expect(notifyCount == 0) // 상태가 실제로 바뀌지 않았으므로 추가 통지 없음.
  }
}
