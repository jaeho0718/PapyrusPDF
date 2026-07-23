import CoreGraphics
import Foundation
@testable import PapyrusCore
import Testing

/// ``FontLoader``/``LoadedFont``/``GlyphList``/``PDFBaseEncoding``을 검증한다
/// (설계 §5.2 FL1-FL9).
struct FontLoaderTests {
  // MARK: FL1 — /Differences 오버레이

  @Test func differencesOverlayReplacesOnlyTargetedCodes() {
    let encoding = COSObject.dictionary(COSDictionary([
      .baseEncoding: .name(.winAnsiEncoding),
      .differences: .array([.integer(65), .name("Euro")])
    ]))
    let inputs = FontLoader.Inputs(
      fontDictionary: COSDictionary([.subtype: .name(.type1)]), encodingObject: encoding
    )
    let font = FontLoader.build(inputs)
    // 코드 65는 오버라이드(Euro)만 반영, 코드 66은 WinAnsi 원본(B)을 유지한다.
    #expect(font.unicode(for: CharacterCode(value: 65, byteLength: 1)) == "\u{20AC}")
    #expect(font.unicode(for: CharacterCode(value: 66, byteLength: 1)) == "B")
  }

  // MARK: FL2 — /Encoding 부재 → Standard, 이름 지정 → 해당 테이블

  @Test func missingEncodingFallsBackToStandard() {
    let inputs = FontLoader.Inputs(fontDictionary: COSDictionary([.subtype: .name(.type1)]))
    let font = FontLoader.build(inputs)
    // Standard는 39번 코드가 quoteright(U+2019) — WinAnsi(quotesingle, ')와 구분된다.
    #expect(font.unicode(for: CharacterCode(value: 39, byteLength: 1)) == "\u{2019}")
  }

  @Test func namedEncodingSelectsCorrectTable() {
    let inputs = FontLoader.Inputs(
      fontDictionary: COSDictionary([.subtype: .name(.type1)]),
      encodingObject: .name(.winAnsiEncoding)
    )
    let font = FontLoader.build(inputs)
    #expect(font.unicode(for: CharacterCode(value: 39, byteLength: 1)) == "'")
  }

  // MARK: FL3 — AGL 해석 경로

  @Test func glyphListResolvesDirectSubsetEntries() {
    #expect(GlyphList.unicode(forGlyphName: "space") == " ")
    #expect(GlyphList.unicode(forGlyphName: "fi") == "\u{FB01}")
  }

  @Test func glyphListResolvesUniAndUAlgorithmicNames() {
    #expect(GlyphList.unicode(forGlyphName: "uni0041") == "A")
    let expectedEmoji = String(Character(Unicode.Scalar(0x1F600)!))
    #expect(GlyphList.unicode(forGlyphName: "u1F600") == expectedEmoji)
    #expect(GlyphList.unicode(forGlyphName: "u41") == nil) // 4자리 미만은 무효
  }

  @Test func glyphListResolvesSingleCharacterNames() {
    #expect(GlyphList.unicode(forGlyphName: "A") == "A")
    #expect(GlyphList.unicode(forGlyphName: "z") == "z")
  }

  @Test func glyphListReturnsNilForUnknownNames() {
    #expect(GlyphList.unicode(forGlyphName: "totallyUnknownGlyphName") == nil)
  }

  // MARK: FL4 — /FirstChar+/Widths, /MissingWidth 폴백

  @Test func simpleWidthsResolveWithMissingWidthFallback() {
    let inputs = FontLoader.Inputs(
      fontDictionary: COSDictionary([
        .subtype: .name(.type1), .firstChar: .integer(65),
        .widths: .array([.integer(600), .integer(700)])
      ]),
      descriptor: COSDictionary([.missingWidth: .integer(250)])
    )
    let font = FontLoader.build(inputs)
    #expect(font.width(for: CharacterCode(value: 65, byteLength: 1)) == 600)
    #expect(font.width(for: CharacterCode(value: 66, byteLength: 1)) == 700)
    #expect(font.width(for: CharacterCode(value: 90, byteLength: 1)) == 250)
  }

  // MARK: FL5 — /W 두 형식 혼합 + /DW 폴백

  @Test func cidWidthsResolveMixedFormsWithDefaultWidthFallback() {
    let descendant = FontLoader.Inputs.DescendantInputs(
      fontDictionary: COSDictionary([.dw: .integer(999)]),
      widthsArray: [
        .integer(1), .array([.integer(100), .integer(200)]),
        .integer(10), .integer(12), .integer(500)
      ],
      encodingName: .identityH
    )
    let inputs = FontLoader.Inputs(
      fontDictionary: COSDictionary([.subtype: .name(.type0)]), descendant: descendant
    )
    let font = FontLoader.build(inputs)
    #expect(font.width(for: CharacterCode(value: 1, byteLength: 2)) == 100)
    #expect(font.width(for: CharacterCode(value: 2, byteLength: 2)) == 200)
    #expect(font.width(for: CharacterCode(value: 11, byteLength: 2)) == 500)
    #expect(font.width(for: CharacterCode(value: 999, byteLength: 2)) == 999)
  }

  /// FL5 회귀(리뷰 should #2): 겹치는 `/W` 구간은 나중에 등장한 구간이 우선하도록
  /// 정규화되어 이진 탐색 조회가 결정적이어야 한다. `[0 10 50]`(0..10 → 50) 뒤에
  /// `[5 7 999]`(5..7 → 999)가 오면 5..7은 999, 나머지(0..4, 8..10)는 50이어야 한다.
  @Test func overlappingCIDWidthRangesNormalizeWithLaterEntryWinning() {
    let elements: [COSObject] = [
      .integer(0), .integer(10), .integer(50),
      .integer(5), .integer(7), .integer(999)
    ]
    let table = CIDWidthTable.build(from: elements)
    #expect(table.width(forCID: 0) == 50)
    #expect(table.width(forCID: 4) == 50)
    #expect(table.width(forCID: 5) == 999)
    #expect(table.width(forCID: 6) == 999)
    #expect(table.width(forCID: 7) == 999)
    #expect(table.width(forCID: 8) == 50)
    #expect(table.width(forCID: 10) == 50)
    #expect(table.width(forCID: 11) == nil)
  }

  /// FL5 회귀: 개별 폭 배열 구간이 뒤따르는 균일 구간에 부분적으로 덮이면, 덮이지 않은
  /// 꼬리 조각의 개별 폭 값이 원래 인덱스에 맞게 보존되어야 한다.
  @Test func overlappingIndividualWidthArraySlicesPreserveRemainingValues() {
    let elements: [COSObject] = [
      .integer(0), .array([.integer(10), .integer(20), .integer(30), .integer(40)]),
      .integer(1), .integer(2), .integer(999)
    ]
    let table = CIDWidthTable.build(from: elements)
    #expect(table.width(forCID: 0) == 10)
    #expect(table.width(forCID: 1) == 999)
    #expect(table.width(forCID: 2) == 999)
    #expect(table.width(forCID: 3) == 40)
  }

  /// FL5 회귀(재리뷰 blocker): CID 값이 `UInt32` 표현 범위를 넘으면(재현 입력
  /// `/W [5_000_000_000 [500 600]]` 그대로) 강제 변환 트랩 없이 해당 엔트리를 스킵해야
  /// 한다.
  @Test func outOfRangeCIDValueIsSkippedWithoutTrapping() {
    let elements: [COSObject] = [
      .integer(5_000_000_000), .array([.integer(500), .integer(600)])
    ]
    let table = CIDWidthTable.build(from: elements)
    #expect(table.width(forCID: 0) == nil)
    #expect(table.width(forCID: 100) == nil)
  }

  /// FL5 회귀(재리뷰 blocker): 음수 CID도 `UInt32(exactly:)` 검증에 걸려 트랩 없이
  /// 스킵되어야 한다.
  @Test func negativeCIDValueIsSkippedWithoutTrapping() {
    let elements: [COSObject] = [
      .integer(-5), .array([.integer(100), .integer(200)])
    ]
    let table = CIDWidthTable.build(from: elements)
    #expect(table.width(forCID: 0) == nil)
  }

  /// FL5 회귀: 균일 구간의 `c2`(second)가 범위를 벗어나도 트랩 없이 그 엔트리만 스킵되고,
  /// 파서는 재동기화해 이후 유효한 엔트리를 계속 인식해야 한다.
  @Test func outOfRangeUniformSecondValueIsSkippedButParsingRecovers() {
    let elements: [COSObject] = [
      .integer(0), .integer(5_000_000_000), .integer(100),
      .integer(10), .integer(20), .integer(999)
    ]
    let table = CIDWidthTable.build(from: elements)
    #expect(table.width(forCID: 15) == 999)
  }

  /// FL5 회귀: 개별 폭 배열 구간의 `lo + (widths.count-1)`이 `UInt32` 상한을 넘겨
  /// 오버플로하면(다른 정수 변환 지점) 트랩 없이 스킵되고, 이후 엔트리는 정상 인식된다.
  @Test func arrayFormUpperBoundOverflowIsSkippedButParsingRecovers() {
    let elements: [COSObject] = [
      .integer(Int(UInt32.max) - 1), .array([.integer(100), .integer(200), .integer(300)]),
      .integer(0), .integer(0), .integer(500)
    ]
    let table = CIDWidthTable.build(from: elements)
    #expect(table.width(forCID: UInt32.max - 1) == nil)
    #expect(table.width(forCID: 0) == 500)
  }

  // MARK: FL6 — Type3 /FontMatrix 폭 스케일

  @Test func type3FontMatrixScalesWidths() {
    let inputs = FontLoader.Inputs(fontDictionary: COSDictionary([
      .subtype: .name(.type3), .firstChar: .integer(0),
      .widths: .array([.integer(500)]),
      .fontMatrix: .array([
        .real(0.002), .integer(0), .integer(0), .real(0.002), .integer(0), .integer(0)
      ])
    ]))
    let font = FontLoader.build(inputs)
    #expect(font.width(for: CharacterCode(value: 0, byteLength: 1)) == 1_000)
  }

  // MARK: FL7 — ToUnicode > 인코딩 우선순위

  @Test func toUnicodeTakesPriorityOverEncoding() {
    let toUnicodeSource = """
    begincmap
    1 beginbfchar
    <41> <0058>
    endbfchar
    endcmap
    """
    let inputs = FontLoader.Inputs(
      fontDictionary: COSDictionary([.subtype: .name(.type1)]),
      toUnicodeData: Data(toUnicodeSource.utf8), encodingObject: .name(.winAnsiEncoding)
    )
    let font = FontLoader.build(inputs)
    // WinAnsi 코드 65는 'A'지만, ToUnicode가 'X'(0x58)로 재매핑한다.
    #expect(font.unicode(for: CharacterCode(value: 65, byteLength: 1)) == "X")
  }

  // MARK: FL8 — 사전정의 CMap 이름 + ToUnicode 없음

  @Test func predefinedCMapNameFallsBackToReplacementCharacter() {
    let descendant = FontLoader.Inputs.DescendantInputs(
      fontDictionary: COSDictionary([.dw: .integer(1_000)]),
      encodingName: COSName("UniJIS-UCS2-H")
    )
    let inputs = FontLoader.Inputs(
      fontDictionary: COSDictionary([.subtype: .name(.type0)]), descendant: descendant
    )
    let font = FontLoader.build(inputs)
    guard case .unsupportedPredefined = font.layout else {
      Issue.record("unsupportedPredefined 레이아웃 기대")
      return
    }
    #expect(font.unicode(for: CharacterCode(value: 0x3042, byteLength: 2)) == "\u{FFFD}")
    #expect(font.width(for: CharacterCode(value: 0x3042, byteLength: 2)) == 1_000)
  }

  // MARK: FL9 — 손상 폰트 딕셔너리

  @Test func malformedFontDictionaryConvergesToFallbackWithoutThrowing() {
    let inputs = FontLoader.Inputs(fontDictionary: COSDictionary())
    let font = FontLoader.build(inputs)
    #expect(font.unicode(for: CharacterCode(value: 65, byteLength: 1)) != "")

    let fallback = FontLoader.fallbackFont()
    #expect(fallback.unicode(for: CharacterCode(value: 1, byteLength: 1)) == "\u{FFFD}")
    #expect(fallback.width(for: CharacterCode(value: 1, byteLength: 1)) == 500)
  }
}
