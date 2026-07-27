import PapyrusPDFCore
@testable import PapyrusPDFUI

/// ``ReaderSelectionController`` 콜백을 기록하는 테스트 헬퍼 (``ReaderSelectionControllerTests``·
/// ``ReaderSelectionGranularityTests``·``ReaderSelectionControllerRegionTests`` 공유).
@MainActor
final class SelectionCallbackRecorder {
  /// `onSelectionChange` 통지 이력.
  var selectionChanges: [TextSelection?] = []
  /// `onOverlayInvalidate` 통지된 페이지 이력 (호출 순서대로, 중복 가능).
  var invalidatedPages: [Int] = []
  /// `onMenuRequest` 통지된 앵커 페이지 이력.
  var menuRequests: [Int] = []
  /// `onMenuDismiss` 호출 횟수.
  var menuDismissCount = 0
  /// `onRegionSelectionChange` 통지 이력 (`SelectableRegion`이 Equatable이 아니므로
  /// `RegionKey`로 기록한다 — `nil`은 해제 통지).
  var regionChanges: [RegionKey?] = []

  /// 컨트롤러의 콜백을 이 레코더에 배선한다.
  /// - Parameter controller: 배선할 컨트롤러.
  func attach(to controller: ReaderSelectionController) {
    controller.onSelectionChange = { [weak self] selection in
      self?.selectionChanges.append(selection)
    }
    controller.onOverlayInvalidate = { [weak self] page in self?.invalidatedPages.append(page) }
    controller.onMenuRequest = { [weak self] page in self?.menuRequests.append(page) }
    controller.onMenuDismiss = { [weak self] in self?.menuDismissCount += 1 }
    controller.onRegionSelectionChange = { [weak self] region in
      self?.regionChanges.append(region.map { RegionKey(pageIndex: $0.pageIndex, id: $0.id) })
    }
  }
}
