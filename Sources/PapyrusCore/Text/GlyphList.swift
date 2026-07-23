/// AGL(Adobe Glyph List) 서브셋 — 글리프 이름 → 유니코드 문자열.
package enum GlyphList {
  /// 글리프 이름을 유니코드 문자열로 변환한다.
  ///
  /// 조회 순서: ① 서브셋 테이블(라틴·구두점·리거처 fi/fl·대시·인용부호 등) ②
  /// `uniXXXX`/`uXXXX[XX]` 알고리즘 해석 ③ 단일 문자 이름("a" 등, 이미 그 자체가 문자인
  /// 경우) ④ `nil`.
  /// - Parameter name: 글리프 이름 (슬래시 제외).
  /// - Returns: 대응 유니코드 문자열, 해석 불가면 `nil`.
  package static func unicode(forGlyphName name: String) -> String? {
    if let mapped = Self.table[name] {
      return mapped
    }
    if let algorithmic = Self.algorithmicUnicode(name) {
      return algorithmic
    }
    if name.count == 1 {
      return name
    }
    return nil
  }

  /// `uniXXXX`(정확히 4자리 hex) 또는 `uXXXX`~`uXXXXXX`(4~6자리 hex) 이름을 해석한다.
  private static func algorithmicUnicode(_ name: String) -> String? {
    if name.hasPrefix("uni") {
      let hex = name.dropFirst(3)
      guard hex.count == 4, let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value)
      else {
        return nil
      }
      return String(Character(scalar))
    }
    if name.hasPrefix("u") {
      let hex = name.dropFirst(1)
      guard (4...6).contains(hex.count), let value = UInt32(hex, radix: 16),
        let scalar = Unicode.Scalar(value)
      else {
        return nil
      }
      return String(Character(scalar))
    }
    return nil
  }
}
