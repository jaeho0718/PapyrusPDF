#if canImport(AppKit)
import AppKit
import CoreGraphics

/// `ResolvedMenuItem`의 실행 클로저를 `NSMenuItem` target/action(셀렉터 기반)에 연결하는
/// 브리지 (`NSMenuItem.target`이 weak 참조라 클로저를 캡슐화해 대신 보관한다).
@MainActor
final class MenuActionBridge: NSObject {
  /// 실행할 액션.
  private let action: @MainActor () -> Void

  /// 브리지를 만든다.
  /// - Parameter action: 메뉴 항목 선택 시 실행할 액션.
  init(action: @escaping @MainActor () -> Void) {
    self.action = action
  }

  /// `NSMenuItem`의 action 셀렉터 대상.
  /// - Parameter sender: 선택된 메뉴 항목 (미사용).
  @objc
  func invoke(_ sender: Any?) {
    self.action()
  }
}

/// `[ResolvedMenuItem]` → `NSMenu` 변환 헬퍼 (향후 공개 메뉴 파이프라인이 재사용할 표면).
enum MacMenuBuilder {
  /// 메뉴와, 항목 target을 붙잡아 둘 브리지 목록을 함께 만든다.
  ///
  /// `NSMenuItem.target`은 weak 참조이므로, 호출자가 반환된 브리지 목록을 메뉴 수명
  /// 동안(예: 다음 메뉴 생성까지) 강한 참조로 보관해야 한다.
  /// - Parameter items: 변환할 메뉴 항목.
  /// - Returns: 조립된 메뉴와 대응 브리지 목록.
  @MainActor
  static func makeMenu(
    for items: [ResolvedMenuItem]
  ) -> (menu: NSMenu, bridges: [MenuActionBridge]) {
    let menu = NSMenu()
    var bridges: [MenuActionBridge] = []
    bridges.reserveCapacity(items.count)
    for item in items {
      let bridge = MenuActionBridge(action: item.action)
      bridges.append(bridge)
      let menuItem = NSMenuItem(
        title: item.title, action: #selector(MenuActionBridge.invoke(_:)), keyEquivalent: ""
      )
      menuItem.target = bridge
      if let systemImage = item.systemImage {
        menuItem.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
      }
      menu.addItem(menuItem)
    }
    return (menu, bridges)
  }
}

/// `ReaderScrollHostView`(macOS)의 `ReaderMenuPresenting` 채택.
///
/// macOS는 pull형(우클릭 시 `menu(for:)`가 직접 질의)이라 push 표면인
/// `presentSelectionMenu`는 호출되지 않는다(`SelectionStyle.presentsMenuOnSelectionEnd ==
/// false`가 코어의 호출 자체를 막는다) — 프로토콜 충족을 위한 no-op으로 명시한다.
/// `NSMenu`는 모달 팝업이라 `dismissSelectionMenu`도 no-op이다.
extension ReaderScrollHostView: ReaderMenuPresenting {
  /// no-op (macOS는 pull형 — 코어가 호출하지 않는다).
  /// - Parameters:
  ///   - items: 미사용.
  ///   - contentRect: 미사용.
  func presentSelectionMenu(_ items: [ResolvedMenuItem], around contentRect: CGRect) {}

  /// no-op (`NSMenu`는 모달 팝업이라 프로그램적으로 닫을 표면이 없다).
  func dismissSelectionMenu() {}
}
#endif
