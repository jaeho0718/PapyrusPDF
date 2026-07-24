import CoreGraphics

extension PageInfo {
  /// PDF 페이지 공간 → 표시 공간(좌상단 원점, y-아래, ``displaySize`` 기준) 변환입니다.
  ///
  /// ``SearchResult/quads`` 등 페이지 공간 quad를 화면 배치 좌표로 옮길 때 사용합니다.
  public var displayTransform: CGAffineTransform {
    PageDisplayTransform.transform(cropBox: self.cropBox, rotation: self.rotation)
  }

  /// 정규화(0...1) 표시 공간 사각형을 PDF 페이지 공간 quad로 변환합니다.
  ///
  /// 페이지를 ``displaySize`` 비율로 렌더한 이미지 위의 OCR 박스를 매핑할 때
  /// 사용합니다. **주의: Vision의 정규화 좌표는 y-위(원점 좌하단)입니다** — 전달 전에
  /// `y' = 1 - y - height`로 뒤집어야 합니다.
  ///
  /// ```swift
  /// // Vision VNRecognizedTextObservation.boundingBox (y-위, 원점 좌하단)를
  /// // 표시 공간 정규화 rect(y-아래, 원점 좌상단)로 뒤집은 뒤 전달합니다.
  /// let visionBox = observation.boundingBox
  /// let displayRect = CGRect(
  ///   x: visionBox.minX, y: 1 - visionBox.minY - visionBox.height,
  ///   width: visionBox.width, height: visionBox.height
  /// )
  /// let quad = pageInfo.pageQuad(normalizedDisplayRect: displayRect)
  /// ```
  ///
  /// 비유한 좌표가 섞인 rect는 영점 quad를 반환합니다. 0...1을 살짝 벗어나는 값은
  /// 클램프하지 않고 그대로 매핑합니다.
  /// - Parameter rect: 정규화(0...1) 표시 공간 사각형입니다.
  /// - Returns: PDF 페이지 공간 quad입니다.
  public func pageQuad(normalizedDisplayRect rect: CGRect) -> Quad {
    let standardized = rect.standardized
    guard standardized.minX.isFinite, standardized.minY.isFinite, standardized.maxX.isFinite,
      standardized.maxY.isFinite
    else {
      return Quad(rect: .zero)
    }

    let size = self.displaySize
    let width = size.width
    let height = size.height
    let bottomLeft = CGPoint(x: standardized.minX * width, y: standardized.maxY * height)
    let bottomRight = CGPoint(x: standardized.maxX * width, y: standardized.maxY * height)
    let topRight = CGPoint(x: standardized.maxX * width, y: standardized.minY * height)
    let topLeft = CGPoint(x: standardized.minX * width, y: standardized.minY * height)

    let inverse = self.displayTransform.inverted()
    return Quad(
      bottomLeft: bottomLeft.applying(inverse), bottomRight: bottomRight.applying(inverse),
      topRight: topRight.applying(inverse), topLeft: topLeft.applying(inverse)
    )
  }
}
