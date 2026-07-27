/// 렌더 요청 식별자 (타일 또는 프리뷰).
package enum RenderRequestKey: Sendable, Hashable {
  /// 타일 요청.
  case tile(TileKey)
  /// 프리뷰 요청.
  case preview(pageIndex: Int)
}

/// 요청 우선순위 (내림차순 — visiblePreview > visibleTile > prefetchTile > prefetchPreview).
package enum RenderPriority: Int, Sendable, Comparable, CaseIterable {
  /// 보이는 페이지의 프리뷰 (공백 화면 방지 — 최우선).
  case visiblePreview = 3
  /// 보이는 영역의 타일.
  case visibleTile = 2
  /// 프리페치 타일 (visible ±0.5 뷰포트).
  case prefetchTile = 1
  /// 프리페치 프리뷰 (visible ±3 페이지).
  case prefetchPreview = 0

  /// rawValue 오름차순 비교.
  package static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// 시작 전 요청의 우선순위 버퍼. `TileRenderQueue` 액터 격리 하 전용 (비-Sendable).
///
/// 순수 값 타입으로 분리한 이유: 우선순위·FIFO·승격·폐기 규칙을 CG 없이 단독
/// 유닛 테스트하기 위해서다 (§5.6).
package struct RenderRequestBuffer {
  /// 대기 항목 (등재 순서 = FIFO 순서, 술어 판정을 위해 우선순위별로 유지).
  private struct Entry {
    let key: RenderRequestKey
    var priority: RenderPriority
    let sequence: Int
  }

  /// 키 → 항목 (조회·중복 검사·승격용).
  private var entriesByKey: [RenderRequestKey: Entry] = [:]

  /// 다음에 부여할 시퀀스 번호 (등급 내 FIFO 순서 보존용, 단조 증가).
  private var nextSequence = 0

  /// 버퍼를 생성한다.
  package init() {}

  /// 대기 수 (테스트 관찰용).
  package var count: Int {
    self.entriesByKey.count
  }

  /// 등재 여부 조회.
  /// - Parameter key: 조회할 요청 키.
  /// - Returns: 대기 중이면 `true`.
  package func contains(_ key: RenderRequestKey) -> Bool {
    self.entriesByKey[key] != nil
  }

  /// 삽입. 이미 있으면 우선순위만 상향 병합한다 (하향은 무시 — 승격 단방향).
  /// - Parameters:
  ///   - key: 등재할 요청 키.
  ///   - priority: 요청 우선순위.
  package mutating func enqueue(_ key: RenderRequestKey, priority: RenderPriority) {
    if var existing = self.entriesByKey[key] {
      if priority > existing.priority {
        existing.priority = priority
        self.entriesByKey[key] = existing
      }
      return
    }
    self.entriesByKey[key] = Entry(key: key, priority: priority, sequence: self.nextSequence)
    self.nextSequence += 1
  }

  /// 최고 우선순위·같은 등급 내 FIFO로 하나 꺼낸다. 비면 `nil`.
  /// - Returns: 꺼낸 요청의 키와 우선순위, 비어 있으면 `nil`.
  package mutating func dequeueHighest() -> (key: RenderRequestKey, priority: RenderPriority)? {
    guard let best = self.entriesByKey.values.min(by: Self.dequeueOrder) else {
      return nil
    }
    self.entriesByKey.removeValue(forKey: best.key)
    return (best.key, best.priority)
  }

  /// 최고 우선순위(내림차순) → 등급 내 FIFO(시퀀스 오름차순) 정렬 술어.
  private static func dequeueOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
    if lhs.priority != rhs.priority {
      return lhs.priority > rhs.priority
    }
    return lhs.sequence < rhs.sequence
  }

  /// 특정 키 제거 (마지막 대기자 취소 경로). 있었으면 true.
  /// - Parameter key: 제거할 요청 키.
  /// - Returns: 제거된 항목이 있었으면 `true`.
  @discardableResult
  package mutating func remove(_ key: RenderRequestKey) -> Bool {
    self.entriesByKey.removeValue(forKey: key) != nil
  }

  /// 술어를 만족하지 않는 키 일괄 폐기, 폐기된 키 반환 (뷰포트 이탈 처리).
  ///
  /// 단 `keepAlways`(외부 대기자 있는 키)는 술어와 무관하게 유지한다.
  /// - Parameters:
  ///   - desired: 유지할 키 집합.
  ///   - keepAlways: 술어와 무관하게 항상 유지할 키 집합 (외부 대기자 보유).
  /// - Returns: 폐기된 키 목록.
  package mutating func removeAll(
    notIn desired: Set<RenderRequestKey>, keepAlways: Set<RenderRequestKey>
  ) -> [RenderRequestKey] {
    let keysToRemove = self.entriesByKey.keys.filter { key in
      !desired.contains(key) && !keepAlways.contains(key)
    }
    for key in keysToRemove {
      self.entriesByKey.removeValue(forKey: key)
    }
    return keysToRemove
  }
}
