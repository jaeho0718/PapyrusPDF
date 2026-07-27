/// 토큰 스트림 → ``COSObject`` 재귀 하강 파서.
///
/// 무상태 순수 변환에 가깝다 — 캐시·xref를 모르며, 지정 오프셋의 구문만 해석한다.
package struct COSParser: Sendable {
  /// `/Length`가 간접 참조일 때 해소를 위임받는 클로저 (M2 액터가 주입).
  /// `nil`이거나 해소 실패 시 `endstream` 스캔 폴백으로 대체된다.
  package typealias LengthResolver = @Sendable (ObjectID) throws -> Int?

  // `file`/`lengthResolver`/`warnings`의 setter는 `internal`이다(`private`이 아님) —
  // 스트림 조립 로직이 파일 길이 제한 때문에 `COSParser+Stream.swift`로 분리되어 있어,
  // 같은 모듈(target) 내 다른 파일에서도 접근할 수 있어야 한다. package 경계 밖(다른
  // target)으로는 여전히 노출되지 않는다.

  /// 파싱 대상 바이트 소스.
  let file: MappedFile

  /// `/Length` 간접 참조 해소용 클로저.
  let lengthResolver: LengthResolver?

  /// 파싱 중 축적된 관용 처리 경고 (에러로 승격하지 않은 이상 신호).
  package internal(set) var warnings: [ParseWarning] = []

  /// 파서를 생성한다.
  /// - Parameters:
  ///   - file: 파싱 대상 바이트 소스.
  ///   - lengthResolver: `/Length` 간접 참조 해소 클로저. `nil`이면 항상 스캔 폴백.
  package init(file: MappedFile, lengthResolver: LengthResolver? = nil) {
    self.file = file
    self.lengthResolver = lengthResolver
  }

  /// 지정 오프셋에서 값 하나를 파싱한다 (트레일러 딕셔너리, 테스트용).
  /// - Parameter offset: 파싱을 시작할 절대 바이트 오프셋.
  /// - Throws: 구문 위반 시 ``COSParseError``.
  package mutating func parseObject(at offset: Int) throws(COSParseError) -> COSObject {
    var lexer = COSLexer(file: self.file, offset: offset)
    return try Self.parseValue(lexer: &lexer, depth: 0)
  }

  /// 지정 오프셋에서 `N G obj ... endobj` 간접 객체 하나를 파싱한다.
  ///
  /// 오프셋은 M1에선 테스트(픽스처 objectOffsets), M2부턴 xref가 공급한다.
  /// - Parameter offset: `N G obj` 헤더가 시작하는 절대 바이트 오프셋.
  /// - Throws: 구문 위반 시 ``COSParseError``.
  package mutating func parseIndirectObject(
    at offset: Int
  ) throws(COSParseError) -> IndirectObject {
    var lexer = COSLexer(file: self.file, offset: offset)
    let id = try Self.parseObjectHeader(lexer: &lexer)
    let value = try Self.parseValue(lexer: &lexer, depth: 0)
    let object = try self.attachStreamIfPresent(value: value, id: id, lexer: &lexer)
    self.consumeEndobj(id: id, lexer: &lexer)
    return IndirectObject(id: id, object: object)
  }
}

/// 간접 객체 파싱 결과.
package struct IndirectObject: Sendable, Equatable {
  /// 객체 식별자.
  package let id: ObjectID

  /// 파싱된 값.
  package let object: COSObject

  /// 간접 객체 파싱 결과를 생성한다.
  /// - Parameters:
  ///   - id: 객체 식별자.
  ///   - object: 파싱된 값.
  package init(id: ObjectID, object: COSObject) {
    self.id = id
    self.object = object
  }
}

// MARK: - 값 파싱 (상태 없는 재귀 하강)

extension COSParser {
  /// `N G obj` 헤더를 검증하고 ``ObjectID``를 만든다.
  private static func parseObjectHeader(lexer: inout COSLexer) throws(COSParseError) -> ObjectID {
    let headerStart = lexer.offset
    guard
      let numberToken = try lexer.nextToken(), case let .integer(number) = numberToken.token,
      let generationToken = try lexer.nextToken(),
      case let .integer(generation) = generationToken.token,
      let objToken = try lexer.nextToken(), case .keyword(.obj) = objToken.token,
      number > 0, (0...65_535).contains(generation)
    else {
      throw COSParseError(code: .invalidObjectHeader, offset: headerStart)
    }
    return ObjectID(number: number, generation: generation)
  }

  /// 진입점. 깊이 상한을 검사한 뒤 반복(iterative) 상태 기계로 값을 조립한다.
  ///
  /// array/dict 하강을 네이티브 함수 재귀가 아니라 힙에 쌓는 명시적 스택(``ContainerFrame``)
  /// 으로 구현한다 — `CoreLimits.maxNestingDepth`(512)만큼 네이티브 콜스택을 쌓으면
  /// 디버그 빌드·작은 스레드 스택(예: 테스트 러너 워커 스레드)에서 스택 오버플로로
  /// 크래시할 수 있다("크래시 금지" 불변식 위반). 스택 깊이는 입력 크기와 무관하게
  /// 상수로 유지되므로 이 문제가 구조적으로 발생하지 않는다.
  private static func parseValue(
    lexer: inout COSLexer, depth: Int
  ) throws(COSParseError) -> COSObject {
    guard depth <= CoreLimits.maxNestingDepth else {
      throw COSParseError(code: .nestingTooDeep, offset: lexer.offset)
    }

    var stack: [ContainerFrame] = []
    var currentDepth = depth

    while true {
      guard let top = stack.last else {
        let started = try Self.scanValueStart(
          lexer: &lexer, stack: &stack, currentDepth: &currentDepth
        )
        if let value = started {
          return value
        }
        continue
      }

      let completed: COSObject?
      switch top {
      case .array:
        completed = try Self.continueArray(
          lexer: &lexer, stack: &stack, currentDepth: &currentDepth
        )
      case .dictionary(_, pendingKey: nil):
        completed = try Self.continueDictionaryKey(
          lexer: &lexer, stack: &stack, currentDepth: &currentDepth
        )
      case .dictionary(_, pendingKey: .some):
        completed = try Self.continueDictionaryValue(
          lexer: &lexer, stack: &stack, currentDepth: &currentDepth
        )
      }
      if let completed {
        return completed
      }
    }
  }

  /// 컨테이너 하강 스택의 진행 중 프레임 — array 원소 누적, dict는 키 대기/값 대기를 오간다.
  private enum ContainerFrame {
    case array([COSObject])
    case dictionary(COSDictionary, pendingKey: COSName?)
  }

  /// 값 하나의 시작을 스캔한다. 스칼라면 즉시 반환하고, `[`/`<<`면 새 프레임을 스택에
  /// 얹은 뒤 `nil`을 반환한다(호출부는 다음 반복에서 그 프레임을 이어 처리한다).
  private static func scanValueStart(
    lexer: inout COSLexer, stack: inout [ContainerFrame], currentDepth: inout Int
  ) throws(COSParseError) -> COSObject? {
    guard let scanned = try lexer.nextToken() else {
      throw COSParseError(code: .unexpectedEndOfFile, offset: lexer.offset)
    }
    if let scalar = Self.scalarValue(for: scanned.token, lexer: &lexer) {
      return scalar
    }
    switch scanned.token {
    case .arrayOpen, .dictionaryOpen:
      let frame: ContainerFrame = scanned.token == .arrayOpen
        ? .array([]) : .dictionary(COSDictionary(), pendingKey: nil)
      try Self.pushContainer(
        frame, stack: &stack, currentDepth: &currentDepth, offset: lexer.offset
      )
      return nil
    default:
      throw COSParseError(code: .unexpectedToken, offset: scanned.range.lowerBound)
    }
  }

  /// 스칼라 토큰(재귀 하강이 필요 없는 값)만 즉시 변환한다. 컨테이너·구조 토큰은 `nil`.
  private static func scalarValue(for token: COSToken, lexer: inout COSLexer) -> COSObject? {
    switch token {
    case let .integer(number):
      return Self.parseIntegerOrReference(number: number, lexer: &lexer)
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

  /// 새 컨테이너 프레임을 스택에 얹기 전 깊이 상한을 검사한다.
  private static func pushContainer(
    _ frame: ContainerFrame, stack: inout [ContainerFrame], currentDepth: inout Int, offset: Int
  ) throws(COSParseError) {
    currentDepth += 1
    guard currentDepth <= CoreLimits.maxNestingDepth else {
      throw COSParseError(code: .nestingTooDeep, offset: offset)
    }
    stack.append(frame)
  }

  /// 스택 최상단이 array일 때 한 걸음 진행한다: `]`면 완결해 부모에 전달하고,
  /// 아니면 새 원소 하나를 스캔해 전달한다.
  private static func continueArray(
    lexer: inout COSLexer, stack: inout [ContainerFrame], currentDepth: inout Int
  ) throws(COSParseError) -> COSObject? {
    let checkpoint = lexer
    guard let scanned = try lexer.nextToken() else {
      throw COSParseError(code: .unexpectedEndOfFile, offset: lexer.offset)
    }
    if case .arrayClose = scanned.token {
      guard case let .array(elements) = stack.removeLast() else {
        return nil
      }
      currentDepth -= 1
      return Self.deliver(.array(elements), into: &stack)
    }
    lexer = checkpoint
    guard let value = try Self.scanValueStart(
      lexer: &lexer, stack: &stack, currentDepth: &currentDepth
    ) else {
      return nil
    }
    return Self.deliver(value, into: &stack)
  }

  /// 스택 최상단이 "키 대기" 딕셔너리일 때 한 걸음 진행한다: `>>`면 완결해 부모에
  /// 전달하고, name이면 "값 대기"로 전이한다. 그 외 토큰은 `unexpectedToken`.
  private static func continueDictionaryKey(
    lexer: inout COSLexer, stack: inout [ContainerFrame], currentDepth: inout Int
  ) throws(COSParseError) -> COSObject? {
    guard let scanned = try lexer.nextToken() else {
      throw COSParseError(code: .unexpectedEndOfFile, offset: lexer.offset)
    }
    if case .dictionaryClose = scanned.token {
      guard case let .dictionary(dictionary, _) = stack.removeLast() else {
        return nil
      }
      currentDepth -= 1
      return Self.deliver(.dictionary(dictionary), into: &stack)
    }
    guard case let .name(key) = scanned.token else {
      throw COSParseError(code: .unexpectedToken, offset: scanned.range.lowerBound)
    }
    guard case let .dictionary(dictionary, _) = stack[stack.count - 1] else {
      return nil
    }
    stack[stack.count - 1] = .dictionary(dictionary, pendingKey: key)
    return nil
  }

  /// 스택 최상단이 "값 대기" 딕셔너리일 때 한 걸음 진행한다: 값을 스캔해 전달한다.
  private static func continueDictionaryValue(
    lexer: inout COSLexer, stack: inout [ContainerFrame], currentDepth: inout Int
  ) throws(COSParseError) -> COSObject? {
    guard let value = try Self.scanValueStart(
      lexer: &lexer, stack: &stack, currentDepth: &currentDepth
    ) else {
      return nil
    }
    return Self.deliver(value, into: &stack)
  }

  /// 완결된 값을 부모 프레임에 병합한다. 스택이 비어 있으면 이 값이 최종 결과다.
  ///
  /// null 값 엔트리는 저장을 생략하고, 중복 키는 마지막 값이 승리한다.
  private static func deliver(
    _ value: COSObject, into stack: inout [ContainerFrame]
  ) -> COSObject? {
    guard !stack.isEmpty else {
      return value
    }
    let topIndex = stack.count - 1
    switch stack[topIndex] {
    case var .array(elements):
      elements.append(value)
      stack[topIndex] = .array(elements)
    case let .dictionary(dictionary, pendingKey: .some(key)):
      var updated = dictionary
      if !value.isNull {
        updated[key] = value
      }
      stack[topIndex] = .dictionary(updated, pendingKey: nil)
    case .dictionary(_, pendingKey: nil):
      // 도달 불가능한 상태다 — 호출부는 pendingKey가 설정된 딕셔너리에만 값을 전달한다.
      // 그래도 "크래시 금지" 원칙에 따라 트랩 대신 조용히 무시하고 진행한다.
      break
    }
    return nil
  }

  /// `N` 정수를 읽은 뒤 `G R` 2토큰 lookahead로 참조 여부를 판별한다.
  ///
  /// 실패하면(패턴 불일치·렉싱 에러 모두) 렉서를 원상 복구하고 평범한 정수를 반환한다.
  private static func parseIntegerOrReference(number: Int, lexer: inout COSLexer) -> COSObject {
    let checkpoint = lexer
    let generationToken = try? lexer.nextToken()
    let keywordToken = try? lexer.nextToken()
    if let generationToken, case let .integer(generation) = generationToken.token,
      let keywordToken, case .keyword(.r) = keywordToken.token,
      number > 0, (0...65_535).contains(generation) {
      return .reference(ObjectID(number: number, generation: generation))
    }
    lexer = checkpoint
    return .integer(number)
  }
}
