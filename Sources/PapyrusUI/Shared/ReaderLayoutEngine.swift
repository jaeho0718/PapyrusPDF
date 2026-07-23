import CoreGraphics

/// 레이아웃 정책 상수 (`RenderingLimits`의 UI판 — 한 곳 원칙).
package enum ReaderLayoutMetrics {
  /// 페이지 사이 간격 (pt, 콘텐츠 공간).
  package static let pageSpacing: CGFloat = 12

  /// 콘텐츠 상하 여백 (pt).
  package static let verticalInset: CGFloat = 12

  /// 콘텐츠 좌우 여백 (pt) — 콘텐츠 폭 = maxPageWidth + 2×horizontalInset.
  package static let horizontalInset: CGFloat = 12

  /// 최대 줌 배율 (버킷 지수 6 = 8배. M5 한도 지수 12 안쪽).
  package static let maxZoomScale: CGFloat = 8

  /// 페이지 한 변 위생 한도 (pt). 손상 파일의 퇴화(0)·병적(초대형) 크기를
  /// `[1, 50_000]`으로 클램프 — 레이아웃 오버플로·0 나눗셈 원천 차단.
  package static let pageSideBounds: ClosedRange<CGFloat> = 1...50_000

  /// 실체화 여유 (visibleRange ±N 페이지, ARCHITECTURE 확정: 2).
  package static let materializationMargin = 2

  /// 유휴 재활용 풀 보관 상한 (ARCHITECTURE 확정: ~8).
  package static let recyclePoolCapacity = 8

  /// 페이지당 스테일(구버킷) 타일 레이어 보관 상한 (§4.5 — 초과분 오래된 순 제거).
  package static let maxStaleTileLayers = 40
}

/// 세로 연속 스크롤 레이아웃 (콘텐츠 공간 = 페이지 pt 공간 적층, 가정 1).
///
/// `pageSizes`만의 순수 함수 — 생성 시 누적 오프셋 배열을 1회 계산한다
/// (5,000페이지 ≈ 40KB, 수 ms 미만). 뷰포트·줌 개념이 없다.
package struct ReaderLayoutEngine: Sendable, Equatable {
  /// 위생 처리(클램프) 후의 페이지 크기들.
  package let pageSizes: [CGSize]

  /// 콘텐츠 전체 크기 (줌 1 기준, 여백 포함).
  package let contentSize: CGSize

  /// 페이지별 콘텐츠 공간 상단 Y 오프셋 + 마지막 페이지 하단 (`count == pageCount + 1`).
  private let yOffsets: [CGFloat]

  /// 페이지 수.
  package var pageCount: Int {
    self.pageSizes.count
  }

  /// 레이아웃을 계산한다. 크기들은 `pageSideBounds`로 클램프된다.
  /// - Parameter pageSizes: 페이지별 표시 크기 (`PageRecord.displaySize` 순서).
  package init(pageSizes: [CGSize]) {
    let sanitized = pageSizes.map(Self.sanitize)
    self.pageSizes = sanitized

    var offsets: [CGFloat] = []
    offsets.reserveCapacity(sanitized.count + 1)
    var cursor = ReaderLayoutMetrics.verticalInset
    for size in sanitized {
      offsets.append(cursor)
      cursor += size.height + ReaderLayoutMetrics.pageSpacing
    }
    if !sanitized.isEmpty {
      cursor -= ReaderLayoutMetrics.pageSpacing
    }
    offsets.append(cursor)
    self.yOffsets = offsets

    let maxWidth = sanitized.map(\.width).max() ?? 0
    let contentWidth = maxWidth + 2 * ReaderLayoutMetrics.horizontalInset
    let contentHeight = cursor + ReaderLayoutMetrics.verticalInset
    self.contentSize = CGSize(width: contentWidth, height: contentHeight)
  }

  /// 페이지 프레임 (콘텐츠 공간, 좌상단 원점). O(1).
  /// 범위 밖 인덱스는 `.null` 아닌 **클램프된 인덱스의 프레임** 대신 `nil`.
  /// - Parameter index: 조회할 페이지 인덱스.
  /// - Returns: 페이지 프레임, 범위 밖이면 `nil`.
  package func pageFrame(at index: Int) -> CGRect? {
    guard self.pageSizes.indices.contains(index) else {
      return nil
    }
    let size = self.pageSizes[index]
    let x = (self.contentSize.width - size.width) / 2
    return CGRect(x: x, y: self.yOffsets[index], width: size.width, height: size.height)
  }

  /// 콘텐츠 Y 좌표가 속한(또는 가장 가까운) 페이지 인덱스. O(log n) 이진 탐색.
  /// 간격(spacing) 위는 다음 페이지로 귀속, 범위 밖은 0 / pageCount−1로 클램프.
  /// 빈 문서는 `nil`.
  /// - Parameter y: 조회할 콘텐츠 공간 Y 좌표.
  /// - Returns: 귀속 페이지 인덱스, 빈 문서면 `nil`.
  package func pageIndex(forContentY y: CGFloat) -> Int? {
    guard self.pageCount > 0 else {
      return nil
    }
    var low = 0
    var high = self.pageCount
    while low < high {
      let mid = (low + high) / 2
      if self.yOffsets[mid] <= y {
        low = mid + 1
      } else {
        high = mid
      }
    }
    let index = max(0, low - 1)
    let bottom = self.yOffsets[index] + self.pageSizes[index].height
    return y > bottom ? min(index + 1, self.pageCount - 1) : index
  }

  /// 콘텐츠 공간 사각형과 교차하는 페이지 범위. O(log n).
  /// 교차 페이지가 없으면(간격 위 등) 가장 가까운 페이지 1개 범위, 빈 문서는 0..<0.
  /// - Parameter rect: 조회할 콘텐츠 공간 사각형.
  /// - Returns: 겹치는 페이지 인덱스 범위.
  package func visiblePageRange(in rect: CGRect) -> Range<Int> {
    guard let top = self.pageIndex(forContentY: rect.minY),
      let bottom = self.pageIndex(forContentY: rect.maxY)
    else {
      return 0..<0
    }
    let lower = min(top, bottom)
    let upper = max(top, bottom)
    return lower..<(upper + 1)
  }

  /// 콘텐츠 공간 사각형을 페이지 표시 공간(좌상단 원점, pt)으로 옮긴 교차 사각형.
  /// 교차가 없거나 인덱스 밖이면 `nil`. (가정 1: 평행이동만 — M5 좌표 규약과 직결.)
  /// - Parameters:
  ///   - pageIndex: 대상 페이지 인덱스.
  ///   - contentRect: 콘텐츠 공간 사각형.
  /// - Returns: 페이지 표시 공간의 교차 사각형, 없으면 `nil`.
  package func pageVisibleRect(pageIndex: Int, contentRect: CGRect) -> CGRect? {
    guard let frame = self.pageFrame(at: pageIndex) else {
      return nil
    }
    let intersection = frame.intersection(contentRect)
    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
      return nil
    }
    return intersection.offsetBy(dx: -frame.minX, dy: -frame.minY)
  }

  /// fit-width 줌 배율 (`viewportWidth / contentSize.width`) — 최소·초기 줌.
  /// - Parameter width: 뷰포트 폭 (pt).
  /// - Returns: fit-width 배율 (항상 유한).
  package func fitWidthScale(forViewportWidth width: CGFloat) -> CGFloat {
    guard self.contentSize.width > 0 else {
      return 1
    }
    let scale = width / self.contentSize.width
    return scale.isFinite && scale > 0 ? scale : 1
  }

  /// 현재 뷰포트 상단으로부터 위치를 포착한다 (§4.6). 빈 문서는 `nil`.
  /// - Parameters:
  ///   - viewportTopY: 뷰포트 상단의 콘텐츠 공간 Y 좌표.
  ///   - zoomScale: 현재 줌 배율.
  /// - Returns: 위치 스냅숏, 빈 문서면 `nil`.
  package func capturePosition(viewportTopY: CGFloat, zoomScale: CGFloat) -> ReaderPosition? {
    guard let index = self.pageIndex(forContentY: viewportTopY),
      let frame = self.pageFrame(at: index)
    else {
      return nil
    }
    let normalized: CGFloat =
      frame.height > 0
      ? min(max((viewportTopY - frame.minY) / frame.height, 0), 1)
      : 0
    return ReaderPosition(pageIndex: index, normalizedOffset: normalized, zoomScale: zoomScale)
  }

  /// 위치를 콘텐츠 Y 오프셋으로 되돌린다 (§4.6, 인덱스·오프셋 클램프).
  /// - Parameter position: 되돌릴 위치 스냅숏.
  /// - Returns: 콘텐츠 공간 Y 오프셋.
  package func contentY(for position: ReaderPosition) -> CGFloat {
    guard self.pageCount > 0 else {
      return ReaderLayoutMetrics.verticalInset
    }
    let index = min(max(position.pageIndex, 0), self.pageCount - 1)
    guard let frame = self.pageFrame(at: index) else {
      return ReaderLayoutMetrics.verticalInset
    }
    let offset = min(max(position.normalizedOffset, 0), 1)
    return frame.minY + offset * frame.height
  }

  /// 페이지 크기를 위생 범위로 클램프한다 (비유한값은 하한으로 대체).
  /// - Parameter size: 원본 크기.
  /// - Returns: 클램프된 크기.
  private static func sanitize(_ size: CGSize) -> CGSize {
    CGSize(width: Self.clampSide(size.width), height: Self.clampSide(size.height))
  }

  /// 한 변 길이를 `pageSideBounds`로 클램프한다.
  /// - Parameter value: 원본 길이.
  /// - Returns: 클램프된 길이.
  private static func clampSide(_ value: CGFloat) -> CGFloat {
    guard value.isFinite else {
      return ReaderLayoutMetrics.pageSideBounds.lowerBound
    }
    return min(
      max(value, ReaderLayoutMetrics.pageSideBounds.lowerBound),
      ReaderLayoutMetrics.pageSideBounds.upperBound
    )
  }
}
