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

/// `[ResolvedMenuItem]` → `NSMenu` 변환 헬퍼 (공개 메뉴 파이프라인의 해소 산출물을 소비한다).
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
/// 텍스트 선택은 계속 pull형(우클릭 시 `menu(for:)`가 직접 질의)이라 이 표면으로
/// 들어오지 않는다. 영역 선택은 양 플랫폼 모두 push라(§0.2-4) macOS에서도 이 표면이
/// 실호출된다 — `NSMenu.popUp`으로 구현한다(M11 계약 ② 개정판).
extension ReaderScrollHostView: ReaderMenuPresenting {
  /// 영역 선택의 즉시 메뉴를 `NSMenu.popUp`으로 앵커 rect 아래에 표시한다.
  ///
  /// `FlippedDocumentView`는 y-아래 flipped이므로 `contentRect.maxY`가 시각적
  /// 아래변이다 — 메뉴가 영역 아래에 뜬다. `popUp`은 자체 트래킹 루프를 도는 메인 액터
  /// 동기 호출이다 — 바깥 클릭 시 자동 닫히며, 닫힌 뒤에도 영역 선택은 유지된다(해제는
  /// 다음 탭).
  /// - Parameters:
  ///   - items: 표시할 메뉴 항목.
  ///   - contentRect: 앵커 사각형 (콘텐츠 공간).
  func presentSelectionMenu(_ items: [ResolvedMenuItem], around contentRect: CGRect) {
    let built = MacMenuBuilder.makeMenu(for: items)
    self.menuActionBridges = built.bridges
    self.presentedMenu = built.menu
    built.menu.popUp(
      positioning: nil,
      at: CGPoint(x: contentRect.minX, y: contentRect.maxY),
      in: self.documentView
    )
  }

  /// 표시 중 popUp 메뉴를 닫는다 (미표시면 no-op — 멱등 계약 유지).
  func dismissSelectionMenu() {
    self.presentedMenu?.cancelTracking()
    self.presentedMenu = nil
  }
}
#endif
