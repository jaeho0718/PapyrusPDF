import CoreGraphics
import PapyrusCore

// 이 파일은 `ReaderSelectionController`의 영역 등록부·히트테스트·활성 선택 투영·재등록
// 규칙과 `tap(at:)` 이벤트 진입점을 담는다 (본체 `ReaderSelectionController.swift`의
// 길이 한도로 이설 — tap이 영역 히트 판정을 최우선으로 다루므로 이 파일이 자연스러운
// 소속이다). 나머지 이벤트 진입(드래그·핸들·clear·select)·통지는
// `ReaderSelectionController.swift`, quad/핸들/문자열 조회는 `+Query.swift` 참조.
// 설계 §1.4.

/// 활성 선택의 종류 (코어의 메뉴 해소 분기용 — 상태 기계의 package 투영).
package enum ActiveReaderSelection: Sendable {
  /// 텍스트 선택.
  case text(TextSelection)
  /// 개발자 정의 선택 가능 영역.
  case region(SelectableRegion)
}

/// 영역 동일성 키 (`SelectableRegion`이 Equatable이 아니므로 id+페이지로 비교한다).
package struct RegionKey: Hashable, Sendable {
  /// 페이지 인덱스.
  package let pageIndex: Int
  /// 영역 식별자.
  package let id: String

  /// 키를 만든다.
  /// - Parameters:
  ///   - pageIndex: 페이지 인덱스.
  ///   - id: 영역 식별자.
  package init(pageIndex: Int, id: String) {
    self.pageIndex = pageIndex
    self.id = id
  }
}

extension ReaderSelectionController {
  /// 현재 활성 선택 (텍스트 dragging/selected → `.text`, regionSelected → `.region`).
  package var activeSelection: ActiveReaderSelection? {
    switch self.state {
    case .idle:
      return nil
    case .dragging:
      return self.selection.map { .text($0) }
    case let .selected(selected):
      return .text(selected.selection)
    case let .regionSelected(region):
      return .region(region)
    }
  }

  /// 탭/클릭 (§3 전이표 T4′/T4″/T13/T20′/T20″/T27a/b/c — 영역 히트를 먼저 판정한다.
  /// `clear()`와 달리 드래그 중에는 히트 판정 자체를 생략하고 무시한다).
  /// - Parameter point: 탭 페이지 점.
  package func tap(at point: PagePoint) {
    switch self.state {
    case .idle: // T4′/T4″
      guard let region = self.hitRegion(at: point) else {
        return
      }
      self.enterRegionSelected(region, invalidating: [region.pageIndex])
      self.onMenuRequest?(region.pageIndex)
    case .dragging: // T13 — 히트 판정 자체를 생략한다.
      return
    case let .selected(selected): // T20′/T20″
      // 두 경로 모두 먼저 idle로 전이한다 — 아래 diffInvalidate가 옛 텍스트 페이지를
      // 동기 무효화하는 순간 `displayQuads`가 이미 해제된 상태를 관측해야 한다(그렇지
      // 않으면 옛 텍스트 quad로 재적용되는 경합이 생긴다).
      self.state = .idle
      guard let region = self.hitRegion(at: point) else {
        self.notifyIfChanged(nil)
        _ = self.diffInvalidate(newRange: nil, previous: selected.selection.pageRange)
        self.onMenuDismiss?()
        return
      }
      self.notifyIfChanged(nil)
      _ = self.diffInvalidate(newRange: nil, previous: selected.selection.pageRange)
      self.onMenuDismiss?()
      self.enterRegionSelected(region, invalidating: [region.pageIndex])
      self.onMenuRequest?(region.pageIndex)
    case let .regionSelected(current):
      guard let region = self.hitRegion(at: point) else { // T27c
        self.state = .idle
        self.notifyRegion(nil)
        self.onOverlayInvalidate?(current.pageIndex)
        self.onMenuDismiss?()
        return
      }
      guard current.pageIndex != region.pageIndex || current.id != region.id else { // T27a
        self.onMenuRequest?(region.pageIndex)
        return
      }
      // T27b
      self.enterRegionSelected(region, invalidating: [current.pageIndex, region.pageIndex])
      self.onMenuDismiss?()
      self.onMenuRequest?(region.pageIndex)
    }
  }

  /// 페이지의 영역 등록을 대체한다 (사전 위생 완료 입력 — 신뢰 경계 안).
  ///
  /// 활성 영역 선택이 이 페이지에 있으면 새 목록에 같은 id가 있을 때 선택을 유지하며
  /// 값을 갱신하고(quad·metadata 교체), 없으면 해제한다 (§0.2-7 — T35). 다른 페이지·
  /// 텍스트 선택·idle이면 등록부만 갱신한다 (T36/T37).
  /// - Parameters:
  ///   - regions: 위생 처리된 등록 목록 (순서 = 겹침 우선순위).
  ///   - pageIndex: 등록 대상 페이지.
  package func setRegions(_ regions: [SelectableRegion], forPage pageIndex: Int) {
    if regions.isEmpty {
      self.regionsByPage.removeValue(forKey: pageIndex)
    } else {
      self.regionsByPage[pageIndex] = regions
    }
    guard case let .regionSelected(current) = self.state, current.pageIndex == pageIndex else {
      return // T36/T37 — 활성 선택이 이 페이지의 영역이 아니면 등록부만 갱신한다.
    }
    if let replacement = regions.first(where: { $0.id == current.id }) { // T35 — 유지·갱신.
      self.state = .regionSelected(replacement)
      self.notifyRegion(replacement)
      self.onOverlayInvalidate?(pageIndex)
    } else { // T35 — id 부재, 해제.
      self.state = .idle
      self.notifyRegion(nil)
      self.onOverlayInvalidate?(pageIndex)
      self.onMenuDismiss?()
    }
  }

  /// 전체 영역 등록 해제 (활성 영역 선택도 해제한다, T38).
  package func clearAllRegions() {
    self.regionsByPage.removeAll()
    guard case let .regionSelected(current) = self.state else {
      return // T37 — 텍스트 선택·idle은 무간섭.
    }
    self.state = .idle
    self.notifyRegion(nil)
    self.onOverlayInvalidate?(current.pageIndex)
    self.onMenuDismiss?()
  }

  /// 페이지의 등록 영역 (없으면 빈 배열) — 모델 조회 위임용.
  /// - Parameter pageIndex: 조회할 페이지 인덱스.
  /// - Returns: 등록 순서의 영역 목록.
  package func regions(forPage pageIndex: Int) -> [SelectableRegion] {
    self.regionsByPage[pageIndex] ?? []
  }

  /// 활성 영역 선택이 이 키와 일치하는가 (코어의 스테일 메뉴 검사용).
  /// - Parameter key: 비교할 영역 키.
  /// - Returns: 일치하면 `true`.
  package func isRegionSelected(_ key: RegionKey) -> Bool {
    guard case let .regionSelected(region) = self.state else {
      return false
    }
    return region.pageIndex == key.pageIndex && region.id == key.id
  }

  /// 우클릭 지점의 영역을 선택한다 (`tap(at:)`과 동일 전이, `onMenuRequest`는 발화하지
  /// 않는다 — 호출측(`menu(for:)`)이 반환 메뉴를 곧장 표시하므로 push 경로가 겹치면
  /// 메뉴가 2회 뜬다). 미스면 상태를 바꾸지 않는다.
  /// - Parameter point: 우클릭 페이지 점.
  /// - Returns: 선택된 영역, 미스면 `nil`.
  package func selectRegionForContextMenu(at point: PagePoint) -> SelectableRegion? {
    guard let region = self.hitRegion(at: point) else {
      return nil
    }
    switch self.state {
    case .idle:
      self.enterRegionSelected(region, invalidating: [region.pageIndex])
    case .dragging:
      return nil
    case let .selected(selected):
      // tap(at:)의 T20′과 동일한 이유로 diffInvalidate 전에 먼저 idle로 전이한다.
      self.state = .idle
      self.notifyIfChanged(nil)
      _ = self.diffInvalidate(newRange: nil, previous: selected.selection.pageRange)
      self.onMenuDismiss?()
      self.enterRegionSelected(region, invalidating: [region.pageIndex])
    case let .regionSelected(current):
      guard current.pageIndex != region.pageIndex || current.id != region.id else {
        return region // 이미 같은 영역이 선택돼 있다 — 상태 무변경.
      }
      self.onMenuDismiss?()
      self.enterRegionSelected(region, invalidating: [current.pageIndex, region.pageIndex])
    }
    return region
  }

  /// 표시 공간 점의 히트 영역을 찾는다 (변환 미보유는 히트 없음 + 페이지 요청 — §0.2-6).
  ///
  /// 파일 분할 접근을 위해 internal.
  /// - Parameter point: 히트테스트할 페이지 점.
  /// - Returns: 히트된 영역, 없으면 `nil`.
  func hitRegion(at point: PagePoint) -> SelectableRegion? {
    guard let regions = self.regionsByPage[point.pageIndex], !regions.isEmpty else {
      return nil
    }
    guard let transform = self.store.displayTransform(forPage: point.pageIndex) else {
      self.store.requestPage(point.pageIndex)
      return nil
    }
    return RegionHitTester.hitRegion(
      at: point.point, regions: regions, displayTransform: transform
    )
  }

  /// 영역 선택 변경을 통지한다 (§0.2-10 — 변경 감지 없음, 전이마다 무조건 발화).
  ///
  /// 파일 분할 접근을 위해 internal.
  /// - Parameter region: 통지할 영역 (해제면 `nil`).
  func notifyRegion(_ region: SelectableRegion?) {
    self.onRegionSelectionChange?(region)
  }

  /// `regionSelected(region)`으로 전이하고 통지·무효화를 적용한다. `onMenuRequest`는
  /// 호출측이 발화한다 — 우클릭 경로(`selectRegionForContextMenu(at:)`)는 발화하지
  /// 않아야 하므로 이 헬퍼에 포함하지 않는다.
  ///
  /// 파일 분할 접근을 위해 internal.
  /// - Parameters:
  ///   - region: 전이할 영역.
  ///   - invalidating: 무효화할 페이지 목록 (중복은 한 번만 통지된다).
  func enterRegionSelected(_ region: SelectableRegion, invalidating pages: [Int]) {
    self.state = .regionSelected(region)
    self.notifyRegion(region)
    for page in Set(pages).sorted() {
      self.onOverlayInvalidate?(page)
    }
  }
}
