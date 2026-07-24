import Foundation

/// 페이지 텍스트 안의 한 위치입니다 (페이지 인덱스 + 그 페이지 문자열의 UTF-16 오프셋).
///
/// 오프셋 좌표계는 ``PageTextContent/string``의 UTF-16 코드유닛이며,
/// ``SearchResult/range``와 동일한 좌표계입니다.
public struct TextPosition: Sendable, Hashable, Comparable, Codable {
  /// 페이지 인덱스입니다 (0 기반).
  public let pageIndex: Int
  /// 해당 페이지 ``PageTextContent/string``의 UTF-16 코드유닛 오프셋입니다.
  public let utf16Offset: Int

  /// 위치를 생성합니다.
  /// - Parameters:
  ///   - pageIndex: 페이지 인덱스입니다 (0 기반).
  ///   - utf16Offset: 해당 페이지 문자열의 UTF-16 코드유닛 오프셋입니다.
  public init(pageIndex: Int, utf16Offset: Int) {
    self.pageIndex = pageIndex
    self.utf16Offset = utf16Offset
  }

  /// 페이지 우선, 같은 페이지면 오프셋 순으로 비교합니다.
  /// - Parameters:
  ///   - lhs: 비교할 왼쪽 값입니다.
  ///   - rhs: 비교할 오른쪽 값입니다.
  /// - Returns: `lhs`가 `rhs`보다 문서 순서상 앞이면 `true`입니다.
  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.pageIndex != rhs.pageIndex {
      return lhs.pageIndex < rhs.pageIndex
    }
    return lhs.utf16Offset < rhs.utf16Offset
  }
}

/// 텍스트 선택 범위입니다 (항상 정규화: `start <= end`). 페이지 경계를 넘을 수 있습니다.
public struct TextSelection: Sendable, Hashable, Codable {
  /// 선택 시작 위치입니다 (문서 순서 기준 앞쪽).
  public let start: TextPosition
  /// 선택 끝 위치입니다 (exclusive).
  public let end: TextPosition

  /// 두 위치를 문서 순서로 정규화하며 생성합니다 (역순 입력은 자동 교환).
  /// - Parameters:
  ///   - start: 선택의 한쪽 끝입니다.
  ///   - end: 선택의 다른 쪽 끝입니다.
  public init(start: TextPosition, end: TextPosition) {
    if start <= end {
      self.start = start
      self.end = end
    } else {
      self.start = end
      self.end = start
    }
  }

  /// 선택이 걸친 페이지 범위입니다.
  public var pageRange: ClosedRange<Int> {
    self.start.pageIndex...self.end.pageIndex
  }

  /// 빈 선택 여부입니다 (`start == end`).
  public var isEmpty: Bool {
    self.start == self.end
  }

  /// 이 선택이 `pageIndex` 페이지에서 차지하는 UTF-16 구간을 반환합니다.
  ///
  /// 중간 페이지는 `0..<pageUTF16Length`, 시작/끝 페이지는 해당 오프셋을
  /// `0...pageUTF16Length`로 클램프한 구간입니다. 선택 밖 페이지면 `nil`입니다.
  /// - Parameters:
  ///   - pageIndex: 조회할 페이지 인덱스입니다.
  ///   - pageUTF16Length: 해당 페이지 문자열의 UTF-16 코드유닛 길이입니다.
  /// - Returns: 이 페이지에서 선택이 차지하는 UTF-16 구간, 선택 밖 페이지면 `nil`입니다.
  public func utf16Range(onPage pageIndex: Int, pageUTF16Length: Int) -> Range<Int>? {
    guard self.pageRange.contains(pageIndex), pageUTF16Length >= 0 else {
      return nil
    }
    let lower = pageIndex == self.start.pageIndex
      ? min(max(self.start.utf16Offset, 0), pageUTF16Length) : 0
    let upper = pageIndex == self.end.pageIndex
      ? min(max(self.end.utf16Offset, 0), pageUTF16Length) : pageUTF16Length
    return min(lower, upper)..<upper
  }
}

// MARK: - Codable

extension TextSelection {
  /// 디코딩 후 지정 이니셜라이저를 경유해 `start <= end` 불변식을 강제합니다
  /// (역순으로 저장된 JSON도 정규화됩니다).
  /// - Parameter decoder: 디코더입니다.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let start = try container.decode(TextPosition.self, forKey: .start)
    let end = try container.decode(TextPosition.self, forKey: .end)
    self.init(start: start, end: end)
  }

  /// 코딩 키입니다.
  private enum CodingKeys: String, CodingKey {
    case start
    case end
  }
}
