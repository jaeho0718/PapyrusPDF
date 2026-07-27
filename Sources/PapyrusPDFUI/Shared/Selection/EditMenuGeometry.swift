import CoreGraphics

/// 편집 메뉴 앵커 좌표 계산 (뷰 계층에 의존하지 않는 순수 함수 — 유닛 테스트 가능).
///
/// iOS의 `UIEditMenuInteraction`은 소스 포인트·타깃 사각형을 상호작용이 설치된 뷰
/// 자신의 좌표계로 해석한다. 호출측(`EditMenuPresenter`)이 받는 콘텐츠 공간 사각형은
/// 상호작용이 설치된 문서 뷰 자신의 좌표계와 이미 같으므로, 이 계산은 좌표계 변환을
/// 전혀 하지 않는다 — 변환을 끼워 넣으면 화면 좌표를 다시 콘텐츠 좌표로 오인해 메뉴가
/// 엉뚱한 위치(화면 모서리)로 튀는 문제가 재현된다.
package enum EditMenuGeometry {
  /// 앵커 사각형 위쪽 중앙점 — 메뉴가 선택 위쪽에 앵커되도록 하는 소스 포인트다.
  /// 공간이 부족하면 시스템이 자동으로 아래쪽 등 대체 위치로 폴백한다.
  /// - Parameter rect: 앵커 사각형 (호출측 좌표계를 그대로 유지 — 내부에서 변환하지 않는다).
  /// - Returns: 사각형 위쪽 변의 중앙점.
  package static func topCenterSourcePoint(of rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX, y: rect.minY)
  }
}
