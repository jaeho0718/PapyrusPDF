import CoreGraphics

/// 페이지 표시 공간의 한 점 (콘텐츠 점을 코어가 분해한 결과).
package struct PagePoint: Sendable, Equatable {
  /// 페이지 인덱스 (0 기반).
  package let pageIndex: Int
  /// 그 페이지 표시 공간(좌상단 원점, pt)의 점 — 페이지 밖(여백)일 수 있다.
  package let point: CGPoint

  /// 페이지 점을 만든다.
  /// - Parameters:
  ///   - pageIndex: 페이지 인덱스 (0 기반).
  ///   - point: 그 페이지 표시 공간의 점.
  package init(pageIndex: Int, point: CGPoint) {
    self.pageIndex = pageIndex
    self.point = point
  }
}

/// 드래그 시작 정밀도 (macOS 클릭 수 / iOS 롱프레스 → word).
package enum SelectionGranularity: Sendable, Equatable {
  /// macOS 단일클릭 드래그, iOS 핸들 드래그 — 문자 단위.
  case character
  /// macOS 더블클릭, iOS 롱프레스 — 단어 단위.
  case word
  /// macOS 트리플클릭 — 라인 단위.
  case line
}

/// 선택 핸들 식별 (iOS).
package enum SelectionHandle: Sendable, Equatable {
  /// 선택 앞끝 (노브 위).
  case start
  /// 선택 뒤끝 (노브 아래).
  case end
}

/// 해소 완료된 메뉴 항목 (``SelectionMenuResolver``가 공개 빌더 산출물을 변환한 결과).
package struct ResolvedMenuItem {
  /// 표시 타이틀.
  package let title: String
  /// SF Symbols 이름 (없으면 `nil`).
  package let systemImage: String?
  /// 실행 클로저 (메인 액터).
  package let action: @MainActor () -> Void

  /// 메뉴 항목을 만든다.
  /// - Parameters:
  ///   - title: 표시 타이틀.
  ///   - systemImage: SF Symbols 이름.
  ///   - action: 실행 클로저.
  package init(title: String, systemImage: String?, action: @escaping @MainActor () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.action = action
  }
}

/// 호스트 → 코어 선택 이벤트·질의 (`ReaderCore`가 구현).
///
/// 좌표는 전부 콘텐츠 공간 (`visibleContentRect`와 동일 축) — 코어가 페이지
/// 표시 공간으로 분해한다.
@MainActor
package protocol ReaderSelectionEventSink: AnyObject {
  /// 드래그(롱프레스·마우스 다운)가 시작됐다.
  /// - Parameters:
  ///   - point: 콘텐츠 공간의 시작 점.
  ///   - granularity: 시작 정밀도.
  func hostSelectionDragBegan(atContentPoint point: CGPoint, granularity: SelectionGranularity)

  /// 드래그가 진행 중이다.
  /// - Parameter point: 콘텐츠 공간의 현재 점.
  func hostSelectionDragChanged(toContentPoint point: CGPoint)

  /// 드래그가 정상 종료됐다.
  func hostSelectionDragEnded()

  /// 드래그가 취소됐다 (예: iOS 터치 취소).
  func hostSelectionDragCancelled()

  /// 점이 핸들 터치 타깃 안이면 해당 핸들을 반환한다 (팬 제스처 게이팅용 질의).
  /// - Parameter point: 콘텐츠 공간의 점.
  /// - Returns: 히트된 핸들, 없으면 `nil`.
  func hostSelectionHandleTest(atContentPoint point: CGPoint) -> SelectionHandle?

  /// 핸들 드래그가 시작됐다.
  /// - Parameters:
  ///   - handle: 시작된 핸들.
  ///   - point: 콘텐츠 공간의 시작 점.
  func hostSelectionHandleDragBegan(_ handle: SelectionHandle, atContentPoint point: CGPoint)

  /// 탭/클릭 — 현재는 선택 해제만 수행한다 (영역 히트는 향후 지원 예정).
  /// - Parameter point: 콘텐츠 공간의 탭 점.
  func hostTap(atContentPoint point: CGPoint)

  /// ⌘C·메뉴 복사.
  func hostCopyCommand()

  /// 선택 존재 여부 (⌘C validate·메뉴 재표시 판단).
  /// - Returns: 선택이 있으면 `true`.
  func hostHasSelection() -> Bool

  /// 우클릭 지점의 컨텍스트 메뉴 항목 (선택 밖·선택 없음이면 빈 배열 — macOS pull 표면).
  /// - Parameter point: 콘텐츠 공간의 우클릭 점.
  /// - Returns: 해소된 메뉴 항목 목록.
  func hostContextMenuItems(atContentPoint point: CGPoint) -> [ResolvedMenuItem]
}

/// 코어 → 호스트 메뉴 표시 (호스트 뷰가 구현 — iOS push 표면).
///
/// 계약 3항:
/// 1. `contentRect`는 콘텐츠 공간(줌 미적용, `visibleContentRect`와 동축)이다 — 뷰 좌표
///    변환은 호스트 책임이다 (iOS는 documentView 좌표 = 콘텐츠 공간이라 무변환).
/// 2. push 표면(`presentSelectionMenu`)은 `SelectionStyle.presentsMenuOnSelectionEnd ==
///    true` 플랫폼에서만 호출된다 (macOS에서는 호출되지 않으므로 no-op 구현이 적법하다).
/// 3. `dismissSelectionMenu`는 멱등이다 — 이미 닫힌 상태에서 호출해도 안전하다.
@MainActor
package protocol ReaderMenuPresenting: AnyObject {
  /// 콘텐츠 공간 `contentRect` 주변에 메뉴를 표시한다 (뷰 좌표 변환은 호스트 책임).
  /// - Parameters:
  ///   - items: 표시할 메뉴 항목 목록.
  ///   - contentRect: 앵커 사각형 (콘텐츠 공간).
  func presentSelectionMenu(_ items: [ResolvedMenuItem], around contentRect: CGRect)

  /// 표시 중 메뉴를 닫는다 (미표시면 no-op — 멱등).
  func dismissSelectionMenu()
}
