/// 렉서가 생산하는 토큰.
package enum COSToken: Sendable, Equatable {
  /// 정수 숫자.
  case integer(Int)

  /// 실수 숫자.
  case real(Double)

  /// 이스케이프 해소가 끝난 문자열 바이트 (literal `(..)` / hex `<..>` 공통).
  case string([UInt8])

  /// 이름 토큰.
  case name(COSName)

  /// `[`.
  case arrayOpen

  /// `]`.
  case arrayClose

  /// `<<`.
  case dictionaryOpen

  /// `>>`.
  case dictionaryClose

  /// `true`/`false`.
  case boolean(Bool)

  /// `null`.
  case null

  /// 나머지 bare 키워드.
  case keyword(Keyword)

  /// bare 키워드. 미지의 키워드는 에러가 아니라 `.other`로 넘겨 파서/복구 계층이 판단한다.
  package enum Keyword: Sendable, Equatable {
    /// `obj`.
    case obj

    /// `endobj`.
    case endobj

    /// `stream`.
    case stream

    /// `endstream`.
    case endstream

    // swiftlint:disable identifier_name
    /// `R` (간접 참조 표기).
    case r
    // swiftlint:enable identifier_name

    /// `xref` — M2 소비 예정. 렉싱은 M1부터 지원.
    case xref

    /// `trailer` — M2 소비 예정. 렉싱은 M1부터 지원.
    case trailer

    /// `startxref` — M2 소비 예정. 렉싱은 M1부터 지원.
    case startxref

    /// 위에 해당하지 않는 bare 키워드 (원문 그대로 보존).
    case other(String)
  }
}

/// 토큰 + 원본 내 바이트 구간. 에러 오프셋 보고와 스트림 시작 계산에 쓰인다.
package struct COSScannedToken: Sendable, Equatable {
  /// 스캔된 토큰.
  package let token: COSToken

  /// 토큰이 차지한 절대 바이트 구간 (`range.upperBound` == 토큰 직후 오프셋).
  package let range: Range<Int>

  /// 스캔된 토큰을 생성한다.
  /// - Parameters:
  ///   - token: 스캔된 토큰.
  ///   - range: 토큰이 차지한 절대 바이트 구간.
  package init(token: COSToken, range: Range<Int>) {
    self.token = token
    self.range = range
  }
}
