import CoreGraphics
import Foundation
@testable import PapyrusCore
@testable import PapyrusRendering
import PapyrusTestSupport
import Testing

/// ``TileRenderQueue``의 dedupe·취소·뷰포트·메모리 상한을 검증한다 (설계 §5 TQ1-TQ6).
///
/// 실제 CG 렌더를 쓰되 판정은 카운터·캐시 상태로만 한다 — 타이밍 단정은 하지 않는다
/// (설계 §5 주의). 뷰포트·경합 시나리오는 폴링 대기로 정착을 확인한다.
struct TileRenderQueueTests {
  /// 지정한 페이지 수·크기의 균일 문서로 큐를 조립한다 (메모리 압박 모니터는 항상 끈다 —
  /// 테스트는 `tileCache.handleMemoryPressure`를 직접 호출한다).
  private static func makeQueue(
    pageCount: Int, pageWidth: Double = 612, pageHeight: Double = 792,
    workerCount: Int = 2, pixelScale: CGFloat = 1,
    tileBudgetBytes: Int = RenderingLimits.defaultTileBudgetBytes,
    previewBudgetBytes: Int = RenderingLimits.defaultPreviewBudgetBytes
  ) async throws -> TileRenderQueue {
    let fixture = PDFFixtureBuilder(
      pageCount: pageCount, pageWidth: pageWidth, pageHeight: pageHeight
    ).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let pageSizes = try await document.pageTree().records.map(\.displaySize)
    let configuration = RenderConfiguration(
      workerCount: workerCount, pixelScale: pixelScale, tileBudgetBytes: tileBudgetBytes,
      previewBudgetBytes: previewBudgetBytes, installsMemoryPressureMonitor: false
    )
    return TileRenderQueue(
      documentData: document.sourceBytes, pageSizes: pageSizes, configuration: configuration
    )
  }

  /// 조건이 참이 될 때까지 짧게 폴링한다 (뷰포트·경합 정착 대기 — 타이밍 단정 아님).
  private static func waitUntil(
    timeoutSeconds: Double = 5, _ condition: () async -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    while !(await condition()) {
      if ContinuousClock.now > deadline {
        Issue.record("polling condition did not settle within timeout")
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  // MARK: TQ1 — dedupe

  /// TQ1: 같은 키 동시 5요청 → 전원 동일 결과, 렌더는 1회만, 나머지 4개는 병합.
  @Test func concurrentRequestsForSameKeyDedupeToOneRender() async throws {
    let queue = try await Self.makeQueue(pageCount: 1, workerCount: 2)
    let key = TileKey(pageIndex: 0, scaleBucket: ScaleBucket(exponent: 0), col: 0, row: 0)

    let results = try await withThrowingTaskGroup(of: RenderedTile.self) { group in
      for _ in 0..<5 {
        group.addTask { try await queue.tile(for: key) }
      }
      var collected: [RenderedTile] = []
      for try await tile in group {
        collected.append(tile)
      }
      return collected
    }

    #expect(results.count == 5)
    #expect(results.allSatisfy { $0.key == key })

    let stats = await queue.statistics()
    #expect(stats.tileRenderCount == 1)
    #expect(stats.joinedRequestCount == 4)
  }

  // MARK: TQ2 — 캐시 히트

  /// TQ2: 재요청 시 렌더 카운트는 늘지 않고, nonisolated 캐시 직조회도 비-nil이다.
  @Test func repeatedRequestAfterCacheFillDoesNotRerender() async throws {
    let queue = try await Self.makeQueue(pageCount: 1, workerCount: 2)
    let key = TileKey(pageIndex: 0, scaleBucket: ScaleBucket(exponent: 0), col: 0, row: 0)

    _ = try await queue.tile(for: key)
    let statsAfterFirst = await queue.statistics()
    #expect(statsAfterFirst.tileRenderCount == 1)

    let cached = try await queue.tile(for: key)
    #expect(cached.key == key)
    let statsAfterSecond = await queue.statistics()
    #expect(statsAfterSecond.tileRenderCount == 1)

    #expect(queue.tileCache.tile(for: key) != nil)
  }

  // MARK: TQ3 — 취소

  /// TQ3: workerCount 1 — 워커가 점유된 동안 아직 시작되지 않은 요청의 태스크를
  /// 취소하면 `.cancelled`가 던져지고 `droppedBeforeStartCount`가 늘며, 이미 대기
  /// 중이던 다른 요청들은 정상적으로 계속 렌더된다.
  ///
  /// 정확한 타이밍을 단정하지 않기 위해(설계 §5 주의) 두 가지를 조합한다:
  /// (1) 워커 1개로 처리할 수 없을 만큼 큰 대기 백로그(조밀 스케일 버킷의 타일 100개)를
  /// 먼저 만들어 둔다 — 취소 대상 키는 그 백로그의 맨 끝이라, 취소를 거는 시점이 아무리
  /// 늦어도 "이미 렌더까지 끝나버렸을" 여지가 없다. (2) 등재 자체가 취소보다 늦게
  /// 일어나는 경합(요청 태스크가 아직 액터에 진입하기 전에 `cancel()`이 도착하는 경우)은
  /// `registerWaiter`가 진입 시점에 `Task.isCancelled`를 직접 확인해 흡수하므로(구현 수정),
  /// 등재 완료를 기다리는 별도 동기화 없이 생성 직후 곧바로 취소해도 결정적이다.
  @Test func cancellingBacklogTailWhileWorkerBusyDropsItBeforeStart() async throws {
    let queue = try await Self.makeQueue(
      pageCount: 1, pageWidth: 600, pageHeight: 600, workerCount: 1, pixelScale: 8
    )
    let denseBucket = ScaleBucket(exponent: 6) // tileSideInPoints 64pt → 600pt 페이지에 10×10 타일
    let grid = TileGrid(pageSize: CGSize(width: 600, height: 600), scaleBucket: denseBucket)
    #expect(grid.columns * grid.rows >= 64) // 대기열이 충분히 크다는 전제 확인.
    let tailKey = TileKey(
      pageIndex: 0, scaleBucket: denseBucket, col: grid.columns - 1, row: grid.rows - 1
    )

    await queue.updateViewport(RenderViewport(
      pages: [RenderViewport.PageViewport(
        pageIndex: 0, visibleRect: CGRect(x: 0, y: 0, width: 600, height: 600)
      )],
      scaleBucket: denseBucket, viewportSize: CGSize(width: 600, height: 600)
    ))

    // 등재 완료를 기다리지 않고 생성 직후 곧바로 취소한다 — 등재보다 취소가 먼저
    // 도착해도 registerWaiter의 Task.isCancelled 확인이 이를 올바르게 흡수한다.
    let tailTask = Task { try await queue.tile(for: tailKey) }
    tailTask.cancel()

    var sawCancelled = false
    do {
      _ = try await tailTask.value
    } catch let error as RenderError {
      sawCancelled = (error == .cancelled)
    }
    #expect(sawCancelled)

    let stats = await queue.statistics()
    #expect(stats.droppedBeforeStartCount >= 1)

    // 취소되지 않은 나머지 백로그는 계속 정상적으로 렌더된다.
    try await Self.waitUntil {
      (await queue.statistics()).tileRenderCount > 0
    }
  }

  // MARK: TQ4 — 뷰포트·프리페치·폐기

  /// TQ4: `updateViewport` 정착 후 가시·프리페치 타일과 visible ±3 프리뷰가 캐시에 존재한다.
  /// 이어서 다른 곳으로 재갱신하면 미시작 프리페치 폐기 카운트가 증가한다.
  @Test func viewportUpdateSettlesPrefetchThenDropsOnReTarget() async throws {
    // 워커 1개 + 촘촘한 스케일 버킷으로 백로그를 만들어, 두 번째 갱신 전에 첫 갱신이
    // 전부 소진되지 않도록 한다.
    let pageCount = 20
    let queue = try await Self.makeQueue(
      pageCount: pageCount, pageWidth: 600, pageHeight: 600, workerCount: 1
    )
    let denseBucket = ScaleBucket(exponent: 6) // tileSideInPoints 64pt → 600pt page에 10×10 타일
    let visiblePage = 10
    let firstViewport = RenderViewport(
      pages: [
        RenderViewport.PageViewport(
          pageIndex: visiblePage, visibleRect: CGRect(x: 0, y: 0, width: 600, height: 600)
        )
      ],
      scaleBucket: denseBucket, viewportSize: CGSize(width: 600, height: 600)
    )
    await queue.updateViewport(firstViewport)

    // 첫 갱신이 아직 배수 진행 중일 때 완전히 다른 페이지로 재갱신한다.
    let secondViewport = RenderViewport(
      pages: [
        RenderViewport.PageViewport(
          pageIndex: 0, visibleRect: CGRect(x: 0, y: 0, width: 600, height: 600)
        )
      ],
      scaleBucket: ScaleBucket(exponent: 0), viewportSize: CGSize(width: 600, height: 600)
    )
    await queue.updateViewport(secondViewport)

    let statsAfterRetarget = await queue.statistics()
    #expect(statsAfterRetarget.droppedBeforeStartCount > 0)

    // 두 번째 뷰포트가 정착할 때까지 폴링 대기 — 가시 타일과 프리뷰가 캐시에 들어온다.
    let visibleKeyForSecond = TileKey(
      pageIndex: 0, scaleBucket: ScaleBucket(exponent: 0), col: 0, row: 0
    )
    try await Self.waitUntil {
      queue.tileCache.tile(for: visibleKeyForSecond) != nil
        && queue.previewCache.preview(forPage: 0) != nil
    }

    // ±3 프리페치 프리뷰 확인 (페이지 0 기준이므로 0...3만 유효 범위).
    for pageIndex in 0...3 {
      try await Self.waitUntil {
        queue.previewCache.preview(forPage: pageIndex) != nil
      }
    }
  }

  // MARK: TQ5 — 메모리 상한 게이트 (완료 기준)

  /// TQ5: 소예산 구성에서 매 렌더 완료 후 `tileCacheBytes ≤ 예산`이 상시 성립하고,
  /// critical 주입 후 `tileCacheCount == 0`이 된다.
  @Test func tileCacheStaysWithinBudgetAndPurgesOnCritical() async throws {
    let budget = 4 << 20 // 4MB
    let queue = try await Self.makeQueue(
      pageCount: 1, pageWidth: 512 * 20, pageHeight: 512, workerCount: 2,
      tileBudgetBytes: budget
    )

    for col in 0..<20 {
      let key = TileKey(pageIndex: 0, scaleBucket: ScaleBucket(exponent: 0), col: col, row: 0)
      _ = try await queue.tile(for: key)
      let stats = await queue.statistics()
      #expect(stats.tileCacheBytes <= budget)
    }

    queue.tileCache.handleMemoryPressure(.critical)
    let statsAfterCritical = await queue.statistics()
    #expect(statsAfterCritical.tileCacheCount == 0)
  }

  // MARK: TQ6 — make(for:)

  /// TQ6: `make(for:)`로 조립한 큐는 회전 페이지를 포함해 파서 표시 크기를 그대로 쓴다.
  @Test func makeForDocumentCapturesRotatedPageSizes() async throws {
    let unrotated = PDFFixtureBuilder.PageTreeSpec.NodeAttributes(mediaBox: .init(0, 0, 612, 792))
    let rotated = PDFFixtureBuilder.PageTreeSpec.NodeAttributes(
      mediaBox: .init(0, 0, 612, 792), rotate: 90
    )
    let spec = PDFFixtureBuilder.PageTreeSpec(root: .pages(attributes: .init(), kids: [
      .page(attributes: unrotated), .page(attributes: rotated)
    ]))
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    let document = try await PapyrusDocument.open(data: fixture.data)

    let queue = try await TileRenderQueue.make(
      for: document,
      configuration: RenderConfiguration(
        workerCount: 2, pixelScale: 1, installsMemoryPressureMonitor: false
      )
    )

    // exp -2(scale 0.5)는 tileSideInPoints 1024pt — 612×792 페이지를 한 타일로 덮는다.
    let scaleBucket = ScaleBucket(exponent: -2)
    let tile0 = try await queue.tile(
      for: TileKey(pageIndex: 0, scaleBucket: scaleBucket, col: 0, row: 0)
    )
    let tile1 = try await queue.tile(
      for: TileKey(pageIndex: 1, scaleBucket: scaleBucket, col: 0, row: 0)
    )

    // 페이지 1은 /Rotate 90 — displaySize가 교환되어 타일 픽셀 크기의 가로·세로가 뒤집힌다.
    #expect(tile0.image.width != tile0.image.height)
    #expect(tile0.image.width == tile1.image.height)
    #expect(tile0.image.height == tile1.image.width)
  }
}
