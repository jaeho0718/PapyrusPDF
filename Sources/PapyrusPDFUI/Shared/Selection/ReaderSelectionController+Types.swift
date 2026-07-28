import CoreGraphics
import PapyrusPDFCore

// 이 파일은 `ReaderSelectionController`의 상태 기계가 쓰는 내부 값 타입을 담는다 —
// 상태·이벤트 진입·통지는 `ReaderSelectionController.swift`, 해석·재계산·조회는
// `+Resolution.swift` 참조. 설계 §5 한도 초과 시 파일 분할 허용에 따른 분리.

/// 드래그 시작 정밀도별 페이지 안 위치 해석 결과 (끝점 하나).
///
/// 파일 분할 접근을 위해 internal이다 — 모듈 밖으로는 노출되지 않는다.
struct ResolvedEnd: Equatable {
  /// 해석된 문서 위치.
  var position: TextPosition
  /// word/line 단위 구간 (그 페이지 문자열 좌표, 캐릭터 단위면 `nil`).
  var unitRange: Range<Int>?
  /// 지오메트리 미보유로 잠정 클램프가 적용됐는지 여부.
  var provisional: Bool
}

/// 잠정 클램프 방향 (앵커 페이지 기준 전진/후진).
///
/// 파일 분할 접근을 위해 internal.
enum ClampDirection {
  /// 앵커 페이지 이상(같은 페이지 포함) — `(k, 0)`로 클램프.
  case forward
  /// 앵커 페이지 미만 — `(k+1, 0)`로 클램프 (페이지 k의 끝과 동일 지점).
  case backward
}

/// 드래그 세션 (단일 활성 — 상태 기계가 1개만 허용).
///
/// 파일 분할 접근을 위해 internal.
struct DragSession {
  /// 드래그 세션 식별 토큰.
  var token: Int
  /// 세션 종류.
  var kind: Kind
  /// 시작 정밀도.
  var granularity: SelectionGranularity
  /// 앵커의 원입력 점 (진실 원천 — 도착 시 재해석).
  var anchorPoint: PagePoint
  /// 포커스의 최신 원입력 점.
  var focusPoint: PagePoint
  /// 앵커 해석 결과.
  var anchorResolved: ResolvedEnd
  /// 포커스 해석 결과.
  var focusResolved: ResolvedEnd
  /// `.handle` 취소 복원용 (드래그 시작 직전 선택).
  var preDragSelection: TextSelection?
  /// 차분 무효화용 — 직전에 무효화 통지한 페이지 범위.
  var lastInvalidatedPages: ClosedRange<Int>?

  /// 세션 종류.
  enum Kind {
    /// 새 드래그(롱프레스·마우스 다운).
    case new
    /// 기존 선택 핸들 드래그.
    case handle(SelectionHandle)
  }
}

/// 드래그 종료 후 지연 정련 (T9 → T23).
///
/// 앵커·포커스 어느 쪽이 잠정으로 남아도 확정 쪽을 모호함 없이 재구성할 수 있도록 대칭
/// 필드(`confirmedAnchor`/`confirmedFocus`)로 구현한다 — 앵커 쪽 단위 구간만 저장하는
/// 방식으로는 "포커스가 확정, 앵커가 잠정"인 역방향 드래그 케이스에서 확정 쪽의 페이지·
/// 단위 구간을 복원할 수 없다(실제 드래그에서는 거의 발생하지 않는 극단 케이스지만,
/// 정확한 구현을 위해 대칭화했다 — 관찰 가능한 상태 전이 동작은 동일하다).
///
/// 파일 분할 접근을 위해 internal.
struct PendingRefinement {
  /// 이 정련을 만든 드래그 세션 토큰 — 불일치 도착은 폐기.
  var token: Int
  /// 시작 정밀도.
  var granularity: SelectionGranularity
  /// 잠정으로 남은 앵커의 원입력 점 (앵커가 확정이면 `nil`).
  var anchorPoint: PagePoint?
  /// 잠정으로 남은 포커스의 원입력 점 (포커스가 확정이면 `nil`).
  var focusPoint: PagePoint?
  /// 확정된 앵커의 해석 결과 (앵커가 잠정이면 `nil`).
  var confirmedAnchor: ResolvedEnd?
  /// 확정된 포커스의 해석 결과 (포커스가 잠정이면 `nil`).
  var confirmedFocus: ResolvedEnd?
}

/// 확정 선택 상태.
///
/// 파일 분할 접근을 위해 internal.
struct SelectedState {
  /// 확정 선택.
  var selection: TextSelection
  /// 잠정 끝의 지연 정련 (드래그 종료 시 잠정이 남았을 때만 non-nil).
  var pendingRefinement: PendingRefinement?
}
