import Foundation
@testable import PapyrusCore
import Testing

/// 파싱 성공 케이스 하나 (입력 문자열 → 기대 시각 컴포넌트).
struct PDFDateParserSuccessCase: Sendable, CustomTestStringConvertible {
  let input: String
  let year: Int
  let month: Int
  let day: Int
  let hour: Int
  let minute: Int
  let second: Int
  let offsetSeconds: Int
  var testDescription: String {
    "\"\(self.input)\""
  }

  /// 기대 `Date` (동일한 `Calendar`/`DateComponents` 조립 경로로 독립 구성).
  var expectedDate: Date {
    var components = DateComponents()
    components.year = self.year
    components.month = self.month
    components.day = self.day
    components.hour = self.hour
    components.minute = self.minute
    components.second = self.second
    var calendar = Calendar(identifier: .gregorian)
    // 고정 초 오프셋은 항상 유효하다.
    // swiftlint:disable:next force_unwrapping
    calendar.timeZone = TimeZone(secondsFromGMT: self.offsetSeconds)!
    // 컴포넌트가 항상 유효하도록 구성했다.
    // swiftlint:disable:next force_unwrapping
    return calendar.date(from: components)!
  }
}

/// ``PDFDateParser``의 관용 파싱을 검증한다 (설계 §5.2 DP1-DP4).
struct PDFDateParserTests {
  // MARK: DP1 — 전체 필드 매트릭스

  static let dp1Cases: [PDFDateParserSuccessCase] = [
    .init(
      input: "D:20240321094500+09'00'", year: 2_024, month: 3, day: 21, hour: 9, minute: 45,
      second: 0, offsetSeconds: 9 * 3_600
    ),
    .init(
      input: "D:2024", year: 2_024, month: 1, day: 1, hour: 0, minute: 0, second: 0,
      offsetSeconds: 0
    ),
    .init(
      input: "20240101120000Z", year: 2_024, month: 1, day: 1, hour: 12, minute: 0, second: 0,
      offsetSeconds: 0
    ),
    .init(
      input: "D:20240321094500+0900", year: 2_024, month: 3, day: 21, hour: 9, minute: 45,
      second: 0, offsetSeconds: 9 * 3_600
    ),
    .init(
      input: "D:20240101000000Z1234abc", year: 2_024, month: 1, day: 1, hour: 0, minute: 0,
      second: 0, offsetSeconds: 0
    )
  ]

  /// DP1: 전체 필드+오프셋, 최소, D: 부재, 어퍼스트러피 생략, 뒤 정크 — 전부 정상 파싱.
  @Test(arguments: dp1Cases)
  func parsesFullAndPartialFieldMatrix(_ testCase: PDFDateParserSuccessCase) {
    let parsed = PDFDateParser.parse(testCase.input)
    #expect(parsed == testCase.expectedDate)
  }

  // MARK: DP2 — 부분 수용

  static let dp2Cases: [PDFDateParserSuccessCase] = [
    .init(
      input: "D:20241301094500", year: 2_024, month: 1, day: 1, hour: 0, minute: 0, second: 0,
      offsetSeconds: 0
    ),
    .init(
      input: "D:20240101120165", year: 2_024, month: 1, day: 1, hour: 12, minute: 1, second: 0,
      offsetSeconds: 0
    )
  ]

  /// DP2: 월 13 → 연도만 수용; 초 위반 → 분까지만 수용.
  @Test(arguments: dp2Cases)
  func partiallyAcceptsUpToFirstViolation(_ testCase: PDFDateParserSuccessCase) {
    let parsed = PDFDateParser.parse(testCase.input)
    #expect(parsed == testCase.expectedDate)
  }

  // MARK: DP3 — 연도 복원 불가

  /// DP3: 연도조차 복원 불가한 입력 → `nil`.
  @Test(arguments: ["D:19", "", "garbage"])
  func returnsNilWhenYearIsUnrecoverable(_ input: String) {
    #expect(PDFDateParser.parse(input) == nil)
  }

  // MARK: DP4 — 오프셋 부재 → UTC

  /// DP4: 오프셋 표기 자체가 없으면 UTC로 해석한다 (가정 4).
  @Test func missingOffsetIsInterpretedAsUTC() {
    let parsed = PDFDateParser.parse("D:20240101120000")
    let expected = PDFDateParserSuccessCase(
      input: "D:20240101120000", year: 2_024, month: 1, day: 1, hour: 12, minute: 0, second: 0,
      offsetSeconds: 0
    ).expectedDate
    #expect(parsed == expected)
  }
}
