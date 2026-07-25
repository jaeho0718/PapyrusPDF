import CoreGraphics
import Papyrus
import Vision

/// Vision 텍스트 인식을 `PageTextProvider`로 감싼 데모 프로바이더.
///
/// OCR 연결 가이드의 `OCRTextProvider` 예제 구조를 그대로 따른다: 페이지 이미지 렌더 →
/// Vision 인식 → 정규화 좌표 y-뒤집기 → `pageQuad(normalizedDisplayRect:)` →
/// `TextRun.uniform`. 검색 워밍업이 여러 페이지를 동시에 요청할 수 있으므로 actor로
/// 격리하고 페이지별 결과를 캐시한다.
///
/// 페이지별 in-flight 중복 요청은 방지하지 않는다 — 데모 수준에서는 과설계이고, 최악의
/// 경우도 같은 페이지를 두 번 인식하는 것뿐이다.
actor VisionTextProvider: PageTextProvider {
  /// 인식 대상 문서.
  private let document: PapyrusDocument

  /// 페이지를 표시 공간 이미지로 렌더하는 렌더러.
  private let renderer: PageImageRenderer

  /// 페이지별 인식 결과 캐시.
  private var cache: [Int: PageTextContent] = [:]

  /// 문서에 대한 프로바이더를 만든다.
  /// - Parameter document: 인식 대상 문서.
  init(document: PapyrusDocument) {
    self.document = document
    self.renderer = PageImageRenderer(document: document)
  }

  /// 페이지 이미지를 Vision으로 인식해 `PageTextContent`를 조립한다.
  ///
  /// Vision 인식이 실패하거나 후보 문자열이 없으면 그 페이지만 빈 콘텐츠로 강등한다
  /// (throw하지 않음) — 데모가 한 페이지의 인식 실패로 멈추지 않는다.
  /// - Parameter pageIndex: 조회할 페이지 인덱스 (0 기반).
  /// - Returns: 인식된(또는 빈) 페이지 텍스트 콘텐츠.
  func textContent(forPage pageIndex: Int) async throws -> PageTextContent {
    if let cached = self.cache[pageIndex] {
      return cached
    }
    try Task.checkCancellation()
    let content = await self.recognize(pageIndex: pageIndex)
    self.cache[pageIndex] = content
    return content
  }

  /// 페이지 하나를 렌더 → 인식 → 조립한다. 실패는 빈 콘텐츠로 강등한다.
  /// - Parameter pageIndex: 인식할 페이지 인덱스.
  /// - Returns: 조립된(실패 시 빈) 페이지 텍스트 콘텐츠.
  private func recognize(pageIndex: Int) async -> PageTextContent {
    guard
      let pageInfo = try? await self.document.page(at: pageIndex),
      let image = try? await self.renderer.image(forPage: pageIndex)
    else {
      return PageTextContent(pageIndex: pageIndex, string: "", runs: [])
    }

    let observations: [RecognizedTextObservation]
    do {
      observations = try await RecognizeTextRequest().perform(on: image)
    } catch {
      return PageTextContent(pageIndex: pageIndex, string: "", runs: [])
    }

    // Vision 정규화 y는 위로 갈수록 커진다 — 읽기 순서(위→아래, 좌→우)로 정렬한다.
    let ordered = observations.sorted { lhs, rhs in
      let lhsCenterY = lhs.boundingBox.origin.y + lhs.boundingBox.height / 2
      let rhsCenterY = rhs.boundingBox.origin.y + rhs.boundingBox.height / 2
      if abs(lhsCenterY - rhsCenterY) > 0.001 {
        return lhsCenterY > rhsCenterY
      }
      return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
    }

    var string = ""
    var runs: [TextRun] = []
    for observation in ordered {
      guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else {
        continue
      }
      if !string.isEmpty {
        string += "\n"
      }
      let visionBox = observation.boundingBox.cgRect
      let displayRect = CGRect(
        x: visionBox.minX, y: 1 - visionBox.minY - visionBox.height,
        width: visionBox.width, height: visionBox.height
      )
      let quad = pageInfo.pageQuad(normalizedDisplayRect: displayRect)
      let start = string.utf16.count
      string += text
      runs.append(TextRun.uniform(range: start..<string.utf16.count, quad: quad))
    }
    return PageTextContent(pageIndex: pageIndex, string: string, runs: runs)
  }
}
