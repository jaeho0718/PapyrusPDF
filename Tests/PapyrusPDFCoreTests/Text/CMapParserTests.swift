import Foundation
@testable import PapyrusPDFCore
import Testing

/// ``CMapParser``의 ToUnicode/CID CMap 파싱을 검증한다 (설계 §5.2 CM1-CM6).
struct CMapParserTests {
  // MARK: CM1 — bfchar 단건·다건 (리거처 포함)

  @Test func bfCharSingleAndMultiUnitMapsExactly() {
    let source = """
    /CIDInit /ProcSet findresource begin
    begincmap
    1 begincodespacerange
    <00> <FF>
    endcodespacerange
    3 beginbfchar
    <41> <0041>
    <42> <0042>
    <66> <FB0169>
    endbfchar
    endcmap
    end
    """
    let map = CMapParser.parseToUnicode(Data(source.utf8))
    #expect(map.unicode(for: 0x41) == "A")
    #expect(map.unicode(for: 0x42) == "B")
    #expect(map.unicode(for: 0x66) == "\u{FB01}\u{0069}")
    #expect(map.unicode(for: 0x99) == nil)
  }

  // MARK: CM2 — bfrange 증분형·배열형, 큰 range

  @Test func bfRangeIncrementalAndArrayFormsResolveCorrectly() {
    let source = """
    begincmap
    2 beginbfrange
    <0020> <007E> <0020>
    <00A0> <00A2> [<00410042> <0043> <0044>]
    endbfrange
    endcmap
    """
    let map = CMapParser.parseToUnicode(Data(source.utf8))
    #expect(map.unicode(for: 0x0041) == "A")
    #expect(map.unicode(for: 0x0020) == " ")
    #expect(map.unicode(for: 0x007E) == "~")
    #expect(map.unicode(for: 0x00A0) == "AB")
    #expect(map.unicode(for: 0x00A1) == "C")
    #expect(map.unicode(for: 0x00A2) == "D")
    // 거대 range라도 조회는 O(1)에 가깝고(선형 스캔이지만 range 목록만) 메모리는 상수.
    #expect(map.unicode(for: 0xFFFF) == nil)
  }

  // MARK: CM3 — 손상 CMap

  @Test func malformedCMapProducesPartialResultWithoutCrashing() {
    let source = """
    begincmap
    2 beginbfchar
    <41> <0041>
    <BADTOKEN
    <42> <0042>
    endbfchar
    """
    let map = CMapParser.parseToUnicode(Data(source.utf8))
    #expect(map.unicode(for: 0x41) == "A")
  }

  /// CM3 회귀(리뷰 blocker): 역전된 `bfrange`(`lo > hi`)는 `ClosedRange` 생성 크래시 없이
  /// 해당 항목만 스킵해야 한다.
  @Test func invertedBFRangeIsSkippedWithoutCrashing() {
    let source = """
    begincmap
    1 beginbfrange
    <ffff> <0000> <0041>
    endbfrange
    endcmap
    """
    let map = CMapParser.parseToUnicode(Data(source.utf8))
    #expect(map.unicode(for: 0x0000) == nil)
    #expect(map.unicode(for: 0xFFFF) == nil)
  }

  /// CM3 회귀(리뷰 blocker): 역전된 `begincodespacerange`/`begincidrange`는 크래시 없이
  /// 해당 항목만 스킵해야 한다 — `matchByteLength`·`cid(for:byteLength:)` 양쪽 모두 검증.
  @Test func invertedCodespaceAndCIDRangeAreSkippedWithoutCrashing() {
    let source = """
    begincmap
    1 begincodespacerange
    <ffff> <0000>
    endcodespacerange
    1 begincidrange
    <ffff> <0000> 5
    endcidrange
    endcmap
    """
    let map = CMapParser.parseCIDMap(Data(source.utf8))
    // codespace 자체가 전부 역전이라 유효 codespace가 하나도 없으면 nil.
    #expect(map == nil)
  }

  /// CM3 회귀: 유효한 codespace와 역전된 codespace가 섞여 있으면 유효한 것만 남고,
  /// 역전된 codespace/cidrange를 향한 조회는 크래시 없이 매핑 실패로 처리된다.
  @Test func invertedRangeAmongValidRangesIsSkippedButOthersSurvive() {
    let source = """
    begincmap
    2 begincodespacerange
    <00> <80>
    <ffff> <0000>
    endcodespacerange
    2 begincidrange
    <00> <7F> 0
    <ffff> <0000> 100
    endcidrange
    endcmap
    """
    guard let map = CMapParser.parseCIDMap(Data(source.utf8)) else {
      Issue.record("유효한 codespace가 하나 있으므로 nil이면 안 된다")
      return
    }
    #expect(map.matchByteLength(startingAt: [0x41][...]) == 1)
    #expect(map.cid(for: 0x41, byteLength: 1) == 0x41)
    // 역전된 codespace/cidrange는 어떤 바이트에도 매칭되지 않는다(크래시 없이).
    #expect(map.matchByteLength(startingAt: [0xFF, 0xFF][...]) == nil)
  }

  // MARK: CM4 — 엔트리 캡 초과

  @Test func entryCapStopsParsingWithoutError() {
    var lines = ["begincmap", "\(CoreLimits.maxCMapEntries + 10) beginbfchar"]
    for code in 0..<(CoreLimits.maxCMapEntries + 10) {
      let hex = String(format: "%04X", code % 0xFFFF)
      lines.append("<\(hex)> <\(hex)>")
    }
    lines.append("endbfchar")
    lines.append("endcmap")
    let map = CMapParser.parseToUnicode(Data(lines.joined(separator: "\n").utf8))
    // 캡에 도달하면 중단하지만 앞서 파싱된 엔트리는 유효하다.
    #expect(map.unicode(for: 0x0000) == "\u{0000}")
  }

  // MARK: CM5 — codespacerange 1/2바이트 혼합 CID CMap

  @Test func mixedByteLengthCodespaceAndCIDRangesResolveCorrectly() {
    let source = """
    begincmap
    2 begincodespacerange
    <00> <80>
    <8100> <FEFF>
    endcodespacerange
    2 begincidrange
    <00> <7F> 0
    <8100> <8200> 1000
    endcidrange
    1 begincidchar
    <20> 500
    endcidchar
    endcmap
    """
    guard let map = CMapParser.parseCIDMap(Data(source.utf8)) else {
      Issue.record("CID map 파싱 실패")
      return
    }
    #expect(map.matchByteLength(startingAt: [0x41][...]) == 1)
    #expect(map.matchByteLength(startingAt: [0x81, 0x00][...]) == 2)
    #expect(map.cid(for: 0x41, byteLength: 1) == 0x41)
    #expect(map.cid(for: 0x20, byteLength: 1) == 500)
    #expect(map.cid(for: 0x8101, byteLength: 2) == 1001)
  }

  // MARK: CM6 — /WMode 1

  @Test func wModeOneSetsVerticalFlag() {
    let source = """
    begincmap
    1 begincodespacerange
    <0000> <FFFF>
    endcodespacerange
    /WMode 1 def
    endcmap
    """
    let map = CMapParser.parseCIDMap(Data(source.utf8))
    #expect(map?.vertical == true)
  }

  @Test func wModeDefaultsToHorizontal() {
    let source = """
    begincmap
    1 begincodespacerange
    <0000> <FFFF>
    endcodespacerange
    endcmap
    """
    let map = CMapParser.parseCIDMap(Data(source.utf8))
    #expect(map?.vertical == false)
  }

  @Test func missingCodespaceReturnsNil() {
    let map = CMapParser.parseCIDMap(Data("begincmap endcmap".utf8))
    #expect(map == nil)
  }
}
