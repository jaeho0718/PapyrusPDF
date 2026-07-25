#if canImport(UIKit)
import QuartzCore
import SwiftUI
import UIKit

/// UIScrollView 기반 호스트. `documentView`(UIView)가 `contentLayer`를 백킹한다.
///
/// - `viewForZooming`은 `documentView` — 핀치 중엔 transform 확대(즉시·흐릿, 가정 3).
/// - `scrollViewDidScroll`/`DidZoom` → `sink.hostViewportDidChange()`.
/// - `scrollViewDidEndZooming` → `sink.hostZoomInteractionDidEnd()`.
/// - `layoutSubviews` 크기 변화 → `sink.hostViewportSizeDidChange()`.
/// - `contentInsetAdjustmentBehavior = .never` (레이아웃 엔진 여백이 유일 원천).
/// - `visibleContentRect = CGRect(origin: contentOffset/zoom, size: bounds.size/zoom)`.
@MainActor
final class ReaderScrollHostView: UIView, ReaderScrollHost, UIScrollViewDelegate {
  /// 호스트 이벤트 수신부 (코어가 자신을 대입한다). 코어는 `ReaderSelectionEventSink`도
  /// 구현하므로, 대입 시 선택 입력·메뉴 프레젠터에 그 표면을 함께 배선한다.
  weak var eventSink: (any ReaderHostEventSink)? {
    didSet {
      let selectionSink = self.eventSink as? ReaderSelectionEventSink
      self.selectionInput.sink = selectionSink
      self.editMenuPresenter.updateSink(selectionSink)
    }
  }

  /// 내부 스크롤 뷰.
  private let scrollView = UIScrollView()

  /// 콘텐츠를 백킹하는 문서 뷰 (줌 대상).
  private let documentView = UIView()

  /// 롱프레스·핸들 팬·탭 제스처 + 확대 루프·오토스크롤 소유자.
  private let selectionInput = SelectionInput()

  /// `UIEditMenuInteraction` 브리지.
  private let editMenuPresenter = EditMenuPresenter()

  /// 페이지 컨테이너 레이어들이 붙는 루트.
  var contentLayer: CALayer {
    self.documentView.layer
  }

  /// 화면 뷰포트 크기 (pt).
  var viewportSize: CGSize {
    self.scrollView.bounds.size
  }

  /// 현재 줌 배율.
  var zoomScale: CGFloat {
    self.scrollView.zoomScale
  }

  /// 뷰포트의 콘텐츠 공간(줌 미적용) 가시 사각형.
  var visibleContentRect: CGRect {
    let zoom = self.scrollView.zoomScale
    guard zoom > 0 else {
      return .zero
    }
    let offset = self.scrollView.contentOffset
    let size = self.scrollView.bounds.size
    return CGRect(
      x: offset.x / zoom, y: offset.y / zoom, width: size.width / zoom, height: size.height / zoom
    )
  }

  /// 프레임으로 뷰를 만든다.
  /// - Parameter frame: 초기 프레임.
  override init(frame: CGRect) {
    super.init(frame: frame)
    self.setUp()
  }

  /// 스토리보드/XIB 복원용 이니셜라이저.
  /// - Parameter coder: 복원 코더.
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    self.setUp()
  }

  /// 스크롤 뷰·문서 뷰를 배선하고 선택 입력·메뉴 프레젠터를 부착한다.
  private func setUp() {
    self.scrollView.delegate = self
    self.scrollView.contentInsetAdjustmentBehavior = .never
    self.scrollView.addSubview(self.documentView)
    self.addSubview(self.scrollView)
    self.selectionInput.attach(to: self.documentView, scrollView: self.scrollView)
    self.editMenuPresenter.attach(hostView: self, documentView: self.documentView)
  }

  /// 레이아웃 갱신 — 뷰포트 크기 변화를 감지해 코어에 통지한다.
  override func layoutSubviews() {
    super.layoutSubviews()
    let previousSize = self.scrollView.bounds.size
    self.scrollView.frame = self.bounds
    if previousSize != self.bounds.size {
      self.eventSink?.hostViewportSizeDidChange()
    }
  }

  /// 콘텐츠 크기(줌 1 기준)를 설정한다.
  /// - Parameter size: 줌 1 기준 콘텐츠 크기.
  func setContentSize(_ size: CGSize) {
    self.documentView.frame = CGRect(origin: .zero, size: size)
    self.scrollView.contentSize = size
  }

  /// 줌 한계를 설정한다.
  /// - Parameters:
  ///   - minimum: 최소 줌 배율.
  ///   - maximum: 최대 줌 배율.
  func setZoomLimits(minimum: CGFloat, maximum: CGFloat) {
    self.scrollView.minimumZoomScale = minimum
    self.scrollView.maximumZoomScale = maximum
  }

  /// 스크롤·줌을 이동한다 (`zoomScale` nil이면 현재 줌 유지).
  /// - Parameters:
  ///   - contentY: 목표 콘텐츠 공간 Y 좌표.
  ///   - zoomScale: 목표 줌 배율 (nil이면 유지).
  ///   - animated: 애니메이션 여부.
  func scrollTo(contentY: CGFloat, zoomScale: CGFloat?, animated: Bool) {
    if let zoomScale {
      self.scrollView.setZoomScale(zoomScale, animated: animated)
    }
    let zoom = zoomScale ?? self.scrollView.zoomScale
    let offset = CGPoint(x: self.scrollView.contentOffset.x, y: contentY * zoom)
    self.scrollView.setContentOffset(offset, animated: animated)
  }

  // MARK: - UIScrollViewDelegate

  /// 줌 대상 뷰 — `documentView`.
  /// - Parameter scrollView: 확대 중인 스크롤 뷰.
  /// - Returns: 줌 대상 뷰.
  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    self.documentView
  }

  /// 스크롤 진행 통지.
  /// - Parameter scrollView: 스크롤된 뷰.
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    self.eventSink?.hostViewportDidChange()
  }

  /// 줌 진행 통지.
  /// - Parameter scrollView: 확대 중인 뷰.
  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    self.eventSink?.hostViewportDidChange()
  }

  /// 줌 제스처 종료 통지 — 버킷 재스냅 트리거.
  /// - Parameters:
  ///   - scrollView: 확대가 끝난 뷰.
  ///   - view: 확대 대상 뷰.
  ///   - scale: 최종 배율.
  func scrollViewDidEndZooming(
    _ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat
  ) {
    self.eventSink?.hostZoomInteractionDidEnd()
  }

  /// 스크롤 시작 — 표시 중인 선택 메뉴를 닫는다.
  /// - Parameter scrollView: 스크롤될 뷰.
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    self.editMenuPresenter.handleScrollWillBegin()
  }

  /// 드래그 종료 — 감속 없이 즉시 정지하면 메뉴 재표시를 시도한다.
  /// - Parameters:
  ///   - scrollView: 스크롤된 뷰.
  ///   - decelerate: 감속(관성 스크롤) 진행 여부.
  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    guard !decelerate else {
      return
    }
    self.editMenuPresenter.handleScrollDidSettle()
  }

  /// 관성 스크롤 정지 — 메뉴 재표시를 시도한다.
  /// - Parameter scrollView: 정지한 뷰.
  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    self.editMenuPresenter.handleScrollDidSettle()
  }
}

/// `ReaderMenuPresenting` 채택 — 구현은 `EditMenuPresenter`에 위임한다.
extension ReaderScrollHostView: ReaderMenuPresenting {
  /// `EditMenuPresenter.present(_:around:)`에 위임한다.
  /// - Parameters:
  ///   - items: 표시할 메뉴 항목.
  ///   - contentRect: 앵커 사각형 (콘텐츠 공간).
  func presentSelectionMenu(_ items: [ResolvedMenuItem], around contentRect: CGRect) {
    self.editMenuPresenter.present(items, around: contentRect)
  }

  /// `EditMenuPresenter.dismiss()`에 위임한다.
  func dismissSelectionMenu() {
    self.editMenuPresenter.dismiss()
  }
}

/// `UIViewRepresentable` 브리지 (`PapyrusReader` 내부 사용).
@MainActor
struct ReaderScrollViewRepresentable: UIViewRepresentable {
  /// 부착할 코어.
  let core: ReaderCore

  /// 호스트 뷰를 만들고 코어를 부착한다.
  /// - Parameter context: 표현 컨텍스트.
  /// - Returns: 생성된 호스트 뷰.
  func makeUIView(context: Context) -> ReaderScrollHostView {
    let view = ReaderScrollHostView()
    view.eventSink = self.core
    self.core.attach(to: view)
    return view
  }

  /// 갱신할 상태가 없다 (코어가 직접 레이어를 관리한다).
  /// - Parameters:
  ///   - uiView: 갱신 대상 호스트 뷰.
  ///   - context: 표현 컨텍스트.
  func updateUIView(_ uiView: ReaderScrollHostView, context: Context) {}
}
#endif
