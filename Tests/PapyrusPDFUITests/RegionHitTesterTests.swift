import CoreGraphics
import PapyrusPDFCore
@testable import PapyrusPDFUI
import Testing

/// `RegionHitTester`의 볼록 quad 내부 판정(§2.1)·겹침 우선순위(§2.2)·등록 위생(§2.3)을
/// 검증한다 (설계 §5-1 — 순수 함수 유닛 테스트).
struct RegionHitTesterTests {
  // MARK: contains — 축 정렬 rect quad

  /// 좌상단 (0,0), 우하단 (100,50)의 축 정렬 rect quad(표시 공간 y-아래 기준).
  private static let axisAlignedQuad = Quad(
    bottomLeft: CGPoint(x: 0, y: 50), bottomRight: CGPoint(x: 100, y: 50),
    topRight: CGPoint(x: 100, y: 0), topLeft: CGPoint(x: 0, y: 0)
  )

  @Test(
    arguments: [
      (CGPoint(x: 50, y: 25), true), // 내부.
      (CGPoint(x: 150, y: 25), false), // 외부(오른쪽).
      (CGPoint(x: -10, y: 25), false), // 외부(왼쪽).
      (CGPoint(x: 50, y: -5), false), // 외부(위).
      (CGPoint(x: 50, y: 60), false), // 외부(아래).
      (CGPoint(x: 0, y: 25), true), // 변 위(왼쪽 변) — 경계 포함.
      (CGPoint(x: 100, y: 25), true), // 변 위(오른쪽 변).
      (CGPoint(x: 50, y: 0), true), // 변 위(위쪽 변).
      (CGPoint(x: 0, y: 0), true), // 꼭짓점.
      (CGPoint(x: 100, y: 50), true) // 꼭짓점.
    ] as [(CGPoint, Bool)]
  )
  func containsAxisAlignedQuad(point: CGPoint, expected: Bool) {
    #expect(RegionHitTester.contains(point, in: Self.axisAlignedQuad) == expected)
  }

  // MARK: contains — 45도 회전 quad (boundingRect 안이지만 quad 밖인 모서리 증명)

  /// 중심 (50,50), "반지름" 50인 45도 회전 정사각형(마름모) — 꼭짓점 (50,0)/(100,50)/
  /// (50,100)/(0,50). boundingRect는 [0,100]×[0,100]이지만 quad 자체는 그보다 작다.
  private static let rotatedQuad = Quad(
    bottomLeft: CGPoint(x: 0, y: 50), bottomRight: CGPoint(x: 50, y: 100),
    topRight: CGPoint(x: 100, y: 50), topLeft: CGPoint(x: 50, y: 0)
  )

  @Test func containsRotatedQuadInteriorPointIsInside() {
    #expect(RegionHitTester.contains(CGPoint(x: 50, y: 50), in: Self.rotatedQuad))
  }

  @Test func containsRotatedQuadCornerOfBoundingRectIsOutside() {
    // boundingRect의 네 모서리(0,0)/(100,0)/(0,100)/(100,100)는 마름모 밖이다 —
    // boundingRect 근사와 정밀 quad 판정이 갈리는 증거(§0.2-3).
    #expect(!RegionHitTester.contains(CGPoint(x: 0, y: 0), in: Self.rotatedQuad))
    #expect(!RegionHitTester.contains(CGPoint(x: 100, y: 0), in: Self.rotatedQuad))
    #expect(!RegionHitTester.contains(CGPoint(x: 0, y: 100), in: Self.rotatedQuad))
    #expect(!RegionHitTester.contains(CGPoint(x: 100, y: 100), in: Self.rotatedQuad))
  }

  @Test func containsRotatedQuadVertexIsInsideBoundaryInclusive() {
    #expect(RegionHitTester.contains(CGPoint(x: 50, y: 0), in: Self.rotatedQuad))
  }

  // MARK: contains — 감김 반전(y-뒤집힌 quad)도 동일 결과

  @Test func containsWindingReversalYieldsSameResult() {
    // 저장 순서를 그대로 y 뒤집기만 하면 감김 방향이 반전된다 — 부호 동일 판정은
    // 방향 무관해야 한다(§2.1).
    let flipped = Quad(
      bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 100, y: 0),
      topRight: CGPoint(x: 100, y: 50), topLeft: CGPoint(x: 0, y: 50)
    )
    #expect(RegionHitTester.contains(CGPoint(x: 50, y: 25), in: flipped))
    #expect(!RegionHitTester.contains(CGPoint(x: 150, y: 25), in: flipped))
  }

  // MARK: contains — 퇴화 quad

  @Test func containsDegenerateQuadAllSamePointIsAlwaysFalse() {
    let point = CGPoint(x: 10, y: 10)
    let degenerate = Quad(bottomLeft: point, bottomRight: point, topRight: point, topLeft: point)
    #expect(!RegionHitTester.contains(point, in: degenerate))
    #expect(!RegionHitTester.contains(CGPoint(x: 5, y: 5), in: degenerate))
  }

  @Test func containsDegenerateCollinearQuadIsAlwaysFalse() {
    // 4점이 한 직선 위 — 면적 0.
    let collinear = Quad(
      bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 10, y: 0),
      topRight: CGPoint(x: 20, y: 0), topLeft: CGPoint(x: 30, y: 0)
    )
    #expect(!RegionHitTester.contains(CGPoint(x: 15, y: 0), in: collinear))
  }

  // MARK: contains — 비유한 좌표

  @Test func containsNaNQuadCoordinateIsAlwaysFalse() {
    let nanQuad = Quad(
      bottomLeft: CGPoint(x: CGFloat.nan, y: 0), bottomRight: CGPoint(x: 100, y: 0),
      topRight: CGPoint(x: 100, y: 50), topLeft: CGPoint(x: 0, y: 50)
    )
    #expect(!RegionHitTester.contains(CGPoint(x: 50, y: 25), in: nanQuad))
  }

  @Test func containsInfiniteQuadCoordinateIsAlwaysFalse() {
    let infiniteQuad = Quad(
      bottomLeft: CGPoint(x: -.infinity, y: 0), bottomRight: CGPoint(x: 100, y: 0),
      topRight: CGPoint(x: 100, y: 50), topLeft: CGPoint(x: 0, y: 50)
    )
    #expect(!RegionHitTester.contains(CGPoint(x: 50, y: 25), in: infiniteQuad))
  }

  @Test func containsNaNPointIsAlwaysFalse() {
    #expect(!RegionHitTester.contains(CGPoint(x: CGFloat.nan, y: 25), in: Self.axisAlignedQuad))
  }

  // MARK: hitRegion — 겹침 우선순위

  private static func region(id: String, page: Int = 0, rect: CGRect) -> SelectableRegion {
    SelectableRegion(id: id, pageIndex: page, quad: Quad(rect: rect))
  }

  @Test func hitRegionOverlapReturnsLaterRegisteredRegion() {
    // 둘 다 원점 근방을 덮는 겹침 — front가 먼저, back이 나중 등록.
    let front = Self.region(id: "front", rect: CGRect(x: 0, y: 0, width: 100, height: 100))
    let back = Self.region(id: "back", rect: CGRect(x: 0, y: 0, width: 100, height: 100))

    let hit = RegionHitTester.hitRegion(
      at: CGPoint(x: 50, y: 50), regions: [front, back], displayTransform: .identity
    )

    #expect(hit?.id == "back")
  }

  @Test func hitRegionPointOutsideOverlapReturnsOnlyContainingRegion() {
    let front = Self.region(id: "front", rect: CGRect(x: 0, y: 0, width: 50, height: 50))
    let back = Self.region(id: "back", rect: CGRect(x: 0, y: 0, width: 100, height: 100))

    let hit = RegionHitTester.hitRegion(
      at: CGPoint(x: 75, y: 75), regions: [front, back], displayTransform: .identity
    )

    #expect(hit?.id == "back")
  }

  @Test func hitRegionEmptyListReturnsNil() {
    let hit = RegionHitTester.hitRegion(
      at: CGPoint(x: 10, y: 10), regions: [], displayTransform: .identity
    )
    #expect(hit == nil)
  }

  @Test func hitRegionPointMissingAllRegionsReturnsNil() {
    let region = Self.region(id: "a", rect: CGRect(x: 0, y: 0, width: 10, height: 10))
    let hit = RegionHitTester.hitRegion(
      at: CGPoint(x: 500, y: 500), regions: [region], displayTransform: .identity
    )
    #expect(hit == nil)
  }

  // MARK: hitRegion — 표시 변환 적용 (회전 페이지 4종)

  @Test(
    arguments: [
      PageRotation.degrees0, .degrees90, .degrees180, .degrees270
    ]
  )
  func hitRegionAppliesDisplayTransformAcrossPageRotations(rotation: PageRotation) {
    // PDF 페이지 공간(y-위) cropBox [0,0,200,100]에 등록된 영역 quad — 표시 변환을
    // 통과하면 회전에 따라 표시 공간의 다른 위치에 나타난다. 등록 quad의 "중심"이
    // 표시 공간에서도 여전히 영역의 중심에 히트해야 한다(변환의 꼭짓점 의미 보존).
    let cropBox = CGRect(x: 0, y: 0, width: 200, height: 100)
    let transform = PageDisplayTransform.transform(cropBox: cropBox, rotation: rotation)
    let pdfSpaceRegionRect = CGRect(x: 50, y: 25, width: 40, height: 20) // PDF 공간 영역.
    let region = Self.region(id: "r", rect: pdfSpaceRegionRect)
    let pdfSpaceCenter = CGPoint(x: pdfSpaceRegionRect.midX, y: pdfSpaceRegionRect.midY)
    let displayCenter = pdfSpaceCenter.applying(transform)

    let hit = RegionHitTester.hitRegion(
      at: displayCenter, regions: [region], displayTransform: transform
    )

    #expect(hit?.id == "r")
  }

  // MARK: sanitized

  @Test func sanitizedDiscardsNonFiniteQuadCoordinates() {
    let valid = Self.region(id: "valid", rect: CGRect(x: 0, y: 0, width: 10, height: 10))
    let invalid = SelectableRegion(
      id: "invalid", pageIndex: 0,
      quad: Quad(
        bottomLeft: CGPoint(x: CGFloat.nan, y: 0), bottomRight: CGPoint(x: 10, y: 0),
        topRight: CGPoint(x: 10, y: 10), topLeft: CGPoint(x: 0, y: 10)
      )
    )

    let result = RegionHitTester.sanitized([valid, invalid], forPage: 0)

    #expect(result.map(\SelectableRegion.id) == ["valid"])
  }

  @Test func sanitizedDiscardsPageIndexMismatch() {
    let matching = Self.region(
      id: "match", page: 2, rect: CGRect(x: 0, y: 0, width: 10, height: 10)
    )
    let mismatching = Self.region(
      id: "mismatch", page: 3, rect: CGRect(x: 0, y: 0, width: 10, height: 10)
    )

    let result = RegionHitTester.sanitized([matching, mismatching], forPage: 2)

    #expect(result.map(\SelectableRegion.id) == ["match"])
  }

  @Test func sanitizedTruncatesToPerPageLimitKeepingFrontInOrder() {
    let regions = (0..<1_025).map { index in
      Self.region(id: "r\(index)", rect: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    let result = RegionHitTester.sanitized(regions, forPage: 0)

    #expect(result.count == UILimits.maxSelectableRegionsPerPage)
    #expect(result.count == 1_024)
    #expect(result.first?.id == "r0")
    #expect(result.last?.id == "r1023")
  }

  @Test func sanitizedPreservesOrder() {
    let regions = ["c", "a", "b"].map { id in
      Self.region(id: id, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    let result = RegionHitTester.sanitized(regions, forPage: 0)

    #expect(result.map(\SelectableRegion.id) == ["c", "a", "b"])
  }
}
