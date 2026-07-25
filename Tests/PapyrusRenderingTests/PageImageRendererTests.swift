import CoreGraphics
import Foundation
@testable import PapyrusCore
@testable import PapyrusRendering
import PapyrusTestSupport
import Testing

/// ``PageImageRenderer``의 픽스처 스모크 테스트 (설계 §7.6, M13 증보 완료 기준).
///
/// `RenderWorkerSmokeTests`의 기법을 재사용한다 — 스냅샷 비교는 하지 않는다(OS별 CG
/// 편차) — 비-nil, 픽셀 크기, 명암 프로브, 좌표 왕복만 검증한다.
struct PageImageRendererTests {
  /// 612×792 페이지 중앙 200×200 검은 사각형 픽스처 (PDF 좌표: x 206..406, y 296..496).
  private static func centeredSquareFixtureData() -> Data {
    let body = Data("0 0 0 rg 206 296 200 200 re f".utf8)
    return PDFFixtureBuilder(
      pageCount: 1, pageWidth: 612, pageHeight: 792, contentStream: .init(body: body)
    ).build().data
  }

  /// `CGImage`의 (x, y) 픽셀에서 알파(스킵) 바이트를 제외한 3개 색상 채널을 읽는다.
  private static func colorChannels(of image: CGImage, x: Int, y: Int) -> [UInt8] {
    guard let data = image.dataProvider?.data as Data? else {
      return []
    }
    let bytesPerRow = image.bytesPerRow
    let bytesPerPixel = image.bitsPerPixel / 8
    let offset = y * bytesPerRow + x * bytesPerPixel
    guard offset + 3 <= data.count else {
      return []
    }
    return Array(data[offset..<(offset + 3)])
  }

  /// 세 채널 전부 임계값 미만(어두움)인지.
  private static func isDark(_ channels: [UInt8], threshold: UInt8 = 64) -> Bool {
    !channels.isEmpty && channels.allSatisfy { $0 < threshold }
  }

  /// 세 채널 전부 임계값 초과(밝음)인지.
  private static func isLight(_ channels: [UInt8], threshold: UInt8 = 240) -> Bool {
    !channels.isEmpty && channels.allSatisfy { $0 > threshold }
  }

  /// 이미지 전체를 스캔해 어두운 픽셀의 경계 사각형을 찾는다 (표시 공간 픽셀 좌표,
  /// 좌상단 원점). 어두운 픽셀이 없으면 `nil`.
  private static func darkBoundingBox(in image: CGImage) -> CGRect? {
    guard let data = image.dataProvider?.data as Data? else {
      return nil
    }
    let bytesPerRow = image.bytesPerRow
    let bytesPerPixel = image.bitsPerPixel / 8
    var minX = image.width
    var maxX = -1
    var minY = image.height
    var maxY = -1
    for y in 0..<image.height {
      for x in 0..<image.width {
        let offset = y * bytesPerRow + x * bytesPerPixel
        guard offset + 3 <= data.count else {
          continue
        }
        if Self.isDark(Array(data[offset..<(offset + 3)])) {
          minX = min(minX, x)
          maxX = max(maxX, x)
          minY = min(minY, y)
          maxY = max(maxY, y)
        }
      }
    }
    guard maxX >= minX, maxY >= minY else {
      return nil
    }
    return CGRect(
      x: CGFloat(minX), y: CGFloat(minY),
      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1)
    )
  }

  /// 부동소수 근사 비교.
  private static func expectClose(_ value: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 3) {
    #expect(abs(value - expected) < tolerance)
  }

  // MARK: 1 — 크기·배율

  /// scale 1/3에서 픽셀 크기가 `displaySize`의 정수배로 일치한다.
  @Test func imageSizeScalesWithRequestedScale() async throws {
    let document = try await PapyrusDocument.open(data: Self.centeredSquareFixtureData())
    let pageInfo = try await document.page(at: 0)
    let renderer = PageImageRenderer(document: document)

    let atScale1 = try await renderer.image(forPage: 0, scale: 1)
    #expect(atScale1.width == Int(pageInfo.displaySize.width.rounded()))
    #expect(atScale1.height == Int(pageInfo.displaySize.height.rounded()))

    let atScale3 = try await renderer.image(forPage: 0, scale: 3)
    #expect(atScale3.width == Int((pageInfo.displaySize.width * 3).rounded()))
    #expect(atScale3.height == Int((pageInfo.displaySize.height * 3).rounded()))
  }

  /// 과대 배율은 최장변 상한(`RenderingLimits.fullPageImageMaxPixelDimension`)으로 클램프된다.
  @Test func hugeScaleClampsToFullPageImageMaxPixelDimension() async throws {
    let document = try await PapyrusDocument.open(data: Self.centeredSquareFixtureData())
    let renderer = PageImageRenderer(document: document)

    let image = try await renderer.image(forPage: 0, scale: 10_000)

    let longestSide = max(image.width, image.height)
    #expect(longestSide == RenderingLimits.fullPageImageMaxPixelDimension)
  }

  /// 비유한·0 이하 배율은 기본 배율(``PageImageRenderer/defaultScale``) 결과와 같은
  /// 크기로 교정된다.
  @Test(arguments: [CGFloat.nan, -1, 0])
  func invalidScaleCorrectsToDefaultScaleResult(scale: CGFloat) async throws {
    let document = try await PapyrusDocument.open(data: Self.centeredSquareFixtureData())
    let renderer = PageImageRenderer(document: document)

    let defaultImage = try await renderer.image(forPage: 0)
    let correctedImage = try await renderer.image(forPage: 0, scale: scale)

    #expect(correctedImage.width == defaultImage.width)
    #expect(correctedImage.height == defaultImage.height)
  }

  // MARK: 2 — 좌표 계약 왕복 (증보의 완료 기준)

  /// 마커 픽스처를 렌더해 어두운 영역의 표시 공간 bounding box를 탐지하고, 정규화 후
  /// `pageQuad(normalizedDisplayRect:)`로 되돌리면 원 PDF 페이지 공간 마커 rect와
  /// ε 오차 내로 일치한다 — `ConnectingOCR` 파이프라인의 "이미지→quad" 반쪽을 실렌더로
  /// 봉인한다.
  @Test func imageCoordinatesRoundTripThroughPageQuad() async throws {
    let document = try await PapyrusDocument.open(data: Self.centeredSquareFixtureData())
    let pageInfo = try await document.page(at: 0)
    let renderer = PageImageRenderer(document: document)

    let image = try await renderer.image(forPage: 0, scale: 1)
    let darkBox = try #require(Self.darkBoundingBox(in: image))

    // 이미지는 이미 표시 공간(좌상단 원점, y-아래) 래스터이므로 그대로 정규화한다.
    let normalizedRect = CGRect(
      x: darkBox.minX / CGFloat(image.width), y: darkBox.minY / CGFloat(image.height),
      width: darkBox.width / CGFloat(image.width), height: darkBox.height / CGFloat(image.height)
    )
    let quad = pageInfo.pageQuad(normalizedDisplayRect: normalizedRect)
    let markerRect = CGRect(x: 206, y: 296, width: 200, height: 200)

    Self.expectClose(quad.boundingRect.minX, markerRect.minX)
    Self.expectClose(quad.boundingRect.minY, markerRect.minY)
    Self.expectClose(quad.boundingRect.maxX, markerRect.maxX)
    Self.expectClose(quad.boundingRect.maxY, markerRect.maxY)
  }

  // MARK: 3 — 회전 4종 치수

  /// 회전 4종에서 이미지 픽셀 치수가 `displaySize`(회전 반영 교환값)와 일치한다.
  @Test(arguments: PageRotation.allCases)
  func rotatedPageImageDimensionsMatchDisplaySize(rotation: PageRotation) async throws {
    let pageTree = PDFFixtureBuilder.PageTreeSpec(
      root: .pages(
        attributes: .init(),
        kids: [
          .page(
            attributes: .init(
              mediaBox: .init(0, 0, 612, 792), cropBox: .init(0, 0, 612, 792),
              rotate: rotation.rawValue
            )
          )
        ]
      )
    )
    let fixture = PDFFixtureBuilder(pageTree: pageTree).build()
    let document = try await PapyrusDocument.open(data: fixture.data)
    let pageInfo = try await document.page(at: 0)
    let renderer = PageImageRenderer(document: document)

    let image = try await renderer.image(forPage: 0, scale: 1)

    #expect(image.width == max(1, Int(pageInfo.displaySize.width.rounded())))
    #expect(image.height == max(1, Int(pageInfo.displaySize.height.rounded())))
  }

  // MARK: 4 — 에러 경로

  /// 페이지 수 밖 인덱스는 `pageUnavailable(pageIndex:)`를 던진다.
  @Test func outOfRangePageIndexThrowsPageUnavailable() async throws {
    let document = try await PapyrusDocument.open(data: Self.centeredSquareFixtureData())
    let renderer = PageImageRenderer(document: document)

    await #expect(throws: RenderError.pageUnavailable(pageIndex: 5)) {
      try await renderer.image(forPage: 5)
    }
  }

  /// 파서는 복구로 열지만 CG는 해석하지 못하는 손상 문서는 `documentUnavailable`이고,
  /// 실패는 영구 메모이즈된다(재호출도 동일 에러 즉시).
  @Test func recoveredButCGUnreadableDocumentFailsPermanentlyWithDocumentUnavailable() async
    throws {
    let fixture = PDFFixtureBuilder(pageCount: 3).build()
    // xref·trailer·%%EOF를 통째로 잘라낸다 — Papyrus의 RecoveryScanner는 전역 스캔으로
    // 여전히 열지만(body의 obj들은 온전), CG는 이 손상을 복구하지 못한다(경험적 확인).
    let corrupted = PDFFixtureCorruptor.apply([.truncateTail(byteCount: 150)], to: fixture)
    let document = try await PapyrusDocument.open(data: corrupted.data)
    let renderer = PageImageRenderer(document: document)

    await #expect(throws: RenderError.documentUnavailable) {
      try await renderer.image(forPage: 0)
    }
    await #expect(throws: RenderError.documentUnavailable) {
      try await renderer.image(forPage: 0)
    }
  }

  /// 이미 취소된 태스크에서의 호출은 `cancelled`를 던진다.
  @Test func cancelledTaskThrowsCancelled() async throws {
    let document = try await PapyrusDocument.open(data: Self.centeredSquareFixtureData())
    let renderer = PageImageRenderer(document: document)

    let task = Task {
      try await renderer.image(forPage: 0)
    }
    task.cancel()

    await #expect(throws: RenderError.cancelled) {
      try await task.value
    }
  }

  // MARK: 5 — 명암 프로브

  /// 마커 중심은 어둡고, 페이지 모서리는 흰 배경으로 밝다.
  @Test func markerCenterIsDarkAndCornerIsLight() async throws {
    let document = try await PapyrusDocument.open(data: Self.centeredSquareFixtureData())
    let renderer = PageImageRenderer(document: document)

    let image = try await renderer.image(forPage: 0, scale: 1)

    // 사각형 중심(표시 공간 306, 396 — 페이지가 상하좌우 대칭이라 PDF 좌표와 동일).
    #expect(Self.isDark(Self.colorChannels(of: image, x: 306, y: 396)))
    // 모서리(표시 공간 5, 5)는 흰 배경.
    #expect(Self.isLight(Self.colorChannels(of: image, x: 5, y: 5)))
  }

  // MARK: 6 — 동시 호출 스모크

  /// 한 렌더러에 2페이지를 동시 요청해도 둘 다 정상 반환한다 (직렬화 안전성 — 순서는
  /// 단언하지 않는다).
  @Test func concurrentImageRequestsBothSucceed() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 2, pageWidth: 300, pageHeight: 300).build()
    let document = try await PapyrusDocument.open(data: fixture.data)
    let renderer = PageImageRenderer(document: document)

    async let first = renderer.image(forPage: 0, scale: 1)
    async let second = renderer.image(forPage: 1, scale: 1)
    let (image0, image1) = try await (first, second)

    #expect(image0.width > 0 && image0.height > 0)
    #expect(image1.width > 0 && image1.height > 0)
  }
}
