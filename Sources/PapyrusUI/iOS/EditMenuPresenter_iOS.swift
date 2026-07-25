#if canImport(UIKit)
import CoreGraphics
import UIKit

/// `UIEditMenuInteraction` 브리지 — `ReaderScrollHostView`가 `ReaderMenuPresenting`을
/// 이 타입에 위임한다.
@MainActor
final class EditMenuPresenter: NSObject {
  /// 메뉴 소스 사각형을 옮길 좌표계 기준 뷰 (호스트 뷰).
  private weak var hostView: UIView?

  /// `contentRect` 변환 기준 문서 뷰 (콘텐츠 공간).
  private weak var documentView: UIView?

  /// `hostHasSelection` 재질의용 선택 이벤트 수신부.
  private weak var sink: (any ReaderSelectionEventSink)?

  /// 설치된 상호작용.
  private var interaction: UIEditMenuInteraction?

  /// 마지막으로 표시(요청)한 항목 (스크롤 정지 후 재표시용 캐시).
  private var cachedItems: [ResolvedMenuItem] = []

  /// 마지막으로 표시(요청)한 앵커 사각형 (콘텐츠 공간).
  private var cachedContentRect: CGRect = .zero

  /// 현재 표시 중 여부 (스크롤 시작 시 닫을지 판단).
  private var isPresenting = false

  /// documentView에 상호작용을 설치한다.
  /// - Parameters:
  ///   - hostView: 좌표 변환 기준 호스트 뷰.
  ///   - documentView: 콘텐츠 공간 기준 문서 뷰.
  func attach(hostView: UIView, documentView: UIView) {
    self.hostView = hostView
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
  ///   - contentRect: 앵커 사각형 (콘텐츠 공간).
  func present(_ items: [ResolvedMenuItem], around contentRect: CGRect) {
    guard let documentView, let hostView, !items.isEmpty else {
      return
    }
    self.cachedItems = items
    self.cachedContentRect = contentRect
    let viewRect = documentView.convert(contentRect, to: hostView)
    let sourcePoint = CGPoint(x: viewRect.midX, y: viewRect.minY)
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

  /// 앵커 사각형을 호스트 뷰 좌표로 변환해 반환한다.
  /// - Parameters:
  ///   - interaction: 상호작용.
  ///   - configuration: 메뉴 구성.
  /// - Returns: 호스트 뷰 좌표의 앵커 사각형.
  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration
  ) -> CGRect {
    guard let documentView, let hostView else {
      return .zero
    }
    return documentView.convert(self.cachedContentRect, to: hostView)
  }
}
#endif
