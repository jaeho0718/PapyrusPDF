@testable import PapyrusRendering
import Testing

/// ``TileCache``의 예산 준수·LRU 퇴거·압박 대응을 검증한다 (설계 §5 TC1, TC2).
struct TileCacheTests {
  /// TC1: 예산 내 삽입은 전부 유지되고 `totalCost`가 정확하다.
  @Test func insertionsWithinBudgetAreAllRetained() {
    let cache = TileCache(budgetBytes: 1_000)
    cache.insert(RenderTestSupport.makeTile(col: 0, cost: 300))
    cache.insert(RenderTestSupport.makeTile(col: 1, cost: 300))
    #expect(cache.count == 2)
    #expect(cache.totalCost == 600)
    #expect(cache.totalCost <= cache.currentBudget)
  }

  /// TC1: 예산 초과 시 가장 오래전에 접근된 항목부터 퇴거된다.
  @Test func exceedingBudgetEvictsLeastRecentlyUsedFirst() {
    let cache = TileCache(budgetBytes: 1_000)
    let first = RenderTestSupport.makeTile(col: 0, cost: 400)
    let second = RenderTestSupport.makeTile(col: 1, cost: 400)
    cache.insert(first)
    cache.insert(second)
    // first를 touch해 second보다 최근으로 만든다.
    _ = cache.tile(for: first.key)
    // 예산을 초과시키는 세 번째 삽입 — LRU인 second가 퇴거되어야 한다.
    let third = RenderTestSupport.makeTile(col: 2, cost: 400)
    cache.insert(third)

    #expect(cache.tile(for: first.key) != nil)
    #expect(cache.tile(for: second.key) == nil)
    #expect(cache.tile(for: third.key) != nil)
    #expect(cache.totalCost <= cache.currentBudget)
  }

  /// TC1: touch(조회)가 LRU 순서를 갱신한다.
  @Test func lookupTouchesUpdateEvictionOrder() {
    let cache = TileCache(budgetBytes: 900)
    let first = RenderTestSupport.makeTile(col: 0, cost: 300)
    let second = RenderTestSupport.makeTile(col: 1, cost: 300)
    let third = RenderTestSupport.makeTile(col: 2, cost: 300)
    cache.insert(first)
    cache.insert(second)
    cache.insert(third)
    // first를 touch — 이제 second가 가장 오래됨.
    _ = cache.tile(for: first.key)

    let fourth = RenderTestSupport.makeTile(col: 3, cost: 300)
    cache.insert(fourth)

    #expect(cache.tile(for: second.key) == nil)
    #expect(cache.tile(for: first.key) != nil)
    #expect(cache.tile(for: third.key) != nil)
    #expect(cache.tile(for: fourth.key) != nil)
  }

  /// TC1: 단일 항목이 예산을 초과하면 삽입되지 않는다 (기존 캐시 상태는 불변).
  @Test func itemLargerThanBudgetIsNotInserted() {
    let cache = TileCache(budgetBytes: 500)
    let existing = RenderTestSupport.makeTile(col: 0, cost: 300)
    cache.insert(existing)
    cache.insert(RenderTestSupport.makeTile(col: 1, cost: 600))

    #expect(cache.count == 1)
    #expect(cache.tile(for: existing.key) != nil)
    #expect(cache.totalCost <= cache.currentBudget)
  }

  /// TC1: `totalCost ≤ currentBudget` 불변식이 임의 삽입 시퀀스에서 상시 성립한다.
  @Test func totalCostNeverExceedsCurrentBudgetAcrossManyInsertions() {
    let cache = TileCache(budgetBytes: 1_000)
    for index in 0..<50 {
      cache.insert(RenderTestSupport.makeTile(col: index, cost: 97))
      #expect(cache.totalCost <= cache.currentBudget)
    }
  }

  /// TC2: warning은 유효 예산을 반감하고 초과분을 퇴거한다.
  @Test func warningHalvesBudgetAndEvictsExcess() {
    let cache = TileCache(budgetBytes: 1_000)
    for index in 0..<10 {
      cache.insert(RenderTestSupport.makeTile(col: index, cost: 90))
    }
    #expect(cache.totalCost <= 1_000)

    cache.handleMemoryPressure(.warning)

    #expect(cache.currentBudget == 500)
    #expect(cache.totalCost <= cache.currentBudget)
  }

  /// TC2: 연속 warning은 바닥(구성 예산의 1/4) 밑으로 내려가지 않는다.
  @Test func repeatedWarningFloorsAtQuarterOfConfiguredBudget() {
    let cache = TileCache(budgetBytes: 1_000)
    cache.handleMemoryPressure(.warning)
    cache.handleMemoryPressure(.warning)
    cache.handleMemoryPressure(.warning)
    cache.handleMemoryPressure(.warning)

    #expect(cache.currentBudget == 250)
  }

  /// TC2: critical은 타일을 전량 퍼지하고 예산은 구성값의 1/4로 남는다.
  @Test func criticalPurgesAllTilesAndFloorsBudget() {
    let cache = TileCache(budgetBytes: 1_000)
    for index in 0..<5 {
      cache.insert(RenderTestSupport.makeTile(col: index, cost: 100))
    }
    #expect(cache.count > 0)

    cache.handleMemoryPressure(.critical)

    #expect(cache.count == 0)
    #expect(cache.totalCost == 0)
    #expect(cache.currentBudget == 250)
  }

  /// TC2: normal은 유효 예산을 구성값으로 복원한다.
  @Test func normalRestoresConfiguredBudget() {
    let cache = TileCache(budgetBytes: 1_000)
    cache.handleMemoryPressure(.critical)
    #expect(cache.currentBudget == 250)

    cache.handleMemoryPressure(.normal)

    #expect(cache.currentBudget == 1_000)
  }

  /// `removeTiles(forPage:)`가 해당 페이지 타일만 제거한다 (M6 확장 심 검증).
  @Test func removeTilesForPageOnlyAffectsThatPage() {
    let cache = TileCache(budgetBytes: 10_000)
    let pageZeroTile = RenderTestSupport.makeTile(pageIndex: 0, col: 0, cost: 100)
    let pageOneTile = RenderTestSupport.makeTile(pageIndex: 1, col: 0, cost: 100)
    cache.insert(pageZeroTile)
    cache.insert(pageOneTile)

    cache.removeTiles(forPage: 0)

    #expect(cache.tile(for: pageZeroTile.key) == nil)
    #expect(cache.tile(for: pageOneTile.key) != nil)
  }

  /// `removeAll()`은 전량 퍼지한다.
  @Test func removeAllPurgesEverything() {
    let cache = TileCache(budgetBytes: 10_000)
    cache.insert(RenderTestSupport.makeTile(col: 0, cost: 100))
    cache.insert(RenderTestSupport.makeTile(col: 1, cost: 100))

    cache.removeAll()

    #expect(cache.count == 0)
    #expect(cache.totalCost == 0)
  }
}
