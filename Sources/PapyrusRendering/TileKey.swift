import CoreGraphics

/// √2 간격 스케일 버킷. `scale = 2^(exponent / 2)`.
///
/// 핀치 중에는 M6가 레이어 transform으로 즉시 확대(흐릿)하고, 제스처 종료 시
/// 현재 줌을 여기에 스냅해 재타일링한다 (ARCHITECTURE 114행).
package struct ScaleBucket: Sendable, Hashable, Comparable {
  /// 버킷 지수. `RenderingLimits.minScaleExponent...maxScaleExponent`로 클램프됨.
  package let exponent: Int

  /// 이 버킷의 배율 (`pow(2, Double(exponent) / 2)`).
  package var scale: CGFloat {
    CGFloat(pow(2, Double(self.exponent) / 2))
  }

  /// 지수로 직접 생성한다 (범위 밖 입력은 클램프).
  /// - Parameter exponent: 버킷 지수.
  package init(exponent: Int) {
    self.exponent = Self.clamp(exponent)
  }

  /// 임의 줌 배율을 가장 가까운 버킷으로 스냅한다.
  ///
  /// `exponent = round(log2(scale) * 2)` 후 클램프. 0 이하·비유한 입력은 지수 0.
  /// - Parameter scale: 스냅할 줌 배율.
  package init(snapping scale: CGFloat) {
    guard scale.isFinite, scale > 0 else {
      self.exponent = 0
      return
    }
    let rawExponent = (log2(Double(scale)) * 2).rounded()
    self.exponent = Self.clamp(Int(rawExponent))
  }

  /// 지수를 정책 범위로 클램프한다.
  private static func clamp(_ exponent: Int) -> Int {
    min(max(exponent, RenderingLimits.minScaleExponent), RenderingLimits.maxScaleExponent)
  }

  /// 지수 오름차순 비교 (배율 오름차순과 동치).
  package static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.exponent < rhs.exponent
  }
}

/// 타일 하나의 식별자. 캐시 키이자 렌더 요청 단위다.
package struct TileKey: Sendable, Hashable {
  /// 페이지 인덱스 (0 기반).
  package let pageIndex: Int

  /// 스케일 버킷.
  package let scaleBucket: ScaleBucket

  /// 열 (0 기반, 페이지 표시 공간 좌→우).
  package let col: Int

  /// 행 (0 기반, 페이지 표시 공간 상→하 — 좌상단 원점 규약).
  package let row: Int

  /// 타일 키를 생성한다.
  /// - Parameters:
  ///   - pageIndex: 페이지 인덱스 (0 기반).
  ///   - scaleBucket: 스케일 버킷.
  ///   - col: 열 (0 기반).
  ///   - row: 행 (0 기반).
  package init(pageIndex: Int, scaleBucket: ScaleBucket, col: Int, row: Int) {
    self.pageIndex = pageIndex
    self.scaleBucket = scaleBucket
    self.col = col
    self.row = row
  }
}

/// 한 페이지×한 버킷의 타일 격자 수학 (순수 값 타입 — CG 문서 불필요, 집중 테스트 대상).
package struct TileGrid: Sendable, Equatable {
  /// 페이지 표시 크기 (pt).
  package let pageSize: CGSize

  /// 스케일 버킷.
  package let scaleBucket: ScaleBucket

  /// 타일 한 개의 페이지 공간 한 변 길이 (`tileSideLength / scale`, pt).
  package var tileSideInPoints: CGFloat {
    RenderingLimits.tileSideLength / self.scaleBucket.scale
  }

  /// 열 수 (`ceil(pageSize.width / tileSideInPoints)`, 최소 1 — 퇴화 크기 방어).
  package var columns: Int {
    Self.tileCount(forSide: self.pageSize.width, tileSide: self.tileSideInPoints)
  }

  /// 행 수 (동일 규칙).
  package var rows: Int {
    Self.tileCount(forSide: self.pageSize.height, tileSide: self.tileSideInPoints)
  }

  /// 타일 격자를 생성한다.
  /// - Parameters:
  ///   - pageSize: 페이지 표시 크기 (pt).
  ///   - scaleBucket: 스케일 버킷.
  package init(pageSize: CGSize, scaleBucket: ScaleBucket) {
    self.pageSize = pageSize
    self.scaleBucket = scaleBucket
  }

  /// 한 변 길이에 대한 타일 개수 (최소 1).
  private static func tileCount(forSide side: CGFloat, tileSide: CGFloat) -> Int {
    guard side > 0, tileSide > 0 else {
      return 1
    }
    return max(1, Int((side / tileSide).rounded(.up)))
  }

  /// 타일의 페이지 표시 공간 사각형 (좌상단 원점). 가장자리 타일은 페이지 경계로 클립됨.
  /// 격자 밖 (col, row)은 `nil`.
  /// - Parameters:
  ///   - col: 열 (0 기반).
  ///   - row: 행 (0 기반).
  /// - Returns: 페이지 표시 공간 사각형, 격자 밖이면 `nil`.
  package func tileRect(col: Int, row: Int) -> CGRect? {
    guard (0..<self.columns).contains(col), (0..<self.rows).contains(row) else {
      return nil
    }
    let side = self.tileSideInPoints
    let minX = CGFloat(col) * side
    let minY = CGFloat(row) * side
    let maxX = min(minX + side, self.pageSize.width)
    let maxY = min(minY + side, self.pageSize.height)
    return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
  }

  /// 사각형과 교차하는 타일 키 열거 (행 우선 순서, `pageIndex`는 호출자가 공급).
  ///
  /// `RenderingLimits.maxTileKeysPerViewportUpdate` 초과분은 절단한다 (폭주 가드).
  /// - Parameters:
  ///   - rect: 교차를 검사할 페이지 표시 공간 사각형.
  ///   - pageIndex: 결과 키에 채울 페이지 인덱스.
  /// - Returns: 교차하는 타일 키 목록 (행 우선, 절단 가능).
  package func tileKeys(intersecting rect: CGRect, pageIndex: Int) -> [TileKey] {
    let side = self.tileSideInPoints
    guard side > 0 else {
      return []
    }
    let pageRect = CGRect(origin: .zero, size: self.pageSize)
    let clamped = rect.intersection(pageRect)
    guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
      return []
    }
    // 부동소수 경계에서 다음 타일로 새는 것을 막기 위한 미세 여유.
    let epsilon: CGFloat = 1e-6
    let minCol = max(0, Int((clamped.minX / side).rounded(.down)))
    let maxCol = min(self.columns - 1, Int(((clamped.maxX - epsilon) / side).rounded(.down)))
    let minRow = max(0, Int((clamped.minY / side).rounded(.down)))
    let maxRow = min(self.rows - 1, Int(((clamped.maxY - epsilon) / side).rounded(.down)))
    guard minCol <= maxCol, minRow <= maxRow else {
      return []
    }

    var keys: [TileKey] = []
    rowLoop: for row in minRow...maxRow {
      for col in minCol...maxCol {
        keys.append(
          TileKey(pageIndex: pageIndex, scaleBucket: self.scaleBucket, col: col, row: row)
        )
        if keys.count >= RenderingLimits.maxTileKeysPerViewportUpdate {
          break rowLoop
        }
      }
    }
    return keys
  }
}
