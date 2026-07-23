import Foundation

/// 워커 N개와 가용 상태를 관리하는 순수 값 타입. `TileRenderQueue` 액터 격리 하 전용
/// (비-Sendable 상태 없음 — 워커 참조 자체는 Sendable인 액터 참조다).
package struct RenderWorkerPool {
  /// 워커 인스턴스 목록 (인덱스가 곧 슬롯 번호).
  private var workers: [RenderWorker]

  /// 슬롯별 사용 중 여부.
  private var busy: [Bool]

  /// 풀을 만든다. 각 워커는 독립 CGPDFDocument를 갖게 된다 (CGPDFDocument 비-Sendable·
  /// 페이지 캐시 비스레드세이프 → 워커당 1문서가 병렬화의 전제).
  /// - Parameters:
  ///   - documentData: 각 워커에 공유되는 원본 PDF 바이트 (무복사).
  ///   - pixelScale: 디스플레이 배율.
  ///   - count: 워커 수 (`RenderingLimits.maxWorkerCount`와 활성 코어 수의 최솟값이 기본).
  package init(documentData: Data, pixelScale: CGFloat, count: Int) {
    let workerCount = max(1, count)
    self.workers = (0..<workerCount).map { _ in
      RenderWorker(documentData: documentData, pixelScale: pixelScale)
    }
    self.busy = Array(repeating: false, count: workerCount)
  }

  /// 총 워커 수.
  package var count: Int {
    self.workers.count
  }

  /// 유휴 워커를 하나 체크아웃한다. 없으면 `nil` (큐가 대기 버퍼로 되돌린다).
  /// - Returns: 체크아웃된 슬롯 인덱스와 워커, 유휴 워커가 없으면 `nil`.
  package mutating func checkout() -> (index: Int, worker: RenderWorker)? {
    guard let index = self.busy.firstIndex(of: false) else {
      return nil
    }
    self.busy[index] = true
    return (index, self.workers[index])
  }

  /// 체크아웃한 워커를 반납한다.
  /// - Parameter index: 반납할 슬롯 인덱스.
  package mutating func checkin(index: Int) {
    guard self.busy.indices.contains(index) else {
      return
    }
    self.busy[index] = false
  }
}
