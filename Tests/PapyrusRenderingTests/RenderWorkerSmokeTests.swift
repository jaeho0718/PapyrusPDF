import CoreGraphics
import Foundation
@testable import PapyrusCore
@testable import PapyrusRendering
import PapyrusTestSupport
import Testing

/// ``RenderWorker``의 픽스처 스모크 테스트 (설계 §5 RW1-RW5, M5 완료 기준).
///
/// 스냅샷 비교는 하지 않는다(OS별 CG 편차) — 비-nil, 픽셀 크기, 명암 프로브만 검증한다.
struct RenderWorkerSmokeTests {
  /// 612×792 페이지 중앙 200×200 검은 사각형 픽스처 (PDF 좌표: x 206..406, y 296..496).
  private static func centeredSquareFixtureData() -> Data {
    let body = Data("0 0 0 rg 206 296 200 200 re f".utf8)
    return PDFFixtureBuilder(
      pageCount: 1, pageWidth: 612, pageHeight: 792, contentStream: .init(body: body)
    ).build().data
  }

  /// `CGImage`의 (x, y) 픽셀에서 알파(스킵) 바이트를 제외한 3개 색상 채널을 읽는다.
  /// 채널 순서는 무관하다 — 흑백 판정에는 대칭이라 순서 지식이 필요 없다.
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

  // MARK: RW1 — 완료 기준 스모크

  /// RW1: 단일 타일이 페이지 전체를 덮는 구성에서 비-nil, 픽셀 크기 정합, 명암 프로브.
  @Test func renderTileProducesExpectedSizeAndContrast() async throws {
    let document = try await PDFDocumentCore.open(data: Self.centeredSquareFixtureData())
    let pageSize = try await document.pageTree().records[0].displaySize
    let worker = RenderWorker(documentData: document.sourceBytes, pixelScale: 1)

    // exp -2(scale 0.5)는 tileSideInPoints 1024pt — 612×792 페이지를 한 타일로 덮는다.
    let scaleBucket = ScaleBucket(exponent: -2)
    let key = TileKey(pageIndex: 0, scaleBucket: scaleBucket, col: 0, row: 0)
    let tile = try await worker.renderTile(key: key, pageSize: pageSize)

    let grid = TileGrid(pageSize: pageSize, scaleBucket: scaleBucket)
    let tileRect = try #require(grid.tileRect(col: 0, row: 0))
    let scale = scaleBucket.scale * 1 // pixelScale 1
    let expectedWidth = max(1, Int((tileRect.width * scale).rounded()))
    let expectedHeight = max(1, Int((tileRect.height * scale).rounded()))

    #expect(tile.image.width == expectedWidth)
    #expect(tile.image.height == expectedHeight)
    #expect(tile.pointRect == tileRect)
    #expect(tile.cost == tile.image.bytesPerRow * tile.image.height)

    // 사각형 중심(표시 공간 306, 396 — 페이지가 상하좌우 대칭이라 PDF 좌표와 동일)은 어둡다.
    let centerX = Int((306 * scale).rounded())
    let centerY = Int((396 * scale).rounded())
    #expect(Self.isDark(Self.colorChannels(of: tile.image, x: centerX, y: centerY)))

    // 모서리(표시 공간 5, 5)는 밝다(흰 배경).
    let cornerX = Int((5 * scale).rounded())
    let cornerY = Int((5 * scale).rounded())
    #expect(Self.isLight(Self.colorChannels(of: tile.image, x: cornerX, y: cornerY)))
  }

  // MARK: RW2 — 버킷별 타일 픽셀 크기 상수(가정 3)

  /// RW2: exp -2/0/2 각각에서 (0,0) 타일(내부 타일)의 픽셀 크기가 상수 `512 × pixelScale`다.
  @Test(arguments: [-2, 0, 2])
  func tilePixelSizeIsConstantAcrossScaleBuckets(exponent: Int) async throws {
    // 2000×2000 큰 페이지 — exp -2(타일 변 1024pt)에서도 (0,0)이 페이지 경계에
    // 걸치지 않는 내부 타일이 되도록 한다. 사각형은 40×40, 표시 공간 (108,108)-(148,148)
    // — 세 버킷의 (0,0) 타일 영역(가장 작아도 256×256) 안에 항상 들어간다.
    let body = Data("0 0 0 rg 108 1852 40 40 re f".utf8)
    let fixture = PDFFixtureBuilder(
      pageCount: 1, pageWidth: 2_000, pageHeight: 2_000, contentStream: .init(body: body)
    ).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let pageSize = try await document.pageTree().records[0].displaySize
    let pixelScale: CGFloat = 2
    let worker = RenderWorker(documentData: document.sourceBytes, pixelScale: pixelScale)

    let scaleBucket = ScaleBucket(exponent: exponent)
    let key = TileKey(pageIndex: 0, scaleBucket: scaleBucket, col: 0, row: 0)
    let tile = try await worker.renderTile(key: key, pageSize: pageSize)

    let expectedSide = Int((RenderingLimits.tileSideLength * pixelScale).rounded())
    #expect(tile.image.width == expectedSide)
    #expect(tile.image.height == expectedSide)

    // 정사각형 중심(표시 공간 128, 128)은 세 버킷 모두에서 어둡다.
    let scale = scaleBucket.scale * pixelScale
    let centerX = Int((128 * scale).rounded())
    let centerY = Int((128 * scale).rounded())
    #expect(Self.isDark(Self.colorChannels(of: tile.image, x: centerX, y: centerY)))
  }

  // MARK: RW3 — 프리뷰

  /// RW3: 프리뷰는 최장변이 `previewMaxPixelDimension`이고 종횡비가 페이지와 일치한다.
  @Test func renderPreviewMatchesLongestSideAndAspectRatio() async throws {
    let document = try await PDFDocumentCore.open(data: Self.centeredSquareFixtureData())
    let pageSize = try await document.pageTree().records[0].displaySize
    let worker = RenderWorker(documentData: document.sourceBytes, pixelScale: 2)

    let preview = try await worker.renderPreview(pageIndex: 0, pageSize: pageSize)

    let longestSide = max(preview.image.width, preview.image.height)
    #expect(longestSide == RenderingLimits.previewMaxPixelDimension)

    let expectedAspect = pageSize.width / pageSize.height
    let actualAspect = Double(preview.image.width) / Double(preview.image.height)
    #expect(abs(actualAspect - expectedAspect) < 0.02)
  }

  // MARK: RW4 — /Rotate 90 픽스처

  /// RW4: /Rotate 90 페이지는 displaySize가 교환되고, 타일 렌더는 스모크 수준(비-nil·크기)만.
  @Test func rotatedNinetyDegreePageSwapsDisplaySizeAndRendersTile() async throws {
    let attrs = PDFFixtureBuilder.PageTreeSpec.NodeAttributes(
      mediaBox: .init(0, 0, 612, 792), rotate: 90
    )
    let spec = PDFFixtureBuilder.PageTreeSpec(
      root: .pages(attributes: .init(), kids: [.page(attributes: attrs)])
    )
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let record = try await document.pageTree().records[0]

    #expect(record.displaySize == CGSize(width: 792, height: 612))

    let worker = RenderWorker(documentData: document.sourceBytes, pixelScale: 1)
    let scaleBucket = ScaleBucket(exponent: -2)
    let key = TileKey(pageIndex: 0, scaleBucket: scaleBucket, col: 0, row: 0)
    let tile = try await worker.renderTile(key: key, pageSize: record.displaySize)

    #expect(tile.image.width > 0)
    #expect(tile.image.height > 0)
  }

  // MARK: RW5 — 손상 문서·범위 밖 페이지

  /// RW5: CG가 열 수 없는 난수 바이트는 `documentUnavailable`이고, 실패는 메모이즈된다
  /// (2회 호출 모두 동일 에러).
  @Test func garbageBytesFailPermanentlyWithDocumentUnavailable() async {
    var generator = SystemRandomNumberGenerator()
    let junk = Data((0..<256).map { _ in UInt8.random(in: 0...255, using: &generator) })
    let worker = RenderWorker(documentData: junk, pixelScale: 1)
    let key = TileKey(pageIndex: 0, scaleBucket: ScaleBucket(exponent: 0), col: 0, row: 0)

    await #expect(throws: RenderError.documentUnavailable) {
      try await worker.renderTile(key: key, pageSize: CGSize(width: 612, height: 792))
    }
    // 두 번째 호출도 동일하게 실패한다 (영구 메모이즈 — 가정 8).
    await #expect(throws: RenderError.documentUnavailable) {
      try await worker.renderTile(key: key, pageSize: CGSize(width: 612, height: 792))
    }
  }

  /// RW5: 파서 페이지 수 밖의 인덱스는 `pageUnavailable`을 던진다.
  @Test func outOfRangePageIndexThrowsPageUnavailable() async throws {
    let document = try await PDFDocumentCore.open(data: Self.centeredSquareFixtureData())
    let pageSize = try await document.pageTree().records[0].displaySize
    let worker = RenderWorker(documentData: document.sourceBytes, pixelScale: 1)
    let key = TileKey(pageIndex: 5, scaleBucket: ScaleBucket(exponent: -2), col: 0, row: 0)

    await #expect(throws: RenderError.pageUnavailable(pageIndex: 5)) {
      try await worker.renderTile(key: key, pageSize: pageSize)
    }
  }
}
