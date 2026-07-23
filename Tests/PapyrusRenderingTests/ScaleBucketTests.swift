import CoreGraphics
@testable import PapyrusRendering
import Testing

/// ``ScaleBucket``의 스냅·클램프·왕복 정확도를 검증한다 (설계 §5 SB1).
struct ScaleBucketTests {
  /// SB1: 정수 배율 1.0은 지수 0으로 스냅된다.
  @Test func snappingUnitScaleYieldsExponentZero() {
    let bucket = ScaleBucket(snapping: 1.0)
    #expect(bucket.exponent == 0)
  }

  /// SB1: √2 근방 배율은 지수 1로 스냅된다 (부동소수 오차 허용).
  @Test func snappingSqrtTwoYieldsExponentOne() {
    let bucket = ScaleBucket(snapping: CGFloat(2.0.squareRoot()) + 0.001)
    #expect(bucket.exponent == 1)
  }

  /// SB1: 0.7 배율은 지수 -1로 스냅된다 (2^(-1/2) ≈ 0.707).
  @Test func snappingBelowUnitScaleYieldsNegativeExponent() {
    let bucket = ScaleBucket(snapping: 0.7)
    #expect(bucket.exponent == -1)
  }

  /// SB1: 범위 밖 지수는 정책 상·하한으로 클램프된다.
  @Test func exponentOutOfRangeClampsToPolicyBounds() {
    #expect(ScaleBucket(exponent: -100).exponent == RenderingLimits.minScaleExponent)
    #expect(ScaleBucket(exponent: 100).exponent == RenderingLimits.maxScaleExponent)
  }

  /// SB1: 0 이하·비유한 배율은 지수 0으로 관용 처리된다.
  @Test func nonPositiveOrNonFiniteScaleFallsBackToExponentZero() {
    #expect(ScaleBucket(snapping: 0).exponent == 0)
    #expect(ScaleBucket(snapping: -5).exponent == 0)
    #expect(ScaleBucket(snapping: .nan).exponent == 0)
    #expect(ScaleBucket(snapping: .infinity).exponent == 0)
  }

  /// SB1: `scale`의 왕복 오차가 1e-9 미만이다 (지수 → 배율 → 재스냅 → 동일 지수).
  @Test func scaleRoundTripsWithinTolerance() {
    for exponent in RenderingLimits.minScaleExponent...RenderingLimits.maxScaleExponent {
      let bucket = ScaleBucket(exponent: exponent)
      let resnapped = ScaleBucket(snapping: bucket.scale)
      #expect(resnapped.exponent == exponent)
    }
  }

  /// 지수 오름차순이 배율 오름차순과 동치임을 확인한다 (`Comparable` 계약).
  @Test func comparisonOrdersByExponent() {
    #expect(ScaleBucket(exponent: -1) < ScaleBucket(exponent: 0))
    #expect(ScaleBucket(exponent: 0) < ScaleBucket(exponent: 2))
  }
}
