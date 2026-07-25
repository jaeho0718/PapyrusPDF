#if canImport(UIKit)
import CoreGraphics
import UIKit

/// `UIEditMenuInteraction` 브리지 — `ReaderScrollHostView`가 `ReaderMenuPresenting`을
/// 이 타입에 위임한다.
///
/// 좌표계 주의: `UIEditMenuInteraction`은 `sourcePoint`·`targetRectFor`의 반환값을 상호작용이
/// **설치된 뷰(`documentView`) 자신의 좌표계**로 해석한다(Apple 헤더 주석: "relative to the
/// interaction's view"). `documentView`는 줌 대상 뷰라 그 자신의 bounds 좌표계가 곧 콘텐츠
/// 공간이므로, `present(_:around:)`가 받는 `contentRect`(콘텐츠 공간)를 다른 뷰 좌표계로
/// 변환하면 안 된다 — 변환하면 이미 화면 좌표로 바뀐 값을 상호작용이 다시 콘텐츠 좌표로
/// 오인해 실제 화면 밖 위치로 튀고, UIKit이 가장 가까운 화면 모서리로 메뉴를 클램프한다.
@MainActor
final class EditMenuPresenter: NSObject {
  /// 상호작용이 설치된 문서 뷰 (콘텐츠 공간 — 상호작용 좌표계와 동일).
  private weak var documentView: UIView?

  /// `hostHasSelection` 재질의용 선택 이벤트 수신부.
  private weak var sink: (any ReaderSelectionEventSink)?

  /// 설치된 상호작용.
  private var interaction: UIEditMenuInteraction?

  /// 마지막으로 표시(요청)한 항목 (스크롤 정지 후 재표시용 캐시).
  private var cachedItems: [ResolvedMenuItem] = []

  /// 마지막으로 표시(요청)한 앵커 사각형 (콘텐츠 공간 — 상호작용에 변환 없이 그대로 전달).
  private var cachedContentRect: CGRect = .zero

  /// 현재 표시 중 여부 (스크롤 시작 시 닫을지 판단).
  private var isPresenting = false

  /// documentView에 상호작용을 설치한다.
  /// - Parameter documentView: 콘텐츠 공간 기준 문서 뷰 (상호작용이 설치될 뷰).
  func attach(documentView: UIView) {
    self.documentView = documentView
    let interaction = UIEditMenuInteraction(delegate: self)
    documentView.addInteraction(interaction)
    self.interaction = interaction
  }

  /// 선택 이벤트 수신부를 갱신한다 (`eventSink` didSet에서 호출).
  /// - Parameter sink: 새 수신부.
  func updateSink(_ sink: (any ReaderSelectionEventSink)?) {
    self.sink = sink
  }

  /// 콘텐츠 공간 `contentRect` 주변에 메뉴를 표시한다.
  /// - Parameters:
  ///   - items: 표시할 메뉴 항목.
  ///   - contentRect: 앵커 사각형 (콘텐츠 공간 — `documentView` 자신의 좌표계와 동일해
  ///     변환 없이 그대로 상호작용에 전달한다).
  func present(_ items: [ResolvedMenuItem], around contentRect: CGRect) {
    guard self.documentView != nil, !items.isEmpty else {
      return
    }
    self.cachedItems = items
    self.cachedContentRect = contentRect
    let sourcePoint = EditMenuGeometry.topCenterSourcePoint(of: contentRect)
    let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: sourcePoint)
    self.interaction?.presentEditMenu(with: configuration)
    self.isPresenting = true
  }

  /// 표시 중 메뉴를 닫는다 (캐시도 비운다).
  func dismiss() {
    self.interaction?.dismissMenu()
    self.cachedItems = []
    self.isPresenting = false
  }

  /// 스크롤이 시작됐다 — 표시 중이면 닫는다 (캐시는 유지 — 정지 시 재표시).
  func handleScrollWillBegin() {
    guard self.isPresenting else {
      return
    }
    self.interaction?.dismissMenu()
    self.isPresenting = false
  }

  /// 스크롤이 정지했다 — 선택이 남아있으면 캐시로 재표시한다 (PDFKit과 동일 관례).
  func handleScrollDidSettle() {
    guard !self.cachedItems.isEmpty, self.sink?.hostHasSelection() == true else {
      return
    }
    self.present(self.cachedItems, around: self.cachedContentRect)
  }
}

extension EditMenuPresenter: @MainActor UIEditMenuInteractionDelegate {
  /// 캐시된 항목을 `UIMenu`로 변환해 반환한다.
  /// - Parameters:
  ///   - interaction: 상호작용.
  ///   - configuration: 메뉴 구성.
  ///   - suggestedActions: 시스템 제안 액션 (미사용).
  /// - Returns: 조립된 메뉴, 캐시가 비어 있으면 `nil`.
  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
    suggestedActions: [UIMenuElement]
  ) -> UIMenu? {
    guard !self.cachedItems.isEmpty else {
      return nil
    }
    let actions = self.cachedItems.map { item in
      let image = item.systemImage.flatMap { UIImage(systemName: $0) }
      return UIAction(title: item.title, image: image) { _ in
        item.action()
      }
    }
    return UIMenu(children: actions)
  }

  /// 캐시된 앵커 사각형을 반환한다 (상호작용이 설치된 `documentView` 자신의 좌표계라
  /// 변환이 필요 없다 — 타입 문서 참조).
  /// - Parameters:
  ///   - interaction: 상호작용.
  ///   - configuration: 메뉴 구성.
  /// - Returns: 앵커 사각형 (콘텐츠 공간 = `documentView` 좌표계).
  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration
  ) -> CGRect {
    self.cachedContentRect
  }
}
#endif
