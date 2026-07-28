#if canImport(UIKit)
import CoreGraphics
import UIKit

/// 롱프레스·핸들 팬·탭 제스처와 확대 루프·오토스크롤을 소유하는 내부 입력 컨트롤러.
///
/// `ReaderScrollHostView`가 `setUp`에서 documentView에 부착하고, `eventSink` 변경 시
/// `sink`만 갱신한다 — 제스처 인식기 자체는 세션 내내 재사용된다.
@MainActor
final class SelectionInput: NSObject {
  /// 선택 이벤트 수신부 (호스트가 배선).
  weak var sink: (any ReaderSelectionEventSink)?

  /// 부착된 문서 뷰 (줌 대상이라 제스처 좌표가 곧 콘텐츠 공간 좌표다).
  private weak var documentView: UIView?

  /// 부착된 스크롤 뷰 (오토스크롤 대상).
  private weak var scrollView: UIScrollView?

  /// 핸들 팬 게이팅용 참조 (`gestureRecognizerShouldBegin`에서 식별).
  private weak var handlePanRecognizer: UIPanGestureRecognizer?

  /// 진행 중 드래그를 구동하는 인식기 (오토스크롤 틱이 위치 재조회에 사용).
  private weak var activeRecognizer: UIGestureRecognizer?

  /// 진행 중 확대 루프 세션 (iOS 17+ API — 배포 최소 버전이 이를 충족해 무조건 사용).
  private var loupeSession: UITextLoupeSession?

  /// 뷰 밖 정지 터치의 연속 오토스크롤용 60Hz 타이머 (드래그 수명에 결속).
  private var autoscrollTimer: Timer?

  /// documentView에 제스처 인식기 3종을 부착한다.
  /// - Parameters:
  ///   - documentView: 줌 대상 문서 뷰.
  ///   - scrollView: 오토스크롤 대상 스크롤 뷰.
  func attach(to documentView: UIView, scrollView: UIScrollView) {
    self.documentView = documentView
    self.scrollView = scrollView

    let longPress = UILongPressGestureRecognizer(
      target: self, action: #selector(self.handleLongPress(_:))
    )
    let handlePan = UIPanGestureRecognizer(
      target: self, action: #selector(self.handleHandlePan(_:))
    )
    handlePan.delegate = self
    let tap = UITapGestureRecognizer(target: self, action: #selector(self.handleTap(_:)))

    documentView.isUserInteractionEnabled = true
    documentView.addGestureRecognizer(longPress)
    documentView.addGestureRecognizer(handlePan)
    documentView.addGestureRecognizer(tap)
    // handlePan은 핸들 밖에서 delegate가 즉시 실패시키므로 스크롤 지연 체감이 없다.
    scrollView.panGestureRecognizer.require(toFail: handlePan)

    self.handlePanRecognizer = handlePan
  }

  // MARK: - 롱프레스 (새 드래그, word 시작)

  /// 롱프레스 상태 변화를 처리한다 (`.began` → word 드래그 시작, 이하 상태는 공통 드래그
  /// 이벤트로 위임).
  /// - Parameter recognizer: 롱프레스 인식기.
  @objc
  private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
    guard let documentView else {
      return
    }
    let point = recognizer.location(in: documentView)
    switch recognizer.state {
    case .began:
      self.sink?.hostSelectionDragBegan(atContentPoint: point, granularity: .word)
      self.activeRecognizer = recognizer
      self.beginLoupe(at: point, widget: recognizer.view)
      self.startAutoscroll()
    case .changed:
      self.sink?.hostSelectionDragChanged(toContentPoint: point)
      self.loupeSession?.move(to: point, withCaretRect: .null, trackingCaret: false)
    case .ended:
      self.sink?.hostSelectionDragEnded()
      self.endDrag()
    case .cancelled, .failed:
      self.sink?.hostSelectionDragCancelled()
      self.endDrag()
    default:
      break
    }
  }

  // MARK: - 핸들 팬 (기존 선택 핸들 드래그)

  /// 핸들 팬 상태 변화를 처리한다 (`.began`에서 히트 재확인 후 핸들 드래그 시작).
  /// - Parameter recognizer: 핸들 팬 인식기.
  @objc
  private func handleHandlePan(_ recognizer: UIPanGestureRecognizer) {
    guard let documentView else {
      return
    }
    let point = recognizer.location(in: documentView)
    switch recognizer.state {
    case .began:
      guard let handle = self.sink?.hostSelectionHandleTest(atContentPoint: point) else {
        return
      }
      self.activeRecognizer = recognizer
      self.sink?.hostSelectionHandleDragBegan(handle, atContentPoint: point)
      self.beginLoupe(at: point, widget: recognizer.view)
      self.startAutoscroll()
    case .changed:
      self.sink?.hostSelectionDragChanged(toContentPoint: point)
      self.loupeSession?.move(to: point, withCaretRect: .null, trackingCaret: false)
    case .ended:
      self.sink?.hostSelectionDragEnded()
      self.endDrag()
    case .cancelled, .failed:
      self.sink?.hostSelectionDragCancelled()
      self.endDrag()
    default:
      break
    }
  }

  // MARK: - 탭

  /// 탭을 선택 해제 이벤트로 전달한다.
  /// - Parameter recognizer: 탭 인식기.
  @objc
  private func handleTap(_ recognizer: UITapGestureRecognizer) {
    guard let documentView, recognizer.state == .ended else {
      return
    }
    let point = recognizer.location(in: documentView)
    self.sink?.hostTap(atContentPoint: point)
  }

  // MARK: - 드래그 공통 종료

  /// 드래그(롱프레스·핸들 팬) 종료·취소 공통 정리.
  private func endDrag() {
    self.endLoupe()
    self.stopAutoscroll()
    self.activeRecognizer = nil
  }

  // MARK: - 확대 루프

  /// 확대 루프 세션을 시작한다.
  /// - Parameters:
  ///   - point: 시작 점 (문서 뷰 좌표 = 콘텐츠 공간).
  ///   - widget: 애니메이션 시작점으로 쓸 시스템 선택 위젯 뷰 (없으면 `nil`).
  private func beginLoupe(at point: CGPoint, widget: UIView?) {
    guard let documentView else {
      return
    }
    self.loupeSession = UITextLoupeSession.begin(
      at: point, fromSelectionWidgetView: widget, in: documentView
    )
  }

  /// 확대 루프 세션을 종료한다.
  private func endLoupe() {
    self.loupeSession?.invalidate()
    self.loupeSession = nil
  }

  // MARK: - 오토스크롤 (§1.9 — 뷰 좌표 가장자리 침투 시 60Hz 틱)

  /// 오토스크롤 타이머를 가동한다.
  private func startAutoscroll() {
    self.autoscrollTimer?.invalidate()
    self.autoscrollTimer = Timer.scheduledTimer(
      withTimeInterval: SelectionStyle.autoscrollInterval, repeats: true
    ) { [weak self] _ in
      Task { @MainActor in
        self?.autoscrollTick()
      }
    }
  }

  /// 오토스크롤 타이머를 해제한다.
  private func stopAutoscroll() {
    self.autoscrollTimer?.invalidate()
    self.autoscrollTimer = nil
  }

  /// 오토스크롤 한 틱: 가장자리 침투 깊이에 비례한 속도로 스크롤하고, 마지막 터치
  /// 위치를 콘텐츠 좌표로 재변환해 `dragChanged`를 재전송한다 — 손가락이 멈춰 있어도
  /// 선택이 자란다. 스크롤 변화는 `scrollViewDidScroll` 경로로 실체화·prefetch가 따라온다.
  private func autoscrollTick() {
    guard let scrollView, let documentView, let recognizer = self.activeRecognizer else {
      return
    }
    let viewPoint = recognizer.location(in: scrollView)
    let bounds = scrollView.bounds
    let inset = SelectionStyle.autoscrollEdgeInset
    let speed: CGFloat
    if viewPoint.y < bounds.minY + inset {
      let depth = (bounds.minY + inset) - viewPoint.y
      speed = -Self.autoscrollSpeed(forPenetration: depth, inset: inset)
    } else if viewPoint.y > bounds.maxY - inset {
      let depth = viewPoint.y - (bounds.maxY - inset)
      speed = Self.autoscrollSpeed(forPenetration: depth, inset: inset)
    } else {
      speed = 0
    }
    guard speed != 0 else {
      return
    }

    var offset = scrollView.contentOffset
    let maxY = max(0, scrollView.contentSize.height - bounds.height)
    offset.y = min(max(offset.y + speed * SelectionStyle.autoscrollInterval, 0), maxY)
    scrollView.contentOffset = offset

    let contentPoint = recognizer.location(in: documentView)
    self.sink?.hostSelectionDragChanged(toContentPoint: contentPoint)
    self.loupeSession?.move(to: contentPoint, withCaretRect: .null, trackingCaret: false)
  }

  /// 가장자리 침투 깊이에 비례한 오토스크롤 속도 (화면 pt/초, 상한 `autoscrollMaxSpeed`).
  /// - Parameters:
  ///   - depth: 가장자리 안쪽으로의 침투 깊이 (pt).
  ///   - inset: 오토스크롤 트리거 가장자리 폭 (pt).
  /// - Returns: 스크롤 속도 (pt/초).
  private static func autoscrollSpeed(forPenetration depth: CGFloat, inset: CGFloat) -> CGFloat {
    guard inset > 0 else {
      return 0
    }
    let ratio = min(max(depth / inset, 0), 1)
    return ratio * SelectionStyle.autoscrollMaxSpeed
  }
}

// MARK: - UIGestureRecognizerDelegate

extension SelectionInput: UIGestureRecognizerDelegate {
  /// 핸들 팬은 점이 핸들 터치 타깃 안일 때만 인식을 시작한다 (그 외는 스크롤이 이긴다).
  /// - Parameter gestureRecognizer: 판정할 인식기.
  /// - Returns: 인식 시작 허용 여부.
  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === self.handlePanRecognizer, let documentView else {
      return true
    }
    let point = gestureRecognizer.location(in: documentView)
    return self.sink?.hostSelectionHandleTest(atContentPoint: point) != nil
  }
}
#endif
