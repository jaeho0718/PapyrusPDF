import CoreGraphics
import CoreText
import Foundation

/// `CGContext(consumer:mediaBox:_:)` 기반 합성 PDF 생성기 (M6 설계 가정 10).
///
/// 데모 앱은 `PapyrusTestSupport`를 쓸 수 없으므로(제품 비노출 타겟), 5,000페이지
/// 스트레스 문서는 CG의 PDF 그리기 API로 직접 생성한다 — 픽스처 빌더 재구현이 아니라
/// CG 위임이라 수십 줄로 끝난다. 각 페이지는 페이지 번호 대형 텍스트 + 100pt 격자
/// 도형을 그려 타일 경계(512pt 화면 커버리지)를 스크롤하며 눈으로 확인할 수 있게 한다.
enum SyntheticPDF {
  /// 지정한 페이지 수의 합성 PDF를 만든다.
  /// - Parameters:
  ///   - pageCount: 생성할 페이지 수.
  ///   - pageWidth: 페이지 폭 (pt, 기본 US Letter 612).
  ///   - pageHeight: 페이지 높이 (pt, 기본 US Letter 792).
  /// - Returns: 생성된 PDF 바이트.
  static func make(pageCount: Int, pageWidth: CGFloat = 612, pageHeight: CGFloat = 792) -> Data {
    let output = NSMutableData()
    guard let consumer = CGDataConsumer(data: output) else {
      preconditionFailure("Failed to create a PDF data consumer.")
    }
    var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
      preconditionFailure("Failed to create a PDF context.")
    }

    let pageSize = CGSize(width: pageWidth, height: pageHeight)
    for pageIndex in 0..<pageCount {
      context.beginPDFPage(nil)
      Self.draw(pageIndex: pageIndex, into: context, size: pageSize)
      context.endPDFPage()
    }
    context.closePDF()
    return output as Data
  }

  /// 페이지 하나(격자 + 페이지 번호)를 그린다.
  /// - Parameters:
  ///   - pageIndex: 페이지 인덱스 (0 기반 — 표시 번호는 +1).
  ///   - context: 그릴 PDF 컨텍스트.
  ///   - size: 페이지 크기.
  private static func draw(pageIndex: Int, into context: CGContext, size: CGSize) {
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))

    Self.drawGrid(into: context, size: size)
    Self.drawPageNumber(pageIndex, into: context, size: size)
  }

  /// 타일 경계 눈검증용 100pt 격자선을 그린다.
  private static func drawGrid(into context: CGContext, size: CGSize) {
    context.setStrokeColor(CGColor(red: 0.75, green: 0.8, blue: 0.95, alpha: 1))
    context.setLineWidth(1)
    let spacing: CGFloat = 100
    var x = spacing
    while x < size.width {
      context.move(to: CGPoint(x: x, y: 0))
      context.addLine(to: CGPoint(x: x, y: size.height))
      x += spacing
    }
    var y = spacing
    while y < size.height {
      context.move(to: CGPoint(x: 0, y: y))
      context.addLine(to: CGPoint(x: size.width, y: y))
      y += spacing
    }
    context.strokePath()
  }

  /// 페이지 중앙에 큼직한 페이지 번호를 그린다 (스크롤 중 위치 파악용).
  private static func drawPageNumber(_ pageIndex: Int, into context: CGContext, size: CGSize) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 160, nil)
    let attributed = NSAttributedString(
      string: "\(pageIndex + 1)",
      attributes: [.font: font, .foregroundColor: CGColor(gray: 0.15, alpha: 1)]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, [])

    context.saveGState()
    context.textPosition = CGPoint(
      x: (size.width - bounds.width) / 2 - bounds.minX,
      y: (size.height - bounds.height) / 2 - bounds.minY
    )
    CTLineDraw(line, context)
    context.restoreGState()
  }
}
