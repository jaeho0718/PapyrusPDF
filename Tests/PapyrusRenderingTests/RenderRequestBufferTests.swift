@testable import PapyrusRendering
import Testing

/// ``RenderRequestBuffer``의 우선순위·FIFO·승격·폐기 규칙을 검증한다 (설계 §5 RB1).
struct RenderRequestBufferTests {
  /// 임의의 서로 다른 타일 키를 만드는 헬퍼.
  private func tileKey(_ col: Int) -> RenderRequestKey {
    .tile(TileKey(pageIndex: 0, scaleBucket: ScaleBucket(exponent: 0), col: col, row: 0))
  }

  /// RB1: 4등급이 내림차순(visiblePreview > visibleTile > prefetchTile > prefetchPreview)으로
  /// dequeue된다.
  @Test func dequeuesInDescendingPriorityOrder() {
    var buffer = RenderRequestBuffer()
    buffer.enqueue(.preview(pageIndex: 0), priority: .prefetchPreview)
    buffer.enqueue(self.tileKey(0), priority: .prefetchTile)
    buffer.enqueue(self.tileKey(1), priority: .visibleTile)
    buffer.enqueue(.preview(pageIndex: 1), priority: .visiblePreview)

    let order = (0..<4).compactMap { _ in buffer.dequeueHighest()?.priority }
    #expect(order == [.visiblePreview, .visibleTile, .prefetchTile, .prefetchPreview])
    #expect(buffer.count == 0)
  }

  /// RB1: 같은 등급 내에서는 FIFO 순서가 유지된다.
  @Test func sameTierPreservesFIFOOrder() {
    var buffer = RenderRequestBuffer()
    buffer.enqueue(self.tileKey(0), priority: .visibleTile)
    buffer.enqueue(self.tileKey(1), priority: .visibleTile)
    buffer.enqueue(self.tileKey(2), priority: .visibleTile)

    let first = buffer.dequeueHighest()?.key
    let second = buffer.dequeueHighest()?.key
    let third = buffer.dequeueHighest()?.key
    #expect(first == self.tileKey(0))
    #expect(second == self.tileKey(1))
    #expect(third == self.tileKey(2))
  }

  /// RB1: 승격은 단방향이다 — 낮은 우선순위 재등재는 기존 값을 낮추지 않는다.
  @Test func promotionIsOneDirectional() {
    var buffer = RenderRequestBuffer()
    let key = self.tileKey(0)
    buffer.enqueue(key, priority: .prefetchTile)
    buffer.enqueue(key, priority: .visibleTile)
    // 하향 시도 — 무시되어야 한다.
    buffer.enqueue(key, priority: .prefetchTile)

    #expect(buffer.count == 1)
    let dequeued = buffer.dequeueHighest()
    #expect(dequeued?.priority == .visibleTile)
  }

  /// `contains(_:)`가 등재 여부를 정확히 보고한다.
  @Test func containsReflectsRegistration() {
    var buffer = RenderRequestBuffer()
    let key = self.tileKey(0)
    #expect(!buffer.contains(key))
    buffer.enqueue(key, priority: .visibleTile)
    #expect(buffer.contains(key))
  }

  /// `remove(_:)`가 등재된 항목을 제거하고 true를 반환, 없으면 false.
  @Test func removeReportsWhetherEntryExisted() {
    var buffer = RenderRequestBuffer()
    let key = self.tileKey(0)
    #expect(buffer.remove(key) == false)
    buffer.enqueue(key, priority: .visibleTile)
    #expect(buffer.remove(key) == true)
    #expect(!buffer.contains(key))
  }

  /// RB1: `removeAll(notIn:keepAlways:)`는 desired 밖의 키를 폐기하되, keepAlways는
  /// 술어와 무관하게 보존한다.
  @Test func removeAllDropsUndesiredKeysButKeepsAlwaysSet() {
    var buffer = RenderRequestBuffer()
    let keep = self.tileKey(0)
    let drop = self.tileKey(1)
    let keptAlways = self.tileKey(2)
    buffer.enqueue(keep, priority: .visibleTile)
    buffer.enqueue(drop, priority: .prefetchTile)
    buffer.enqueue(keptAlways, priority: .prefetchTile)

    let dropped = buffer.removeAll(notIn: [keep], keepAlways: [keptAlways])

    #expect(dropped == [drop])
    #expect(buffer.contains(keep))
    #expect(!buffer.contains(drop))
    #expect(buffer.contains(keptAlways))
  }

  /// 빈 버퍼에서 dequeue는 `nil`.
  @Test func dequeueOnEmptyBufferReturnsNil() {
    var buffer = RenderRequestBuffer()
    #expect(buffer.dequeueHighest() == nil)
  }
}
