import CoreGraphics
import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// 콘텐츠 스트림 인터프리터 + 지오메트리 통합 테스트 (설계 §5.3 CI1-CI16).
struct ContentStreamInterpreterTests {
  // MARK: CI1 — 단순 텍스트, 위치

  @Test func simpleTextExtractsStringAndOrigin() async throws {
    let page = Self.page(
      operations: "BT /F1 12 Tf 72 720 Td (Hello) Tj ET", fonts: [Self.standardFont()]
    )
    let content = try await Self.extract(page)
    #expect(content.string == "Hello")
    #expect(content.runs.count == 1)
    let quad = content.runs[0].quad
    #expect(abs(quad.bottomLeft.x - 72) < 0.01)
    #expect(quad.bottomLeft.y < 720)
    #expect(quad.topLeft.y > 720)
  }

  // MARK: CI2 — Td/TD/Tm/T* 위치 연쇄

  @Test func positioningOperatorsChainCorrectly() async throws {
    let operations = """
    BT /F1 10 Tf 100 700 Td (A) Tj
    20 -15 Td (B) Tj
    T* (C) Tj
    1 0 0 1 300 500 Tm (D) Tj
    ET
    """
    let page = Self.page(operations: operations, fonts: [Self.standardFont()])
    let content = try await Self.extract(page)
    #expect(content.runs.count == 4)
    // A: origin(100,700). B: Td(20,-15) → (120,685). C: T*(0,-TL=0) → 동일 y(685) 좌표 유지(TL 미설정=0).
    #expect(abs(content.runs[0].quad.bottomLeft.x - 100) < 0.01)
    #expect(abs(content.runs[1].quad.bottomLeft.x - 120) < 0.01)
    #expect(abs(content.runs[3].quad.bottomLeft.x - 300) < 0.01)
  }

  // MARK: CI3 — TJ 배열 + 큰 음수 오프셋

  @Test func tjArrayWithLargeNegativeOffsetSplitsWords() async throws {
    let page = Self.page(
      operations: #"BT /F1 12 Tf 72 720 Td [(He) -300 (llo)] TJ ET"#, fonts: [Self.standardFont()]
    )
    let content = try await Self.extract(page)
    #expect(content.runs.count == 2)
    let acceptable = ["He llo", "Hello"]
    #expect(acceptable.contains(content.string) || content.string.hasPrefix("He"))
  }

  // MARK: CI4 — Tc/Tw/Tz 반영 advance

  @Test func characterAndWordSpacingAffectAdvances() async throws {
    let page = Self.page(
      operations: "BT /F1 12 Tf 10 Tc 0 Tw 100 Tz 0 0 Td (AA) Tj ET", fonts: [Self.standardFont()]
    )
    let content = try await Self.extract(page)
    #expect(content.runs.count == 1)
    #expect(content.runs[0].advances.count == 2)
    // 폭 600(1000단위)/1000×12 + Tc(10) = 7.2+10 = 17.2 (Tz=100%→배율1).
    #expect(abs(content.runs[0].advances[0] - 17.2) < 0.01)
  }

  // MARK: CI5 — cm 스케일·회전 (45°)

  @Test func rotatedTextProducesNonAxisAlignedQuad() async throws {
    let radians = Double.pi / 4
    let cosValue = cos(radians)
    let sinValue = sin(radians)
    let operations = "q \(cosValue) \(sinValue) \(-sinValue) \(cosValue) 200 300 cm " +
      "BT /F1 12 Tf 0 0 Td (Hi) Tj ET Q"
    let page = Self.page(operations: operations, fonts: [Self.standardFont()])
    let content = try await Self.extract(page)
    #expect(content.runs.count == 1)
    let quad = content.runs[0].quad
    // 회전 45도이므로 bottomLeft와 bottomRight의 y가 달라야 한다(축 정렬 아님).
    #expect(abs(quad.bottomLeft.y - quad.bottomRight.y) > 0.5)
    #expect(quad.boundingRect.width > 0)
  }

  // MARK: CI6 — Ts(rise) 반영

  @Test func riseShiftsQuadVertically() async throws {
    let baseline = Self.page(
      operations: "BT /F1 12 Tf 72 720 Td (A) Tj ET", fonts: [Self.standardFont()]
    )
    let raised = Self.page(
      operations: "BT /F1 12 Tf 5 Ts 72 720 Td (A) Tj ET", fonts: [Self.standardFont()]
    )
    let baseContent = try await Self.extract(baseline)
    let raisedContent = try await Self.extract(raised)
    #expect(raisedContent.runs[0].quad.bottomLeft.y - baseContent.runs[0].quad.bottomLeft.y > 4)
  }

  // MARK: CI7 — Tr 3 투명 텍스트

  @Test func renderMode3MarksInvisibleButKeepsText() async throws {
    let page = Self.page(
      operations: "BT /F1 12 Tf 3 Tr 72 720 Td (Hidden) Tj ET", fonts: [Self.standardFont()]
    )
    let content = try await Self.extract(page)
    #expect(content.string == "Hidden")
    #expect(content.runs[0].isInvisible == true)
  }

  // MARK: CI8 — Type0 Identity-H

  @Test func identityHDecodesTwoByteCodesWithToUnicodeAndWidths() async throws {
    let font = PDFFixtureBuilder.TextFixtureSpec.FontFixtureSpec(
      resourceName: "F1",
      kind: .type0IdentityH(
        baseFont: "TestCID", toUnicode: [1: "A", 2: "B"],
        cidWidths: [.init(first: 1, last: 2, width: 1_000)], defaultWidth: 1_000
      ),
      descriptor: .init(ascent: 800, descent: -200)
    )
    let page = Self.page(
      operations: "BT /F1 10 Tf 0 0 Td <00010002> Tj ET", fonts: [font]
    )
    let content = try await Self.extract(page)
    #expect(content.string == "AB")
    #expect(content.runs.count == 1)
    #expect(content.runs[0].advances.count == 2)
    #expect(abs(content.runs[0].advances[0] - 10) < 0.01) // 1000/1000×10
  }

  // MARK: CI9 — Form XObject 내 텍스트 (Matrix 오프셋)

  @Test func formXObjectTextReflectsMatrixOffset() async throws {
    let form = PDFFixtureBuilder.TextFixtureSpec.FormXObjectFixtureSpec(
      resourceName: "Fm1", operations: "BT /F1 12 Tf 0 0 Td (Hi) Tj ET",
      matrix: [1, 0, 0, 1, 50, 60], fonts: [Self.standardFont()]
    )
    let page = Self.page(operations: "q 1 0 0 1 0 0 cm /Fm1 Do Q", fonts: [], formXObjects: [form])
    let content = try await Self.extract(page)
    #expect(content.string == "Hi")
    #expect(abs(content.runs[0].quad.bottomLeft.x - 50) < 0.01)
  }

  // MARK: CI10 — 폼 자기 참조 (순환)

  @Test func selfReferencingFormDoesNotInfiniteLoop() async throws {
    let form = PDFFixtureBuilder.TextFixtureSpec.FormXObjectFixtureSpec(
      resourceName: "Fm1", operations: "BT /F1 12 Tf 0 0 Td (X) Tj ET /Fm1 Do",
      fonts: [Self.standardFont()]
    )
    let page = Self.page(operations: "/Fm1 Do", fonts: [], formXObjects: [form])
    let content = try await Self.extract(page)
    // 순환은 절단되지만, 최초 1회분 텍스트는 보존된다.
    #expect(content.string.contains("X"))
  }

  // MARK: CI11 — 인라인 이미지 사이의 텍스트

  @Test func inlineImageIsSkippedTextAroundItSurvives() async throws {
    let operations = """
    BT /F1 12 Tf 72 720 Td (Before) Tj ET
    BI /W 2 /H 2 /BPC 8 /CS /G ID \u{01}\u{02}\u{03}\u{04} EI
    BT /F1 12 Tf 72 700 Td (After) Tj ET
    """
    let page = Self.page(operations: operations, fonts: [Self.standardFont()])
    let content = try await Self.extract(page)
    #expect(content.string.contains("Before"))
    #expect(content.string.contains("After"))
  }

  // MARK: CI12 — 미지 연산자·오퍼랜드 부족·q/Q 불균형

  @Test func unknownOperatorsAndUnbalancedStateAreIgnored() async throws {
    let operations = "Q Q /Nonexistent gs BT /F1 12 Tf 72 720 Td (Ok) Tj ET q q"
    let page = Self.page(operations: operations, fonts: [Self.standardFont()])
    let content = try await Self.extract(page)
    #expect(content.string == "Ok")
  }

  // MARK: CI13 — 손상 콘텐츠 (바이너리 쓰레기 삽입)

  @Test func corruptedBinaryGarbageDoesNotCrashAndRecoversTail() async throws {
    var bytes = Array("BT /F1 12 Tf 72 720 Td (Head) Tj ET ".utf8)
    bytes.append(contentsOf: [0xFF, 0xFE, 0x00, 0x01, 0x02])
    bytes.append(contentsOf: Array(" BT /F1 12 Tf 72 700 Td (Tail) Tj ET".utf8))
    // `String(decoding:as:)`는 실패하지 않는(손실 허용) 안전한 변환이라 여기서는 규칙의
    // 우려(강제 언래핑 크래시)에 해당하지 않는다 — 병적 바이너리 바이트를 그대로 보존한다.
    // swiftlint:disable:next optional_data_string_conversion
    let operationsText = String(decoding: bytes, as: UTF8.self)
    let page = PDFFixtureBuilder.TextFixtureSpec.TextPageSpec(
      operations: operationsText, fonts: [Self.standardFont()]
    )
    let content = try await Self.extract(page)
    #expect(content.string.contains("Head"))
  }

  // MARK: CI14 — advances 누적합 == quad 폭 (수평 무회전)

  @Test func advancesSumMatchesQuadWidthForHorizontalText() async throws {
    let page = Self.page(
      operations: "BT /F1 12 Tf 72 720 Td (Hello) Tj ET", fonts: [Self.standardFont()]
    )
    let content = try await Self.extract(page)
    let run = content.runs[0]
    let totalAdvance = run.advances.reduce(0, +)
    let quadWidth = run.quad.bottomRight.x - run.quad.bottomLeft.x
    #expect(abs(totalAdvance - quadWidth) < 0.01)
  }

  // MARK: CI15 — /Contents 배열(세그먼트 경계에서 토큰 분리)

  @Test func splitContentSegmentsReconnectAcrossTokenBoundary() async throws {
    let operations = "BT /F1 12 Tf 72 720 Td (Hello) Tj ET"
    // 숫자 토큰 "720"과 "Td" 사이(공백 경계)에서 분할 — 세그먼트 연결 시 삽입되는 공백
    // 1바이트가 기존 공백과 합쳐질 뿐 토큰 자체는 끊기지 않는다.
    guard let range = operations.range(of: "720 Td") else {
      Issue.record("고정 픽스처 텍스트 불일치")
      return
    }
    let breakPoint = operations.utf8.distance(
      from: operations.utf8.startIndex, to: range.lowerBound.samePosition(in: operations.utf8)!
    ) + 3
    let page = PDFFixtureBuilder.TextFixtureSpec.TextPageSpec(
      operations: operations, fonts: [Self.standardFont()], segmentBreaks: [breakPoint]
    )
    let content = try await Self.extract(page)
    #expect(content.string == "Hello")
  }

  // MARK: CI16 — 글리프 캡

  @Test func glyphCapTruncatesPathologicalRepetition() async throws {
    let repeated = String(repeating: "(AAAAAAAAAA) Tj ", count: CoreLimits.maxGlyphsPerPage / 5)
    let page = Self.page(
      operations: "BT /F1 12 Tf 72 720 Td \(repeated) ET", fonts: [Self.standardFont()]
    )
    let content = try await Self.extract(page)
    #expect(content.runs.count <= CoreLimits.maxGlyphsPerPage)
    #expect(content.string.count <= CoreLimits.maxGlyphsPerPage)
    #expect(!content.string.isEmpty)
  }
}

// MARK: - 테스트 헬퍼

extension ContentStreamInterpreterTests {
  /// ASCII 32...126을 항등 매핑하는 ToUnicode + 균일 600 폭을 갖는 표준 테스트 폰트.
  static func standardFont(
    resourceName: String = "F1"
  ) -> PDFFixtureBuilder.TextFixtureSpec.FontFixtureSpec {
    var toUnicode: [UInt8: String] = [:]
    for code in 32...126 {
      toUnicode[UInt8(code)] = String(UnicodeScalar(UInt8(code)))
    }
    let widths = Array(repeating: 600, count: 95)
    return PDFFixtureBuilder.TextFixtureSpec.FontFixtureSpec(
      resourceName: resourceName,
      kind: .simple(
        baseFont: "Helvetica", baseEncoding: "WinAnsiEncoding", differences: [:], firstChar: 32,
        widths: widths, toUnicode: toUnicode
      ),
      descriptor: .init(ascent: 800, descent: -200)
    )
  }

  static func page(
    operations: String, fonts: [PDFFixtureBuilder.TextFixtureSpec.FontFixtureSpec],
    formXObjects: [PDFFixtureBuilder.TextFixtureSpec.FormXObjectFixtureSpec] = []
  ) -> PDFFixtureBuilder.TextFixtureSpec.TextPageSpec {
    PDFFixtureBuilder.TextFixtureSpec.TextPageSpec(
      operations: operations, fonts: fonts, formXObjects: formXObjects
    )
  }

  static func extract(
    _ page: PDFFixtureBuilder.TextFixtureSpec.TextPageSpec
  ) async throws -> PageTextContent {
    let fixture = PDFFixtureBuilder(textFixture: .init(pages: [page])).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    return try await document.pageText(at: 0)
  }
}
