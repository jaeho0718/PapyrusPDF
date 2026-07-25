import CoreGraphics
import PapyrusCore
import PapyrusUI

/// `ReaderSelectionController`/`SelectablePageStore` 관련 테스트가 공유하는 결정적
/// 텍스트 픽스처 (선택 스토어/컨트롤러/크로스페이지 테스트가 함께 참조).
@MainActor
enum SelectionTestFixtures {
  /// 문자당 폭 (pt) — `singleLineContent`의 균등 배치와 `point(forOffset:)`가 짝을 이룬다.
  static let charWidth: CGFloat = 10

  /// 페이지당 단일 라인 콘텐츠를 만든다 (표시 공간 y-아래 기준, 균등 `charWidth`pt/문자,
  /// 라인 y밴드 `[0, 20]`). `displayTransform: { _ in .identity }`와 짝지어 쓰면 run quad가
  /// 곧 표시 공간 quad다.
  /// - Parameters:
  ///   - pageIndex: 페이지 인덱스.
  ///   - text: 페이지 문자열 (기본 "Hello World" — 5자 단어 + 공백 + 5자 단어).
  /// - Returns: 단일 run 콘텐츠.
  static func singleLineContent(pageIndex: Int, text: String = "Hello World") -> PageTextContent {
    let width = CGFloat(text.utf16.count) * Self.charWidth
    let run = TextRun.uniform(
      range: 0..<text.utf16.count,
      quad: Quad(
        bottomLeft: CGPoint(x: 0, y: 20), bottomRight: CGPoint(x: width, y: 20),
        topRight: CGPoint(x: width, y: 0), topLeft: CGPoint(x: 0, y: 0)
      )
    )
    return PageTextContent(pageIndex: pageIndex, string: text, runs: [run])
  }

  /// `singleLineContent` 위에서 UTF-16 오프셋 `offset`의 문자 칸 안쪽(왼쪽 치우침) 점을
  /// 반환한다 — `textOffset(at:)`가 결정적으로 `offset`을 되돌리도록 칸 경계를 피한다.
  /// - Parameters:
  ///   - offset: 목표 UTF-16 오프셋.
  ///   - y: 표시 공간 y (기본 라인 중앙 10).
  /// - Returns: 해당 오프셋을 가리키는 표시 공간 점.
  static func point(forOffset offset: Int, y: CGFloat = 10) -> CGPoint {
    CGPoint(x: CGFloat(offset) * Self.charWidth + 2, y: y)
  }

  /// 오프셋 `offset`을 가리키는 페이지 점 (`point(forOffset:)`을 `PagePoint`로 감싼다).
  /// - Parameters:
  ///   - offset: 목표 UTF-16 오프셋.
  ///   - page: 페이지 인덱스 (기본 0).
  /// - Returns: 페이지 점.
  static func pagePoint(_ offset: Int, page: Int = 0) -> PagePoint {
    PagePoint(pageIndex: page, point: Self.point(forOffset: offset))
  }

  /// 지정 페이지들의 콘텐츠를 미리 로드해 둔 선택 컨트롤러·스토어를 만든다
  /// (``ReaderSelectionControllerTests``·``ReaderSelectionGranularityTests``
  /// 공유 헬퍼 — 콘텐츠가 이미 캐시에 있는(잠정 클램프 없는) 시나리오 전용. 잠정→재계산
  /// 흐름은 ``SelectionCrossPageTests``가 담당한다).
  /// - Parameters:
  ///   - pages: 미리 로드할 페이지 인덱스 목록.
  ///   - texts: 페이지별 텍스트 (미지정 페이지는 기본 "Hello World").
  /// - Returns: 준비된 컨트롤러와 스토어.
  static func makeReadySelectionController(
    pages: [Int], texts: [Int: String] = [:]
  ) async throws -> (controller: ReaderSelectionController, store: ReaderSelectablePageStore) {
    var contents: [Int: PageTextContent] = [:]
    for page in pages {
      contents[page] = Self.singleLineContent(pageIndex: page, text: texts[page] ?? "Hello World")
    }
    let provider = DictionaryTextProvider(contents: contents)
    let store = ReaderSelectablePageStore(provider: provider, displayTransform: { _ in .identity })
    for page in pages {
      store.requestPage(page)
    }
    try await UITestSupport.waitUntil { pages.allSatisfy { store.geometry(forPage: $0) != nil } }
    return (ReaderSelectionController(store: store), store)
  }
}
