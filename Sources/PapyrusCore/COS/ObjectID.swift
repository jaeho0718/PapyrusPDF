/// 간접 객체 식별자 (객체 번호 + 세대 번호).
package struct ObjectID: Hashable, Sendable, CustomStringConvertible {
  /// 객체 번호 (> 0).
  package let number: Int

  /// 세대 번호 (0...65535).
  package let generation: Int

  /// 식별자를 생성한다.
  /// - Parameters:
  ///   - number: 객체 번호.
  ///   - generation: 세대 번호.
  package init(number: Int, generation: Int) {
    self.number = number
    self.generation = generation
  }

  /// `"12 0 R"` 형식의 PDF 간접 참조 표기.
  package var description: String {
    "\(self.number) \(self.generation) R"
  }
}
