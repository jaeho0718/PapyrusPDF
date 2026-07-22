/// 손상·악성 입력에 대한 방어 한도.
///
/// 전부 상수 — 정책 조정은 여기 한 곳에서 이뤄진다.
package enum CoreLimits {
  /// array/dict 재귀 하강 최대 깊이.
  package static let maxNestingDepth = 512

  /// 단일 스트림 디코딩 출력 상한 (압축 폭탄 가드). 512 MiB.
  package static let maxDecodedStreamBytes = 512 << 20
}
