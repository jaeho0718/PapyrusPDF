import CoreGraphics
@testable import PapyrusPDFUI
import Testing

/// 이슈 #19(호스트 부착 전 명령 유실)의 수정을 검증한다 — 설계
/// `_workspace/36_architect_reader-readiness-zoom.md` §5, 케이스 1~5, 10.
///
/// 재생 게이트가 "코어 연결"에서 "코어 연결 ∧ 호스트 부착"으로 옮겨졌으므로, 모델에
/// 접수된 이동 명령은 `core.attach(to:)`가 실제로 호출될 때까지 보류돼야 한다.
@MainActor
struct ReaderReadinessTests {
  /// 케이스 1: 코어 연결·호스트 미부착 시 보류. 모델에 `goToPage(11)` 접수 →
  /// `attach(core:)`(호스트 없음) → 호스트가 나중에 부착되면 그때야 재생된다.
  @Test func pendingNavigationSurvivesCoreAttachAndReplaysOnHostAttach() async throws {
    let model = PapyrusPDFReaderModel()
    model.goToPage(11, animated: true)

    let core = try await UITestSupport.makeReaderCore(
      pageCount: 20, pageWidth: 200, pageHeight: 200
    )
    model.attach(core: core) // 코어는 연결됐지만 호스트는 아직 없다.
    #expect(model.loadState == .ready)
    #expect(core.isHostAttached == false)

    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    core.attach(to: host) // 이 시점에야 보류 명령이 재생된다.

    let frame = try #require(core.layout.pageFrame(at: 11))
    let expectedY = max(0, frame.minY - ReaderLayoutMetrics.pageSpacing / 2)
    let call = try #require(host.scrollToCalls.last)
    #expect(abs(call.contentY - expectedY) < 0.001)
    #expect(call.animated == false) // 가정 1 — 재생은 항상 무애니메이션.
  }

  /// 케이스 2: 초기 스크롤 대체. 보류 명령이 없으면 attach가 `(0, fit)` 초기 스크롤을
  /// 1회 기록하고, 보류 명령이 있으면 그 초기 스크롤 대신 목표 스크롤만 기록된다.
  @Test func initialFitScrollIsReplacedByReplayedPendingCommand() async throws {
    let coreWithoutPending = try await UITestSupport.makeReaderCore(
      pageCount: 10, pageWidth: 200, pageHeight: 200
    )
    let hostWithoutPending = MockScrollHost()
    hostWithoutPending.viewportSize = CGSize(width: 300, height: 300)
    coreWithoutPending.attach(to: hostWithoutPending)

    let fit = min(
      coreWithoutPending.layout.fitWidthScale(forViewportWidth: 300),
      ReaderLayoutMetrics.maxZoomScale
    )
    #expect(hostWithoutPending.scrollToCalls.count == 1)
    let initialCall = try #require(hostWithoutPending.scrollToCalls.first)
    #expect(initialCall.contentY == 0)
    #expect(initialCall.zoomScale == fit)
    #expect(initialCall.animated == false)

    let model = PapyrusPDFReaderModel()
    model.goToPage(5, animated: true)
    let coreWithPending = try await UITestSupport.makeReaderCore(
      pageCount: 10, pageWidth: 200, pageHeight: 200
    )
    model.attach(core: coreWithPending)
    let hostWithPending = MockScrollHost()
    hostWithPending.viewportSize = CGSize(width: 300, height: 300)
    coreWithPending.attach(to: hostWithPending)

    // 초기 (0, fit) 스크롤은 기록되지 않고, 목표 스크롤 1건만 기록된다.
    #expect(hostWithPending.scrollToCalls.count == 1)
    let frame = try #require(coreWithPending.layout.pageFrame(at: 5))
    let expectedY = max(0, frame.minY - ReaderLayoutMetrics.pageSpacing / 2)
    let replayedCall = try #require(hostWithPending.scrollToCalls.first)
    #expect(abs(replayedCall.contentY - expectedY) < 0.001)
    #expect(replayedCall.contentY != 0)
  }

  /// 케이스 3: 재생 순서 — 이동 뒤 줌. pre-attach에 `restore(p)`와 `fitWidth()`가
  /// 별도 슬롯(탐색·줌)으로 접수되면, 부착 시 이동이 먼저·줌이 나중에 재생되어 최종
  /// 줌은 fit이지만 Y는 `p`의 정규화 위치 기준으로 유지된다.
  @Test func replayOrderAppliesNavigationBeforeZoomAndPreservesPosition() async throws {
    let model = PapyrusPDFReaderModel()
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 10, pageWidth: 200, pageHeight: 200
    )
    let position = ReaderPosition(pageIndex: 4, normalizedOffset: 0.5, zoomScale: 3)

    model.restore(position) // 탐색 슬롯.
    model.fitWidth() // 줌 슬롯 — 탐색 슬롯을 밀어내지 않는다.
    model.attach(core: core)

    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    // 실제 호스트(UIScrollView 등)는 애니메이션 없는 `scrollTo` 직후 콘텐츠 오프셋을
    // 동기로 반영한다 — `fitWidth`의 `.current` 폴백이 이동 재생 직후의 위치를 그대로
    // 포착하는 것을 재현하기 위해 목 호스트를 미리 그 위치로 둔다.
    host.visibleContentRect = CGRect(
      x: 0, y: core.layout.contentY(for: position), width: 300, height: 300
    )

    core.attach(to: host)

    #expect(host.scrollToCalls.count == 2) // 이동 1회 + 줌 1회.
    #expect(host.scrollToCalls.allSatisfy { $0.animated == false })

    let fit = min(
      core.layout.fitWidthScale(forViewportWidth: 300), ReaderLayoutMetrics.maxZoomScale
    )
    let finalCall = try #require(host.scrollToCalls.last)
    #expect(finalCall.zoomScale == fit)
    let expectedY = core.layout.contentY(for: position)
    #expect(abs(finalCall.contentY - expectedY) < 0.001)
  }

  /// 케이스 4: 최신 것만 유지. 연결 전 `goToPage`가 여러 번 접수되면 마지막 것만
  /// 재생된다 (기존 `PendingReaderCommand` 정책 그대로 승계).
  @Test func onlyTheLatestPendingCommandReplays() async throws {
    let model = PapyrusPDFReaderModel()
    model.goToPage(3, animated: true)
    model.goToPage(7, animated: true)

    let core = try await UITestSupport.makeReaderCore(
      pageCount: 10, pageWidth: 200, pageHeight: 200
    )
    model.attach(core: core)
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    core.attach(to: host)

    #expect(host.scrollToCalls.count == 1)
    let frame = try #require(core.layout.pageFrame(at: 7))
    let expectedY = max(0, frame.minY - ReaderLayoutMetrics.pageSpacing / 2)
    let call = try #require(host.scrollToCalls.last)
    #expect(abs(call.contentY - expectedY) < 0.001)
  }

  /// 케이스 5: 호스트 재부착 생존. 부착된 코어의 호스트가 분리된 뒤 접수된 명령은
  /// 모델 게이트에 보류됐다가, 같은 코어에 새 호스트가 부착되면 재생된다 — 화면에서
  /// 사라진 뷰어가 재표시될 때의 시나리오.
  @Test func pendingCommandReplaysAfterHostReattachment() async throws {
    let model = PapyrusPDFReaderModel()
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 10, pageWidth: 200, pageHeight: 200
    )
    model.attach(core: core)

    let firstHost = MockScrollHost()
    firstHost.viewportSize = CGSize(width: 300, height: 300)
    core.attach(to: firstHost)
    core.detach()
    #expect(core.isHostAttached == false)

    model.goToPage(5, animated: true) // 모델 게이트가 보류 — 코어는 있지만 호스트가 없다.

    let secondHost = MockScrollHost()
    secondHost.viewportSize = CGSize(width: 300, height: 300)
    core.attach(to: secondHost)

    let frame = try #require(core.layout.pageFrame(at: 5))
    let expectedY = max(0, frame.minY - ReaderLayoutMetrics.pageSpacing / 2)
    let call = try #require(secondHost.scrollToCalls.last)
    #expect(abs(call.contentY - expectedY) < 0.001)
  }

  /// 케이스 10: 동기 완료 재진입 (macOS 계약). `scrollTo` 안에서 즉시
  /// `hostScrollAnimationDidEnd()`를 호출하는 목 변형으로도 인플라이트 래치가 잔존하지
  /// 않는다 — `perform`이 래치를 `scrollTo` 호출 *이전*에 확정하는 순서의 회귀 가드.
  @Test func synchronousAnimationCompletionDuringScrollToLeavesNoStaleLatch() async throws {
    let core = try await UITestSupport.makeReaderCore(
      pageCount: 10, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)

    var synchronousCompletionCount = 0
    host.synchronousAnimationCompletion = { [weak core] in
      synchronousCompletionCount += 1
      core?.hostScrollAnimationDidEnd()
    }

    core.goToPage(9, animated: true)

    #expect(synchronousCompletionCount == 1)
    #expect(core.inFlightNavigation == nil)

    // 래치가 잔존했다면, 이어지는 리사이즈가 9쪽 상단으로 재점프했을 것이다. 잔존이
    // 없으므로 대신 (변경되지 않은) 현재 위치 포착 경로로 떨어진다.
    host.scrollToCalls.removeAll()
    host.viewportSize = CGSize(width: 250, height: 300)
    core.hostViewportSizeDidChange()
    let frame9 = try #require(core.layout.pageFrame(at: 9))
    let page9Y = max(0, frame9.minY - ReaderLayoutMetrics.pageSpacing / 2)
    let resizeCall = try #require(host.scrollToCalls.last)
    #expect(abs(resizeCall.contentY - page9Y) > 0.001)
  }
}
