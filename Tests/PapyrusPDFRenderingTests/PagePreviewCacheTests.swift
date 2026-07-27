@testable import PapyrusPDFRendering
import Testing

/// ``PagePreviewCache``의 예산 준수·LRU 퇴거·압박 대응을 검증한다 (설계 §5 PC1).
struct PagePreviewCacheTests {
  /// PC1: 예산 내 삽입은 전부 유지된다 (TC1 동형).
  @Test func insertionsWithinBudgetAreAllRetained() {
    let cache = PagePreviewCache(budgetBytes: 1_000)
    cache.insert(RenderTestSupport.makePreview(pageIndex: 0, cost: 300))
    cache.insert(RenderTestSupport.makePreview(pageIndex: 1, cost: 300))
    #expect(cache.count == 2)
    #expect(cache.totalCost == 600)
  }

  /// PC1: 예산 초과 시 LRU 순서로 퇴거된다 (TC1 동형).
  @Test func exceedingBudgetEvictsLeastRecentlyUsedFirst() {
    let cache = PagePreviewCache(budgetBytes: 1_000)
    cache.insert(RenderTestSupport.makePreview(pageIndex: 0, cost: 400))
    cache.insert(RenderTestSupport.makePreview(pageIndex: 1, cost: 400))
    _ = cache.preview(forPage: 0)
    cache.insert(RenderTestSupport.makePreview(pageIndex: 2, cost: 400))

    #expect(cache.preview(forPage: 0) != nil)
    #expect(cache.preview(forPage: 1) == nil)
    #expect(cache.preview(forPage: 2) != nil)
    #expect(cache.totalCost <= cache.currentBudget)
  }

  /// PC1: 단일 항목이 예산을 초과하면 삽입되지 않는다.
  @Test func itemLargerThanBudgetIsNotInserted() {
    let cache = PagePreviewCache(budgetBytes: 500)
    cache.insert(RenderTestSupport.makePreview(pageIndex: 0, cost: 300))
    cache.insert(RenderTestSupport.makePreview(pageIndex: 1, cost: 600))

    #expect(cache.count == 1)
    #expect(cache.preview(forPage: 0) != nil)
  }

  /// PC1: warning은 예산 반감 + 초과분 퇴거만 한다 (TC1/TC2 동형).
  @Test func warningHalvesBudgetAndEvictsExcess() {
    let cache = PagePreviewCache(budgetBytes: 1_000)
    for index in 0..<10 {
      cache.insert(RenderTestSupport.makePreview(pageIndex: index, cost: 90))
    }
    cache.handleMemoryPressure(.warning)

    #expect(cache.currentBudget == 500)
    #expect(cache.totalCost <= cache.currentBudget)
    #expect(cache.count > 0)
  }

  /// PC1 핵심: critical에서도 전량 퍼지하지 않는다 — 예산 반감(바닥 구성/4) + 퇴거만.
  @Test func criticalHalvesBudgetButDoesNotPurgeEverything() {
    let cache = PagePreviewCache(budgetBytes: 1_000)
    for index in 0..<5 {
      cache.insert(RenderTestSupport.makePreview(pageIndex: index, cost: 50))
    }
    let beforeCount = cache.count

    cache.handleMemoryPressure(.critical)

    #expect(cache.currentBudget == 500)
    #expect(cache.totalCost <= cache.currentBudget)
    #expect(cache.count > 0)
    #expect(cache.count <= beforeCount)
  }

  /// PC1: critical 반복은 바닥(구성/4) 밑으로 내려가지 않는다.
  @Test func repeatedCriticalFloorsAtQuarterOfConfiguredBudget() {
    let cache = PagePreviewCache(budgetBytes: 1_000)
    cache.handleMemoryPressure(.critical)
    cache.handleMemoryPressure(.critical)
    cache.handleMemoryPressure(.critical)
    cache.handleMemoryPressure(.critical)

    #expect(cache.currentBudget == 250)
  }

  /// PC1: normal은 유효 예산을 구성값으로 복원한다.
  @Test func normalRestoresConfiguredBudget() {
    let cache = PagePreviewCache(budgetBytes: 1_000)
    cache.handleMemoryPressure(.critical)
    cache.handleMemoryPressure(.normal)

    #expect(cache.currentBudget == 1_000)
  }

  /// `removeAll()`은 전량 퍼지한다.
  @Test func removeAllPurgesEverything() {
    let cache = PagePreviewCache(budgetBytes: 10_000)
    cache.insert(RenderTestSupport.makePreview(pageIndex: 0, cost: 100))
    cache.removeAll()

    #expect(cache.count == 0)
    #expect(cache.totalCost == 0)
  }
}
