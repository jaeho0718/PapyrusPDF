@testable import PapyrusPDFCore
import Testing

/// ``TextBoundary``의 문자·단어 경계 스냅을 검증한다 (설계 §5.5-5).
struct TextBoundaryTests {
  // MARK: snapToCharacterBoundary

  @Test func snapKeepsOffsetAlreadyOnBoundary() {
    let string = "hello"
    #expect(TextBoundary.snapToCharacterBoundary(2, in: string) == 2)
  }

  @Test func snapMovesInsideSurrogatePairToNearestBoundary() {
    // 😀는 서로게이트 쌍(2 UTF-16 유닛) — 내부 오프셋 1은 양끝(0, 2)과 동거리 → 동률은 뒤쪽.
    let string = "😀"
    #expect(TextBoundary.snapToCharacterBoundary(1, in: string) == 2)
  }

  @Test func snapMovesInsideZWJEmojiToNearestBoundary() {
    // 가족 이모지(ZWJ 결합) — 그레이프 클러스터 내부 임의 오프셋도 크래시 없이 스냅되어야 한다.
    let string = "👨‍👩‍👧"
    let utf16Count = string.utf16.count
    let midpoint = utf16Count / 2
    let snapped = TextBoundary.snapToCharacterBoundary(midpoint, in: string)
    #expect(snapped == 0 || snapped == utf16Count)
  }

  @Test func snapClampsOffsetOutOfRange() {
    let string = "abc"
    #expect(TextBoundary.snapToCharacterBoundary(-5, in: string) == 0)
    #expect(TextBoundary.snapToCharacterBoundary(999, in: string) == 3)
  }

  // MARK: wordRange

  @Test func wordRangeAtCenterOfWord() {
    let string = "hello world"
    let range = TextBoundary.wordRange(around: 2, in: string, window: 0..<string.utf16.count)
    #expect(range == 0..<5)
  }

  @Test func wordRangeAtStartOfWord() {
    let string = "hello world"
    let range = TextBoundary.wordRange(around: 0, in: string, window: 0..<string.utf16.count)
    #expect(range == 0..<5)
  }

  @Test func wordRangeAtEndOfWord() {
    let string = "hello world"
    let range = TextBoundary.wordRange(around: 11, in: string, window: 0..<string.utf16.count)
    #expect(range == 6..<11)
  }

  @Test func wordRangeOnWhitespaceSnapsToNearerWordPreferringLater() {
    // "hi  there" — 공백 2칸(인덱스 2, 3) 중 인덱스 3은 "hi"(끝 2)·"there"(시작 4)와
    // 동거리(각 1) → 동률은 뒤 단어("there").
    let string = "hi  there"
    let range = TextBoundary.wordRange(around: 3, in: string, window: 0..<string.utf16.count)
    #expect(range == 4..<9)
  }

  @Test func wordRangeAdjacentToPunctuation() {
    let string = "hello, world"
    let range = TextBoundary.wordRange(around: 1, in: string, window: 0..<string.utf16.count)
    #expect(range == 0..<5)
  }

  @Test func wordRangeTokenizesCJKPerFoundationBehavior() {
    // Foundation 토크나이저의 CJK 분리 동작을 그대로 관찰·고정한다 (자체 규칙 없음).
    let string = "你好世界"
    let range = TextBoundary.wordRange(around: 0, in: string, window: 0..<string.utf16.count)
    #expect(range != nil)
    #expect(range!.lowerBound == 0)
  }

  @Test func wordRangeIgnoresWordsOutsideWindow() {
    let string = "alpha beta gamma"
    // window를 "beta"만 포함하도록 제한 — "alpha"·"gamma"는 창 밖이라 무시되어야 한다.
    let window = 6..<10
    let range = TextBoundary.wordRange(around: 6, in: string, window: window)
    #expect(range == 6..<10)
  }

  @Test func wordRangeReturnsNilWhenWindowHasNoWords() {
    let string = "alpha   beta"
    // window가 공백만 포함 — 단어 없음.
    let range = TextBoundary.wordRange(around: 6, in: string, window: 5..<8)
    #expect(range == nil)
  }
}
