import Foundation

/// 선택·검색이 소비할 페이지 텍스트 콘텐츠 공급원입니다.
///
/// 결과의 좌표 계약은 ``PapyrusDocument/text(forPage:)``와 동일합니다 — ``TextRun/quad``는
/// PDF 페이지 공간, ``TextRun/range``는 반환 문자열의 UTF-16 좌표계입니다.
/// OCR 결과처럼 표시 공간 정규화 좌표를 가진 소스는
/// ``PageInfo/pageQuad(normalizedDisplayRect:)``와 ``TextRun/uniform(range:quad:isInvisible:)``으로
/// 변환해 공급합니다.
///
/// 반환값은 소비 전 위생 검사를 거칩니다 — 범위 이탈 run은 클램프·폐기되고, 비유한
/// 좌표는 폐기되며, run 수·문자열 길이는 상한이 적용됩니다. 잘못된 값이 크래시를
/// 일으키지는 않지만, 계약을 지킬 때만 정확한 선택·검색을 보장합니다.
public protocol PageTextProvider: Sendable {
  /// 페이지 하나의 텍스트 콘텐츠를 반환합니다.
  ///
  /// 반환값의 `pageIndex`는 인자와 일치해야 합니다 (불일치 시 인자 기준으로 교정됩니다).
  /// throw하면 해당 페이지는 "텍스트 없음"으로 처리됩니다 — 검색은 그 페이지를 건너뛰고,
  /// 선택은 그 페이지에서 비활성입니다.
  ///
  /// 검색 워밍업과 선택 프리페치가 병렬로 동작하므로, 여러 페이지에 대해 동시에 호출될 수
  /// 있습니다 — 구현이 내부 캐시를 가진다면 actor 등으로 격리하세요.
  /// - Parameter pageIndex: 조회할 페이지 인덱스입니다 (0 기반).
  /// - Returns: 페이지 텍스트 콘텐츠입니다.
  /// - Throws: 프로바이더 구현이 정의하는 임의의 에러입니다.
  func textContent(forPage pageIndex: Int) async throws -> PageTextContent
}

/// 기본 프로바이더 — 문서의 내장 텍스트 추출 결과를 그대로 공급합니다.
///
/// ``PapyrusDocument/text(forPage:)`` 위임입니다 (LRU 캐시·중복 요청 병합 포함).
public struct DocumentTextProvider: PageTextProvider {
  /// 공급원 문서입니다.
  public let document: PapyrusDocument

  /// 문서를 감싸 생성합니다.
  /// - Parameter document: 공급원 문서입니다.
  public init(document: PapyrusDocument) {
    self.document = document
  }

  /// ``PapyrusDocument/text(forPage:)``에 위임합니다.
  /// - Parameter pageIndex: 조회할 페이지 인덱스입니다 (0 기반).
  /// - Returns: 페이지 텍스트 콘텐츠입니다.
  /// - Throws: ``PapyrusError`` (문서 내장 추출 실패).
  public func textContent(forPage pageIndex: Int) async throws -> PageTextContent {
    try await self.document.text(forPage: pageIndex)
  }
}
