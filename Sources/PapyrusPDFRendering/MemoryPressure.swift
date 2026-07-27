import Dispatch

/// `DispatchSource.makeMemoryPressureSource` 래퍼. 이벤트를 ``MemoryPressureLevel``로
/// 번역해 핸들러에 전달한다. 핸들러는 캐시의 `handleMemoryPressure`를 직접 부른다
/// (캐시가 Sendable 클래스라 액터 홉 없이 즉시 반응 — 압박 대응은 지연이 곧 실패다).
package final class MemoryPressureMonitor: Sendable {
  /// 압박 이벤트를 감시하는 디스패치 소스.
  private let source: DispatchSourceMemoryPressure

  /// 모니터를 만들고 즉시 감시를 시작한다.
  /// - Parameter handler: 압박 수준 변화 콜백 (글로벌 큐에서 호출됨 — `@Sendable`).
  package init(handler: @escaping @Sendable (MemoryPressureLevel) -> Void) {
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility)
    )
    source.setEventHandler {
      handler(Self.level(for: source.data))
    }
    self.source = source
    source.resume()
  }

  /// 감시를 중단한다 (deinit에서도 호출됨 — 소스 누수 방지).
  package func cancel() {
    self.source.cancel()
  }

  deinit {
    self.source.cancel()
  }

  /// 디스패치 이벤트 마스크를 우선순위(critical > warning > normal)에 따라 번역한다.
  private static func level(for data: DispatchSource.MemoryPressureEvent) -> MemoryPressureLevel {
    if data.contains(.critical) {
      return .critical
    }
    if data.contains(.warning) {
      return .warning
    }
    return .normal
  }
}
