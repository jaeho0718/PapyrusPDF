/// PDF 헤더 버전 (`%PDF-M.N`).
package struct PDFVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
  /// 주 버전 번호.
  package let major: Int

  /// 부 버전 번호.
  package let minor: Int

  /// 버전을 생성한다.
  /// - Parameters:
  ///   - major: 주 버전 번호.
  ///   - minor: 부 버전 번호.
  package init(major: Int, minor: Int) {
    self.major = major
    self.minor = minor
  }

  /// `(major, minor)` 사전식 비교.
  package static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
  }

  /// `"1.7"` 형식의 표시용 문자열.
  package var description: String {
    "\(self.major).\(self.minor)"
  }
}
