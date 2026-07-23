import Synchronization

/// 메모리 압박 수준 (`MemoryPressureMonitor`와 캐시가 공유하는 어휘).
package enum MemoryPressureLevel: Sendable, Equatable {
  /// 압박 해소 — 예산을 구성값으로 복원한다.
  case normal
  /// 경고 — 예산 반감 (연속 경고 시 바닥은 구성 예산의 1/4).
  case warning
  /// 위험 — 타일 전량 퍼지 (프리뷰는 반감만 — ``PagePreviewCache`` 참조).
  case critical
}

/// 비용 예산 tick-LRU 저장소. `Mutex`가 보호하는 상태 내부 전용이라 자체 잠금은
/// 두지 않는다 (`PapyrusCore.LRUCache`와 알고리즘은 동형이나 잠금 모델이 다르다 —
/// M5 설계 §2.6 근거).
struct CostBoundLRUStorage<Key: Hashable, Value> {
  /// 저장 항목 (값 + 비용 + 마지막 접근 tick).
  private struct Entry {
    var value: Value
    var cost: Int
    var tick: Int
  }

  /// 키 → 항목.
  private var storage: [Key: Entry] = [:]

  /// 다음에 부여할 tick (단조 증가).
  private var nextTick = 0

  /// 현재 적재 비용 합.
  private(set) var totalCost = 0

  /// 적재 항목 수.
  var count: Int {
    self.storage.count
  }

  /// 조회 (LRU touch 포함). 없으면 `nil`.
  mutating func value(for key: Key) -> Value? {
    guard var entry = self.storage[key] else {
      return nil
    }
    entry.tick = self.nextTick
    self.nextTick += 1
    self.storage[key] = entry
    return entry.value
  }

  /// 삽입한다. 예산 초과분은 LRU 순서로 퇴거한다. 단일 항목이 예산을 초과하면
  /// 캐시에 넣지 않고 그대로 버린다.
  mutating func insert(_ value: Value, cost: Int, for key: Key, budget: Int) {
    guard cost <= budget else {
      return
    }
    if let existing = self.storage[key] {
      self.totalCost -= existing.cost
    }
    while self.totalCost + cost > budget, !self.storage.isEmpty {
      self.evictLeastRecentlyUsed()
    }
    self.storage[key] = Entry(value: value, cost: cost, tick: self.nextTick)
    self.nextTick += 1
    self.totalCost += cost
  }

  /// 현재 예산을 초과하는 항목을 LRU 순서로 퇴거한다 (압박 반감 후 정리용).
  mutating func evictExcess(budget: Int) {
    while self.totalCost > budget, !self.storage.isEmpty {
      self.evictLeastRecentlyUsed()
    }
  }

  /// 술어를 만족하는 항목을 전부 제거한다.
  mutating func remove(where predicate: (Key) -> Bool) {
    let keysToRemove = self.storage.keys.filter(predicate)
    for key in keysToRemove {
      if let removed = self.storage.removeValue(forKey: key) {
        self.totalCost -= removed.cost
      }
    }
  }

  /// 모든 항목을 제거한다.
  mutating func removeAll() {
    self.storage.removeAll()
    self.totalCost = 0
  }

  /// 가장 오래전에 접근된 항목 하나를 제거한다.
  private mutating func evictLeastRecentlyUsed() {
    guard let leastRecentKey = self.storage.min(by: { $0.value.tick < $1.value.tick })?.key else {
      return
    }
    if let removed = self.storage.removeValue(forKey: leastRecentKey) {
      self.totalCost -= removed.cost
    }
  }
}

/// 타일 바이트 비용 LRU. `Mutex` 기반 Sendable — 렌더 완료(액터 태스크)와 M6의
/// 동기 조회(레이어 표시 경로, await 불가)가 잠금 하나로 만난다.
///
/// `PapyrusCore`의 internal `LRUCache`를 재사용하지 않는 이유: 그것은 "액터 격리 하
/// 전용·잠금 없음" 계약의 비-Sendable 타입이고 타 모듈에 비공개다. 여기서는 잠금
/// 모델 자체가 다르다 (내부에 동형의 tick 기반 LRU를 별도 구현 — O(n) 퇴거,
/// n ≈ 예산/타일비용 ≈ 수십~수백이라 충분).
package final class TileCache: Sendable {
  /// 잠금이 보호하는 캐시 상태.
  private struct State {
    var storage = CostBoundLRUStorage<TileKey, RenderedTile>()
    let configuredBudget: Int
    var effectiveBudget: Int
  }

  /// 상태 잠금.
  private let state: Mutex<State>

  /// 캐시를 만든다.
  /// - Parameter budgetBytes: 바이트 예산 (기본 `RenderingLimits.defaultTileBudgetBytes`).
  package init(budgetBytes: Int) {
    self.state = Mutex(State(configuredBudget: budgetBytes, effectiveBudget: budgetBytes))
  }

  /// 조회 (LRU touch). 동기 — M6 표시 경로에서 직접 호출 가능.
  /// - Parameter key: 조회할 타일 키.
  /// - Returns: 캐시된 타일, 없으면 `nil`.
  package func tile(for key: TileKey) -> RenderedTile? {
    self.state.withLock { $0.storage.value(for: key) }
  }

  /// 삽입. 예산 초과분은 LRU 퇴거. 단일 항목이 예산 초과면 넣지 않고 버린다
  /// (호출자는 반환값으로 이미 사용 중 — M2 ObjectStreamCache와 동일 규칙).
  /// - Parameter tile: 저장할 타일.
  package func insert(_ tile: RenderedTile) {
    self.state.withLock { state in
      state.storage.insert(tile, cost: tile.cost, for: tile.key, budget: state.effectiveBudget)
    }
  }

  /// 특정 페이지의 타일 전부 제거 (M6 확장 심 — v1 내부 소비 없음, 테스트만).
  /// - Parameter pageIndex: 제거할 페이지 인덱스.
  package func removeTiles(forPage pageIndex: Int) {
    self.state.withLock { state in
      state.storage.remove { $0.pageIndex == pageIndex }
    }
  }

  /// 전량 퍼지.
  package func removeAll() {
    self.state.withLock { $0.storage.removeAll() }
  }

  /// 메모리 압박 대응 (§3.5). 모니터 콜백과 테스트가 직접 호출한다.
  /// - Parameter level: 통지된 압박 수준.
  package func handleMemoryPressure(_ level: MemoryPressureLevel) {
    self.state.withLock { state in
      switch level {
      case .normal:
        state.effectiveBudget = state.configuredBudget
      case .warning:
        state.effectiveBudget = max(state.effectiveBudget / 2, state.configuredBudget / 4)
        state.storage.evictExcess(budget: state.effectiveBudget)
      case .critical:
        state.storage.removeAll()
        state.effectiveBudget = state.configuredBudget / 4
      }
    }
  }

  /// 현재 적재 바이트 (테스트·통계 관찰용).
  package var totalCost: Int {
    self.state.withLock { $0.storage.totalCost }
  }

  /// 적재 항목 수.
  package var count: Int {
    self.state.withLock { $0.storage.count }
  }

  /// 현재 유효 예산 (압박 반감 반영값 — 테스트 관찰용).
  package var currentBudget: Int {
    self.state.withLock { $0.effectiveBudget }
  }
}
