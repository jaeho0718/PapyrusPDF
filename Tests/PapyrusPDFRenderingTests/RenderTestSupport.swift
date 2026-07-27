import CoreGraphics
@testable import PapyrusPDFRendering

/// 캐시·스케줄러 유닛 테스트 전용 최소 `CGImage` 생성 헬퍼 (실제 렌더 없이 비용 있는
/// `RenderedTile`/`RenderedPreview`를 조립하기 위함).
enum RenderTestSupport {
  /// `size` × `size` 픽셀의 단색 비트맵 이미지를 만든다 (테스트 값 조립용).
  static func makeImage(size: Int = 4) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
      CGImageAlphaInfo.noneSkipFirst.rawValue | CGImageByteOrderInfo.order32Host.rawValue
    guard let context = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace, bitmapInfo: bitmapInfo
    ), let image = context.makeImage() else {
      preconditionFailure("test-only bitmap creation must succeed")
    }
    return image
  }

  /// 지정한 비용의 타일 하나를 만든다 (키·사각형은 임의값 — 캐시 로직만 검증 대상).
  static func makeTile(
    pageIndex: Int = 0, col: Int = 0, row: Int = 0, cost: Int
  ) -> RenderedTile {
    let key = TileKey(
      pageIndex: pageIndex, scaleBucket: ScaleBucket(exponent: 0), col: col, row: row
    )
    return RenderedTile(
      key: key, image: self.makeImage(), pointRect: CGRect(x: 0, y: 0, width: 512, height: 512),
      cost: cost
    )
  }

  /// 지정한 비용의 프리뷰 하나를 만든다.
  static func makePreview(pageIndex: Int = 0, cost: Int) -> RenderedPreview {
    RenderedPreview(pageIndex: pageIndex, image: self.makeImage(), cost: cost)
  }
}
