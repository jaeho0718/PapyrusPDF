import CoreGraphics
import PapyrusPDFCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import PapyrusPDFUI
import SwiftUI
import Testing

/// `SelectionMenuResolver`의 폴백 규칙(설계 §3)·캡 절단·컨텍스트 캡처를 검증한다
/// (설계 §6-1 — 뷰 트리 없는 유닛 테스트).
@MainActor
struct SelectionMenuResolverTests {
  /// 결정적 텍스트 선택 컨텍스트를 만든다.
  private static func makeTextContext(text: String = "Hello") -> SelectionContext {
    .text(
      TextSelectionContext(
        selection: TextSelection(
          start: TextPosition(pageIndex: 0, utf16Offset: 0),
          end: TextPosition(pageIndex: 0, utf16Offset: text.utf16.count)
        ),
        selectedText: text
      )
    )
  }

  /// 결정적 영역 선택 컨텍스트를 만든다.
  private static func makeRegionContext(id: String = "r1") -> SelectionContext {
    .region(
      SelectableRegion(
        id: id, pageIndex: 0, quad: Quad(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
      )
    )
  }

  // MARK: 빌더 nil — 기본 폴백

  @Test func resolveWithNilBuilderReturnsDefaultCopyItem() {
    let items = SelectionMenuResolver.resolve(context: Self.makeTextContext(), builder: nil)

    #expect(items.count == 1)
    #expect(items.first?.title == "Copy")
    #expect(items.first?.systemImage == "doc.on.doc")
  }

  @Test func resolveRegionContextWithNilBuilderReturnsEmptyDefault() {
    let items = SelectionMenuResolver.resolve(context: Self.makeRegionContext(), builder: nil)

    #expect(items.isEmpty) // 계획 §3.2 확정 — 영역 기본 메뉴는 없다.
  }

  // MARK: 커스텀 빌더 — 순서·title·systemImage 보존

  @Test func resolveWithCustomBuilderPreservesOrderAndFields() {
    let builder: SelectionMenuItemsBuilder = { _ in
      [
        SelectionMenuItem(title: "Highlight", systemImage: "highlighter") { _ in },
        SelectionMenuItem(title: "Translate", systemImage: nil) { _ in },
        SelectionMenuItem(title: "Search") { _ in }
      ]
    }

    let items = SelectionMenuResolver.resolve(context: Self.makeTextContext(), builder: builder)

    #expect(items.count == 3)
    #expect(items.map(\.title) == ["Highlight", "Translate", "Search"])
    #expect(items[0].systemImage == "highlighter")
    #expect(items[1].systemImage == nil)
    #expect(items[2].systemImage == nil)
  }

  @Test func resolveRegionContextWithCustomBuilderPreservesItems() {
    let builder: SelectionMenuItemsBuilder = { context in
      guard case .region = context else {
        return []
      }
      return [SelectionMenuItem(title: "Show Caption", systemImage: "text.bubble") { _ in }]
    }

    let items = SelectionMenuResolver.resolve(context: Self.makeRegionContext(), builder: builder)

    #expect(items.map(\.title) == ["Show Caption"])
    #expect(items.first?.systemImage == "text.bubble")
  }

  // MARK: 빈 배열 — 명시적 억제

  @Test func resolveWithBuilderReturningEmptyArrayYieldsNoItems() {
    let builder: SelectionMenuItemsBuilder = { _ in [] }

    let items = SelectionMenuResolver.resolve(context: Self.makeTextContext(), builder: builder)

    #expect(items.isEmpty)
  }

  // MARK: 65개 반환 — 64개 절단 (텍스트·영역 공통)

  @Test func resolveTruncatesBuilderOutputToMaxItems() {
    let builder: SelectionMenuItemsBuilder = { _ in
      (0..<65).map { index in
        SelectionMenuItem(title: "Item \(index)") { _ in }
      }
    }

    let items = SelectionMenuResolver.resolve(context: Self.makeTextContext(), builder: builder)

    #expect(items.count == SelectionMenuResolver.maxItems)
    #expect(items.count == 64)
    #expect(items.last?.title == "Item 63")
  }

  @Test func resolveTruncatesRegionBuilderOutputToMaxItemsToo() {
    let builder: SelectionMenuItemsBuilder = { _ in
      (0..<65).map { index in
        SelectionMenuItem(title: "Item \(index)") { _ in }
      }
    }

    let items = SelectionMenuResolver.resolve(context: Self.makeRegionContext(), builder: builder)

    #expect(items.count == 64)
    #expect(items.last?.title == "Item 63")
  }

  // MARK: 액션 실행 — 빌더 호출 시점의 컨텍스트를 받는다

  @Test func resolvedItemActionReceivesContextCapturedAtBuildTime() {
    let expectedContext = Self.makeTextContext(text: "Captured")
    var received: [SelectionContext] = []
    let builder: SelectionMenuItemsBuilder = { _ in
      [SelectionMenuItem(title: "Echo") { received.append($0) }]
    }

    let items = SelectionMenuResolver.resolve(context: expectedContext, builder: builder)
    items.first?.action()

    guard case let .text(receivedTextContext) = received.first else {
      Issue.record("expected a .text context")
      return
    }
    guard case let .text(expectedTextContext) = expectedContext else {
      Issue.record("expected a .text context")
      return
    }
    #expect(receivedTextContext.selectedText == expectedTextContext.selectedText)
    #expect(receivedTextContext.selection == expectedTextContext.selection)
  }

  // MARK: .copy 액션 — 페이스트보드에 selectedText를 기록한다

  @Test func copyItemActionWritesSelectedTextToPasteboard() {
    let context = Self.makeTextContext(text: "Copy me \(UUID().uuidString)")
    let items = SelectionMenuResolver.resolve(context: context, builder: nil)

    items.first?.action()

    #if canImport(AppKit)
    let readBack = NSPasteboard.general.string(forType: .string)
    #elseif canImport(UIKit)
    let readBack = UIPasteboard.general.string
    #endif
    guard case let .text(textContext) = context else {
      Issue.record("expected a .text context")
      return
    }
    #expect(readBack == textContext.selectedText)
  }

  @Test func copyItemActionIsNoOpForRegionContext() {
    let sentinel = "sentinel-\(UUID().uuidString)"
    PlatformPasteboard.setString(sentinel)
    let region = SelectableRegion(
      id: "r1", pageIndex: 0, quad: Quad(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
    )
    let items = SelectionMenuResolver.resolve(context: .region(region), builder: nil)

    // defaultItems(.region) == [] — 기본 메뉴는 항목이 없다. `.copy`가 명시적으로 커스텀
    // 빌더에 포함됐을 때만 실행 가능하며, region 컨텍스트에서는 no-op이어야 한다.
    #expect(items.isEmpty)
    let copyItems = SelectionMenuResolver.resolve(
      context: .region(region), builder: { _ in [.copy] }
    )
    copyItems.first?.action()

    #if canImport(AppKit)
    let readBack = NSPasteboard.general.string(forType: .string)
    #elseif canImport(UIKit)
    let readBack = UIPasteboard.general.string
    #endif
    #expect(readBack == sentinel) // 페이스트보드가 바뀌지 않았다 — region no-op.
  }

  // MARK: Environment 키 — 기본값·대입 (뷰 트리 없이, 설계 §6-2)

  @Test func environmentSelectionMenuDefaultsToNilAndRoundTripsAssignment() {
    var environment = EnvironmentValues()
    #expect(environment.papyrusPDFSelectionMenu == nil)

    let builder: SelectionMenuItemsBuilder = { _ in
      [SelectionMenuItem(title: "Custom") { _ in }]
    }
    environment.papyrusPDFSelectionMenu = builder

    let readBack = environment.papyrusPDFSelectionMenu
    let capturedTitles = readBack?(Self.makeTextContext()).map(\.title) ?? []
    #expect(capturedTitles == ["Custom"])
  }
}
