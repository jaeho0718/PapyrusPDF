/// 캐시 관찰 스냅숏 (테스트 전용 소비).
package struct CacheStatistics: Sendable, Equatable {
  /// 객체 LRU 적재 항목 수.
  package let objectCacheCount: Int

  /// ObjStm 캐시 적재 바이트.
  package let objectStreamCacheBytes: Int

  /// ObjStm 캐시 적재 컨테이너 수.
  package let objectStreamCacheContainerCount: Int

  /// 누적 컨테이너 압축 해제 횟수 (in-flight dedupe 검증용 — 캐시 히트면 늘지 않는다).
  package let containerDecodeCount: Int

  /// 페이지 트리 평탄화가 실제로 실행된 횟수 (dedupe 검증용).
  package let pageTreeBuildCount: Int

  /// 메타데이터 수집이 실제로 실행된 횟수 (dedupe 검증용).
  package let metadataBuildCount: Int

  /// 목차 구축이 실제로 실행된 횟수 (dedupe 검증용).
  package let outlineBuildCount: Int

  /// 텍스트 추출이 실제로 실행된 횟수 (dedupe 검증용).
  package let textExtractionCount: Int

  /// 폰트 빌드가 실제로 실행된 횟수 (dedupe 검증용).
  package let fontBuildCount: Int

  /// 페이지 텍스트 LRU 적재 바이트.
  package let textPageCacheBytes: Int

  /// 캐시 통계를 생성한다.
  /// - Parameters:
  ///   - objectCacheCount: 객체 LRU 적재 항목 수.
  ///   - objectStreamCacheBytes: ObjStm 캐시 적재 바이트.
  ///   - objectStreamCacheContainerCount: ObjStm 캐시 적재 컨테이너 수.
  ///   - containerDecodeCount: 누적 컨테이너 압축 해제 횟수.
  ///   - pageTreeBuildCount: 페이지 트리 평탄화가 실제로 실행된 횟수.
  ///   - metadataBuildCount: 메타데이터 수집이 실제로 실행된 횟수.
  ///   - outlineBuildCount: 목차 구축이 실제로 실행된 횟수.
  ///   - textExtractionCount: 텍스트 추출이 실제로 실행된 횟수.
  ///   - fontBuildCount: 폰트 빌드가 실제로 실행된 횟수.
  ///   - textPageCacheBytes: 페이지 텍스트 LRU 적재 바이트.
  package init(
    objectCacheCount: Int, objectStreamCacheBytes: Int, objectStreamCacheContainerCount: Int,
    containerDecodeCount: Int, pageTreeBuildCount: Int = 0, metadataBuildCount: Int = 0,
    outlineBuildCount: Int = 0, textExtractionCount: Int = 0, fontBuildCount: Int = 0,
    textPageCacheBytes: Int = 0
  ) {
    self.objectCacheCount = objectCacheCount
    self.objectStreamCacheBytes = objectStreamCacheBytes
    self.objectStreamCacheContainerCount = objectStreamCacheContainerCount
    self.containerDecodeCount = containerDecodeCount
    self.pageTreeBuildCount = pageTreeBuildCount
    self.metadataBuildCount = metadataBuildCount
    self.outlineBuildCount = outlineBuildCount
    self.textExtractionCount = textExtractionCount
    self.fontBuildCount = fontBuildCount
    self.textPageCacheBytes = textPageCacheBytes
  }
}
