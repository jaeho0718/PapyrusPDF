import CoreGraphics
import Foundation

/// 렌더링 파이프라인의 정책 상수. `CoreLimits`와 같은 "한 곳 원칙".
package enum RenderingLimits {
  /// 타일 한 변의 화면 크기 (pt). 페이지 공간 커버리지는 `tileSideLength / scale`.
  package static let tileSideLength: CGFloat = 512

  /// 프리뷰 이미지 최장변 픽셀 수 (pixelScale 무관 고정 — 저해상도 밑그림 용도).
  package static let previewMaxPixelDimension = 512

  /// `PageImageRenderer` 전체 페이지 이미지의 최장변 픽셀 상한 (병적 cropBox·과대 배율
  /// 가드 — A4 scale 3이 2,526px로 여유롭게 통과하고, 4K 초과는 OCR 이득이 없는 구간).
  package static let fullPageImageMaxPixelDimension = 4_096

  /// 스케일 버킷 지수 하한 (2^(-8/2) = 1/16 배).
  package static let minScaleExponent = -8

  /// 스케일 버킷 지수 상한 (2^(12/2) = 64 배).
  package static let maxScaleExponent = 12

  /// 워커 풀 크기 상한 (실크기 = min(이 값, 활성 코어 수)).
  package static let maxWorkerCount = 4

  /// 프리뷰 프리페치 반경 (visible ±N 페이지, ARCHITECTURE 확정: 3).
  package static let previewPrefetchRadius = 3

  /// 타일 프리페치 확장 계수 (visible ±N × 뷰포트 높이, ARCHITECTURE 확정: 0.5).
  package static let tilePrefetchViewportFactor: CGFloat = 0.5

  /// 뷰포트 갱신 1회가 열거하는 타일 키 상한 (병적 뷰포트/줌 폭주 가드).
  package static let maxTileKeysPerViewportUpdate = 256

  /// 기본 타일 캐시 예산: min(256MB, 물리 메모리 / 8) (ARCHITECTURE 확정).
  package static var defaultTileBudgetBytes: Int {
    min(256 << 20, Int(ProcessInfo.processInfo.physicalMemory) / 8)
  }

  /// 기본 프리뷰 캐시 예산: min(64MB, 물리 메모리 / 32).
  ///
  /// 프리뷰 1장 ≈ 0.3~1MB — 수십~수백 페이지 분량을 "작고 많이" 유지한다 (115행).
  package static var defaultPreviewBudgetBytes: Int {
    min(64 << 20, Int(ProcessInfo.processInfo.physicalMemory) / 32)
  }
}
