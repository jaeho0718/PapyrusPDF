/// 손상·악성 입력에 대한 방어 한도.
///
/// 전부 상수 — 정책 조정은 여기 한 곳에서 이뤄진다.
package enum CoreLimits {
  /// array/dict 재귀 하강 최대 깊이.
  package static let maxNestingDepth = 512

  /// 단일 스트림 디코딩 출력 상한 (압축 폭탄 가드). 512 MiB.
  package static let maxDecodedStreamBytes = 512 << 20

  /// `%PDF-` 헤더 탐색 윈도 (파일 선두). 스펙 관용: 앞 1KB 정크 허용.
  package static let headerScanWindow = 1_024

  /// `startxref` 역방향 탐색 윈도 (파일 말미).
  package static let startxrefScanWindow = 1_024

  /// /Prev 체인 최대 섹션 수 (순환 가드의 상한 보조).
  package static let maxXRefSections = 1_024

  /// 문서 전체 xref 엔트리 수 상한 (손상된 count/Size가 유발하는 메모리 폭주 가드).
  package static let maxXRefEntries = 8_000_000

  /// xref 스트림 /W 필드 하나의 최대 바이트 폭.
  package static let maxXRefFieldWidth = 8

  /// ObjStm 컨테이너 하나의 /N 상한.
  package static let maxObjectsPerObjectStream = 100_000

  /// ObjStm 컨테이너 LRU 캐시 바이트 예산 (~16MB, ARCHITECTURE.md 확정).
  package static let maxObjectStreamCacheBytes = 16 << 20

  /// 객체 LRU 캐시 항목 수 캡.
  package static let objectCacheEntryCap = 4_096

  /// `resolve(_:)`가 따라가는 참조 사슬 최대 길이 (R→R→… 순환 가드).
  package static let maxReferenceChainLength = 32
}
