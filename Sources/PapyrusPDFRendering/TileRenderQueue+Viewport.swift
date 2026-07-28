import CoreGraphics

// `TileRenderQueue`의 뷰포트 갱신·프리페치 계산(§3.4). 파일 분리는 순수 조직적
// 이유(`PDFDocumentCore+PageTree.swift` 등 기존 확장 파일 분리 관례와 동형)이며,
// 본체에 직접 선언한 것과 완전히 동일한 액터·의미를 갖는다.

/// 프리페치 계산 전역에 공통인 문맥 (스케일 버킷 + 가시 페이지 집합).
///
/// 별도 타입으로 묶은 이유: 관련 파라미터를 하나로 모아 `addSpillPrefetch`의 인자 수를
/// 낮게 유지하기 위함 — 뷰포트 갱신 1회 동안 불변인 값들이라 묶는 편이 자연스럽다.
struct PrefetchContext {
  /// 현재 스냅된 스케일 버킷.
  let scaleBucket: ScaleBucket
  /// 가시 페이지 인덱스 집합 (스필 대상에서 제외하는 기준).
  let visiblePageIndices: Set<Int>
}

extension TileRenderQueue {
  /// 캐시에 있거나 이미 진행 중인 요청인가 (뷰포트 반영 2단계의 스킵 조건).
  func isAlreadySatisfied(_ key: RenderRequestKey) -> Bool {
    if self.inFlight.contains(key) {
      return true
    }
    switch key {
    case let .tile(tileKey):
      return self.tileCache.tile(for: tileKey) != nil
    case let .preview(pageIndex):
      return self.previewCache.preview(forPage: pageIndex) != nil
    }
  }

  /// 뷰포트로부터 원하는 요청 집합(우선순위 포함)을 계산한다.
  func desiredRequests(for viewport: RenderViewport) -> [RenderRequestKey: RenderPriority] {
    var desired: [RenderRequestKey: RenderPriority] = [:]
    let visiblePageIndices = Set(viewport.pages.map(\.pageIndex))

    for pageViewport in viewport.pages {
      desired[.preview(pageIndex: pageViewport.pageIndex)] = .visiblePreview
      guard self.pageSizes.indices.contains(pageViewport.pageIndex) else {
        continue
      }
      let grid = TileGrid(
        pageSize: self.pageSizes[pageViewport.pageIndex], scaleBucket: viewport.scaleBucket
      )
      for key in grid.tileKeys(
        intersecting: pageViewport.visibleRect, pageIndex: pageViewport.pageIndex
      ) {
        desired[.tile(key)] = .visibleTile
      }
    }

    let context = PrefetchContext(
      scaleBucket: viewport.scaleBucket, visiblePageIndices: visiblePageIndices
    )
    self.addTilePrefetch(for: viewport, context: context, into: &desired)
    self.addPreviewPrefetch(for: viewport, context: context, into: &desired)
    return desired
  }

  /// 타일 프리페치 (visible ±0.5 뷰포트, 페이지 경계 스필 근사 포함, 가정 9).
  private func addTilePrefetch(
    for viewport: RenderViewport, context: PrefetchContext,
    into desired: inout [RenderRequestKey: RenderPriority]
  ) {
    let margin = RenderingLimits.tilePrefetchViewportFactor * viewport.viewportSize.height
    for pageViewport in viewport.pages {
      guard self.pageSizes.indices.contains(pageViewport.pageIndex) else {
        continue
      }
      let pageSize = self.pageSizes[pageViewport.pageIndex]
      let pageRect = CGRect(origin: .zero, size: pageSize)
      let expanded = pageViewport.visibleRect.insetBy(dx: 0, dy: -margin)
      let grid = TileGrid(pageSize: pageSize, scaleBucket: context.scaleBucket)
      let clamped = expanded.intersection(pageRect)
      if !clamped.isNull {
        for key in grid.tileKeys(intersecting: clamped, pageIndex: pageViewport.pageIndex)
        where desired[.tile(key)] == nil {
          desired[.tile(key)] = .prefetchTile
        }
      }
      self.addSpillPrefetch(
        for: pageViewport, expanded: expanded, pageSize: pageSize, context: context, into: &desired
      )
    }
  }

  /// 뷰포트 확장이 페이지 경계를 넘는 분을 인접 페이지의 가장자리 스트립으로
  /// 근사 투영한다 (가정 9). 인접 페이지가 이미 가시 집합이면 생략(자체 확장이 커버).
  private func addSpillPrefetch(
    for pageViewport: RenderViewport.PageViewport, expanded: CGRect, pageSize: CGSize,
    context: PrefetchContext, into desired: inout [RenderRequestKey: RenderPriority]
  ) {
    let topSpill = max(0, -expanded.minY)
    if topSpill > 0 {
      let previousIndex = pageViewport.pageIndex - 1
      if previousIndex >= 0, !context.visiblePageIndices.contains(previousIndex),
        self.pageSizes.indices.contains(previousIndex) {
        let previousSize = self.pageSizes[previousIndex]
        let stripHeight = min(topSpill, previousSize.height)
        let strip = CGRect(
          x: pageViewport.visibleRect.minX, y: previousSize.height - stripHeight,
          width: pageViewport.visibleRect.width, height: stripHeight
        )
        let grid = TileGrid(pageSize: previousSize, scaleBucket: context.scaleBucket)
        for key in grid.tileKeys(intersecting: strip, pageIndex: previousIndex)
        where desired[.tile(key)] == nil {
          desired[.tile(key)] = .prefetchTile
        }
      }
    }

    let bottomSpill = max(0, expanded.maxY - pageSize.height)
    if bottomSpill > 0 {
      let nextIndex = pageViewport.pageIndex + 1
      if self.pageSizes.indices.contains(nextIndex),
        !context.visiblePageIndices.contains(nextIndex) {
        let nextSize = self.pageSizes[nextIndex]
        let stripHeight = min(bottomSpill, nextSize.height)
        let strip = CGRect(
          x: pageViewport.visibleRect.minX, y: 0,
          width: pageViewport.visibleRect.width, height: stripHeight
        )
        let grid = TileGrid(pageSize: nextSize, scaleBucket: context.scaleBucket)
        for key in grid.tileKeys(intersecting: strip, pageIndex: nextIndex)
        where desired[.tile(key)] == nil {
          desired[.tile(key)] = .prefetchTile
        }
      }
    }
  }

  /// 프리뷰 프리페치 (visible 페이지 인덱스 [min−3, max+3] ∩ [0, pageCount), 가시 집합 제외).
  private func addPreviewPrefetch(
    for viewport: RenderViewport, context: PrefetchContext,
    into desired: inout [RenderRequestKey: RenderPriority]
  ) {
    guard let minIndex = context.visiblePageIndices.min(),
      let maxIndex = context.visiblePageIndices.max()
    else {
      return
    }
    let radius = RenderingLimits.previewPrefetchRadius
    let lowerBound = max(0, minIndex - radius)
    let upperBound = min(self.pageSizes.count - 1, maxIndex + radius)
    guard lowerBound <= upperBound else {
      return
    }
    for pageIndex in lowerBound...upperBound
    where !context.visiblePageIndices.contains(pageIndex) {
      let key = RenderRequestKey.preview(pageIndex: pageIndex)
      if desired[key] == nil {
        desired[key] = .prefetchPreview
      }
    }
  }
}
