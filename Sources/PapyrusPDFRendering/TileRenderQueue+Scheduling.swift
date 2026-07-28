import CoreGraphics
import Foundation

// `TileRenderQueue`의 요청 등재·취소·디스패치 루프(§3.3). 파일 분리는 순수 조직적
// 이유(`PDFDocumentCore+PageTree.swift` 등 기존 확장 파일 분리 관례와 동형)이며,
// 본체에 직접 선언한 것과 완전히 동일한 액터·의미를 갖는다.

// MARK: - 요청 등재·취소

extension TileRenderQueue {
  /// 캐시 히트 대기 → 등재 → pump까지의 공통 경로.
  func requestResult(
    for key: RenderRequestKey, priority: RenderPriority
  ) async throws(RenderError) -> RenderResult {
    let waiterID = UUID()
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: RenderContinuation) in
        self.registerWaiter(id: waiterID, key: key, priority: priority, continuation: continuation)
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: waiterID, key: key) }
    }
    switch outcome {
    case let .success(result):
      return result
    case let .failure(error):
      throw error
    }
  }

  /// 대기자를 등재하고, 최초 요청이면 대기 버퍼에 넣는다 (아니면 병합 카운트만 증가).
  ///
  /// 등재 직전에 `Task.isCancelled`를 확인한다 — `withTaskCancellationHandler`는 태스크가
  /// 이 함수 진입 전에 이미 취소돼 있으면 `onCancel`을 즉시(= 이 등재보다 먼저) 실행하고
  /// `operation`도 그대로 계속 진행시킨다(Swift 동시성 계약). 그 경우 `onCancel`의
  /// `cancelWaiter`는 아직 등재되지 않은 대기자를 찾지 못해 조용히 없는 일이 되므로, 여기서
  /// 별도로 취소를 잡지 않으면 취소가 유실되고 렌더가 완주해 버린다(가정 6 위반 — "시작 전
  /// 취소"가 이 지점에서는 아직 시작 전이 맞다). 등재 자체를 생략하고 즉시 폐기 처리한다.
  private func registerWaiter(
    id: UUID, key: RenderRequestKey, priority: RenderPriority, continuation: RenderContinuation
  ) {
    guard !Task.isCancelled else {
      self.droppedBeforeStartCount += 1
      continuation.resume(returning: .failure(.cancelled))
      return
    }
    self.waiters[key, default: [:]][id] = continuation
    self.externallyWaited.insert(key)
    if self.inFlight.contains(key) {
      self.joinedRequestCount += 1
    } else if self.pending.contains(key) {
      self.joinedRequestCount += 1
      self.pending.enqueue(key, priority: priority)
    } else {
      self.pending.enqueue(key, priority: priority)
    }
    self.pump()
  }

  /// 취소 핸들러의 액터 재진입 지점 — 마지막 대기자였고 시작 전이면 요청을 폐기한다.
  private func cancelWaiter(id: UUID, key: RenderRequestKey) {
    guard var waitersForKey = self.waiters[key],
      let continuation = waitersForKey.removeValue(forKey: id)
    else {
      return
    }
    if waitersForKey.isEmpty {
      self.waiters.removeValue(forKey: key)
      self.externallyWaited.remove(key)
      if self.pending.remove(key) {
        self.droppedBeforeStartCount += 1
      }
    } else {
      self.waiters[key] = waitersForKey
    }
    continuation.resume(returning: .failure(.cancelled))
  }
}

// MARK: - 디스패치 루프

extension TileRenderQueue {
  /// 유휴 워커가 있는 한 대기 버퍼에서 최고 우선순위 요청을 꺼내 배정한다.
  func pump() {
    while let (slot, worker) = self.pool.checkout() {
      guard let (key, _) = self.pending.dequeueHighest() else {
        self.pool.checkin(index: slot)
        return
      }
      self.inFlight.insert(key)
      let pageSizes = self.pageSizes
      Task {
        let outcome = await Self.performRender(worker: worker, key: key, pageSizes: pageSizes)
        self.finish(slot: slot, key: key, outcome: outcome)
      }
    }
  }

  /// 워커 배정 태스크의 본체 (액터 밖 — 요청자 취소가 렌더를 중단시키지 않는다, 가정 6).
  private static func performRender(
    worker: RenderWorker, key: RenderRequestKey, pageSizes: [CGSize]
  ) async -> Result<RenderResult, RenderError> {
    switch key {
    case let .tile(tileKey):
      guard pageSizes.indices.contains(tileKey.pageIndex) else {
        return .failure(.pageUnavailable(pageIndex: tileKey.pageIndex))
      }
      do {
        let tile = try await worker.renderTile(
          key: tileKey, pageSize: pageSizes[tileKey.pageIndex]
        )
        return .success(.tile(tile))
      } catch {
        return .failure(error)
      }
    case let .preview(pageIndex):
      guard pageSizes.indices.contains(pageIndex) else {
        return .failure(.pageUnavailable(pageIndex: pageIndex))
      }
      do {
        let preview = try await worker.renderPreview(
          pageIndex: pageIndex, pageSize: pageSizes[pageIndex]
        )
        return .success(.preview(preview))
      } catch {
        return .failure(error)
      }
    }
  }

  /// 렌더 완료 처리: 워커 반납, 캐시 삽입(+카운트), 대기자 전원 통지, 재펌프.
  ///
  /// 뷰포트를 이미 벗어난 요청이어도 캐시에는 삽입한다 — LRU가 곧 밀어낸다
  /// (가정 6의 완주 원칙).
  func finish(slot: Int, key: RenderRequestKey, outcome: Result<RenderResult, RenderError>) {
    self.pool.checkin(index: slot)
    self.inFlight.remove(key)
    self.externallyWaited.remove(key)
    if case let .success(result) = outcome {
      switch result {
      case let .tile(tile):
        self.tileCache.insert(tile)
        self.tileRenderCount += 1
      case let .preview(preview):
        self.previewCache.insert(preview)
        self.previewRenderCount += 1
      }
    }
    if let waitersForKey = self.waiters.removeValue(forKey: key) {
      for continuation in waitersForKey.values {
        continuation.resume(returning: outcome)
      }
    }
    self.pump()
  }
}
