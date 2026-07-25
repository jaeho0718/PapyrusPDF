/// 공개 메뉴 빌더 산출물을 플랫폼 소비용 `ResolvedMenuItem`으로 해소하는 순수 로직.
///
/// 뷰·코어 의존이 없어 뷰 트리 없이 유닛 테스트한다.
@MainActor
enum SelectionMenuResolver {
  /// 항목 수 상한 — 방어적 절단 (초과분 무시). 네이티브 메뉴가 수백 항목에서 보이는
  /// 퇴행(레이아웃 정체)을 결정적으로 차단한다.
  static let maxItems = 64

  /// 빌더(없으면 기본 폴백)를 호출해 해소한다.
  /// - Parameters:
  ///   - context: 해소할 선택 컨텍스트.
  ///   - builder: 공개 메뉴 빌더 (nil이면 `defaultItems`로 폴백).
  /// - Returns: 해소 항목 (빈 배열이면 호출측이 메뉴를 표시하지 않는다).
  static func resolve(
    context: SelectionContext, builder: SelectionMenuItemsBuilder?
  ) -> [ResolvedMenuItem] {
    let items = builder?(context) ?? Self.defaultItems(for: context)
    return items.prefix(Self.maxItems).map { item in
      ResolvedMenuItem(title: item.title, systemImage: item.systemImage) {
        item.action(context)
      }
    }
  }

  /// 빌더 미지정 시 기본 항목 (텍스트: 복사 1개).
  /// - Parameter context: 대상 선택 컨텍스트.
  /// - Returns: 기본 메뉴 항목 목록.
  static func defaultItems(for context: SelectionContext) -> [SelectionMenuItem] {
    switch context {
    case .text:
      return [.copy]
    }
  }
}
