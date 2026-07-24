import Foundation
@testable import PapyrusCore
import Testing

/// ``TextPosition``·``TextSelection``의 비교·정규화·Codable을 검증한다 (설계 §5.5-1).
struct TextSelectionModelTests {
  // MARK: TextPosition 비교

  @Test func positionComparesByPageFirstThenOffset() {
    #expect(
      TextPosition(pageIndex: 0, utf16Offset: 5) < TextPosition(pageIndex: 1, utf16Offset: 0)
    )
    #expect(
      TextPosition(pageIndex: 2, utf16Offset: 1) < TextPosition(pageIndex: 2, utf16Offset: 5)
    )
    #expect(
      !(TextPosition(pageIndex: 2, utf16Offset: 5) < TextPosition(pageIndex: 2, utf16Offset: 5))
    )
  }

  // MARK: TextSelection 역순 입력 정규화

  @Test func selectionNormalizesReversedInput() {
    let later = TextPosition(pageIndex: 3, utf16Offset: 0)
    let earlier = TextPosition(pageIndex: 1, utf16Offset: 0)
    let selection = TextSelection(start: later, end: earlier)
    #expect(selection.start == earlier)
    #expect(selection.end == later)
  }

  @Test func selectionKeepsOrderWhenAlreadyNormalized() {
    let start = TextPosition(pageIndex: 1, utf16Offset: 2)
    let end = TextPosition(pageIndex: 1, utf16Offset: 8)
    let selection = TextSelection(start: start, end: end)
    #expect(selection.start == start)
    #expect(selection.end == end)
  }

  // MARK: isEmpty / pageRange

  @Test func isEmptyReflectsEqualEndpoints() {
    let point = TextPosition(pageIndex: 0, utf16Offset: 5)
    #expect(TextSelection(start: point, end: point).isEmpty)
    #expect(!TextSelection(start: point, end: TextPosition(pageIndex: 0, utf16Offset: 6)).isEmpty)
  }

  @Test func pageRangeSpansStartToEndPageIndex() {
    let selection = TextSelection(
      start: TextPosition(pageIndex: 1, utf16Offset: 0),
      end: TextPosition(pageIndex: 4, utf16Offset: 3)
    )
    #expect(selection.pageRange == 1...4)
  }

  // MARK: utf16Range(onPage:pageUTF16Length:)

  @Test func utf16RangeOnSinglePageSelection() {
    let selection = TextSelection(
      start: TextPosition(pageIndex: 2, utf16Offset: 3),
      end: TextPosition(pageIndex: 2, utf16Offset: 8)
    )
    #expect(selection.utf16Range(onPage: 2, pageUTF16Length: 20) == 3..<8)
  }

  @Test func utf16RangeOnStartPageOfMultiPageSelection() {
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 5),
      end: TextPosition(pageIndex: 2, utf16Offset: 3)
    )
    #expect(selection.utf16Range(onPage: 0, pageUTF16Length: 10) == 5..<10)
  }

  @Test func utf16RangeOnMiddlePageOfMultiPageSelection() {
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 5),
      end: TextPosition(pageIndex: 2, utf16Offset: 3)
    )
    #expect(selection.utf16Range(onPage: 1, pageUTF16Length: 42) == 0..<42)
  }

  @Test func utf16RangeOnEndPageOfMultiPageSelection() {
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 5),
      end: TextPosition(pageIndex: 2, utf16Offset: 3)
    )
    #expect(selection.utf16Range(onPage: 2, pageUTF16Length: 30) == 0..<3)
  }

  @Test func utf16RangeReturnsNilOutsidePageRange() {
    let selection = TextSelection(
      start: TextPosition(pageIndex: 1, utf16Offset: 0),
      end: TextPosition(pageIndex: 2, utf16Offset: 0)
    )
    #expect(selection.utf16Range(onPage: 0, pageUTF16Length: 10) == nil)
    #expect(selection.utf16Range(onPage: 3, pageUTF16Length: 10) == nil)
  }

  @Test func utf16RangeClampsNegativeOffset() {
    // 음수 오프셋은 Codable 왕복 등에서 발생할 수 있는 방어적 입력 — 크래시 없이 클램프.
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: -5),
      end: TextPosition(pageIndex: 0, utf16Offset: 3)
    )
    #expect(selection.utf16Range(onPage: 0, pageUTF16Length: 10) == 0..<3)
  }

  @Test func utf16RangeClampsOffsetExceedingPageLength() {
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 2),
      end: TextPosition(pageIndex: 0, utf16Offset: 999)
    )
    #expect(selection.utf16Range(onPage: 0, pageUTF16Length: 10) == 2..<10)
  }

  @Test func utf16RangeWithZeroPageLengthIsEmptyRange() {
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 0),
      end: TextPosition(pageIndex: 0, utf16Offset: 0)
    )
    #expect(selection.utf16Range(onPage: 0, pageUTF16Length: 0) == 0..<0)
  }

  // MARK: Codable 왕복 + 역순 JSON 정규화

  @Test func codableRoundTripsNormalizedSelection() throws {
    let selection = TextSelection(
      start: TextPosition(pageIndex: 0, utf16Offset: 1),
      end: TextPosition(pageIndex: 0, utf16Offset: 5)
    )
    let data = try JSONEncoder().encode(selection)
    let decoded = try JSONDecoder().decode(TextSelection.self, from: data)
    #expect(decoded == selection)
  }

  @Test func decodingReversedJSONNormalizesOrder() throws {
    // start/end가 뒤바뀐 JSON — 커스텀 init(from:)이 지정 이니셜라이저를 경유해
    // start <= end 불변식을 강제해야 한다.
    struct RawPair: Encodable {
      let start: TextPosition
      let end: TextPosition
    }
    let reversed = RawPair(
      start: TextPosition(pageIndex: 5, utf16Offset: 0),
      end: TextPosition(pageIndex: 1, utf16Offset: 0)
    )
    let data = try JSONEncoder().encode(reversed)
    let decoded = try JSONDecoder().decode(TextSelection.self, from: data)
    #expect(decoded.start == TextPosition(pageIndex: 1, utf16Offset: 0))
    #expect(decoded.end == TextPosition(pageIndex: 5, utf16Offset: 0))
  }
}
