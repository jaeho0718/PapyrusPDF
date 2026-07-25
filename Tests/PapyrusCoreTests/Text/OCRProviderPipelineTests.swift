import CoreGraphics
@testable import PapyrusCore
import Testing

/// OCR 스타일 좌표 계약(Vision 정규화 박스 → `pageQuad` → `TextRun.uniform` → 선택 히트
/// 테스트)의 종단 파이프라인을 검증한다 (설계 §5-1 — 계획 리스크 6 회귀 방어).
///
/// 여기 조립 헬퍼(``makeContent(text:visionBox:pageInfo:)``)는 `ConnectingOCR` 아티클의
/// 좌표 계약 예제와 동일한 파이프라인이다 — 문서와 테스트가 같은 조립 순서를 공유해
/// 문서 부패를 구조적으로 방지한다.
struct OCRProviderPipelineTests {
  // MARK: 종단 왕복 (회전 4종)

  @Test(arguments: PageRotation.allCases)
  func visionStyleBoxRoundTripsThroughSelectionGeometry(rotation: PageRotation) {
    let pageInfo = PageInfo(
      index: 0, mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792),
      cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: rotation
    )
    let text = "hello"
    // Vision 스타일 정규화 박스 (y-위, 원점 좌하단).
    let visionBox = CGRect(x: 0.2, y: 0.6, width: 0.3, height: 0.1)
    let content = Self.makeContent(text: text, visionBox: visionBox, pageInfo: pageInfo)
    let transform = PageDisplayTransform.transform(cropBox: pageInfo.cropBox, rotation: rotation)
    let geometry = SelectionGeometry.build(content: content, pageIndex: 0, transform: transform)

    // (a) 박스 중심의 표시 공간 점 히트 → 그 run(전체 문자열 하나뿐)의 오프셋 구간 안.
    let displayRect = Self.flippedDisplayRect(visionBox)
    let size = pageInfo.displaySize
    let center = CGPoint(x: displayRect.midX * size.width, y: displayRect.midY * size.height)
    let offset = geometry.textOffset(at: center)
    #expect((0...text.utf16.count).contains(offset))

    // (b) displayQuads(forRange:)가 원 정규화 박스의 표시 공간 rect와 일치(ε 허용).
    let quads = geometry.displayQuads(forRange: 0..<text.utf16.count)
    let boundingRect = quads.first?.boundingRect
    let expected = CGRect(
      x: displayRect.minX * size.width, y: displayRect.minY * size.height,
      width: displayRect.width * size.width, height: displayRect.height * size.height
    )
    Self.expectClose(boundingRect?.minX, expected.minX)
    Self.expectClose(boundingRect?.minY, expected.minY)
    Self.expectClose(boundingRect?.maxX, expected.maxX)
    Self.expectClose(boundingRect?.maxY, expected.maxY)
  }

  // MARK: 음성 케이스 — 뒤집기 생략 시 상하 반전 (왜 뒤집어야 하는가의 실증)

  @Test func skippingFlipMapsToVerticallyMirroredPosition() {
    let pageInfo = PageInfo(
      index: 0, mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792),
      cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: .degrees0
    )
    let size = pageInfo.displaySize
    let text = "hello"
    let visionBox = CGRect(x: 0.2, y: 0.6, width: 0.3, height: 0.1)
    let transform = PageDisplayTransform.transform(cropBox: pageInfo.cropBox, rotation: .degrees0)

    // 올바른 파이프라인: y' = 1 - y - height로 뒤집은 뒤 quad화.
    let correctContent = Self.makeContent(text: text, visionBox: visionBox, pageInfo: pageInfo)
    let correctGeometry = SelectionGeometry.build(
      content: correctContent, pageIndex: 0, transform: transform
    )
    let correctRect = correctGeometry.displayQuads(forRange: 0..<text.utf16.count).first?
      .boundingRect

    // 잘못된 파이프라인: 뒤집기를 생략하고 원 Vision y를 표시 정규화 y로 그대로 사용.
    let wrongQuad = pageInfo.pageQuad(normalizedDisplayRect: visionBox)
    let wrongRun = TextRun.uniform(range: 0..<text.utf16.count, quad: wrongQuad)
    let wrongContent = PageTextContent(pageIndex: 0, string: text, runs: [wrongRun])
    let wrongGeometry = SelectionGeometry.build(
      content: wrongContent, pageIndex: 0, transform: transform
    )
    let wrongRect = wrongGeometry.displayQuads(forRange: 0..<text.utf16.count).first?.boundingRect

    let correctRectValue = correctRect ?? .zero
    let wrongRectValue = wrongRect ?? .zero
    #expect(correctRect != nil)
    #expect(wrongRect != nil)
    // 상하 반전: wrong.minY == size.height - correct.maxY (그 반대도 성립).
    Self.expectClose(wrongRectValue.minY, size.height - correctRectValue.maxY)
    Self.expectClose(wrongRectValue.maxY, size.height - correctRectValue.minY)
    // x는 y 뒤집기의 영향을 받지 않는다.
    Self.expectClose(wrongRectValue.minX, correctRectValue.minX)
    Self.expectClose(wrongRectValue.maxX, correctRectValue.maxX)
  }
}

// MARK: - 테스트 헬퍼 (`ConnectingOCR` 아티클의 좌표 계약 예제와 동일한 조립 순서)

extension OCRProviderPipelineTests {
  /// Vision 스타일 정규화 박스(y-위, 원점 좌하단)를 표시 공간 정규화 rect(y-아래, 원점
  /// 좌상단)로 뒤집는다.
  static func flippedDisplayRect(_ visionBox: CGRect) -> CGRect {
    CGRect(
      x: visionBox.minX, y: 1 - visionBox.minY - visionBox.height,
      width: visionBox.width, height: visionBox.height
    )
  }

  /// Vision 스타일 박스 하나로 페이지 콘텐츠를 조립한다 (뒤집기 → `pageQuad` →
  /// `TextRun.uniform` → `PageTextContent` — OCR 프로바이더 파이프라인과 동일한 순서).
  static func makeContent(text: String, visionBox: CGRect, pageInfo: PageInfo) -> PageTextContent {
    let displayRect = Self.flippedDisplayRect(visionBox)
    let quad = pageInfo.pageQuad(normalizedDisplayRect: displayRect)
    let run = TextRun.uniform(range: 0..<text.utf16.count, quad: quad)
    return PageTextContent(pageIndex: 0, string: text, runs: [run])
  }

  /// 부동소수 근사 비교 (`nil`이면 즉시 실패).
  static func expectClose(_ value: CGFloat?, _ expected: CGFloat, tolerance: CGFloat = 0.5) {
    guard let value else {
      Issue.record("expected a value close to \(expected) but got nil")
      return
    }
    #expect(abs(value - expected) < tolerance)
  }
}
