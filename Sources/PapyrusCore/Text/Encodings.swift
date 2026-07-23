/// 단순 폰트 기본 인코딩 테이블 (코드 → 글리프 이름, 256 엔트리).
package enum PDFBaseEncoding {
  /// StandardEncoding 정적 테이블 (256 엔트리, 부재 코드는 `nil`).
  package static let standard: [String?] = Self.buildTable(overrides: Self.standardOverrides)

  /// WinAnsiEncoding 정적 테이블 (256 엔트리, Windows-1252 근사).
  package static let winAnsi: [String?] = Self.buildTable(overrides: Self.winAnsiOverrides)

  /// MacRomanEncoding 정적 테이블 (256 엔트리, Mac OS Roman 근사).
  package static let macRoman: [String?] = Self.buildTable(overrides: Self.macRomanOverrides)

  /// `/Encoding` 이름으로 테이블을 선택한다. 미인식(MacExpertEncoding 포함)은 standard.
  /// - Parameter named: `/Encoding` 또는 `/BaseEncoding` 이름 (부재면 `nil`).
  /// - Returns: 선택된 256엔트리 테이블.
  package static func table(named: COSName?) -> [String?] {
    switch named {
    case .some(.winAnsiEncoding):
      return Self.winAnsi
    case .some(.macRomanEncoding):
      return Self.macRoman
    default:
      return Self.standard
    }
  }
}
