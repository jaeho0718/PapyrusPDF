/// 병합 완료된 xref 테이블의 엔트리 하나.
package enum XRefEntry: Sendable, Equatable {
  /// free 엔트리 (type 0). 증분 업데이트의 객체 삭제 표현 — 조회 시 `.null`로 해소된다.
  case free

  /// 파일 최상위의 비압축 객체 (type 1). `offset`은 `N G obj` 헤더 시작 절대 오프셋.
  case uncompressed(offset: Int, generation: Int)

  /// ObjStm 컨테이너 안에 압축된 객체 (type 2). 세대는 항상 0.
  case compressed(containerNumber: Int, indexInContainer: Int)
}
