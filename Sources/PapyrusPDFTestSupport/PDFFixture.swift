import Foundation

/// ``PDFFixtureBuilder``가 생성한 PDF 바이트와 구조 메타데이터.
///
/// `objectOffsets`/`xrefOffset`을 노출하는 이유:
/// (1) M0 바이트 수준 검증 테스트가 오프셋 대조에 쓴다.
/// (2) M2 손상 모드가 "특정 오프셋의 바이트를 훼손"하는 후처리로 구현될 기반이다.
package struct PDFFixture: Sendable {
  /// 완성된 PDF 파일 바이트.
  package let data: Data

  /// 객체 번호 → `N 0 obj` 시작 바이트 오프셋. (v0는 세대 번호 전부 0)
  package let objectOffsets: [Int: Int]

  /// `xref` 키워드 시작 오프셋 (= startxref가 가리키는 값).
  package let xrefOffset: Int

  /// 파일에 기록된 모든 xref 섹션(또는 xref 스트림 객체)의 시작 오프셋 목록,
  /// 기록 순서(과거 → 최신) 그대로. M2 증분 업데이트·손상 모드·체인 테스트용
  /// (기존 이니셜라이저 호출과의 호환을 위해 기본값 `[]`).
  package let sectionOffsets: [Int]

  /// 문서 내 총 객체 수 (free object 0 제외). 카탈로그 1 + Pages 1 + 페이지 N.
  package var objectCount: Int {
    self.objectOffsets.count
  }

  /// 픽스처를 생성한다.
  /// - Parameters:
  ///   - data: 완성된 PDF 파일 바이트.
  ///   - objectOffsets: 객체 번호 → `N 0 obj` 시작 바이트 오프셋.
  ///   - xrefOffset: `xref` 키워드(또는 xref 스트림 객체) 시작 오프셋.
  ///   - sectionOffsets: 모든 xref 섹션의 시작 오프셋 목록 (기본 `[]`).
  package init(
    data: Data, objectOffsets: [Int: Int], xrefOffset: Int, sectionOffsets: [Int] = []
  ) {
    self.data = data
    self.objectOffsets = objectOffsets
    self.xrefOffset = xrefOffset
    self.sectionOffsets = sectionOffsets
  }
}
