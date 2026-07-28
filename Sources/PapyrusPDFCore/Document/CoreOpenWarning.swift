/// 문서 열기 중 축적된 관용 처리 신호. 에러로 승격되지 않은 이상 징후의 기록이다.
/// M3에서 공개 `OpenWarning`(struct) 대분류로 매핑된다 (§4.2).
package enum CoreOpenWarning: Sendable, Equatable {
  // MARK: - 헤더/꼬리

  /// `%PDF` 앞에 정크 바이트 존재 (offset == 헤더 시작 위치).
  case junkBeforeHeader(byteCount: Int)

  /// 헤더 버전 표기가 비정상 → 1.4로 폴백함.
  case malformedVersion

  /// `%%EOF` 부재.
  case missingEOFMarker

  /// startxref 부재/숫자 아님 → 복구 스캔으로 전환됨.
  case invalidStartxref

  // MARK: - xref 체인

  /// xref 오프셋들이 헤더 정크만큼 편이되어 있어 +bias 보정으로 성공함.
  case xrefOffsetsBiased(by: Int)

  /// 클래식 행이 20바이트 규격 밖이었으나 복원함.
  case malformedXRefRow(offset: Int)

  /// 엔트리 오프셋이 파일 범위 밖 → 해당 엔트리 폐기.
  case entryOutOfBounds(objectNumber: Int)

  /// /Prev 체인에서 이미 방문한 오프셋 재방문 → 체인 절단.
  case xrefChainCycle(offset: Int)

  /// /Prev 체인이 상한(CoreLimits.maxXRefSections) 도달 → 절단.
  case xrefChainTruncated

  /// 체인 중간 섹션 파싱 실패 → 그 지점에서 체인 절단, 이미 병합된 것만 사용.
  case xrefSectionUnreadable(offset: Int)

  /// xref 스트림 데이터 길이가 /Index 기대보다 짧아 행 단위로 절단 수용함.
  case xrefStreamTruncated(offset: Int)

  // MARK: - 복구

  /// xref를 신뢰할 수 없어 전역 스캔으로 테이블을 재구성함.
  case rebuiltViaRecoveryScan

  /// 복구 스캔 중 trailer 딕셔너리를 찾지 못해 /Type /Catalog 객체 탐색으로 /Root를 정함.
  case rootFoundBySignatureScan

  // MARK: - ObjStm

  /// 컨테이너 딕셔너리에 /Type /ObjStm 부재했으나 /N·/First가 유효해 수용함.
  case objectStreamMissingType(containerNumber: Int)

  /// 컨테이너 헤더 쌍의 오프셋이 페이로드 범위 밖 → 해당 멤버 폐기.
  case objectStreamMemberOutOfBounds(containerNumber: Int, objectNumber: Int)

  // MARK: - M1 파서 경고 승격

  /// 열기 중 수행된 COS 파싱에서 나온 관용 처리 경고.
  case parse(ParseWarning)
}
