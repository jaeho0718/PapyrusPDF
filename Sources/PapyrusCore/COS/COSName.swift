/// PDF name 객체 (`/Type` 등). `#xx` 이스케이프는 렉싱 시점에 해소된 상태로 저장.
package struct COSName: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
  /// 슬래시·이스케이프 해소 후의 이름 문자열 (UTF-8 해석).
  package let rawValue: String

  /// 이름 문자열로부터 생성한다.
  /// - Parameter rawValue: 슬래시 없이, 이스케이프가 이미 해소된 이름.
  package init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  /// 문자열 리터럴로부터 생성한다 (`let name: COSName = "Type"`).
  /// - Parameter value: 이름 문자열.
  package init(stringLiteral value: String) {
    self.rawValue = value
  }

  /// 슬래시를 붙인 표시용 문자열.
  package var description: String {
    "/\(self.rawValue)"
  }
}

/// M1에서 필요한 표준 이름 상수. 마일스톤마다 필요분만 추가한다.
extension COSName {
  /// `/Type`.
  package static let type: COSName = "Type"

  /// `/Length`.
  package static let length: COSName = "Length"

  /// `/Filter`.
  package static let filter: COSName = "Filter"

  /// `/DecodeParms`.
  package static let decodeParms: COSName = "DecodeParms"

  /// `/DP` (`/DecodeParms`의 축약형).
  package static let dp: COSName = "DP"

  /// `/Predictor`.
  package static let predictor: COSName = "Predictor"

  /// `/Columns`.
  package static let columns: COSName = "Columns"

  /// `/Colors`.
  package static let colors: COSName = "Colors"

  /// `/BitsPerComponent`.
  package static let bitsPerComponent: COSName = "BitsPerComponent"
}

/// M2에서 필요한 표준 이름 상수 (xref/ObjStm/암호화 감지).
extension COSName {
  /// `/Root`.
  package static let root: COSName = "Root"

  /// `/Prev`.
  package static let prev: COSName = "Prev"

  /// `/XRefStm`.
  package static let xRefStm: COSName = "XRefStm"

  /// `/Size`.
  package static let size: COSName = "Size"

  /// `/Index`.
  package static let index: COSName = "Index"

  /// `/W`.
  package static let wKey: COSName = "W"

  /// `/Encrypt`.
  package static let encrypt: COSName = "Encrypt"

  /// `/First`.
  package static let first: COSName = "First"

  /// `/N`.
  package static let nKey: COSName = "N"

  /// `/ObjStm`.
  package static let objStm: COSName = "ObjStm"

  /// `/Catalog`.
  package static let catalog: COSName = "Catalog"
}

/// M3에서 필요한 표준 이름 상수 (페이지 트리/메타데이터/목차/네임 트리).
extension COSName {
  /// `/Pages`.
  package static let pages: COSName = "Pages"

  /// `/Page`.
  package static let page: COSName = "Page"

  /// `/Kids`.
  package static let kids: COSName = "Kids"

  /// `/Count`.
  package static let count: COSName = "Count"

  /// `/Parent`.
  package static let parent: COSName = "Parent"

  /// `/MediaBox`.
  package static let mediaBox: COSName = "MediaBox"

  /// `/CropBox`.
  package static let cropBox: COSName = "CropBox"

  /// `/Rotate`.
  package static let rotate: COSName = "Rotate"

  /// `/Resources`.
  package static let resources: COSName = "Resources"

  /// `/Info`.
  package static let info: COSName = "Info"

  /// `/Title`.
  package static let title: COSName = "Title"

  /// `/Author`.
  package static let author: COSName = "Author"

  /// `/Subject`.
  package static let subject: COSName = "Subject"

  /// `/Keywords`.
  package static let keywords: COSName = "Keywords"

  /// `/Creator`.
  package static let creator: COSName = "Creator"

  /// `/Producer`.
  package static let producer: COSName = "Producer"

  /// `/CreationDate`.
  package static let creationDate: COSName = "CreationDate"

  /// `/ModDate`.
  package static let modDate: COSName = "ModDate"

  /// `/Metadata`.
  package static let metadataKey: COSName = "Metadata"

  /// `/Outlines`.
  package static let outlines: COSName = "Outlines"

  /// `/Next`.
  package static let next: COSName = "Next"

  /// `/Last`.
  package static let last: COSName = "Last"

  /// `/Dest`.
  package static let dest: COSName = "Dest"

  /// `/A`.
  package static let aKey: COSName = "A"

  /// `/S`.
  package static let sKey: COSName = "S"

  /// `/D`.
  package static let dKey: COSName = "D"

  /// `/GoTo`.
  package static let goTo: COSName = "GoTo"

  /// `/Names`.
  package static let names: COSName = "Names"

  /// `/Dests`.
  package static let dests: COSName = "Dests"

  /// `/Limits`.
  package static let limits: COSName = "Limits"

  /// `/Version`.
  package static let version: COSName = "Version"
}

/// M4에서 필요한 표준 이름 상수 (텍스트 추출/폰트/CMap/LZW).
extension COSName {
  /// `/Contents`.
  package static let contents: COSName = "Contents"

  /// `/EarlyChange`.
  package static let earlyChange: COSName = "EarlyChange"

  /// `/Font`.
  package static let font: COSName = "Font"

  /// `/Subtype`.
  package static let subtype: COSName = "Subtype"

  /// `/BaseFont`.
  package static let baseFont: COSName = "BaseFont"

  /// `/Encoding`.
  package static let encoding: COSName = "Encoding"

  /// `/BaseEncoding`.
  package static let baseEncoding: COSName = "BaseEncoding"

  /// `/Differences`.
  package static let differences: COSName = "Differences"

  /// `/FirstChar`.
  package static let firstChar: COSName = "FirstChar"

  /// `/LastChar`.
  package static let lastChar: COSName = "LastChar"

  /// `/Widths`.
  package static let widths: COSName = "Widths"

  /// `/FontDescriptor`.
  package static let fontDescriptor: COSName = "FontDescriptor"

  /// `/Ascent`.
  package static let ascent: COSName = "Ascent"

  /// `/Descent`.
  package static let descent: COSName = "Descent"

  /// `/MissingWidth`.
  package static let missingWidth: COSName = "MissingWidth"

  /// `/ToUnicode`.
  package static let toUnicode: COSName = "ToUnicode"

  /// `/DescendantFonts`.
  package static let descendantFonts: COSName = "DescendantFonts"

  /// `/DW`.
  package static let dw: COSName = "DW"

  /// `/XObject`.
  package static let xObject: COSName = "XObject"

  /// `/Form`.
  package static let form: COSName = "Form"

  /// `/Matrix`.
  package static let matrix: COSName = "Matrix"

  /// `/BBox`.
  package static let bbox: COSName = "BBox"

  /// `/FontMatrix`.
  package static let fontMatrix: COSName = "FontMatrix"

  /// `/WMode`.
  package static let wMode: COSName = "WMode"

  /// `/L`.
  package static let lKey: COSName = "L"

  /// `/Identity-H`.
  package static let identityH: COSName = "Identity-H"

  /// `/Identity-V`.
  package static let identityV: COSName = "Identity-V"

  /// `/Type0`.
  package static let type0: COSName = "Type0"

  /// `/Type1`.
  package static let type1: COSName = "Type1"

  /// `/Type3`.
  package static let type3: COSName = "Type3"

  /// `/TrueType`.
  package static let trueType: COSName = "TrueType"

  /// `/MMType1`.
  package static let mmType1: COSName = "MMType1"

  /// `/WinAnsiEncoding`.
  package static let winAnsiEncoding: COSName = "WinAnsiEncoding"

  /// `/MacRomanEncoding`.
  package static let macRomanEncoding: COSName = "MacRomanEncoding"

  /// `/StandardEncoding`.
  package static let standardEncoding: COSName = "StandardEncoding"

  /// `/MacExpertEncoding`.
  package static let macExpertEncoding: COSName = "MacExpertEncoding"
}
