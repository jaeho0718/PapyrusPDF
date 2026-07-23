import CoreGraphics
import PapyrusRendering
import PapyrusUI
import QuartzCore
import Testing

/// ``PageLayerController``/``PageLayerPool``을 검증한다 (설계 §6 PLC1-PLC3, POOL1).
@MainActor
struct PageLayerControllerTests {
  // MARK: PLC1 — 레이어 트리 구조

  /// PLC1: configure → setPreview/setTile 레이어 트리 구조(프리뷰 아래·타일 위·
  /// overlayLayer 최상단), tile frame == pointRect.
  @Test func configureThenSetPreviewAndTileOrdersLayersBottomToTop() {
    let controller = PageLayerController()
    let frame = CGRect(x: 0, y: 0, width: 200, height: 300)
    controller.configure(pageIndex: 0, frame: frame)
    controller.activateBucket(ScaleBucket(exponent: 0))

    controller.setPreview(UITestSupport.makePreview(pageIndex: 0))
    let tileRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    let tile = UITestSupport.makeTile(pointRect: tileRect)
    controller.setTile(tile)

    let sublayers = controller.containerLayer.sublayers ?? []
    #expect(sublayers.count == 3)
    #expect(sublayers[0].frame == CGRect(origin: .zero, size: frame.size))
    #expect(sublayers[0].contents != nil)
    #expect(sublayers[1].frame == tile.pointRect)
    #expect(sublayers[2] === controller.overlayLayer)
    #expect(controller.pageIndex == 0)
    #expect(controller.currentBucket == ScaleBucket(exponent: 0))
  }

  // MARK: PLC2 — 버킷 전환·스테일 제거 규칙

  /// PLC2 (a): activateBucket 후 구타일은 스테일로 강등되어 `hasTile`에서 사라진다.
  @Test func activateBucketDemotesCurrentTilesToStale() {
    let controller = PageLayerController()
    controller.configure(pageIndex: 0, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    let bucketA = ScaleBucket(exponent: 0)
    let bucketB = ScaleBucket(exponent: 2)
    controller.activateBucket(bucketA)

    let tileA = UITestSupport.makeTile(
      scaleBucket: bucketA, pointRect: CGRect(x: 0, y: 0, width: 100, height: 100)
    )
    controller.setTile(tileA)
    #expect(controller.hasTile(for: tileA.key))
    let sublayerCountBeforeTransition = controller.containerLayer.sublayers?.count

    controller.activateBucket(bucketB)

    #expect(controller.currentBucket == bucketB)
    #expect(!controller.hasTile(for: tileA.key)) // 강등되어 "현재"에서 사라짐.
    // 강등만으로는 레이어가 제거되지 않는다 (표시 재료 유지, 가정 5).
    #expect(controller.containerLayer.sublayers?.count == sublayerCountBeforeTransition)
  }

  /// PLC2 (b): 신버킷 setTile이 구버킷 스테일을 완전히 덮으면 즉시 제거된다.
  @Test func setTileRemovesFullyCoveredStaleLayer() {
    let controller = PageLayerController()
    controller.configure(pageIndex: 0, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    let bucketA = ScaleBucket(exponent: 0)
    let bucketB = ScaleBucket(exponent: 2)
    let rect = CGRect(x: 0, y: 0, width: 100, height: 100)

    controller.activateBucket(bucketA)
    controller.setTile(UITestSupport.makeTile(scaleBucket: bucketA, pointRect: rect))
    controller.activateBucket(bucketB) // demotes to stale
    let countWithStale = controller.containerLayer.sublayers?.count ?? 0

    // 동일 프레임을 정확히 덮는 신버킷 타일 — 스테일이 완전 포함되어 즉시 제거된다.
    controller.setTile(UITestSupport.makeTile(scaleBucket: bucketB, pointRect: rect))
    let countAfterCoveringTile = controller.containerLayer.sublayers?.count ?? 0

    #expect(countAfterCoveringTile == countWithStale) // 스테일 제거 + 신규 추가로 순증감 없음.
  }

  /// PLC2 (c): `removeStaleTiles()`는 남은 스테일을 전량 제거한다.
  @Test func removeStaleTilesPurgesAllRemainingStaleLayers() {
    let controller = PageLayerController()
    controller.configure(pageIndex: 0, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    let bucketA = ScaleBucket(exponent: 0)
    let bucketB = ScaleBucket(exponent: 2)

    controller.activateBucket(bucketA)
    let firstRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    controller.setTile(UITestSupport.makeTile(scaleBucket: bucketA, pointRect: firstRect))
    controller.activateBucket(bucketB) // 스테일 1개.
    // 신버킷 타일은 스테일과 겹치지 않는 위치(별도 청소 대상 유지).
    let secondRect = CGRect(x: 100, y: 100, width: 50, height: 50)
    controller.setTile(UITestSupport.makeTile(scaleBucket: bucketB, pointRect: secondRect))
    let countBeforeRemoveStale = controller.containerLayer.sublayers?.count ?? 0

    controller.removeStaleTiles()

    let countAfterRemoveStale = controller.containerLayer.sublayers?.count ?? 0
    #expect(countAfterRemoveStale == countBeforeRemoveStale - 1)
  }

  /// PLC2 (d): 구버킷 늦은 도착 타일은 무시된다.
  @Test func lateArrivingOldBucketTileIsIgnored() {
    let controller = PageLayerController()
    controller.configure(pageIndex: 0, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    let bucketA = ScaleBucket(exponent: 0)
    let bucketB = ScaleBucket(exponent: 2)
    controller.activateBucket(bucketA)
    let staleTile = UITestSupport.makeTile(scaleBucket: bucketA, col: 3, row: 3)
    controller.activateBucket(bucketB)

    let countBefore = controller.containerLayer.sublayers?.count ?? 0
    controller.setTile(staleTile) // 이미 지나간 bucketA 타일 — 무시되어야 한다.

    #expect(!controller.hasTile(for: staleTile.key))
    #expect(controller.containerLayer.sublayers?.count == countBefore)
  }

  // MARK: PLC3 — 재사용·스테일 캡

  /// PLC3 (a): `prepareForReuse` 후 contents 전부 nil·pageIndex nil.
  @Test func prepareForReuseClearsContentsAndIdentity() {
    let controller = PageLayerController()
    controller.configure(pageIndex: 2, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    controller.activateBucket(ScaleBucket(exponent: 0))
    controller.setPreview(UITestSupport.makePreview(pageIndex: 2))
    let tileRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    controller.setTile(UITestSupport.makeTile(pointRect: tileRect))

    controller.prepareForReuse()

    #expect(controller.pageIndex == nil)
    #expect(controller.currentBucket == nil)
    let sublayers = controller.containerLayer.sublayers ?? []
    #expect(sublayers.count == 2) // preview + overlay만 남는다 (영구 멤버).
    #expect(sublayers[0].contents == nil)
  }

  /// PLC3 (b): 스테일 수가 `maxStaleTileLayers`를 넘으면 오래된 순으로 제거된다.
  @Test func staleCapEvictsOldestFirst() {
    let controller = PageLayerController()
    controller.configure(pageIndex: 0, frame: CGRect(x: 0, y: 0, width: 10_000, height: 10_000))

    // 버킷 지수 범위(-8...12)가 유한하므로 두 버킷을 번갈아 활성화해 매번
    // "직전과 다른 버킷"이 되도록 한다 (강등이 매 반복 정확히 1건씩 일어나야 한다).
    let bucketZero = ScaleBucket(exponent: 0)
    let bucketTwo = ScaleBucket(exponent: 2)
    var bucket = bucketZero
    controller.activateBucket(bucket)
    let overflow = 5
    let total = ReaderLayoutMetrics.maxStaleTileLayers + overflow
    for index in 1...total {
      let rect = CGRect(x: CGFloat(index) * 10, y: 0, width: 5, height: 5)
      controller.setTile(UITestSupport.makeTile(scaleBucket: bucket, pointRect: rect))
      bucket = (bucket == bucketZero) ? bucketTwo : bucketZero
      controller.activateBucket(bucket) // 직전에 추가한 타일 1개를 스테일로 강등.
    }

    let sublayers = controller.containerLayer.sublayers ?? []
    // preview + overlay(2) + 캡(maxStaleTileLayers).
    #expect(sublayers.count == 2 + ReaderLayoutMetrics.maxStaleTileLayers)
    // 가장 오래된(첫 번째) 강등분은 제거되고, 가장 최근 강등분은 남아 있어야 한다.
    #expect(!sublayers.contains { $0.frame.origin.x == 10 })
    #expect(sublayers.contains { $0.frame.origin.x == CGFloat(total) * 10 })
  }

  // MARK: POOL1 — 재활용 풀

  /// POOL1: acquire/release 재사용 확인, 캡 초과 release 시 폐기, idleCount 관찰.
  @Test func poolReusesReleasedControllersAndDropsBeyondCapacity() {
    let pool = PageLayerPool(capacity: 2)
    #expect(pool.idleCount == 0)

    let first = pool.acquire()
    let second = pool.acquire()
    #expect(pool.idleCount == 0)

    pool.release(first)
    #expect(pool.idleCount == 1)

    let reused = pool.acquire()
    #expect(reused === first) // 유휴에서 재사용.
    #expect(pool.idleCount == 0)

    pool.release(reused)
    pool.release(second)
    #expect(pool.idleCount == 2)

    let discarded = PageLayerController()
    pool.release(discarded) // 캡(2) 초과 — 폐기.
    #expect(pool.idleCount == 2)
  }
}
