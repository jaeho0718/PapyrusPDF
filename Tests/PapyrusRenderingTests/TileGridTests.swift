import CoreGraphics
@testable import PapyrusRendering
import Testing

/// ``TileGrid``의 격자 수학을 검증한다 (설계 §5 TG1, TG2).
struct TileGridTests {
  /// TG1: 612×792 페이지, exp 0(scale 1) — 열 2·행 2, 가장자리 클립, 무겹침 합집합.
  @Test func exponentZeroGridHasTwoByTwoTilesCoveringPageExactly() {
    let grid = TileGrid(
      pageSize: CGSize(width: 612, height: 792), scaleBucket: ScaleBucket(exponent: 0)
    )
    #expect(grid.columns == 2)
    #expect(grid.rows == 2)

    var unionArea: CGFloat = 0
    var rects: [CGRect] = []
    for row in 0..<grid.rows {
      for col in 0..<grid.columns {
        guard let rect = grid.tileRect(col: col, row: row) else {
          Issue.record("expected a tile rect at (\(col), \(row))")
          continue
        }
        rects.append(rect)
        unionArea += rect.width * rect.height
      }
    }
    // 겹침 없음: 사각형 쌍이 서로 교차 면적을 갖지 않는다.
    for i in rects.indices {
      for j in rects.indices where j > i {
        let intersection = rects[i].intersection(rects[j])
        #expect(intersection.isNull || intersection.width == 0 || intersection.height == 0)
      }
    }
    // 합집합 면적이 페이지 면적과 같다 (무겹침 타일링이므로 면적 합 == 전체 면적).
    #expect(abs(unionArea - 612 * 792) < 0.0001)

    // 가장자리 타일은 페이지 경계로 클립된다.
    let edgeTile = grid.tileRect(col: 1, row: 1)
    #expect(edgeTile?.maxX == 612)
    #expect(edgeTile?.maxY == 792)
  }

  /// 격자 밖 (col, row)은 nil.
  @Test func outOfBoundsTileRectReturnsNil() {
    let grid = TileGrid(
      pageSize: CGSize(width: 612, height: 792), scaleBucket: ScaleBucket(exponent: 0)
    )
    #expect(grid.tileRect(col: 2, row: 0) == nil)
    #expect(grid.tileRect(col: 0, row: 2) == nil)
    #expect(grid.tileRect(col: -1, row: 0) == nil)
  }

  /// TG2: exp 2(scale 2) — tileSideInPoints 256, 열 3·행 4.
  @Test func exponentTwoGridHasExpectedTileSideAndCount() {
    let grid = TileGrid(
      pageSize: CGSize(width: 612, height: 792), scaleBucket: ScaleBucket(exponent: 2)
    )
    #expect(abs(grid.tileSideInPoints - 256) < 0.0001)
    #expect(grid.columns == 3)
    #expect(grid.rows == 4)
  }

  /// TG2: `tileKeys(intersecting:)`의 교차 정확성 — 사각형이 걸치는 타일만 반환된다.
  @Test func tileKeysIntersectingReturnsExactCoverage() {
    let grid = TileGrid(
      pageSize: CGSize(width: 612, height: 792), scaleBucket: ScaleBucket(exponent: 2)
    )
    // 좌상단 타일(0,0) 안쪽 한 점만 덮는 작은 사각형 — 정확히 1개 키만 나와야 한다.
    let small = CGRect(x: 10, y: 10, width: 5, height: 5)
    let keys = grid.tileKeys(intersecting: small, pageIndex: 7)
    #expect(keys.count == 1)
    #expect(keys.first?.col == 0)
    #expect(keys.first?.row == 0)
    #expect(keys.first?.pageIndex == 7)

    // 전체 페이지를 덮는 사각형 — columns × rows 전부.
    let whole = CGRect(origin: .zero, size: grid.pageSize)
    let allKeys = grid.tileKeys(intersecting: whole, pageIndex: 0)
    #expect(allKeys.count == grid.columns * grid.rows)

    // 페이지 완전히 밖의 사각형 — 빈 배열.
    let outside = CGRect(x: 10_000, y: 10_000, width: 10, height: 10)
    #expect(grid.tileKeys(intersecting: outside, pageIndex: 0).isEmpty)
  }

  /// TG2: 열거 캡(`maxTileKeysPerViewportUpdate`) 초과분은 절단된다.
  @Test func tileKeysIntersectingTruncatesAtCap() {
    // 아주 작은 타일을 만들어 격자 크기를 캡보다 훨씬 크게 부풀린다.
    let hugeExponent = RenderingLimits.maxScaleExponent
    let grid = TileGrid(
      pageSize: CGSize(width: 10_000, height: 10_000),
      scaleBucket: ScaleBucket(exponent: hugeExponent)
    )
    let whole = CGRect(origin: .zero, size: grid.pageSize)
    let keys = grid.tileKeys(intersecting: whole, pageIndex: 0)
    #expect(keys.count == RenderingLimits.maxTileKeysPerViewportUpdate)
  }
}
