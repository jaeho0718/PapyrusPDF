import CoreGraphics
import PapyrusPDFUI
import Testing

/// ``EditMenuGeometry``를 검증한다 — iPad 수동 검증에서 발견된 회귀(선택 위가 아니라
/// 화면 모서리에 메뉴가 뜨던 버그)의 원인이었던 부가 좌표 변환이 없는지 확인한다.
///
/// `EditMenuPresenter_iOS.swift`의 UIKit 결합부(`UIEditMenuInteraction` 설치·표시·
/// 스크롤 시작/정지 시 닫기·재표시)는 뷰 계층이 필요해 유닛 테스트 대상이 아니다 —
/// 데모 앱(iPad) 수동 검증 대상으로 남겨 둔다.
struct EditMenuGeometryTests {
  @Test func topCenterSourcePointReturnsTopMidOfRect() {
    let rect = CGRect(x: 10, y: 20, width: 100, height: 40)

    let point = EditMenuGeometry.topCenterSourcePoint(of: rect)

    #expect(point == CGPoint(x: 60, y: 20)) // midX = 10+50, minY = 20(표시 공간 y-아래 위쪽).
  }

  @Test func topCenterSourcePointPassesThroughLargeContentSpaceCoordinatesUnchanged() {
    // 줌·스크롤로 콘텐츠 공간 좌표가 커진 상황을 흉내낸다(예: 5,000페이지 문서 중간).
    // 이 함수는 변환을 하지 않아야 한다 — 값이 그대로(스케일·클램프 없이) 나와야 회귀가
    // 재현되지 않았음을 보증한다.
    let rect = CGRect(x: 12_345, y: 987_654, width: 300, height: 20)

    let point = EditMenuGeometry.topCenterSourcePoint(of: rect)

    #expect(point == CGPoint(x: 12_495, y: 987_654))
  }

  @Test func topCenterSourcePointHandlesZeroSizedRect() {
    let rect = CGRect(x: 5, y: 5, width: 0, height: 0)

    let point = EditMenuGeometry.topCenterSourcePoint(of: rect)

    #expect(point == CGPoint(x: 5, y: 5))
  }
}
