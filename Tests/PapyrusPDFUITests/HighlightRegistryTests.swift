import CoreGraphics
import PapyrusPDFCore
@testable import PapyrusPDFUI
import Testing

/// `HighlightRegistry`의 diff 통지·위생·순서 결정성(설계 §5-2)을 검증하는 순수 값 타입
/// 유닛 테스트 — 뷰 트리 없이 성립한다.
struct HighlightRegistryTests {
  /// 결정적 테스트 quad (기본값은 유한 좌표).
  private static func quad(x: CGFloat = 0) -> Quad {
    Quad(rect: CGRect(x: x, y: 0, width: 10, height: 10))
  }

  /// 비유한 좌표를 포함한 quad.
  private static func nonFiniteQuad() -> Quad {
    Quad(
      bottomLeft: CGPoint(x: CGFloat.nan, y: 0), bottomRight: CGPoint(x: 10, y: 0),
      topRight: CGPoint(x: 10, y: 10), topLeft: CGPoint(x: 0, y: 10)
    )
  }

  private static func highlight(
    id: String, page: Int, x: CGFloat = 0, color: HighlightColor = .yellow
  ) -> Highlight {
    Highlight(id: id, pageIndex: page, quads: [Self.quad(x: x)], color: color)
  }

  // MARK: add — 정확히 변경 페이지 집합

  @Test func addReturnsExactlyChangedPagesAcrossMultiplePages() {
    var registry = HighlightRegistry()
    let changed = registry.add([
      Self.highlight(id: "a", page: 0), Self.highlight(id: "b", page: 2)
    ])
    #expect(changed == [0, 2])
    #expect(registry.highlights(forPage: 0).map(\.id) == ["a"])
    #expect(registry.highlights(forPage: 2).map(\.id) == ["b"])
    #expect(registry.highlights(forPage: 1).isEmpty)
  }

  /// 동일 id 재등록(무변경처럼 보이는 값이라도)은 항상 변경으로 취급된다.
  @Test func reregisteringSameIDWithIdenticalValueIsStillReportedAsChanged() {
    var registry = HighlightRegistry()
    _ = registry.add([Self.highlight(id: "a", page: 0)])

    let changed = registry.add([Self.highlight(id: "a", page: 0)])

    #expect(changed == [0])
  }

  // MARK: 동일 id 다른 페이지로 대체

  @Test func reregisteringSameIDOnDifferentPageMarksBothPagesChangedAndUpdatesReverseMap() {
    var registry = HighlightRegistry()
    _ = registry.add([Self.highlight(id: "a", page: 0)])

    let changed = registry.add([Self.highlight(id: "a", page: 5)])

    #expect(changed == [0, 5])
    #expect(registry.highlights(forPage: 0).isEmpty) // 역맵 정합 — 옛 페이지에서 제거.
    #expect(registry.highlights(forPage: 5).map(\.id) == ["a"])
  }

  // MARK: 배치 내 동일 id — 마지막 항목 승리

  @Test func lastWriteWinsWithinSingleBatchForSameID() {
    var registry = HighlightRegistry()
    let first = Self.highlight(id: "a", page: 0, color: .yellow)
    let second = Self.highlight(id: "a", page: 0, color: .blue)

    _ = registry.add([first, second])

    let stored = registry.highlights(forPage: 0)
    #expect(stored.count == 1)
    #expect(stored.first?.color == .blue)
  }

  // MARK: 위생 — 음수 페이지 폐기

  @Test func negativePageIndexIsDiscarded() {
    var registry = HighlightRegistry()
    let changed = registry.add([Self.highlight(id: "a", page: -1)])
    #expect(changed.isEmpty)
    #expect(registry.all.isEmpty)
  }

  // MARK: 위생 — 비유한 quad 부분/전부 폐기

  @Test func partiallyNonFiniteQuadsAreFilteredButHighlightSurvives() {
    var registry = HighlightRegistry()
    let highlight = Highlight(
      id: "a", pageIndex: 0, quads: [Self.quad(), Self.nonFiniteQuad()], color: .yellow
    )

    let changed = registry.add([highlight])

    #expect(changed == [0])
    let stored = registry.highlights(forPage: 0)
    #expect(stored.count == 1)
    #expect(stored.first?.quads.count == 1)
  }

  @Test func entirelyNonFiniteQuadsDiscardsWholeHighlight() {
    var registry = HighlightRegistry()
    let highlight = Highlight(id: "a", pageIndex: 0, quads: [Self.nonFiniteQuad()], color: .yellow)

    let changed = registry.add([highlight])

    #expect(changed.isEmpty)
    #expect(registry.highlights(forPage: 0).isEmpty)
  }

  // MARK: 위생 — 페이지 캡 절단(기존 우선)

  @Test func perPageCapDiscardsExcessKeepingExistingRegistrationsFirst() {
    var registry = HighlightRegistry()
    let existing = (0..<UILimits.maxHighlightsPerPage).map {
      Self.highlight(id: "existing-\($0)", page: 0, x: CGFloat($0))
    }
    _ = registry.add(existing)
    #expect(registry.highlights(forPage: 0).count == UILimits.maxHighlightsPerPage)

    let overflow = Self.highlight(id: "overflow", page: 0, x: 999)
    let changed = registry.add([overflow])

    #expect(changed == [0]) // 페이지 자체는 여전히 "만졌다"고 보고된다 (add 시도).
    let stored = registry.highlights(forPage: 0)
    #expect(stored.count == UILimits.maxHighlightsPerPage)
    #expect(!stored.contains { $0.id == "overflow" }) // 초과분 폐기.
    #expect(stored.first?.id == "existing-0") // 기존 등록 유지.
  }

  // MARK: remove(id:)

  @Test func removeByIDReturnsThatPageAndClearsReverseMap() {
    var registry = HighlightRegistry()
    _ = registry.add([Self.highlight(id: "a", page: 2)])

    let changed = registry.remove(id: "a")

    #expect(changed == [2])
    #expect(registry.highlights(forPage: 2).isEmpty)
    // 제거된 id 재등록 시 옛 페이지 흔적이 없어야 한다(역맵 정합 재확인).
    _ = registry.add([Self.highlight(id: "a", page: 7)])
    #expect(registry.highlights(forPage: 7).map(\.id) == ["a"])
  }

  @Test func removeUnknownIDReturnsEmptySet() {
    var registry = HighlightRegistry()
    let changed = registry.remove(id: "missing")
    #expect(changed.isEmpty)
  }

  // MARK: removeAll()

  @Test func removeAllReturnsAllPreviouslyOccupiedPages() {
    var registry = HighlightRegistry()
    _ = registry.add([
      Self.highlight(id: "a", page: 0), Self.highlight(id: "b", page: 3)
    ])

    let changed = registry.removeAll()

    #expect(changed == [0, 3])
    #expect(registry.all.isEmpty)
  }

  // MARK: all — 결정적 순서

  @Test func allOrdersByPageAscendingThenRegistrationOrderWithinPage() {
    var registry = HighlightRegistry()
    _ = registry.add([
      Self.highlight(id: "p2-a", page: 2), Self.highlight(id: "p0-a", page: 0),
      Self.highlight(id: "p0-b", page: 0, x: 5), Self.highlight(id: "p1-a", page: 1)
    ])

    let ids = registry.all.map(\.id)

    #expect(ids == ["p0-a", "p0-b", "p1-a", "p2-a"])
  }
}
