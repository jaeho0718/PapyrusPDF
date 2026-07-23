import Synchronization

/// 페이지 프리뷰 LRU. 구조는 ``TileCache``와 동형, 키만 페이지 인덱스.
///
/// 별도 타입으로 두는 이유: 예산·압박 정책이 다르고(critical에도 생존), 프리뷰는
/// "작고 많이"가 목표라 타일과 예산을 공유하면 큰 타일이 프리뷰를 밀어낸다 (115행).
package final class PagePreviewCache: Sendable {
  /// 잠금이 보호하는 캐시 상태.
  private struct State {
    var storage = CostBoundLRUStorage<Int, RenderedPreview>()
    let configuredBudget: Int
    var effectiveBudget: Int
  }

  /// 상태 잠금.
  private let state: Mutex<State>

  /// 캐시를 만든다.
  /// - Parameter budgetBytes: 바이트 예산 (기본 `RenderingLimits.defaultPreviewBudgetBytes`).
  package init(budgetBytes: Int) {
    self.state = Mutex(State(configuredBudget: budgetBytes, effectiveBudget: budgetBytes))
  }

  /// 조회 (LRU touch). 동기 — M6 표시 경로에서 직접 호출 가능.
  /// - Parameter pageIndex: 조회할 페이지 인덱스.
  /// - Returns: 캐시된 프리뷰, 없으면 `nil`.
  package func preview(forPage pageIndex: Int) -> RenderedPreview? {
    self.state.withLock { $0.storage.value(for: pageIndex) }
  }

  /// 삽입. 예산 초과분은 LRU 퇴거. 단일 항목이 예산 초과면 넣지 않고 버린다.
  /// - Parameter preview: 저장할 프리뷰.
  package func insert(_ preview: RenderedPreview) {
    self.state.withLock { state in
      state.storage.insert(
        preview, cost: preview.cost, for: preview.pageIndex, budget: state.effectiveBudget
      )
    }
  }

  /// 전량 퍼지.
  package func removeAll() {
    self.state.withLock { $0.storage.removeAll() }
  }

  /// 메모리 압박 대응. critical에도 전량 퍼지하지 않고 반감 퇴거만 한다 (편차 표).
  /// - Parameter level: 통지된 압박 수준.
  package func handleMemoryPressure(_ level: MemoryPressureLevel) {
    self.state.withLock { state in
      switch level {
      case .normal:
        state.effectiveBudget = state.configuredBudget
      case .warning, .critical:
        state.effectiveBudget = max(state.effectiveBudget / 2, state.configuredBudget / 4)
        state.storage.evictExcess(budget: state.effectiveBudget)
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
