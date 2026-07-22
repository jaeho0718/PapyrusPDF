/// 필터 디코딩 실패.
package struct FilterError: Error, Sendable, Equatable {
  /// 실패 종류.
  package let code: Code

  /// 실패한 필터 이름 (파이프라인 단계 특정용).
  package let filterName: COSName?

  /// 에러를 생성한다.
  /// - Parameters:
  ///   - code: 실패 종류.
  ///   - filterName: 실패한 필터 이름. 단일 디코더 호출처럼 파이프라인 밖이면 `nil`.
  package init(code: Code, filterName: COSName? = nil) {
    self.code = code
    self.filterName = filterName
  }

  /// 실패 종류.
  package enum Code: Sendable, Equatable {
    /// 구조적으로 해석 불가한 입력.
    case corruptedData

    /// EOD/종료 전에 입력이 소진됨.
    case truncatedData

    /// 알파벳 밖 문자 (hex/85).
    case invalidCharacter

    /// `maxDecodedSize` 초과 (압축 폭탄 가드).
    case outputLimitExceeded

    /// DCT/JPX/JBIG2/CCITT/LZW(M4 전) 등 미지원 필터.
    case unsupportedFilter(COSName)

    /// 미지 Predictor 값.
    case unsupportedPredictor(Int)

    /// 행 크기 불일치, TIFF 서브바이트 등 predictor 레이아웃 오류.
    case invalidPredictorLayout

    /// `/Filter`·`/DecodeParms`에 미해소 참조가 있다 (M1 제약, §7).
    case indirectParameter
  }
}
