import CoreGraphics
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// ``PageInfo/displayTransform``·``PageInfo/pageQuad(normalizedDisplayRect:)``를
/// 검증한다 (설계 §5.8).
struct PageInfoDisplayGeometryTests {
  // MARK: displayTransform ≡ PageDisplayTransform.transform (회전 4종)

  @Test(arguments: PageRotation.allCases)
  func displayTransformMatchesPageDisplayTransform(rotation: PageRotation) async throws {
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
    let document = try await PapyrusPDFDocument.open(data: fixture.data)
    let pageInfo = try await document.page(at: 0)

    #expect(pageInfo.rotation == rotation)
    let expected = PageDisplayTransform.transform(cropBox: pageInfo.cropBox, rotation: rotation)
    #expect(pageInfo.displayTransform == expected)
  }

  // MARK: pageQuad 왕복 (회전 4종)

  @Test(arguments: PageRotation.allCases)
  func pageQuadRoundTripsThroughDisplayTransform(rotation: PageRotation) async throws {
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
    let document = try await PapyrusPDFDocument.open(data: fixture.data)
    let pageInfo = try await document.page(at: 0)

    let normalizedRect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.15)
    let quad = pageInfo.pageQuad(normalizedDisplayRect: normalizedRect)

    // 역변환의 역변환 = 원 변환 — quad 4점에 displayTransform을 적용하면 표시 공간
    // 좌표(pt)로 되돌아온다. 정규화(0...1)로 나눠 원본 rect의 네 꼭짓점과 비교한다.
    let size = pageInfo.displaySize
    let transform = pageInfo.displayTransform
    let bottomLeft = quad.bottomLeft.applying(transform)
    let topRight = quad.topRight.applying(transform)

    let recoveredMinX = min(bottomLeft.x, topRight.x) / size.width
    let recoveredMaxX = max(bottomLeft.x, topRight.x) / size.width
    let recoveredMinY = min(bottomLeft.y, topRight.y) / size.height
    let recoveredMaxY = max(bottomLeft.y, topRight.y) / size.height

    Self.expectClose(recoveredMinX, normalizedRect.minX)
    Self.expectClose(recoveredMaxX, normalizedRect.maxX)
    Self.expectClose(recoveredMinY, normalizedRect.minY)
    Self.expectClose(recoveredMaxY, normalizedRect.maxY)
  }

  // MARK: 비유한 rect → 영점 quad

  @Test func pageQuadWithNonFiniteRectReturnsZeroQuad() {
    let pageInfo = PageInfo(
      index: 0, mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792),
      cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: .degrees0
    )
    let badRect = CGRect(x: .nan, y: 0, width: 0.1, height: 0.1)
    let quad = pageInfo.pageQuad(normalizedDisplayRect: badRect)
    #expect(quad == Quad(rect: .zero))
  }

  // MARK: 음수 크기 rect 표준화

  @Test func pageQuadStandardizesNegativeSizedRect() {
    let pageInfo = PageInfo(
      index: 0, mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792),
      cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: .degrees0
    )
    let negativeRect = CGRect(x: 0.5, y: 0.5, width: -0.2, height: -0.2)
    let standardizedRect = CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)
    #expect(
      pageInfo.pageQuad(normalizedDisplayRect: negativeRect)
        == pageInfo.pageQuad(normalizedDisplayRect: standardizedRect)
    )
  }
}

// MARK: - 테스트 헬퍼

extension PageInfoDisplayGeometryTests {
  /// 부동소수 근사 비교.
  /// - Parameters:
  ///   - value: 실제 값.
  ///   - expected: 기대 값.
  static func expectClose(_ value: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.001) {
    #expect(abs(value - expected) < tolerance)
  }
}
