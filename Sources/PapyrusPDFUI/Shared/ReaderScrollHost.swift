import CoreGraphics
import QuartzCore

/// 플랫폼 스크롤 뷰가 코어에 제공해야 하는 표면 (ARCHITECTURE 123행의 프로토콜).
///
/// 좌표 계약: `contentLayer`는 좌상단 원점·y-아래 방향(가정 9), 크기 = 줌 1 기준
/// `contentSize`. 줌은 호스트가 이 레이어(를 담은 문서 뷰)에 배율로 적용한다.
@MainActor
package protocol ReaderScrollHost: AnyObject {
  /// 페이지 컨테이너 레이어들이 붙는 루트 (문서 뷰의 백킹 레이어).
  var contentLayer: CALayer { get }

  /// 화면 뷰포트 크기 (pt).
  var viewportSize: CGSize { get }

  /// 현재 줌 배율.
  var zoomScale: CGFloat { get }

  /// 뷰포트의 콘텐츠 공간(줌 미적용) 가시 사각형.
  var visibleContentRect: CGRect { get }

  /// 콘텐츠 크기(줌 1 기준)를 설정한다.
  /// - Parameter size: 줌 1 기준 콘텐츠 크기.
  func setContentSize(_ size: CGSize)

  /// 줌 한계를 설정한다.
  /// - Parameters:
  ///   - minimum: 최소 줌 배율.
  ///   - maximum: 최대 줌 배율.
  func setZoomLimits(minimum: CGFloat, maximum: CGFloat)

  /// 스크롤·줌을 이동한다 (`zoomScale` nil이면 현재 줌 유지).
  /// `contentY`는 콘텐츠 공간 Y (호스트가 줌 곱해 실제 오프셋으로 변환).
  /// - Parameters:
  ///   - contentY: 목표 콘텐츠 공간 Y 좌표.
  ///   - zoomScale: 목표 줌 배율 (nil이면 유지).
  ///   - animated: 애니메이션 여부.
  func scrollTo(contentY: CGFloat, zoomScale: CGFloat?, animated: Bool)
}

/// 호스트 → 코어 이벤트 수신부 (`ReaderCore`가 구현. 델리게이트 방향 분리로
/// 호스트가 코어 구체 타입을 모른 채 컴파일되게 한다 — iOS/macOS 파일이
/// Shared에 의존하되 역방향 없음).
@MainActor
package protocol ReaderHostEventSink: AnyObject {
  /// 스크롤·줌 진행으로 가시 영역이 바뀌었다 (매 프레임 호출 가능 — §4.7 예산 준수).
  func hostViewportDidChange()

  /// 줌 제스처(핀치/매그니피케이션)가 끝났다 — 버킷 재스냅 트리거 (가정 3).
  func hostZoomInteractionDidEnd()

  /// 뷰포트 크기가 바뀌었다 (회전·창 리사이즈) — 줌 한계 재계산 + 위치 보존.
  func hostViewportSizeDidChange()
}
