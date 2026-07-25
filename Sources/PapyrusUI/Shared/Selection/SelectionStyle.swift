import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 선택 시각·거동 상수 (v0.3 공개 커스터마이징 확장 심 — `HighlightStyle` 전례).
package enum SelectionStyle {
  /// 선택 채움 색 (시스템 블루 계열, 반투명). 레이어 기반이라 다이내믹 컬러를
  /// 추적하지 않는다 — 고정 sRGB (0.3.0에서 재검토).
  package static let fillColor = CGColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 0.25)
  /// 핸들(캐럿 선 + 노브) 색 (불투명).
  package static let handleColor = CGColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1)
  /// 핸들 캐럿 선 두께 (pt, 줌 1 기준 — 줌 종료 시 1/zoom 재계산).
  package static let handleLineWidth: CGFloat = 2
  /// 핸들 노브 반지름 (pt, 줌 1 기준).
  package static let handleKnobRadius: CGFloat = 5
  /// 핸들 터치 타깃 반경 (화면 pt — 콘텐츠 좌표 판정 시 1/zoom 적용).
  package static let handleTouchTargetRadius: CGFloat = 22
  /// 오토스크롤 트리거 가장자리 폭 (화면 pt).
  package static let autoscrollEdgeInset: CGFloat = 44
  /// 오토스크롤 최대 속도 (화면 pt/초 — 가장자리 침투 깊이에 비례해 가속).
  package static let autoscrollMaxSpeed: CGFloat = 900
  /// 오토스크롤 틱 간격 (초).
  package static let autoscrollInterval: TimeInterval = 1.0 / 60.0

  /// 선택 확정 시 메뉴 자동 표시 여부 (iOS `true` / macOS `false` — 각 플랫폼 관례).
  #if canImport(UIKit)
  package static let presentsMenuOnSelectionEnd = true
  #else
  package static let presentsMenuOnSelectionEnd = false
  #endif
}

/// UI 계층 한도 상수 (`CoreLimits`의 UI판 — 한 곳 원칙).
package enum UILimits {
  /// 선택 문자열(복사·selectedString) 총량 캡 (UTF-16 코드유닛). 초과분은
  /// Character 경계로 안쪽 스냅해 절단한다 — 병적 문서에서 메모리 폭주 방지.
  package static let maxSelectedTextUTF16 = 4 << 20
  /// 페이지당 선택 가능 영역 등록 상한 (초과분은 앞에서부터 유지, 절단) — 탭 히트테스트
  /// O(영역 수)의 결정적 유계.
  package static let maxSelectableRegionsPerPage = 1_024
}

/// 플랫폼 페이스트보드 어댑터 (복사 한 곳).
package enum PlatformPasteboard {
  /// 일반 텍스트를 페이스트보드에 쓴다 (`UIPasteboard.general` / `NSPasteboard.general`).
  /// - Parameter string: 페이스트보드에 쓸 텍스트.
  package static func setString(_ string: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = string
    #elseif canImport(AppKit)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
    #endif
  }
}
