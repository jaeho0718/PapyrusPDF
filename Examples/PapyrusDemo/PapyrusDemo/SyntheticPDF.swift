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

  /// 페이지별로 결정적으로 달라지는 본문 문장 후보 (OCR 시나리오에서 특정 페이지만
  /// 매치되는 검색을 확인할 수 있도록 고정 배열 + 페이지 번호 조합을 쓴다).
  private static let bodySentences = [
    "Papyrus renders large PDF documents without loading the whole file into memory.",
    "Optical character recognition connects scanned pages back to searchable text.",
    "Selection, search, and highlighting all read from the same text provider.",
    "Vision recognizes text from a rendered page image, one page at a time.",
    "Every recognized line becomes a text run with a page-space quadrilateral.",
    "The demo app exercises this pipeline end to end on a synthetic document."
  ]

  /// 내장 텍스트가 전혀 없는 "스캔 문서" 합성 PDF를 만든다 — 각 페이지를 비트맵으로
  /// 먼저 그린 뒤 그 이미지를 PDF 페이지에 붙인다 (텍스트 연산자 미포함 → OCR 경로 강제).
  /// - Parameter pageCount: 생성할 페이지 수 (OCR은 페이지당 비용이 크므로 소수 권장).
  /// - Returns: 생성된 PDF 바이트.
  static func makeScanned(pageCount: Int) -> Data {
    let output = NSMutableData()
    guard let consumer = CGDataConsumer(data: output) else {
      preconditionFailure("Failed to create a PDF data consumer.")
    }
    let pageWidth: CGFloat = 612
    let pageHeight: CGFloat = 792
    var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
    guard let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
      preconditionFailure("Failed to create a PDF context.")
    }

    let pageSize = CGSize(width: pageWidth, height: pageHeight)
    for pageIndex in 0..<pageCount {
      let image = Self.makeScannedPageImage(pageIndex: pageIndex, size: pageSize)
      pdfContext.beginPDFPage(nil)
      pdfContext.draw(image, in: CGRect(origin: .zero, size: pageSize))
      pdfContext.endPDFPage()
    }
    pdfContext.closePDF()
    return output as Data
  }

  /// 스캔 페이지 하나를 비트맵(2배 해상도)으로 그려 `CGImage`로 반환한다.
  /// - Parameters:
  ///   - pageIndex: 페이지 인덱스 (0 기반 — 표시 번호는 +1).
  ///   - size: 페이지 크기 (pt).
  /// - Returns: 텍스트가 래스터화된 페이지 이미지.
  private static func makeScannedPageImage(pageIndex: Int, size: CGSize) -> CGImage {
    let scale: CGFloat = 2
    let pixelWidth = Int(size.width * scale)
    let pixelHeight = Int(size.height * scale)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard
      let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else {
      preconditionFailure("Failed to create a bitmap context for the scanned page.")
    }
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(origin: .zero, size: size))

    Self.drawScannedHeader(pageIndex, into: context, size: size)
    Self.drawScannedBody(pageIndex, into: context, size: size)

    guard let image = context.makeImage() else {
      preconditionFailure("Failed to rasterize the scanned page.")
    }
    return image
  }

  /// "Scanned page N" 헤더를 페이지 상단에 그린다.
  private static func drawScannedHeader(_ pageIndex: Int, into context: CGContext, size: CGSize) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 22, nil)
    let attributed = NSAttributedString(
      string: "Scanned page \(pageIndex + 1)",
      attributes: [.font: font, .foregroundColor: CGColor(gray: 0.1, alpha: 1)]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    context.saveGState()
    context.textPosition = CGPoint(x: 56, y: size.height - 80)
    CTLineDraw(line, context)
    context.restoreGState()
  }

  /// 본문 4~6줄을 페이지별로 결정적으로 선택해 그린다 (18pt — Vision이 안정적으로
  /// 읽는 크기).
  private static func drawScannedBody(_ pageIndex: Int, into context: CGContext, size: CGSize) {
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    let lineCount = 4 + pageIndex % 3
    var y = size.height - 140
    for line in 0..<lineCount {
      let sentence = Self.bodySentences[(pageIndex + line) % Self.bodySentences.count]
      let text = "\(sentence) (page \(pageIndex + 1), line \(line + 1))"
      let attributed = NSAttributedString(
        string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0.15, alpha: 1)]
      )
      let ctLine = CTLineCreateWithAttributedString(attributed)
      context.saveGState()
      context.textPosition = CGPoint(x: 56, y: y)
      CTLineDraw(ctLine, context)
      context.restoreGState()
      y -= 32
    }
  }
}
