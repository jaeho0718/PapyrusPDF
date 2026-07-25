import CoreGraphics
import Foundation

/// 렌더 산출물: 타일 하나. 담긴 `CGImage`는 불변이다 (SDK가 이미 `CGImage: Sendable`을
/// 선언하므로 `@unchecked` 없이 통과한다 — 담긴 이미지는 생성 후 변형되지 않는다).
package struct RenderedTile: Sendable {
  /// 타일 식별자.
  package let key: TileKey

  /// 래스터 이미지 (불변, 스레드 안전).
  package let image: CGImage

  /// 이 타일이 커버하는 페이지 표시 공간 사각형 (좌상단 원점, pt) — M6 레이어 배치 입력.
  package let pointRect: CGRect

  /// 캐시 비용 (`bytesPerRow × height` — 실제 백킹 바이트).
  package let cost: Int

  /// 렌더 산출물을 생성한다.
  /// - Parameters:
  ///   - key: 타일 식별자.
  ///   - image: 래스터 이미지.
  ///   - pointRect: 이 타일이 커버하는 페이지 표시 공간 사각형.
  ///   - cost: 캐시 비용 (바이트).
  package init(key: TileKey, image: CGImage, pointRect: CGRect, cost: Int) {
    self.key = key
    self.image = image
    self.pointRect = pointRect
    self.cost = cost
  }
}

/// 렌더 산출물: 페이지 프리뷰 (저해상도 전체 페이지).
package struct RenderedPreview: Sendable {
  /// 페이지 인덱스.
  package let pageIndex: Int

  /// 래스터 이미지.
  package let image: CGImage

  /// 캐시 비용.
  package let cost: Int

  /// 렌더 산출물을 생성한다.
  /// - Parameters:
  ///   - pageIndex: 페이지 인덱스.
  ///   - image: 래스터 이미지.
  ///   - cost: 캐시 비용 (바이트).
  package init(pageIndex: Int, image: CGImage, cost: Int) {
    self.pageIndex = pageIndex
    self.image = image
    self.cost = cost
  }
}

/// 렌더링 실패입니다. 손상된 문서에서도 크래시·행 없이 이 에러로 수렴합니다
/// (패키지 불변식).
public enum RenderError: Error, Sendable, Equatable {
  /// CGPDFDocument 생성에 실패했습니다 — CG가 문서를 해석하지 못한 경우입니다 (영구적).
  case documentUnavailable
  /// 해당 인덱스의 페이지가 CG 문서에 없습니다 (파서 페이지 수 > CG 페이지 수인 손상 파일).
  case pageUnavailable(pageIndex: Int)
  /// 비트맵 컨텍스트·이미지 생성에 실패했습니다 (메모리 고갈 등).
  case imageCreationFailed
  /// 시작 전 취소됐습니다 (태스크 취소 또는 뷰포트 이탈 폐기).
  case cancelled
}

/// CGPDFDocument 하나를 독점 소유하고 래스터화를 수행하는 액터.
///
/// CG 객체(CGPDFDocument/CGPDFPage/CGContext)는 절대 액터 밖으로 나가지 않는다 —
/// 반환은 불변 `CGImage`를 담은 값 타입뿐이다 (ARCHITECTURE 109행).
/// 문서는 첫 렌더 시 지연 생성하고, 생성 실패는 영구 메모이즈한다 (가정 8).
package actor RenderWorker {
  /// 원본 PDF 바이트 (매핑 공유, 무복사).
  private let documentData: Data

  /// 디스플레이 배율 (인스턴스 수명 동안 고정).
  private let pixelScale: CGFloat

  /// 지연 생성된 CG 문서 (성공 시 메모이즈).
  private var document: CGPDFDocument?

  /// 문서 생성이 이미 실패했는지 (영구 메모이즈 — 가정 8).
  private var documentCreationFailed = false

  /// 워커를 만든다. 이 시점에는 CG 문서를 만들지 않는다 (지연 생성).
  /// - Parameters:
  ///   - documentData: 원본 PDF 바이트 (`PDFDocumentCore.sourceBytes` — 매핑 공유, 무복사).
  ///   - pixelScale: 디스플레이 배율 (가정 4 — 인스턴스 수명 동안 고정).
  package init(documentData: Data, pixelScale: CGFloat) {
    self.documentData = documentData
    self.pixelScale = pixelScale
  }

  /// 타일 하나를 렌더한다 (§3.2 알고리즘).
  /// - Parameters:
  ///   - key: 타일 식별자.
  ///   - pageSize: 페이지 표시 크기 (파서 진실 원천 — 가정 5).
  /// - Throws: ``RenderError``.
  /// - Returns: 렌더된 타일.
  package func renderTile(key: TileKey, pageSize: CGSize) throws(RenderError) -> RenderedTile {
    guard !Task.isCancelled else {
      throw .cancelled
    }
    let document = try self.resolvedDocument()
    guard let page = document.page(at: key.pageIndex + 1) else {
      throw .pageUnavailable(pageIndex: key.pageIndex)
    }
    let grid = TileGrid(pageSize: pageSize, scaleBucket: key.scaleBucket)
    guard let tileRect = grid.tileRect(col: key.col, row: key.row) else {
      throw .pageUnavailable(pageIndex: key.pageIndex)
    }

    let scale = key.scaleBucket.scale * self.pixelScale
    let pixelWidth = max(1, Int((tileRect.width * scale).rounded()))
    let pixelHeight = max(1, Int((tileRect.height * scale).rounded()))
    guard let context = Self.makeBitmapContext(width: pixelWidth, height: pixelHeight) else {
      throw .imageCreationFailed
    }
    Self.fillWhite(context, width: pixelWidth, height: pixelHeight)

    // ctx는 좌하단 원점. 타일의 좌하단 모서리는 페이지 표시 공간(좌상단 원점)의
    // (tileRect.minX, tileRect.maxY) → 좌하단 기준 y = pageSize.height − tileRect.maxY.
    context.translateBy(x: -tileRect.minX * scale, y: -(pageSize.height - tileRect.maxY) * scale)
    context.scaleBy(x: scale, y: scale)
    Self.drawPage(page, into: context, pageSize: pageSize)

    guard let image = context.makeImage() else {
      throw .imageCreationFailed
    }
    return RenderedTile(
      key: key, image: image, pointRect: tileRect, cost: context.bytesPerRow * pixelHeight
    )
  }

  /// 페이지 프리뷰를 렌더한다 (최장변 `RenderingLimits.previewMaxPixelDimension` px).
  /// - Parameters:
  ///   - pageIndex: 페이지 인덱스 (0 기반).
  ///   - pageSize: 페이지 표시 크기 (파서 진실 원천 — 가정 5).
  /// - Throws: ``RenderError``.
  /// - Returns: 렌더된 프리뷰.
  package func renderPreview(
    pageIndex: Int, pageSize: CGSize
  ) throws(RenderError) -> RenderedPreview {
    guard !Task.isCancelled else {
      throw .cancelled
    }
    let longestSide = max(pageSize.width, pageSize.height)
    guard longestSide > 0 else {
      throw .imageCreationFailed
    }
    let fit = CGFloat(RenderingLimits.previewMaxPixelDimension) / longestSide
    return try self.renderFullPage(pageIndex: pageIndex, pageSize: pageSize, pixelsPerPoint: fit)
  }

  /// 페이지 전체를 OCR 등 외부 처리용 이미지로 렌더한다 (§7.2 — `PageImageRenderer`의
  /// 유일한 소비 지점).
  ///
  /// `scale`이 유한한 양수가 아니면 `PageImageRenderer.defaultScale`로 교정하고, 산출
  /// 픽셀 최장변은 `RenderingLimits.fullPageImageMaxPixelDimension`으로 자동 클램프한다 —
  /// 어떤 배율 입력도 실패나 과도한 메모리를 만들지 않는다.
  /// - Parameters:
  ///   - pageIndex: 페이지 인덱스 (0 기반).
  ///   - pageSize: 페이지 표시 크기 (파서 진실 원천 — 가정 5).
  ///   - scale: 표시 크기(pt)당 픽셀 수 요청값 (위생 검사 전).
  /// - Throws: ``RenderError``.
  /// - Returns: 렌더된 페이지 전체 이미지 (`RenderedPreview`의 페이지 인덱스·이미지·비용
  ///   형태를 그대로 재사용한다).
  package func renderPageImage(
    pageIndex: Int, pageSize: CGSize, scale: CGFloat
  ) throws(RenderError) -> RenderedPreview {
    guard !Task.isCancelled else {
      throw .cancelled
    }
    let longestSide = max(pageSize.width, pageSize.height)
    guard longestSide > 0 else {
      throw .imageCreationFailed
    }
    let sanitizedScale = (scale.isFinite && scale > 0) ? scale : PageImageRenderer.defaultScale
    let clampedScale = min(
      sanitizedScale, CGFloat(RenderingLimits.fullPageImageMaxPixelDimension) / longestSide
    )
    return try self.renderFullPage(
      pageIndex: pageIndex, pageSize: pageSize, pixelsPerPoint: clampedScale
    )
  }

  /// `renderPreview`·`renderPageImage`의 공통부 — 문서 해석→페이지 조회→컨텍스트
  /// 생성→흰 배경 채움→배율 적용→페이지 드로잉→이미지화. 두 호출자는 배율 계산만
  /// 달리해 이 헬퍼에 위임한다 (로직 한 벌 원칙).
  /// - Parameters:
  ///   - pageIndex: 페이지 인덱스 (0 기반).
  ///   - pageSize: 페이지 표시 크기.
  ///   - pixelsPerPoint: 호출자가 이미 결정한(위생 검사·클램프 완료) 최종 배율.
  /// - Throws: ``RenderError``.
  /// - Returns: 렌더된 페이지 전체 이미지.
  private func renderFullPage(
    pageIndex: Int, pageSize: CGSize, pixelsPerPoint: CGFloat
  ) throws(RenderError) -> RenderedPreview {
    let document = try self.resolvedDocument()
    guard let page = document.page(at: pageIndex + 1) else {
      throw .pageUnavailable(pageIndex: pageIndex)
    }

    let pixelWidth = max(1, Int((pageSize.width * pixelsPerPoint).rounded()))
    let pixelHeight = max(1, Int((pageSize.height * pixelsPerPoint).rounded()))
    guard let context = Self.makeBitmapContext(width: pixelWidth, height: pixelHeight) else {
      throw .imageCreationFailed
    }
    Self.fillWhite(context, width: pixelWidth, height: pixelHeight)

    context.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
    Self.drawPage(page, into: context, pageSize: pageSize)

    guard let image = context.makeImage() else {
      throw .imageCreationFailed
    }
    return RenderedPreview(
      pageIndex: pageIndex, image: image, cost: context.bytesPerRow * pixelHeight
    )
  }

  /// CG 문서를 지연 생성하고 실패를 영구 메모이즈한다 (가정 8).
  private func resolvedDocument() throws(RenderError) -> CGPDFDocument {
    if self.documentCreationFailed {
      throw .documentUnavailable
    }
    if let document {
      return document
    }
    guard let provider = CGDataProvider(data: self.documentData as CFData),
      let newDocument = CGPDFDocument(provider),
      !(newDocument.isEncrypted && !newDocument.isUnlocked)
    else {
      self.documentCreationFailed = true
      throw .documentUnavailable
    }
    self.document = newDocument
    return newDocument
  }

  /// 페이지를 표시 사각형(`pageSize`)에 비율 유지로 맞춰(fit) 그린다 — 파서 cropBox가
  /// 진실 원천이고 CG cropBox와 어긋나면 여백으로 흡수한다 (가정 5).
  private static func drawPage(_ page: CGPDFPage, into context: CGContext, pageSize: CGSize) {
    let transform = page.getDrawingTransform(
      .cropBox, rect: CGRect(origin: .zero, size: pageSize), rotate: 0, preserveAspectRatio: true
    )
    context.concatenate(transform)
    context.drawPDFPage(page)
  }

  /// 불투명 sRGB 비트맵 컨텍스트를 만든다 (8bit/채널, 4바이트/픽셀).
  private static func makeBitmapContext(width: Int, height: Int) -> CGContext? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      return nil
    }
    let bitmapInfo =
      CGImageAlphaInfo.noneSkipFirst.rawValue | CGImageByteOrderInfo.order32Host.rawValue
    return CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace, bitmapInfo: bitmapInfo
    )
  }

  /// 흰색으로 채운다 (PDF 관례 배경 — 타일 불투명이 합성 비용도 최소).
  private static func fillWhite(_ context: CGContext, width: Int, height: Int) {
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  }
}
