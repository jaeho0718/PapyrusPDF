/// xref 섹션 파싱 실패. `TrailerResolver`가 잡아 복구 스캔으로 전환하는 내부 신호에 가깝다.
package struct XRefError: Error, Sendable, Equatable {
  /// 오류 종류.
  package let code: Code

  /// 오류가 감지된 절대 바이트 오프셋 (디코딩된 스트림 내부면 스트림 내 상대 오프셋).
  package let offset: Int

  /// 오류를 생성한다.
  /// - Parameters:
  ///   - code: 오류 종류.
  ///   - offset: 오류가 감지된 절대 바이트 오프셋.
  package init(code: Code, offset: Int) {
    self.code = code
    self.offset = offset
  }

  /// 오류 종류.
  package enum Code: Sendable, Equatable {
    /// 오프셋에 xref 키워드도, xref 스트림 객체도 없음.
    case notAnXRefSection

    /// `"start count"` 형식 위반.
    case invalidSubsectionHeader

    /// 행에서 오프셋/세대/타입을 복원 못 함.
    case malformedEntry

    /// 누적 엔트리 수가 CoreLimits 상한 초과.
    case entryCountTooLarge

    /// 클래식 섹션 뒤 trailer 부재.
    case missingTrailer

    /// `/Type /XRef` 스트림의 `/W`·`/Size`·`/Index` 위반.
    case invalidStreamDictionary

    /// `/W` 원소 > 8.
    case fieldWidthTooLarge

    /// 필터 파이프라인 실패 (FilterError 요약).
    case decodeFailed

    /// 내부 COS 파싱 실패 (COSParseError 요약).
    case parseFailed
  }
}
