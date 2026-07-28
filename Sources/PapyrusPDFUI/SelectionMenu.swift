import PapyrusPDFCore
import SwiftUI

/// 선택 메뉴가 표시되는 대상입니다.
///
/// 텍스트 선택(``text(_:)``)과 개발자 정의 선택 가능 영역(``region(_:)``) 두 케이스가
/// 있습니다.
public enum SelectionContext: Sendable {
  /// 텍스트 선택입니다.
  case text(TextSelectionContext)
  /// 개발자 정의 선택 가능 영역입니다.
  case region(SelectableRegion)
}

/// 텍스트 선택 메뉴 컨텍스트입니다.
public struct TextSelectionContext: Sendable {
  /// 선택 범위입니다.
  ///
  /// `PapyrusPDFCore.TextSelection`으로 정규화된 명칭입니다 — 같은 이름의 SwiftUI 타입과
  /// 충돌하지 않도록 이 파일 안에서는 모듈 한정으로 표기합니다.
  public let selection: PapyrusPDFCore.TextSelection
  /// 해소된 선택 문자열입니다 (페이지 경계는 개행 결합, 총량 캡 적용).
  public let selectedText: String

  /// 컨텍스트를 생성합니다 (테스트·프리뷰에서 직접 만들 수 있습니다).
  /// - Parameters:
  ///   - selection: 선택 범위입니다.
  ///   - selectedText: 해소된 선택 문자열입니다.
  public init(selection: PapyrusPDFCore.TextSelection, selectedText: String) {
    self.selection = selection
    self.selectedText = selectedText
  }
}

/// 선택 메뉴 항목 하나입니다.
///
/// 항목은 값이며, 실행 클로저는 메인 액터에서 호출됩니다.
public struct SelectionMenuItem: Sendable {
  /// 표시 타이틀입니다.
  public let title: String
  /// SF Symbols 이름입니다 (플랫폼이 지원할 때 표시되며, 없으면 `nil`입니다).
  public let systemImage: String?
  /// 선택 시 실행되는 액션입니다 (메인 액터에서 호출됩니다).
  public let action: @MainActor @Sendable (SelectionContext) -> Void

  /// 항목을 생성합니다.
  /// - Parameters:
  ///   - title: 표시 타이틀입니다.
  ///   - systemImage: SF Symbols 이름입니다.
  ///   - action: 선택 시 실행되는 액션입니다 (메인 액터에서 호출됩니다).
  public init(
    title: String, systemImage: String? = nil,
    action: @escaping @MainActor @Sendable (SelectionContext) -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.action = action
  }

  /// 기본 복사 항목입니다.
  ///
  /// 텍스트 선택이면 ``TextSelectionContext/selectedText``를 시스템 페이스트보드에
  /// 복사합니다. 커스텀 메뉴에 기본 복사를 유지하려면 이 항목을 배열에 포함합니다.
  /// 영역 컨텍스트에서는 동작하지 않습니다.
  public static var copy: SelectionMenuItem {
    SelectionMenuItem(title: "Copy", systemImage: "doc.on.doc") { context in
      switch context {
      case let .text(textContext):
        PlatformPasteboard.setString(textContext.selectedText)
      case .region:
        break
      }
    }
  }
}

/// 선택 메뉴 항목 빌더입니다 (컨텍스트를 받아 항목 배열을 반환하며, 메인 액터에서
/// 호출됩니다).
public typealias SelectionMenuItemsBuilder =
  @MainActor @Sendable (SelectionContext) -> [SelectionMenuItem]

extension View {
  /// 하위 ``PapyrusPDFReader``의 선택 메뉴 항목을 지정합니다.
  ///
  /// 미지정 시 기본 메뉴(텍스트 선택: 복사)가 적용됩니다. 빌더가 빈 배열을 반환하면
  /// 그 선택에는 메뉴가 표시되지 않습니다.
  /// - Parameter items: 선택 컨텍스트를 받아 메뉴 항목을 반환하는 빌더입니다.
  /// - Returns: 환경이 적용된 뷰입니다.
  public func papyrusPDFSelectionMenu(
    _ items: @escaping SelectionMenuItemsBuilder
  ) -> some View {
    self.environment(\.papyrusPDFSelectionMenu, items)
  }
}

extension EnvironmentValues {
  /// 선택 메뉴 빌더 (미지정 nil — 내부 전파 전용, 공개 표면은 modifier).
  @Entry var papyrusPDFSelectionMenu: SelectionMenuItemsBuilder?
}
