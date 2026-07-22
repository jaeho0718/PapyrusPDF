/// 증분 체인 병합이 끝난 최종 xref 뷰. 열기 이후 불변.
package struct XRefTable: Sendable, Equatable {
  /// 객체 번호 → 엔트리. free 엔트리도 보존한다 (부재와 구분 — 둘 다 null 해소지만
  /// 통계·디버깅 가치가 있고 병합 규칙 구현에 필요하다).
  package private(set) var entries: [Int: XRefEntry]

  /// 최신 우선으로 병합된 트레일러 딕셔너리 (/Root /Info /Encrypt /ID /Size).
  /// /Prev·/XRefStm은 병합에서 제외된다 (체인 내비게이션 전용 키).
  package private(set) var trailer: COSDictionary

  /// 빈 테이블을 생성한다.
  package init() {
    self.entries = [:]
    self.trailer = COSDictionary()
  }

  /// 객체 번호로 엔트리를 조회한다. 세대 번호는 무시한다 (가정 5).
  /// - Parameter objectNumber: 조회할 객체 번호.
  package func entry(for objectNumber: Int) -> XRefEntry? {
    self.entries[objectNumber]
  }

  /// first-wins 병합: 이미 있는 번호는 유지, 없는 번호만 추가한다.
  /// 섹션을 최신 → 과거 순으로 공급하는 호출 규약과 결합해 "최신 우선"을 이룬다.
  /// - Parameter section: 병합할 섹션.
  package mutating func mergeSection(_ section: XRefSection) {
    for (number, entry) in section.entries where self.entries[number] == nil {
      self.entries[number] = entry
    }
    for key in section.trailer.keys where self.trailer[key] == nil {
      self.trailer[key] = section.trailer[key]
    }
  }
}

/// 파일 내 xref 섹션 하나(클래식 테이블 또는 xref 스트림)의 파싱 결과.
package struct XRefSection: Sendable, Equatable {
  /// 이 섹션이 선언한 엔트리들 (객체 0 free 헤드는 제외하고 담는다).
  package var entries: [Int: XRefEntry]

  /// 이 섹션의 트레일러 딕셔너리 (클래식: trailer 키워드 뒤, 스트림: 스트림 딕셔너리 자신).
  package var trailer: COSDictionary

  /// /Prev 오프셋 (없으면 nil).
  package var previousOffset: Int?

  /// /XRefStm 오프셋 (하이브리드 클래식 섹션만, 없으면 nil).
  package var xrefStreamOffset: Int?

  /// 섹션을 생성한다.
  /// - Parameters:
  ///   - entries: 이 섹션이 선언한 엔트리들.
  ///   - trailer: 이 섹션의 트레일러 딕셔너리.
  ///   - previousOffset: /Prev 오프셋.
  ///   - xrefStreamOffset: /XRefStm 오프셋.
  package init(
    entries: [Int: XRefEntry] = [:], trailer: COSDictionary = COSDictionary(),
    previousOffset: Int? = nil, xrefStreamOffset: Int? = nil
  ) {
    self.entries = entries
    self.trailer = trailer
    self.previousOffset = previousOffset
    self.xrefStreamOffset = xrefStreamOffset
  }
}
