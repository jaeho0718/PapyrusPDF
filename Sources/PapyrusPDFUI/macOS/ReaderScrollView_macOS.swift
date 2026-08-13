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

  /// 선택 이벤트 수신부 (`ReaderScrollHostView.eventSink` didSet이 배선한다).
  ///
  /// 마우스·⌘C·컨텍스트 메뉴 오버라이드는 `SelectionInput_macOS.swift`의 extension에
  /// 있다 (파일 분리 — 이 파일 수정 최소화). 저장 프로퍼티는 extension에 못 두므로
  /// 여기 둔다.
  weak var selectionSink: (any ReaderSelectionEventSink)?

  /// `mouseDown` 시점 위치 (콘텐츠 공간) — `mouseUp`의 클릭/드래그 판정용.
  var mouseDownPoint: CGPoint?

  /// 현재 클릭이 드래그(선택 시작)로 승격됐는지 여부.
  var isSelectionDragging = false

  /// 뷰 밖 정지 마우스의 연속 오토스크롤용 60Hz 타이머 (드래그 수명에 결속).
  var autoscrollTimer: Timer?

  /// 오토스크롤 틱이 재사용할 마지막 마우스 이벤트.
  var lastDragEvent: NSEvent?

  /// 우클릭 메뉴 액션 브리지 보관 (`NSMenuItem.target`은 weak 참조라 별도 보관 필요).
  var menuActionBridges: [MenuActionBridge] = []
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
/// - `NSScrollView.willStartLiveScrollNotification`/`willStartLiveMagnifyNotification`
///   → `hostScrollInteractionWillBegin` (#20).
/// - `scrollTo(animated: true)`는 적용 직후 동기로 `hostScrollAnimationDidEnd`를 호출한다
///   — macOS는 즉시 적용되므로 애니메이션 완료 = scrollTo 반환 시점 (`ReaderHostEventSink`
///   계약, §2.2).
@MainActor
final class ReaderScrollHostView: NSView, ReaderScrollHost {
  /// 호스트 이벤트 수신부 (코어가 자신을 대입한다). 코어는 `ReaderSelectionEventSink`도
  /// 구현하므로, 대입 시 documentView에 그 표면을 함께 배선한다.
  weak var eventSink: (any ReaderHostEventSink)? {
    didSet {
      self.documentView.selectionSink = self.eventSink as? ReaderSelectionEventSink
    }
  }

  /// 내부 스크롤 뷰.
  private let scrollView = NSScrollView()

  /// 콘텐츠를 백킹하는 문서 뷰 (좌상단 원점 강제).
  ///
  /// `SelectionInput_macOS.swift`(마우스·⌘C·컨텍스트 메뉴 오버라이드)가 참조하므로
  /// `private`가 아니라 모듈 스코프로 둔다 (M5 `TileRenderQueue`+확장 파일 분리와 동일 패턴).
  let documentView = FlippedDocumentView()

  /// 마지막으로 통지한 뷰포트 크기 (중복 통지 방지).
  private var lastViewportSize: CGSize = .zero

  /// 영역 선택 메뉴(`popUp`) 액션 브리지 보관 (`FlippedDocumentView.menuActionBridges`와
  /// 별개 — 우클릭 pull 경로는 documentView가, push(popUp) 경로는 이 뷰가 보관한다).
  ///
  /// `MenuPresenter_macOS.swift`(파일 분리된 `ReaderMenuPresenting` 채택)가 참조하므로
  /// `private`가 아니라 모듈 스코프로 둔다.
  var menuActionBridges: [MenuActionBridge] = []

  /// 표시 중인 영역 선택 popUp 메뉴 (`dismissSelectionMenu`의 취소 대상).
  ///
  /// `MenuPresenter_macOS.swift`가 참조하므로 모듈 스코프로 둔다.
  var presentedMenu: NSMenu?

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
    NotificationCenter.default.addObserver(
      self, selector: #selector(self.willStartLiveInteraction),
      name: NSScrollView.willStartLiveScrollNotification, object: self.scrollView
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(self.willStartLiveInteraction),
      name: NSScrollView.willStartLiveMagnifyNotification, object: self.scrollView
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
  /// 않으므로, 여기서 직접 `hostZoomInteractionDidEnd()`를 호출해 재스냅한다. macOS는
  /// 항상 즉시 적용되므로, `animated == true`였다면 적용 직후 동기로
  /// `hostScrollAnimationDidEnd()`를 호출해 `ReaderHostEventSink` 계약(§2.2)을
  /// 이행한다 — 즉시 완료도 완료다.
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
    if animated {
      self.eventSink?.hostScrollAnimationDidEnd()
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

  /// 라이브 스크롤·매그니피케이션 시작 통지 — 사용자가 조작권을 가져갔으므로 진행
  /// 중 프로그램 이동의 목표를 폐기한다 (#20).
  /// - Parameter notification: 시작 통지.
  @objc
  private func willStartLiveInteraction(_ notification: Notification) {
    self.eventSink?.hostScrollInteractionWillBegin()
  }
}

/// `NSViewRepresentable` 브리지 (`PapyrusPDFReader` 내부 사용).
@MainActor
struct ReaderScrollViewRepresentable: NSViewRepresentable {
  /// 부착할 코어.
  let core: ReaderCore

  /// `View.papyrusPDFSelectionMenu(_:)`로 지정된 선택 메뉴 빌더 (미지정이면 `nil`).
  let menuBuilder: SelectionMenuItemsBuilder?

  /// 호스트 뷰를 만들고 코어를 부착한다.
  /// - Parameter context: 표현 컨텍스트.
  /// - Returns: 생성된 호스트 뷰.
  func makeNSView(context: Context) -> ReaderScrollHostView {
    let view = ReaderScrollHostView()
    view.eventSink = self.core
    self.core.selectionMenuBuilder = self.menuBuilder
    self.core.attach(to: view)
    return view
  }

  /// 선택 메뉴 빌더를 코어에 재대입한다 (환경 변화 반영 — 재조립 없음).
  /// - Parameters:
  ///   - nsView: 갱신 대상 호스트 뷰 (미사용 — 코어가 레이어를 직접 관리한다).
  ///   - context: 표현 컨텍스트.
  func updateNSView(_ nsView: ReaderScrollHostView, context: Context) {
    self.core.selectionMenuBuilder = self.menuBuilder
  }
}
#endif
