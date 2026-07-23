import CoreGraphics

/// 인터프리터가 방출하는 원시 run — 어셈블러 입력 (package 내부 전용).
package struct RawGlyphRun: Sendable {
  /// run의 텍스트 (UTF-16 코드유닛).
  package var utf16: [UInt16]

  /// 코드유닛당 페이지 공간 전진량 (가정 3의 귀속 규칙 적용 완료).
  package var advances: [CGFloat]

  /// 페이지 공간 quad (ascent/descent 박스, rise 반영).
  package var quad: Quad

  /// 베이스라인 시작점 (페이지 공간).
  package var origin: CGPoint

  /// 베이스라인 단위 방향 벡터 (페이지 공간 — 정렬·간격 휴리스틱용).
  package var baselineDirection: CGVector

  /// 유효 폰트 크기 (페이지 공간 — 간격 허용치 계산용).
  package var effectiveFontSize: CGFloat

  /// Tr 3 여부.
  package var isInvisible: Bool

  /// 수직 쓰기 run 여부 (어셈블러가 별도 클러스터로 처리).
  package var isVertical: Bool

  /// 원시 run을 생성한다.
  /// - Parameters:
  ///   - utf16: run의 텍스트 (UTF-16 코드유닛).
  ///   - advances: 코드유닛당 페이지 공간 전진량.
  ///   - quad: 페이지 공간 quad.
  ///   - origin: 베이스라인 시작점 (페이지 공간).
  ///   - baselineDirection: 베이스라인 단위 방향 벡터.
  ///   - effectiveFontSize: 유효 폰트 크기 (페이지 공간).
  ///   - isInvisible: Tr 3 여부.
  ///   - isVertical: 수직 쓰기 run 여부.
  package init(
    utf16: [UInt16], advances: [CGFloat], quad: Quad, origin: CGPoint,
    baselineDirection: CGVector, effectiveFontSize: CGFloat, isInvisible: Bool, isVertical: Bool
  ) {
    self.utf16 = utf16
    self.advances = advances
    self.quad = quad
    self.origin = origin
    self.baselineDirection = baselineDirection
    self.effectiveFontSize = effectiveFontSize
    self.isInvisible = isInvisible
    self.isVertical = isVertical
  }
}
