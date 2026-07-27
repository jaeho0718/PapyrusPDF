/// COS 구문 오류. 항상 원본 바이트 오프셋을 동반한다.
package struct COSParseError: Error, Sendable, Equatable {
  /// 오류 종류.
  package let code: Code

  /// 오류가 감지된 절대 바이트 오프셋.
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
    /// 토큰을 완성하기 전에 파일이 끝났다.
    case unexpectedEndOfFile

    /// 숫자 문법 위반.
    case invalidNumber

    /// hex 문자열에 `0-9A-Fa-f`·공백 밖의 문자가 나타났다.
    case invalidHexCharacter

    /// EOF까지 닫히지 않은 `(...)`.
    case unbalancedString

    /// 고아 `)` `>` `{` `}` 등.
    case unexpectedDelimiter

    /// 문맥상 허용 안 되는 토큰 (설명은 offset으로 추적).
    case unexpectedToken

    /// ``CoreLimits/maxNestingDepth`` 초과.
    case nestingTooDeep

    /// `"N G obj"` 형식 위반 (N<=0, G 범위 밖 포함).
    case invalidObjectHeader

    /// `endstream`을 파일 끝까지 못 찾음.
    case missingEndstream

    /// `LengthResolver`가 throw 했다.
    case lengthResolutionFailed
  }
}

/// 에러로 승격하지 않은 관용 처리 신호. M2에서 공개 `CoreOpenWarning`으로 집계된다.
package enum ParseWarning: Sendable, Equatable {
  /// `/Length`가 실제 `endstream` 위치와 불일치 → 스캔으로 복구함.
  case streamLengthMismatch(id: ObjectID?, declared: Int?, actual: Int)

  /// `stream` 직후 EOL이 비표준 (CR 단독 등).
  case nonstandardStreamEOL(offset: Int)

  /// `endobj` 누락 — 객체는 정상 반환함.
  case missingEndobj(id: ObjectID)
}
