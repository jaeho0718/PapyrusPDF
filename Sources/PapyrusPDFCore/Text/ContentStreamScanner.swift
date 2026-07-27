import Foundation

/// 콘텐츠 스트림 전용 토큰 공급기 — COSLexer 재사용 + 연산자/합성 오퍼랜드 조립.
///
/// COS 렉서와의 차이: bare 키워드를 연산자 문자열로 취급하고, `[`/`<<`를 만나면
/// 닫힘까지 재귀 없이(명시적 스택, 깊이 캡) 조립해 오퍼랜드 하나로 반환한다.
/// 렉서 에러 시 1바이트 전진 후 재시도 (커서 단조 증가 — 종료 보장).
package struct ContentStreamScanner {
  /// 스캐너가 방출하는 요소.
  package enum Element: Sendable, Equatable {
    /// 값 오퍼랜드 (숫자·문자열·이름·배열·딕셔너리·불리언·null).
    case operand(COSObject)
    /// 연산자 문자열 (`Tj`, `BT`, `Do` 등).
    case `operator`(String)
  }

  /// 원본 바이트 (인라인 이미지 휴리스틱 스킵의 원시 스캔용).
  private let bytes: [UInt8]

  /// 토큰화 커서.
  private var lexer: COSLexer

  /// 스캐너를 생성한다.
  /// - Parameter data: 디코딩 완료된 콘텐츠 스트림 바이트.
  package init(data: Data) {
    self.bytes = Array(data)
    self.lexer = COSLexer(file: MappedFile(data: data))
  }

  /// 다음 요소. EOF면 `nil`. throw하지 않는다 (관용 재동기화).
  /// - Returns: 다음 오퍼랜드 또는 연산자, EOF면 `nil`.
  package mutating func next() -> Element? {
    while true {
      guard let token = self.nextResyncing() else {
        return nil
      }
      switch token.token {
      case .arrayOpen:
        return .operand(self.assembleComposite(isArray: true))
      case .dictionaryOpen:
        return .operand(self.assembleComposite(isArray: false))
      case .arrayClose, .dictionaryClose:
        continue // 고아 닫힘 토큰 — 무시하고 다음 요소로 (관용).
      case let .keyword(keyword):
        return .operator(Self.keywordText(keyword))
      default:
        guard let scalar = Self.scalarValue(for: token.token) else {
          continue // 도달 불가 방어 (모든 스칼라 토큰은 scalarValue가 처리).
        }
        return .operand(scalar)
      }
    }
  }

  /// `BI`…`ID`…`EI` 인라인 이미지를 스킵한다 (`BI` 연산자 수신 직후 호출, 가정 9).
  ///
  /// `ID` 키워드까지 정상 토큰화로 건너뛴 뒤, 그 직후 1바이트(구분자)를 건너뛰고
  /// "공백류 + `EI` + (공백류|EOF)" 패턴을 선형 탐색해 커서를 그 뒤로 옮긴다.
  /// `EI`를 찾지 못하면 콘텐츠 끝까지 커서를 옮긴다(해당 세그먼트 잔여 포기).
  package mutating func skipInlineImage() {
    while let token = self.nextResyncing() {
      if case .keyword(.other("ID")) = token.token {
        break
      }
    }
    self.lexer.seek(to: self.lexer.offset + 1)
    self.skipToEndOfInlineImageData()
  }
}

// MARK: - 인라인 이미지 원시 스캔

extension ContentStreamScanner {
  private mutating func skipToEndOfInlineImageData() {
    var cursor = self.lexer.offset
    while cursor < self.bytes.count {
      let isWhitespace = Self.isWhitespace(self.bytes[cursor])
      if isWhitespace, Self.matchesEIMarker(self.bytes, whitespaceAt: cursor) {
        self.lexer.seek(to: cursor + 3)
        return
      }
      cursor += 1
    }
    self.lexer.seek(to: self.bytes.count)
  }

  /// `whitespaceAt`이 공백이라는 전제 하에, 그 직후가 `EI` + (공백|EOF)인지 검사한다.
  private static func matchesEIMarker(_ bytes: [UInt8], whitespaceAt index: Int) -> Bool {
    let markerStart = index + 1
    guard markerStart + 1 < bytes.count, bytes[markerStart] == UInt8(ascii: "E"),
      bytes[markerStart + 1] == UInt8(ascii: "I")
    else {
      return false
    }
    let after = markerStart + 2
    return after >= bytes.count || Self.isWhitespace(bytes[after])
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20:
      return true
    default:
      return false
    }
  }
}

// MARK: - 합성 오퍼랜드 조립 (명시적 스택, 재귀 없음)

extension ContentStreamScanner {
  /// 배열/딕셔너리 조립 중인 프레임.
  private enum CompositeFrame {
    case array([COSObject])
    case dictionary(COSDictionary, pendingKey: COSName?)

    var asObject: COSObject {
      switch self {
      case let .array(elements):
        return .array(elements)
      case let .dictionary(dictionary, _):
        return .dictionary(dictionary)
      }
    }

    var isArray: Bool {
      if case .array = self {
        return true
      }
      return false
    }
  }

  /// `[`/`<<` 직후부터 시작해 닫힘까지 조립한다. 깊이 캡 초과·EOF는 그 시점까지의
  /// 최상위 프레임 내용을 그대로 반환한다(관용).
  private mutating func assembleComposite(isArray: Bool) -> COSObject {
    var stack: [CompositeFrame] = [
      isArray ? .array([]) : .dictionary(COSDictionary(), pendingKey: nil)
    ]

    while true {
      guard stack.count <= CoreLimits.maxContentOperandDepth else {
        return stack[0].asObject
      }
      guard let token = self.nextResyncing() else {
        return stack[0].asObject
      }
      switch token.token {
      case .arrayClose, .dictionaryClose:
        let matchesArray = token.token == .arrayClose
        let finished = stack.removeLast()
        guard matchesArray == finished.isArray else {
          if stack.isEmpty {
            return finished.asObject
          }
          continue
        }
        if stack.isEmpty {
          return finished.asObject
        }
        Self.append(finished.asObject, to: &stack)
      case .arrayOpen:
        stack.append(.array([]))
      case .dictionaryOpen:
        stack.append(.dictionary(COSDictionary(), pendingKey: nil))
      default:
        Self.handleScalarOrKey(token.token, stack: &stack)
      }
    }
  }

  private static func append(_ value: COSObject, to stack: inout [CompositeFrame]) {
    guard !stack.isEmpty else {
      return
    }
    let topIndex = stack.count - 1
    switch stack[topIndex] {
    case var .array(elements):
      elements.append(value)
      stack[topIndex] = .array(elements)
    case let .dictionary(dictionary, .some(key)):
      var updated = dictionary
      if !value.isNull {
        updated[key] = value
      }
      stack[topIndex] = .dictionary(updated, pendingKey: nil)
    case .dictionary(_, nil):
      break // 대기 중인 키 없이 값이 옴 — 관용 폐기.
    }
  }

  private static func handleScalarOrKey(_ token: COSToken, stack: inout [CompositeFrame]) {
    guard !stack.isEmpty else {
      return
    }
    let topIndex = stack.count - 1
    if case .dictionary(let dictionary, nil) = stack[topIndex], case let .name(key) = token {
      stack[topIndex] = .dictionary(dictionary, pendingKey: key)
      return
    }
    guard let scalar = Self.scalarValue(for: token) else {
      return // 연산자·알 수 없는 토큰 — 관용 무시.
    }
    Self.append(scalar, to: &stack)
  }
}

// MARK: - 토큰 변환·재동기화 공용 헬퍼

extension ContentStreamScanner {
  /// 스칼라(컨테이너가 아닌) 토큰만 값으로 변환한다.
  private static func scalarValue(for token: COSToken) -> COSObject? {
    switch token {
    case let .integer(value):
      return .integer(value)
    case let .real(value):
      return .real(value)
    case let .string(bytes):
      return .string(bytes)
    case let .name(name):
      return .name(name)
    case let .boolean(value):
      return .boolean(value)
    case .null:
      return .null
    default:
      return nil
    }
  }

  /// 키워드 토큰을 연산자 문자열로 변환한다.
  private static func keywordText(_ keyword: COSToken.Keyword) -> String {
    switch keyword {
    case .obj:
      return "obj"
    case .endobj:
      return "endobj"
    case .stream:
      return "stream"
    case .endstream:
      return "endstream"
    case .r:
      return "R"
    case .xref:
      return "xref"
    case .trailer:
      return "trailer"
    case .startxref:
      return "startxref"
    case let .other(word):
      return word
    }
  }

  /// 렉서 에러를 1바이트 전진으로 재동기화하며 다음 토큰을 얻는다 (커서 단조 증가 —
  /// 종료 보장). EOF면 `nil`.
  private mutating func nextResyncing() -> COSScannedToken? {
    while true {
      do {
        return try self.lexer.nextToken()
      } catch {
        self.lexer.seek(to: self.lexer.offset + 1)
      }
    }
  }
}
