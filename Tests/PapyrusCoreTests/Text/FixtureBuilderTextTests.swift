import Foundation
@testable import PapyrusCore
import PapyrusTestSupport
import Testing

/// M4 텍스트 픽스처 빌더 자체 검증 (설계 §5.6 FB1-FB3).
///
/// `PapyrusTestSupportTests`가 아니라 여기 두는 이유: FB1·FB2는 `PapyrusCore`의
/// `CMapParser`/`LZWDecode`로 재검증해야 하는데 `PapyrusTestSupportTests`는
/// `PapyrusTestSupport`에만 의존하고 `PapyrusCore`에는 의존하지 않는다(Package.swift) —
/// 두 타겟 모두에 의존하는 이 타겟이 유일한 검증 지점이다.
struct FixtureBuilderTextTests {
  // MARK: FB1 — ToUnicode 스트림이 CMapParser로 재파싱 가능

  @Test func simpleFontToUnicodeStreamIsReparsableByCMapParser() async throws {
    let font = ContentStreamInterpreterTests.standardFont()
    let page = ContentStreamInterpreterTests.page(
      operations: "BT /F1 12 Tf 72 720 Td (Hi) Tj ET", fonts: [font]
    )
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: [page])).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)

    // 폰트를 로딩시켜 loadedFont 캐시를 경유하지 않고, 원문 스트림을 직접 재파싱한다:
    // 페이지 텍스트 추출 자체가 이미 ToUnicode를 소비하므로, 결과 문자열이 항등 매핑과
    // 일치하는지로 "CMapParser가 이 스트림을 정확히 재파싱했다"를 간접 검증한다.
    let content = try await document.pageText(at: 0)
    #expect(content.string == "Hi")
  }

  // MARK: FB2 — .lzw 인코딩 라운드트립 (빌더 인코더 ↔ LZWDecode, 실제 PDF 스트림 경유)

  @Test func lzwEncodedContentStreamRoundTripsThroughRealDocument() async throws {
    let font = ContentStreamInterpreterTests.standardFont()
    let page = PDFFixtureBuilder.TextFixtureSpec.TextPageSpec(
      operations: "BT /F1 12 Tf 72 720 Td (LZWText) Tj ET", fonts: [font], encodings: [.lzw]
    )
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: [page])).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let content = try await document.pageText(at: 0)
    #expect(content.string == "LZWText")
  }

  // MARK: FB3 — M2 열기·M3 페이지 트리 통과

  @Test func textFixtureDocumentPassesM2OpenAndM3PageTree() async throws {
    let pages = (0..<3).map { index in
      ContentStreamInterpreterTests.page(
        operations: "BT /F1 12 Tf 72 720 Td (Page\(index)) Tj ET",
        fonts: [ContentStreamInterpreterTests.standardFont()]
      )
    }
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: pages)).build()
    let document = try await PDFDocumentCore.open(data: fixture.data) // M2 열기.
    let snapshot = try await document.pageTree() // M3 페이지 트리.
    #expect(snapshot.pageCount == 3)
    for index in 0..<3 {
      let content = try await document.pageText(at: index)
      #expect(content.string == "Page\(index)")
    }
  }
}
