#if canImport(AppKit)
import AppKit
import QuartzCore
import SwiftUI

/// 콘텐츠 좌표계를 iOS와 통일하기 위한 flipped 문서 뷰 (가정 9 확정 방식).
///
/// AppKit은 플립된 뷰의 백킹 레이어 지오메트리를 플립해 주므로 서브레이어
/// frame·이미지 contents가 iOS와 동일하게 좌상단 원점·y-아래 방향으로 동작한다.
final class FlippedDocumentView: NSView {
  /// 좌상단 원점·y-아래 방향으로 강제한다.
  override var isFlipped: Bool {
    true
  }
}

/// NSScrollView 기반 호스트. documentView = `FlippedDocumentView`
/// (isFlipped = true, wantsLayer = true — 가정 9의 좌표 통일).
///
/// - `allowsMagnification = true`, `magnification` = 줌.
/// - `contentView.postsBoundsChangedNotifications` → `hostViewportDidChange`
///   (NSScrollView magnification 하에서 `contentView.bounds`가 곧
///   콘텐츠 공간 가시 사각형이다 — `visibleContentRect`로 그대로 반환).
/// - `NSScrollView.didEndLiveMagnifyNotification` → `hostZoomInteractionDidEnd`
///   (+ 프로그램적 줌 변경 후에는 직접 재스냅 호출).
/// - `setFrameSize`/`viewDidEndLiveResize` → `hostViewportSizeDidChange`.
@MainActor
final class ReaderScrollHostView: NSView, ReaderScrollHost {
  /// 호스트 이벤트 수신부 (코어가 자신을 대입한다).
  weak var eventSink: (any ReaderHostEventSink)?

  /// 내부 스크롤 뷰.
  private let scrollView = NSScrollView()

  /// 콘텐츠를 백킹하는 문서 뷰 (좌상단 원점 강제).
  private let documentView = FlippedDocumentView()

  /// 마지막으로 통지한 뷰포트 크기 (중복 통지 방지).
  private var lastViewportSize: CGSize = .zero

  /// 페이지 컨테이너 레이어들이 붙는 루트.
  ///
  /// `setUp()`이 초기화 시점에 `documentView.layer`를 반드시 만들어 두므로 항상 존재한다
  /// (강제 언래핑 대신 그 불변식을 명시적으로 검사한다).
  var contentLayer: CALayer {
    guard let layer = self.documentView.layer else {
      preconditionFailure(
        "documentView.layer must exist — setUp() assigns one before this property is read."
      )
    }
    return layer
  }

  /// 화면 뷰포트 크기 (pt).
  var viewportSize: CGSize {
    self.scrollView.contentView.bounds.size
  }

  /// 현재 줌 배율.
  var zoomScale: CGFloat {
    self.scrollView.magnification
  }

  /// 뷰포트의 콘텐츠 공간(줌 미적용) 가시 사각형.
  var visibleContentRect: CGRect {
    self.scrollView.contentView.bounds
  }

  /// 프레임으로 뷰를 만든다.
  /// - Parameter frameRect: 초기 프레임.
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    self.setUp()
  }

  /// 스토리보드/XIB 복원용 이니셜라이저.
  /// - Parameter coder: 복원 코더.
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    self.setUp()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  /// 스크롤 뷰·문서 뷰를 배선하고 통지를 구독한다.
  private func setUp() {
    self.documentView.wantsLayer = true
    if self.documentView.layer == nil {
      self.documentView.layer = CALayer()
    }
    self.scrollView.documentView = self.documentView
    self.scrollView.allowsMagnification = true
    self.scrollView.hasVerticalScroller = true
    self.scrollView.autoresizingMask = [.width, .height]
    self.scrollView.frame = self.bounds
    self.scrollView.contentView.postsBoundsChangedNotifications = true
    self.addSubview(self.scrollView)

    NotificationCenter.default.addObserver(
      self, selector: #selector(self.boundsDidChange),
      name: NSView.boundsDidChangeNotification, object: self.scrollView.contentView
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(self.didEndLiveMagnify),
      name: NSScrollView.didEndLiveMagnifyNotification, object: self.scrollView
    )
  }

  /// 프레임 크기 변화 — 뷰포트 크기 변화를 감지해 코어에 통지한다.
  /// - Parameter newSize: 새 프레임 크기.
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    self.scrollView.frame = self.bounds
    self.notifyViewportSizeChangeIfNeeded()
  }

  /// 라이브 리사이즈 종료 — 최종 크기를 다시 확인한다.
  override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    self.notifyViewportSizeChangeIfNeeded()
  }

  /// 콘텐츠 크기(줌 1 기준)를 설정한다.
  /// - Parameter size: 줌 1 기준 콘텐츠 크기.
  func setContentSize(_ size: CGSize) {
    self.documentView.frame = CGRect(origin: .zero, size: size)
  }

  /// 줌 한계를 설정한다.
  /// - Parameters:
  ///   - minimum: 최소 줌 배율.
  ///   - maximum: 최대 줌 배율.
  func setZoomLimits(minimum: CGFloat, maximum: CGFloat) {
    self.scrollView.minMagnification = minimum
    self.scrollView.maxMagnification = maximum
  }

  /// 스크롤·줌을 이동한다 (`zoomScale` nil이면 현재 줌 유지).
  ///
  /// 프로그램적 매그니피케이션 변경은 `didEndLiveMagnifyNotification`을 발생시키지
  /// 않으므로, 여기서 직접 `hostZoomInteractionDidEnd()`를 호출해 재스냅한다.
  /// - Parameters:
  ///   - contentY: 목표 콘텐츠 공간 Y 좌표.
  ///   - zoomScale: 목표 줌 배율 (nil이면 유지).
  ///   - animated: 애니메이션 여부 (macOS 매그니피케이션은 즉시 적용).
  func scrollTo(contentY: CGFloat, zoomScale: CGFloat?, animated: Bool) {
    if let zoomScale {
      self.scrollView.magnification = zoomScale
    }
    let point = NSPoint(x: self.scrollView.contentView.bounds.minX, y: contentY)
    self.documentView.scroll(point)
    if zoomScale != nil {
      self.eventSink?.hostZoomInteractionDidEnd()
    }
  }

  /// 뷰포트 크기가 실제로 바뀌었을 때만 코어에 통지한다.
  private func notifyViewportSizeChangeIfNeeded() {
    let size = self.viewportSize
    guard size != self.lastViewportSize else {
      return
    }
    self.lastViewportSize = size
    self.eventSink?.hostViewportSizeDidChange()
  }

  /// 콘텐츠 뷰 bounds 변화(스크롤·매그니피케이션) 통지.
  /// - Parameter notification: bounds 변화 통지.
  @objc
  private func boundsDidChange(_ notification: Notification) {
    self.eventSink?.hostViewportDidChange()
  }

  /// 라이브 매그니피케이션(트랙패드 핀치) 종료 통지 — 버킷 재스냅 트리거.
  /// - Parameter notification: 매그니피케이션 종료 통지.
  @objc
  private func didEndLiveMagnify(_ notification: Notification) {
    self.eventSink?.hostZoomInteractionDidEnd()
  }
}

/// `NSViewRepresentable` 브리지 (`PapyrusReader` 내부 사용).
@MainActor
struct ReaderScrollViewRepresentable: NSViewRepresentable {
  /// 부착할 코어.
  let core: ReaderCore

  /// 호스트 뷰를 만들고 코어를 부착한다.
  /// - Parameter context: 표현 컨텍스트.
  /// - Returns: 생성된 호스트 뷰.
  func makeNSView(context: Context) -> ReaderScrollHostView {
    let view = ReaderScrollHostView()
    view.eventSink = self.core
    self.core.attach(to: view)
    return view
  }

  /// 갱신할 상태가 없다 (코어가 직접 레이어를 관리한다).
  /// - Parameters:
  ///   - nsView: 갱신 대상 호스트 뷰.
  ///   - context: 표현 컨텍스트.
  func updateNSView(_ nsView: ReaderScrollHostView, context: Context) {}
}
#endif
