import CoreGraphics
import Foundation
import PapyrusPDFCore

/// 렌더 서비스 구성.
package struct RenderConfiguration: Sendable {
  /// 워커 수 (기본 `min(RenderingLimits.maxWorkerCount, 활성 코어 수)`; 1 미만은 1로 클램프).
  package var workerCount: Int

  /// 디스플레이 배율 (기본 2 — pixelScale은 서비스 인스턴스 생성 시 고정된다).
  package var pixelScale: CGFloat

  /// 타일 캐시 예산 (기본 `RenderingLimits.defaultTileBudgetBytes`).
  package var tileBudgetBytes: Int

  /// 프리뷰 캐시 예산 (기본 `RenderingLimits.defaultPreviewBudgetBytes`).
  package var previewBudgetBytes: Int

  /// 실제 메모리 압박 모니터 설치 여부 (기본 true — 테스트는 false로 끄고 직접 주입).
  package var installsMemoryPressureMonitor: Bool

  /// 렌더 서비스 구성을 생성한다.
  /// - Parameters:
  ///   - workerCount: 워커 수 (기본 `min(RenderingLimits.maxWorkerCount, 활성 코어 수)`).
  ///   - pixelScale: 디스플레이 배율 (기본 2).
  ///   - tileBudgetBytes: 타일 캐시 예산 (기본 `RenderingLimits.defaultTileBudgetBytes`).
  ///   - previewBudgetBytes: 프리뷰 캐시 예산 (기본 `RenderingLimits.defaultPreviewBudgetBytes`).
  ///   - installsMemoryPressureMonitor: 실제 메모리 압박 모니터 설치 여부 (기본 true).
  package init(
    workerCount: Int = min(
      RenderingLimits.maxWorkerCount, ProcessInfo.processInfo.activeProcessorCount
    ),
    pixelScale: CGFloat = 2,
    tileBudgetBytes: Int = RenderingLimits.defaultTileBudgetBytes,
    previewBudgetBytes: Int = RenderingLimits.defaultPreviewBudgetBytes,
    installsMemoryPressureMonitor: Bool = true
  ) {
    self.workerCount = max(1, workerCount)
    self.pixelScale = pixelScale
    self.tileBudgetBytes = tileBudgetBytes
    self.previewBudgetBytes = previewBudgetBytes
    self.installsMemoryPressureMonitor = installsMemoryPressureMonitor
  }
}

/// 뷰포트 스냅숏 — M6 레이아웃 엔진이 계산해 넘긴다 (M5는 스크롤 공간을 모른다).
package struct RenderViewport: Sendable, Equatable {
  /// 페이지 하나의 가시 영역.
  package struct PageViewport: Sendable, Equatable {
    /// 페이지 인덱스.
    package var pageIndex: Int
    /// 페이지 표시 공간(좌상단 원점, pt)에서의 가시 사각형.
    package var visibleRect: CGRect

    /// 페이지 가시 영역을 생성한다.
    /// - Parameters:
    ///   - pageIndex: 페이지 인덱스.
    ///   - visibleRect: 페이지 표시 공간에서의 가시 사각형.
    package init(pageIndex: Int, visibleRect: CGRect) {
      self.pageIndex = pageIndex
      self.visibleRect = visibleRect
    }
  }

  /// 보이는 페이지들 (문서 순서, 비면 "화면 밖" — 프리페치만 남는다).
  package var pages: [PageViewport]

  /// 현재 스냅된 스케일 버킷.
  package var scaleBucket: ScaleBucket

  /// 뷰포트 크기 (pt) — 타일 프리페치 확장(±0.5×높이)의 기준.
  package var viewportSize: CGSize

  /// 뷰포트 스냅숏을 생성한다.
  /// - Parameters:
  ///   - pages: 보이는 페이지들 (문서 순서).
  ///   - scaleBucket: 현재 스냅된 스케일 버킷.
  ///   - viewportSize: 뷰포트 크기 (pt).
  package init(pages: [PageViewport], scaleBucket: ScaleBucket, viewportSize: CGSize) {
    self.pages = pages
    self.scaleBucket = scaleBucket
    self.viewportSize = viewportSize
  }
}

/// 큐·캐시 통계 스냅숏 (테스트 전용 소비 — `CacheStatistics` 패턴).
package struct RenderStatistics: Sendable, Equatable {
  /// 실제 실행된 타일 렌더 횟수 (캐시 히트·병합이면 늘지 않는다 — dedupe 검증용).
  package let tileRenderCount: Int
  /// 실제 실행된 프리뷰 렌더 횟수.
  package let previewRenderCount: Int
  /// 기존 요청에 병합된 횟수.
  package let joinedRequestCount: Int
  /// 시작 전 폐기(뷰포트 이탈·취소)된 횟수.
  package let droppedBeforeStartCount: Int
  /// 타일 캐시 적재 바이트.
  package let tileCacheBytes: Int
  /// 타일 캐시 적재 항목 수.
  package let tileCacheCount: Int
  /// 프리뷰 캐시 적재 바이트.
  package let previewCacheBytes: Int
  /// 프리뷰 캐시 적재 항목 수.
  package let previewCacheCount: Int

  /// 통계 스냅숏을 생성한다.
  /// - Parameters:
  ///   - tileRenderCount: 실제 실행된 타일 렌더 횟수.
  ///   - previewRenderCount: 실제 실행된 프리뷰 렌더 횟수.
  ///   - joinedRequestCount: 기존 요청에 병합된 횟수.
  ///   - droppedBeforeStartCount: 시작 전 폐기된 횟수.
  ///   - tileCacheBytes: 타일 캐시 적재 바이트.
  ///   - tileCacheCount: 타일 캐시 적재 항목 수.
  ///   - previewCacheBytes: 프리뷰 캐시 적재 바이트.
  ///   - previewCacheCount: 프리뷰 캐시 적재 항목 수.
  package init(
    tileRenderCount: Int, previewRenderCount: Int, joinedRequestCount: Int,
    droppedBeforeStartCount: Int, tileCacheBytes: Int, tileCacheCount: Int,
    previewCacheBytes: Int, previewCacheCount: Int
  ) {
    self.tileRenderCount = tileRenderCount
    self.previewRenderCount = previewRenderCount
    self.joinedRequestCount = joinedRequestCount
    self.droppedBeforeStartCount = droppedBeforeStartCount
    self.tileCacheBytes = tileCacheBytes
    self.tileCacheCount = tileCacheCount
    self.previewCacheBytes = previewCacheBytes
    self.previewCacheCount = previewCacheCount
  }
}

/// 렌더링 파이프라인의 퍼사드 액터: 우선순위 스케줄링, in-flight dedupe, 프리페치,
/// 취소, 캐시·압박 배선을 소유한다. M6 `ReaderCore`가 유일한 소비자다.
package actor TileRenderQueue {
  /// 렌더 완료 값 (타일/프리뷰 합 — 대기자에게 전달되는 내부 표현).
  ///
  /// 구현 세부(internal) — `TileRenderQueue+Scheduling.swift`/`+Viewport.swift`
  /// 확장 파일에서도 참조하므로 파일 스코프 `private`가 아니라 모듈 스코프로 둔다.
  enum RenderResult: Sendable {
    /// 타일 렌더 결과.
    case tile(RenderedTile)
    /// 프리뷰 렌더 결과.
    case preview(RenderedPreview)
  }

  /// 외부 대기자 continuation 타입 (반복 등장하는 긴 제네릭 표기를 줄이기 위한 별칭).
  typealias RenderContinuation = CheckedContinuation<Result<RenderResult, RenderError>, Never>

  /// 타일 캐시 — 동기 조회를 위해 nonisolated (Mutex 기반 Sendable).
  package nonisolated let tileCache: TileCache

  /// 프리뷰 캐시 — 동일.
  package nonisolated let previewCache: PagePreviewCache

  /// 워커 풀.
  var pool: RenderWorkerPool

  /// 페이지별 표시 크기 (인덱스 = 페이지 인덱스 — 파서 진실 원천).
  let pageSizes: [CGSize]

  /// 시작 전 요청 버퍼.
  var pending = RenderRequestBuffer()

  /// 워커에 배정되어 실행 중인 요청 키.
  var inFlight: Set<RenderRequestKey> = []

  /// 외부 대기자 (요청 키 → 대기자 ID → continuation).
  var waiters: [RenderRequestKey: [UUID: RenderContinuation]] = [:]

  /// 외부 대기자가 있는 요청 키 (`removeAll(notIn:keepAlways:)`의 keepAlways 원천).
  var externallyWaited: Set<RenderRequestKey> = []

  /// 실제 실행된 타일 렌더 횟수 (통계).
  var tileRenderCount = 0

  /// 실제 실행된 프리뷰 렌더 횟수 (통계).
  var previewRenderCount = 0

  /// 기존 요청에 병합된 횟수 (통계).
  var joinedRequestCount = 0

  /// 시작 전 폐기된 횟수 (통계).
  var droppedBeforeStartCount = 0

  /// 실제 메모리 압박 모니터 (`installsMemoryPressureMonitor`가 true일 때만 존재).
  let memoryPressureMonitor: MemoryPressureMonitor?

  /// 서비스를 만든다.
  /// - Parameters:
  ///   - documentData: 원본 PDF 바이트 (`PDFDocumentCore.sourceBytes`).
  ///   - pageSizes: 페이지별 표시 크기 (인덱스 = 페이지 인덱스 — 파서 진실 원천).
  ///   - configuration: 구성.
  package init(
    documentData: Data, pageSizes: [CGSize],
    configuration: RenderConfiguration = RenderConfiguration()
  ) {
    self.pageSizes = pageSizes
    self.pool = RenderWorkerPool(
      documentData: documentData, pixelScale: configuration.pixelScale,
      count: configuration.workerCount
    )
    let tileCache = TileCache(budgetBytes: configuration.tileBudgetBytes)
    let previewCache = PagePreviewCache(budgetBytes: configuration.previewBudgetBytes)
    self.tileCache = tileCache
    self.previewCache = previewCache
    if configuration.installsMemoryPressureMonitor {
      self.memoryPressureMonitor = MemoryPressureMonitor { level in
        tileCache.handleMemoryPressure(level)
        previewCache.handleMemoryPressure(level)
      }
    } else {
      self.memoryPressureMonitor = nil
    }
  }

  /// 열린 문서에서 서비스를 조립하는 편의 팩토리 (페이지 트리 1회 접근).
  /// - Parameters:
  ///   - document: 대상 문서.
  ///   - configuration: 구성.
  /// - Throws: 페이지 트리 실패 시 코어 에러 그대로 (호출자는 M6 — package 경계 내부).
  /// - Returns: 조립된 렌더 서비스.
  package static func make(
    for document: PapyrusPDFDocument,
    configuration: RenderConfiguration = RenderConfiguration()
  ) async throws -> TileRenderQueue {
    let snapshot = try await document.core.pageTree()
    let pageSizes = snapshot.records.map(\.displaySize)
    return TileRenderQueue(
      documentData: document.core.sourceBytes, pageSizes: pageSizes, configuration: configuration
    )
  }

  /// 타일을 얻는다. 캐시 히트는 즉시, 아니면 렌더를 스케줄하고 완료를 기다린다.
  ///
  /// 동일 키 동시 요청은 하나의 렌더로 병합된다. 호출 태스크 취소는 전파된다 —
  /// 마지막 대기자가 취소되고 아직 시작 전이면 요청 자체가 폐기된다 (가정 6).
  /// - Parameter key: 타일 식별자.
  /// - Throws: ``RenderError`` (취소는 `.cancelled`).
  /// - Returns: 렌더된 타일.
  package func tile(for key: TileKey) async throws(RenderError) -> RenderedTile {
    if let cached = self.tileCache.tile(for: key) {
      return cached
    }
    let result = try await self.requestResult(for: .tile(key), priority: .visibleTile)
    guard case let .tile(tile) = result else {
      throw RenderError.imageCreationFailed
    }
    return tile
  }

  /// 프리뷰를 얻는다. 규칙은 ``tile(for:)``와 동일.
  /// - Parameter pageIndex: 페이지 인덱스 (0 기반).
  /// - Throws: ``RenderError`` (취소는 `.cancelled`).
  /// - Returns: 렌더된 프리뷰.
  package func preview(forPage pageIndex: Int) async throws(RenderError) -> RenderedPreview {
    if let cached = self.previewCache.preview(forPage: pageIndex) {
      return cached
    }
    let key = RenderRequestKey.preview(pageIndex: pageIndex)
    let result = try await self.requestResult(for: key, priority: .visiblePreview)
    guard case let .preview(preview) = result else {
      throw RenderError.imageCreationFailed
    }
    return preview
  }

  /// 뷰포트 갱신(§3.4): 가시 타일·프리뷰를 visible 등급으로, 프리페치 집합을
  /// prefetch 등급으로 등재하고, 새 집합 밖의 시작 전 요청을 폐기한다.
  ///
  /// 스크롤 중 고빈도 호출 전제 — O(가시 타일 수) 이하로 유지한다.
  /// - Parameter viewport: 최신 뷰포트 스냅숏.
  package func updateViewport(_ viewport: RenderViewport) {
    let desired = self.desiredRequests(for: viewport)
    for (key, priority) in desired where !self.isAlreadySatisfied(key) {
      self.pending.enqueue(key, priority: priority)
    }
    let dropped = self.pending.removeAll(
      notIn: Set(desired.keys), keepAlways: self.externallyWaited
    )
    self.droppedBeforeStartCount += dropped.count
    self.pump()
  }

  /// 통계 스냅숏 (테스트 전용).
  /// - Returns: 현재 큐·캐시 통계.
  package func statistics() -> RenderStatistics {
    RenderStatistics(
      tileRenderCount: self.tileRenderCount, previewRenderCount: self.previewRenderCount,
      joinedRequestCount: self.joinedRequestCount,
      droppedBeforeStartCount: self.droppedBeforeStartCount,
      tileCacheBytes: self.tileCache.totalCost, tileCacheCount: self.tileCache.count,
      previewCacheBytes: self.previewCache.totalCost, previewCacheCount: self.previewCache.count
    )
  }
}
