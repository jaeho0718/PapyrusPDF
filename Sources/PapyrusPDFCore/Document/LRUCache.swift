/// 비용 예산 기반 제네릭 LRU. 액터 격리 하 전용 — 비-Sendable, 잠금 없음.
///
/// 구현: Dictionary + 단조 증가 tick. 퇴거는 최소 tick 선형 탐색 — O(n)이지만
/// n이 작다(ObjStm 수십 개 / 객체 캐시 ≤ 4096). 연결 리스트 관리 코드의 복잡도가
/// 이 규모에선 이득이 없다 (대안: 이중 연결 리스트 O(1) — 기각).
struct LRUCache<Key: Hashable, Value> {
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

  /// 비용 예산.
  private let costBudget: Int

  /// 현재 적재 비용 합.
  private(set) var totalCost = 0

  /// 캐시를 생성한다.
  /// - Parameter costBudget: 비용 예산.
  init(costBudget: Int) {
    self.costBudget = costBudget
  }

  /// 적재 항목 수.
  var count: Int {
    self.storage.count
  }

  /// 조회 (LRU touch 포함). 없으면 `nil`.
  /// - Parameter key: 조회할 키.
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
  /// - Parameters:
  ///   - value: 저장할 값.
  ///   - cost: 이 값의 비용.
  ///   - key: 저장할 키.
  mutating func insert(_ value: Value, cost: Int, for key: Key) {
    guard cost <= self.costBudget else {
      return
    }
    if let existing = self.storage[key] {
      self.totalCost -= existing.cost
    }
    while self.totalCost + cost > self.costBudget, !self.storage.isEmpty {
      self.evictLeastRecentlyUsed()
    }
    self.storage[key] = Entry(value: value, cost: cost, tick: self.nextTick)
    self.nextTick += 1
    self.totalCost += cost
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
