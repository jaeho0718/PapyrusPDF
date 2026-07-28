import CoreGraphics
import Foundation

// 3단 중첩(FontLoader → Inputs → DescendantInputs)은 M4 설계(§2.3)가 명시한 구조를 그대로
// 따른다 — SwiftLint 기본 `nesting`(최대 1단) 규칙과 충돌하므로 이 파일 범위에서만 끈다.
// swiftlint:disable nesting

/// 폰트 딕셔너리 → `LoadedFont` 순수 빌드. 액터가 참조 해소·스트림 디코딩을 끝낸
/// `Inputs`를 만들어 넘기고, CPU 작업(CMap 파싱·테이블 조립)은 여기서 nonisolated 실행.
package enum FontLoader {
  /// 사전 해소 완료된 폰트 로딩 입력 (전부 값 — Sendable).
  package struct Inputs: Sendable {
    /// 폰트 딕셔너리 (1레벨 해소 완료).
    package var fontDictionary: COSDictionary
    /// `/FontDescriptor` (해소 완료).
    package var descriptor: COSDictionary?
    /// ToUnicode 스트림 디코딩 완료 바이트.
    package var toUnicodeData: Data?
    /// `/Encoding` (이름 또는 딕셔너리, 해소 완료).
    package var encodingObject: COSObject?
    /// Type0 전용 — DescendantFonts[0] 관련 입력.
    package var descendant: DescendantInputs?

    /// Type0 하위 폰트(DescendantFonts[0])의 사전 해소 입력.
    package struct DescendantInputs: Sendable {
      /// DescendantFonts[0] 딕셔너리 (해소 완료).
      package var fontDictionary: COSDictionary
      /// 하위 폰트의 `/FontDescriptor` (해소 완료).
      package var descriptor: COSDictionary?
      /// `/W` 배열 (해소 완료).
      package var widthsArray: [COSObject]?
      /// `/Encoding`이 스트림이면 그 디코딩 결과.
      package var embeddedCMapData: Data?
      /// `/Encoding`이 이름이면(Identity-H 등).
      package var encodingName: COSName?

      /// 하위 폰트 입력을 생성한다.
      /// - Parameters:
      ///   - fontDictionary: DescendantFonts[0] 딕셔너리 (해소 완료).
      ///   - descriptor: 하위 폰트의 `/FontDescriptor` (해소 완료).
      ///   - widthsArray: `/W` 배열 (해소 완료).
      ///   - embeddedCMapData: `/Encoding`이 스트림이면 그 디코딩 결과.
      ///   - encodingName: `/Encoding`이 이름이면.
      package init(
        fontDictionary: COSDictionary, descriptor: COSDictionary? = nil,
        widthsArray: [COSObject]? = nil, embeddedCMapData: Data? = nil,
        encodingName: COSName? = nil
      ) {
        self.fontDictionary = fontDictionary
        self.descriptor = descriptor
        self.widthsArray = widthsArray
        self.embeddedCMapData = embeddedCMapData
        self.encodingName = encodingName
      }
    }

    /// 폰트 로딩 입력을 생성한다.
    /// - Parameters:
    ///   - fontDictionary: 폰트 딕셔너리 (1레벨 해소 완료).
    ///   - descriptor: `/FontDescriptor` (해소 완료).
    ///   - toUnicodeData: ToUnicode 스트림 디코딩 완료 바이트.
    ///   - encodingObject: `/Encoding` (해소 완료).
    ///   - descendant: Type0 전용 하위 폰트 입력.
    package init(
      fontDictionary: COSDictionary, descriptor: COSDictionary? = nil, toUnicodeData: Data? = nil,
      encodingObject: COSObject? = nil, descendant: DescendantInputs? = nil
    ) {
      self.fontDictionary = fontDictionary
      self.descriptor = descriptor
      self.toUnicodeData = toUnicodeData
      self.encodingObject = encodingObject
      self.descendant = descendant
    }
  }

  /// 어떤 입력에도 throw하지 않는다 — 해석 불능 조합은 폴백 폰트 규칙으로 수렴 (§3.2).
  /// - Parameter inputs: 사전 해소된 폰트 로딩 입력.
  /// - Returns: 로딩 완료된 폰트.
  package static func build(_ inputs: Inputs) -> LoadedFont {
    let toUnicode = inputs.toUnicodeData.map { CMapParser.parseToUnicode($0) }
    if let descendant = inputs.descendant {
      return Self.buildType0(inputs: inputs, descendant: descendant, toUnicode: toUnicode)
    }
    return Self.buildSimple(inputs: inputs, toUnicode: toUnicode)
  }

  /// 폰트 해소 실패 시의 폴백 (1바이트, U+FFFD, 폭 500) — 위치 보존용.
  /// - Returns: 폴백 폰트.
  package static func fallbackFont() -> LoadedFont {
    LoadedFont(
      layout: .simple, toUnicode: nil, simpleEncoding: nil, simpleWidths: nil, cidWidths: nil,
      defaultWidth: 1_000, missingWidth: 500, ascent: 800, descent: -200
    )
  }
}

// swiftlint:enable nesting

// MARK: - Type0 빌드

extension FontLoader {
  private static func buildType0(
    inputs: Inputs, descendant: Inputs.DescendantInputs, toUnicode: ToUnicodeMap?
  ) -> LoadedFont {
    let layout = Self.type0Layout(descendant: descendant)
    let cidWidths = descendant.widthsArray.map(CIDWidthTable.build(from:))
    let defaultWidth = Self.numeric(descendant.fontDictionary, key: .dw, default: 1_000)
    let descriptor = descendant.descriptor
    return LoadedFont(
      layout: layout, toUnicode: toUnicode, simpleEncoding: nil, simpleWidths: nil,
      cidWidths: cidWidths, defaultWidth: defaultWidth,
      missingWidth: Self.numeric(descriptor, key: .missingWidth, default: 0),
      ascent: Self.numeric(descriptor, key: .ascent, default: 800),
      descent: Self.numeric(descriptor, key: .descent, default: -200)
    )
  }

  /// `/Encoding`으로부터 코드 해석 방식을 판정한다 (§3.2).
  private static func type0Layout(descendant: Inputs.DescendantInputs) -> LoadedFont.CodeLayout {
    if descendant.encodingName == .identityH {
      return .identity(vertical: false)
    }
    if descendant.encodingName == .identityV {
      return .identity(vertical: true)
    }
    if let cmapData = descendant.embeddedCMapData, let map = CMapParser.parseCIDMap(cmapData) {
      return .embeddedCMap(map, vertical: map.vertical)
    }
    return .unsupportedPredefined(vertical: false)
  }
}

// MARK: - 단순 폰트 빌드

extension FontLoader {
  private static func buildSimple(inputs: Inputs, toUnicode: ToUnicodeMap?) -> LoadedFont {
    let baseTable = Self.resolveBaseEncoding(inputs.encodingObject)
    let glyphNames = Self.applyDifferences(base: baseTable, encodingObject: inputs.encodingObject)
    let simpleEncoding = glyphNames.map { name in name.flatMap(GlyphList.unicode(forGlyphName:)) }
    let scale = Self.type3WidthScale(inputs: inputs)
    let simpleWidths = Self.buildSimpleWidths(inputs: inputs, scale: scale)
    let descriptor = inputs.descriptor
    return LoadedFont(
      layout: .simple, toUnicode: toUnicode, simpleEncoding: simpleEncoding,
      simpleWidths: simpleWidths, cidWidths: nil, defaultWidth: 1_000,
      missingWidth: Self.numeric(descriptor, key: .missingWidth, default: 0),
      ascent: Self.numeric(descriptor, key: .ascent, default: 800),
      descent: Self.numeric(descriptor, key: .descent, default: -200)
    )
  }

  /// `/Encoding`(이름 또는 딕셔너리의 `/BaseEncoding`)으로 기본 인코딩 테이블을 고른다.
  /// 부재·미인식은 standard.
  private static func resolveBaseEncoding(_ encodingObject: COSObject?) -> [String?] {
    switch encodingObject {
    case let .name(name):
      return PDFBaseEncoding.table(named: name)
    case let .dictionary(dictionary):
      return PDFBaseEncoding.table(named: dictionary.name(for: .baseEncoding))
    default:
      return PDFBaseEncoding.table(named: nil)
    }
  }

  /// `/Differences` 오버레이 — 정수는 다음 코드 설정, 이름은 현재 코드에 배정 후 +1.
  /// 0~255 밖 코드는 스킵.
  private static func applyDifferences(
    base: [String?], encodingObject: COSObject?
  ) -> [String?] {
    guard case let .dictionary(dictionary) = encodingObject,
      let differences = dictionary.array(for: .differences)
    else {
      return base
    }
    var table = base
    var code = 0
    for element in differences {
      switch element {
      case let .integer(value):
        code = value
      case let .name(name):
        if (0..<256).contains(code) {
          table[code] = name.rawValue
        }
        code += 1
      default:
        continue
      }
    }
    return table
  }

  /// Type3 폭 스케일 — `/FontMatrix`의 a 성분(기본 0.001) × 1000. 비-Type3는 1(무변경).
  private static func type3WidthScale(inputs: Inputs) -> CGFloat {
    guard inputs.fontDictionary.name(for: .subtype) == .type3 else {
      return 1
    }
    guard let matrix = inputs.fontDictionary[.fontMatrix]?.arrayValue,
      let first = matrix.first?.realValue
    else {
      return 0.001 * 1_000
    }
    return CGFloat(first) * 1_000
  }

  /// `/FirstChar`+`/Widths` → 256 배열 (Type3는 `scale`만큼 곱해 정규화).
  private static func buildSimpleWidths(inputs: Inputs, scale: CGFloat) -> [CGFloat?]? {
    guard let firstChar = inputs.fontDictionary.integer(for: .firstChar),
      let widthsArray = inputs.fontDictionary.array(for: .widths)
    else {
      return nil
    }
    var table = [CGFloat?](repeating: nil, count: 256)
    for (offset, object) in widthsArray.enumerated() {
      let code = firstChar + offset
      guard (0..<256).contains(code), let raw = object.realValue else {
        continue
      }
      table[code] = CGFloat(raw) * scale
    }
    return table
  }
}

// MARK: - 공용 헬퍼

extension FontLoader {
  /// 딕셔너리에서 정수·실수 어느 쪽이든 수용하는 수치 접근자 (부재·비수치는 기본값).
  private static func numeric(
    _ dictionary: COSDictionary?, key: COSName, default defaultValue: CGFloat
  ) -> CGFloat {
    dictionary?[key]?.realValue.map { CGFloat($0) } ?? defaultValue
  }
}
