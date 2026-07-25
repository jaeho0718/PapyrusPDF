#if canImport(AppKit)
import AppKit
import CoreGraphics

// 이 파일은 `FlippedDocumentView`(`ReaderScrollView_macOS.swift`에 선언)의 마우스·⌘C·
// 컨텍스트 메뉴 오버라이드를 담는다 — 저장 프로퍼티(`selectionSink`·드래그 상태·타이머)는
// extension에 둘 수 없어 원 파일에 있다. 설계 §1.9 — 기존 파일 수정 최소화 목적의 분리.

extension FlippedDocumentView {
  /// 단일클릭이 드래그(선택 시작)로 승격되는 이동 임계값 (pt).
  private static let dragPromotionThreshold: CGFloat = 2

  /// ⌘C 등 표준 편집 커맨드를 받으려면 첫 responder 자격이 필요하다.
  override var acceptsFirstResponder: Bool {
    true
  }

  /// 마우스 다운 — `clickCount` 1/2/3 → `.character`/`.word`/`.line`.
  ///
  /// 단일클릭(`clickCount == 1`)은 드래그 시작을 `mouseDragged`로 지연한다(이동 임계
  /// 판정 — 단순 클릭과 드래그를 구분해 `mouseUp`에서 탭/드래그종료를 가른다). 더블·
  /// 트리플클릭은 이동 없이도 즉시 단어·라인 선택을 시작한다(네이티브 관례). ⇧ 확장·
  /// ⌥ 열 선택 모디파이어는 지원하지 않아 무시하고 일반 드래그로 처리한다.
  /// - Parameter event: 마우스 다운 이벤트.
  override func mouseDown(with event: NSEvent) {
    self.window?.makeFirstResponder(self)
    let point = self.convert(event.locationInWindow, from: nil)
    self.mouseDownPoint = point
    self.isSelectionDragging = false

    guard event.clickCount >= 2 else {
      return
    }
    let granularity: SelectionGranularity = event.clickCount >= 3 ? .line : .word
    self.selectionSink?.hostSelectionDragBegan(atContentPoint: point, granularity: granularity)
    self.isSelectionDragging = true
    self.startAutoscrollTimer()
  }

  /// 마우스 드래그 — AppKit 내장 `autoscroll(with:)`로 뷰포트를 밀고, 단일클릭 드래그는
  /// 임계 초과 시점에 지연 시작한다.
  /// - Parameter event: 마우스 드래그 이벤트.
  override func mouseDragged(with event: NSEvent) {
    self.autoscroll(with: event)
    self.lastDragEvent = event
    let point = self.convert(event.locationInWindow, from: nil)

    if !self.isSelectionDragging {
      guard let downPoint = self.mouseDownPoint,
        Self.distance(downPoint, point) >= Self.dragPromotionThreshold
      else {
        return
      }
      self.selectionSink?.hostSelectionDragBegan(
        atContentPoint: downPoint, granularity: .character
      )
      self.isSelectionDragging = true
      self.startAutoscrollTimer()
    }
    self.selectionSink?.hostSelectionDragChanged(toContentPoint: point)
  }

  /// 마우스 업 — 드래그로 승격된 적이 없으면(단순 클릭) 탭으로, 아니면 드래그 종료로 처리한다.
  /// - Parameter event: 마우스 업 이벤트.
  override func mouseUp(with event: NSEvent) {
    self.stopAutoscrollTimer()
    defer {
      self.mouseDownPoint = nil
      self.isSelectionDragging = false
    }
    if self.isSelectionDragging {
      self.selectionSink?.hostSelectionDragEnded()
    } else {
      let point = self.convert(event.locationInWindow, from: nil)
      self.selectionSink?.hostTap(atContentPoint: point)
    }
  }

  /// ⌘C·Edit 메뉴 Copy — 표준 액션 이름 규약(`copy:`)에 의해 응답자 체인이 호출한다.
  /// - Parameter sender: 액션 발신자 (미사용).
  @objc
  func copy(_ sender: Any?) {
    self.selectionSink?.hostCopyCommand()
  }

  /// 우클릭 컨텍스트 메뉴 — 선택 항목이 있으면 조립해 표시하고, 없으면 기본 메뉴 없음(`nil`).
  /// - Parameter event: 우클릭 이벤트.
  /// - Returns: 조립된 메뉴, 항목이 없으면 `nil`.
  override func menu(for event: NSEvent) -> NSMenu? {
    let point = self.convert(event.locationInWindow, from: nil)
    guard let items = self.selectionSink?.hostContextMenuItems(atContentPoint: point),
      !items.isEmpty
    else {
      return nil
    }
    let built = MacMenuBuilder.makeMenu(for: items)
    self.menuActionBridges = built.bridges
    return built.menu
  }

  /// 뷰 밖 정지 마우스도 오토스크롤이 이어지도록 60Hz 타이머를 가동한다 (드래그 수명에 결속).
  fileprivate func startAutoscrollTimer() {
    self.autoscrollTimer?.invalidate()
    self.autoscrollTimer = Timer.scheduledTimer(
      withTimeInterval: SelectionStyle.autoscrollInterval, repeats: true
    ) { [weak self] _ in
      Task { @MainActor in
        self?.autoscrollTick()
      }
    }
  }

  /// 오토스크롤 타이머를 해제한다 (드래그 종료·취소 시).
  fileprivate func stopAutoscrollTimer() {
    self.autoscrollTimer?.invalidate()
    self.autoscrollTimer = nil
    self.lastDragEvent = nil
  }

  /// 오토스크롤 틱: 마지막 드래그 이벤트로 스크롤을 이어가고 선택도 재전송한다.
  private func autoscrollTick() {
    guard let event = self.lastDragEvent else {
      return
    }
    self.autoscroll(with: event)
    let point = self.convert(event.locationInWindow, from: nil)
    self.selectionSink?.hostSelectionDragChanged(toContentPoint: point)
  }

  /// 두 점의 유클리드 거리.
  /// - Parameters:
  ///   - lhs: 첫 번째 점.
  ///   - rhs: 두 번째 점.
  /// - Returns: 두 점 사이 거리.
  private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    let dx = lhs.x - rhs.x
    let dy = lhs.y - rhs.y
    return (dx * dx + dy * dy).squareRoot()
  }
}

/// `copy:` 등 표준 편집 액션의 활성 여부를 응답자 체인에 알린다.
extension FlippedDocumentView: NSUserInterfaceValidations {
  /// `copy(_:)`는 선택이 있을 때만 활성화한다.
  /// - Parameter item: 검증할 액션 항목.
  /// - Returns: 활성화 여부.
  func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    guard item.action == #selector(FlippedDocumentView.copy(_:)) else {
      return true
    }
    return self.selectionSink?.hostHasSelection() ?? false
  }
}
#endif
