import CoreGraphics

/// PDF 페이지 공간 → 페이지 표시 공간(좌상단 원점, y-아래) 변환.
///
/// `c = p - cropBox.origin`, `W = cropBox.width`, `H = cropBox.height`일 때 회전별
/// 대응은 다음과 같다 (도출: 꼭짓점 대응 검증 완료).
///
/// | rotation | display.x | display.y |
/// |---|---|---|
/// | 0°   | cx     | H − cy |
/// | 90°  | cy     | cx     |
/// | 180° | W − cx | cy     |
/// | 270° | H − cy | W − cx |
package enum PageDisplayTransform {
  /// cropBox·회전으로 변환을 만든다. 반환 변환은 `Quad` 4점에 각각 적용한다.
  /// - Parameters:
  ///   - cropBox: 페이지 /CropBox (PDF 사용자 공간).
  ///   - rotation: 페이지 회전.
  /// - Returns: PDF 페이지 공간 → 페이지 표시 공간 변환.
  package static func transform(cropBox: CGRect, rotation: PageRotation) -> CGAffineTransform {
    let originX = cropBox.origin.x
    let originY = cropBox.origin.y
    let width = cropBox.width
    let height = cropBox.height
    switch rotation {
    case .degrees0:
      return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -originX, ty: height + originY)
    case .degrees90:
      return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: -originY, ty: -originX)
    case .degrees180:
      return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: originX + width, ty: -originY)
    case .degrees270:
      return CGAffineTransform(
        a: 0, b: -1, c: -1, d: 0, tx: originY + height, ty: originX + width
      )
    }
  }

  /// quad에 변환을 적용한다 (4점 개별 적용 — 꼭짓점 의미는 유지된다).
  /// - Parameters:
  ///   - transform: 적용할 변환.
  ///   - quad: 변환할 PDF 페이지 공간 quad.
  /// - Returns: 표시 공간으로 옮겨진 quad.
  package static func apply(_ transform: CGAffineTransform, to quad: Quad) -> Quad {
    Quad(
      bottomLeft: quad.bottomLeft.applying(transform),
      bottomRight: quad.bottomRight.applying(transform),
      topRight: quad.topRight.applying(transform),
      topLeft: quad.topLeft.applying(transform)
    )
  }
}
