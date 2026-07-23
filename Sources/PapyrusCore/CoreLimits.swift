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

  /// 평탄화가 수용하는 최대 페이지 수 (손상 트리의 폭주 가드).
  package static let maxPages = 1_000_000

  /// 페이지 트리 최대 깊이 (Kids 중첩).
  package static let maxPageTreeDepth = 256

  /// /Count 힌트로 예약하는 용량 상한 (거짓 /Count의 과대 할당 가드).
  package static let maxPageCountHint = 10_000

  /// 목차 항목 수 상한 (ARCHITECTURE.md: 5만 캡).
  package static let maxOutlineItems = 50_000

  /// 목차 트리 최대 깊이 (재귀 하강 캡 — 입력 비례 재귀 금지의 상수 상한).
  package static let maxOutlineDepth = 64

  /// 네임 트리 하강 최대 깊이.
  package static let maxNameTreeDepth = 64

  /// 네임 트리 조회 1회가 해소하는 노드 수 상한 (병적 /Kids 부채꼴 가드).
  package static let maxNameTreeNodesPerLookup = 1_024

  /// XMP 메타데이터 스트림 최대 수용 바이트 (10MB — 초과 시 XMP 무시).
  package static let maxXMPMetadataBytes = 10 << 20

  /// 페이지 텍스트 LRU 바이트 예산 (16MB).
  package static let maxTextPageCacheBytes = 16 << 20

  /// 폰트 캐시 항목 수 캡.
  package static let maxLoadedFontEntries = 256

  /// Form XObject 재귀 깊이 캡 (ARCHITECTURE.md: 16).
  package static let maxFormXObjectDepth = 16

  /// 페이지당 방출 글리프 상한 (병적 콘텐츠 폭주 가드).
  package static let maxGlyphsPerPage = 500_000

  /// 콘텐츠 오퍼랜드 스택 상한 (초과 시 오래된 것부터 폐기).
  package static let maxContentOperands = 1_024

  /// 콘텐츠 배열/딕셔너리 오퍼랜드 조립 깊이 캡.
  package static let maxContentOperandDepth = 32

  /// q/Q 그래픽 상태 스택 깊이 캡.
  package static let maxGraphicsStateDepth = 256

  /// CMap 엔트리(개별 char + range 항목 합) 상한.
  package static let maxCMapEntries = 262_144

  /// 페이지 1장 콘텐츠(폼 포함) 디코딩 총량 상한 (32MB — 초과 세그먼트는 절단).
  package static let maxContentBytesPerPage = 32 << 20

  /// 페이지당 검색 매치 상한 (병적 문서의 스트림 버퍼 폭주 방지).
  package static let maxSearchMatchesPerPage = 1_000

  /// 문서당 검색 매치 총 상한 — 도달 시 스트림은 정상 종료한다.
  package static let maxSearchTotalMatches = 10_000

  /// 검색 워밍업 병렬 폭 상한 (실제 폭 = min(이 값, 활성 코어 수, 페이지 수)).
  package static let maxSearchWarmupWidth = 4
}
