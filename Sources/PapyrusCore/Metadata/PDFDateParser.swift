import Foundation

/// PDF 날짜 문자열(`D:YYYYMMDDHHmmSSOHH'mm'`) 관용 파서. 필드 대부분이 선택적이다.
package enum PDFDateParser {
  /// 날짜 문자열을 파싱한다. 왼쪽부터 유효한 필드까지 수용하고(연도는 필수),
  /// 첫 위반 지점 이후는 버린다. 오프셋 부재는 UTC로 해석한다 (가정 4).
  /// - Parameter string: 파싱할 PDF 날짜 문자열.
  /// - Returns: 파싱된 시각. 연도조차 복원 불가하면 `nil`.
  package static func parse(_ string: String) -> Date? {
    var text = string.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("D:") {
      text.removeFirst(2)
    }
    let chars = Array(text)
    var cursor = 0
    guard let year = Self.readDigits(chars, &cursor, width: 4) else {
      return nil
    }

    let components = Self.parseRemainingComponents(chars: chars, cursor: &cursor, year: year)
    var calendar = Calendar(identifier: .gregorian)
    // "UTC"는 항상 유효한 식별자다.
    // swiftlint:disable:next force_unwrapping
    calendar.timeZone = components.timeZone ?? TimeZone(identifier: "UTC")!
    return calendar.date(from: components)
  }

  /// 연도 이후 필드(월·일·시·분·초·오프셋)를 순차 파싱한다. 첫 실패 지점 이후는 기본값으로
  /// 채운다 (월·일은 1, 시·분·초는 0, 오프셋은 UTC).
  private static func parseRemainingComponents(
    chars: [Character], cursor: inout Int, year: Int
  ) -> DateComponents {
    var components = DateComponents()
    components.year = year
    components.month = 1
    components.day = 1
    components.hour = 0
    components.minute = 0
    components.second = 0
    // "UTC"는 항상 유효한 식별자다.
    // swiftlint:disable:next force_unwrapping
    components.timeZone = TimeZone(identifier: "UTC")!

    guard let month = Self.readDigits(chars, &cursor, width: 2), (1...12).contains(month) else {
      return components
    }
    components.month = month

    guard let day = Self.readDigits(chars, &cursor, width: 2), (1...31).contains(day) else {
      return components
    }
    components.day = day

    guard let hour = Self.readDigits(chars, &cursor, width: 2), (0...23).contains(hour) else {
      return components
    }
    components.hour = hour

    guard let minute = Self.readDigits(chars, &cursor, width: 2), (0...59).contains(minute) else {
      return components
    }
    components.minute = minute

    guard let second = Self.readDigits(chars, &cursor, width: 2), (0...59).contains(second) else {
      return components
    }
    components.second = second

    if let offset = Self.readOffset(chars, &cursor) {
      components.timeZone = offset
    }
    return components
  }

  /// 고정폭 십진수 필드를 읽는다. 자릿수 부족·비숫자면 커서를 되돌리지 않고 `nil`을
  /// 반환한다 (호출부가 그 지점에서 파싱을 중단한다).
  private static func readDigits(_ chars: [Character], _ cursor: inout Int, width: Int) -> Int? {
    guard cursor + width <= chars.count else {
      return nil
    }
    var value = 0
    for offset in 0..<width {
      let character = chars[cursor + offset]
      guard character.isASCII, let ascii = character.asciiValue, (0x30...0x39).contains(ascii)
      else {
        return nil
      }
      value = value * 10 + Int(ascii - 0x30)
    }
    cursor += width
    return value
  }

  /// 시간대 오프셋을 읽는다. `Z`, `+HH`, `+HH'mm'`(어퍼스트러피 생략·분 생략 관용) 형태를
  /// 수용한다. 오프셋 자체가 없거나 범위를 벗어나면 `nil` (호출부가 UTC로 대체한다).
  private static func readOffset(_ chars: [Character], _ cursor: inout Int) -> TimeZone? {
    guard cursor < chars.count else {
      return nil
    }
    let marker = chars[cursor]
    if marker == "Z" {
      cursor += 1
      return TimeZone(identifier: "UTC")
    }
    guard marker == "+" || marker == "-" else {
      return nil
    }
    let sign = marker == "-" ? -1 : 1
    cursor += 1
    guard let hourOffset = Self.readDigits(chars, &cursor, width: 2), (0...23).contains(hourOffset)
    else {
      return nil
    }
    if cursor < chars.count, chars[cursor] == "'" {
      cursor += 1
    }
    var minuteOffset = 0
    if let rawMinute = Self.readDigits(chars, &cursor, width: 2), (0...59).contains(rawMinute) {
      minuteOffset = rawMinute
      if cursor < chars.count, chars[cursor] == "'" {
        cursor += 1
      }
    }
    let totalSeconds = sign * (hourOffset * 3_600 + minuteOffset * 60)
    return TimeZone(secondsFromGMT: totalSeconds)
  }
}
