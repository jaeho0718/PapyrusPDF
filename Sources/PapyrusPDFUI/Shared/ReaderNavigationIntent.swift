import CoreGraphics

/// 이동·줌 의도의 심볼릭 표현. 실행 시점에 좌표·배율로 해석되므로, 뷰포트 크기가
/// 바뀐 뒤 재실행하면 새 지오메트리 기준으로 다시 해석된다 (#20의 핵심 —
/// `.fitWidth`·`.keep`은 값이 아니라 규칙으로 래치된다).
package struct ReaderNavigationIntent: Equatable, Sendable {
  /// 목표 지점.
  package enum Destination: Equatable, Sendable {
    /// 페이지 상단 (goToPage — 인덱스는 실행 시 클램프).
    case pageTop(Int)
    /// 정규화 위치 (restore·줌의 위치 보존).
    case position(ReaderPosition)
    /// 실행 시점의 현재 뷰포트 상단 (줌 전용 — 실행 시 `.position`으로 구체화).
    case current
  }

  /// 목표 줌.
  package enum Zoom: Equatable, Sendable {
    /// 현재 줌 유지 (단, 새 fit-width 하한보다 작으면 하한으로 올린다).
    case keep
    /// 절대 배율 (실행 시 [fit, max]로 클램프. 비유한값은 fit으로 위생 처리).
    case scale(CGFloat)
    /// 실행 시점의 fit-width 배율 (심볼릭 유지 — 리사이즈 후 새 fit으로 재해석).
    case fitWidth
  }

  /// 목표 지점.
  package let destination: Destination
  /// 목표 줌.
  package let zoom: Zoom

  /// 의도를 만든다.
  /// - Parameters:
  ///   - destination: 목표 지점.
  ///   - zoom: 목표 줌.
  package init(destination: Destination, zoom: Zoom) {
    self.destination = destination
    self.zoom = zoom
  }
}
