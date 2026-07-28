import CoreGraphics

// `ContentStreamInterpreter`의 연산자 디스패치. 파일 분리는 순수 조직적 이유(파일 길이 제한
// + `perform`의 순환 복잡도 관리 — 카테고리별 소함수로 나눠 각각 SwiftLint 임계값 아래로
// 유지한다)이며, `ContentStreamInterpreter.swift`와 동일한 타입·의미를 다룬다.

extension ContentStreamInterpreter {
  /// 연산자 하나를 오퍼랜드와 함께 실행한다 (§3.4). 미지 연산자·타입 불일치는 무시.
  ///
  /// 카테고리별 소함수로 나눠 순차 위임한다 — 앞선 카테고리가 처리하면 이후는 건너뛴다.
  static func perform(
    _ op: String, operands: [COSObject], resources: ResolvedResources,
    context: InterpreterContext, depth: Int
  ) {
    let handledStructural = Self.performStructural(
      op, operands: operands, resources: resources, context: context, depth: depth
    )
    if handledStructural {
      return
    }
    if Self.performTextPositioning(op, operands: operands, context: context) {
      return
    }
    if Self.performTextState(op, operands: operands, context: context) {
      return
    }
    _ = Self.performTextShowing(op, operands: operands, resources: resources, context: context)
  }

  /// 그래픽 상태·구조 연산자: `q`/`Q`/`cm`/`BT`/`ET`/`Do`.
  ///
  /// 각 케이스 본문을 소함수로 위임한다 — switch 자체의 분기 수만 순환 복잡도에
  /// 반영되도록 해 SwiftLint 임계값(10) 아래로 유지한다.
  private static func performStructural(
    _ op: String, operands: [COSObject], resources: ResolvedResources,
    context: InterpreterContext, depth: Int
  ) -> Bool {
    switch op {
    case "q":
      Self.pushGraphicsState(context: context)
    case "Q":
      Self.popGraphicsState(context: context)
    case "cm":
      Self.applyCM(operands, context: context)
    case "BT":
      context.tm = .identity
      context.tlm = .identity
    case "ET":
      break
    case "Do":
      Self.applyDo(operands, resources: resources, context: context, depth: depth)
    default:
      return false
    }
    return true
  }

  private static func pushGraphicsState(context: InterpreterContext) {
    guard context.stateStack.count < CoreLimits.maxGraphicsStateDepth else {
      return
    }
    context.stateStack.append(context.state)
  }

  private static func popGraphicsState(context: InterpreterContext) {
    guard let popped = context.stateStack.popLast() else {
      return
    }
    context.state = popped
  }

  private static func applyCM(_ operands: [COSObject], context: InterpreterContext) {
    guard let matrix = Self.matrix(from: operands) else {
      return
    }
    context.state.ctm = matrix.concatenating(context.state.ctm)
  }

  private static func applyDo(
    _ operands: [COSObject], resources: ResolvedResources, context: InterpreterContext, depth: Int
  ) {
    guard case let .name(name) = operands.last else {
      return
    }
    Self.performDo(name, resources: resources, context: context, depth: depth)
  }

  /// 텍스트 위치 연산자: `Td`/`TD`/`Tm`/`T*`.
  private static func performTextPositioning(
    _ op: String, operands: [COSObject], context: InterpreterContext
  ) -> Bool {
    switch op {
    case "Td":
      Self.applyTd(operands, context: context)
    case "TD":
      Self.applyTD(operands, context: context)
    case "Tm":
      Self.applyTm(operands, context: context)
    case "T*":
      Self.applyTStar(context: context)
    default:
      return false
    }
    return true
  }

  /// 텍스트 상태 수치 연산자: `Tc`/`Tw`/`Tz`/`TL`/`Ts`/`Tr`. 전부 "마지막 오퍼랜드 숫자
  /// 하나를 상태 필드에 반영"하는 동일 패턴이라, 케이스별 setter 클로저 테이블로 위임해
  /// switch 자체의 분기만 순환 복잡도에 반영되게 한다.
  private static func performTextState(
    _ op: String, operands: [COSObject], context: InterpreterContext
  ) -> Bool {
    guard let setter = Self.textStateSetter(for: op) else {
      return false
    }
    if let value = operands.last?.realValue {
      setter(context, CGFloat(value))
    }
    return true
  }

  private static func textStateSetter(
    for op: String
  ) -> ((InterpreterContext, CGFloat) -> Void)? {
    switch op {
    case "Tc":
      return { $0.state.text.charSpacing = $1 }
    case "Tw":
      return { $0.state.text.wordSpacing = $1 }
    case "Tz":
      return { $0.state.text.horizontalScale = $1 / 100 }
    case "TL":
      return { $0.state.text.leading = $1 }
    case "Ts":
      return { $0.state.text.rise = $1 }
    case "Tr":
      return { $0.state.text.renderMode = max(0, min(7, Int($1))) }
    default:
      return nil
    }
  }

  /// 텍스트 표시 연산자: `Tf`/`Tj`/`'`/`"`/`TJ`.
  private static func performTextShowing(
    _ op: String, operands: [COSObject], resources: ResolvedResources, context: InterpreterContext
  ) -> Bool {
    switch op {
    case "Tf":
      Self.applyTf(operands, resources: resources, context: context)
    case "Tj":
      if case let .string(bytes) = operands.last {
        Self.showText(bytes, context: context)
      }
    case "'":
      Self.applyTStar(context: context)
      if case let .string(bytes) = operands.last {
        Self.showText(bytes, context: context)
      }
    case "\"":
      Self.applyQuoteQuote(operands, context: context)
    case "TJ":
      if case let .array(elements) = operands.last {
        Self.showTJ(elements, context: context)
      }
    default:
      return false
    }
    return true
  }

  private static func applyQuoteQuote(_ operands: [COSObject], context: InterpreterContext) {
    if operands.count >= 3, let aw = operands[operands.count - 3].realValue,
      let ac = operands[operands.count - 2].realValue {
      context.state.text.wordSpacing = CGFloat(aw)
      context.state.text.charSpacing = CGFloat(ac)
    }
    Self.applyTStar(context: context)
    if case let .string(bytes) = operands.last {
      Self.showText(bytes, context: context)
    }
  }

  private static func performDo(
    _ name: COSName, resources: ResolvedResources, context: InterpreterContext, depth: Int
  ) {
    guard depth < CoreLimits.maxFormXObjectDepth, let form = resources.formXObjects[name],
      context.stateStack.count < CoreLimits.maxGraphicsStateDepth
    else {
      return
    }
    context.stateStack.append(context.state)
    context.state.ctm = form.matrix.concatenating(context.state.ctm)
    Self.execute(data: form.content, resources: form.resources, context: context, depth: depth + 1)
    if let restored = context.stateStack.popLast() {
      context.state = restored
    }
  }
}

// MARK: - 텍스트 위치 연산자 (Td/TD/Tm/T*/Tf)

extension ContentStreamInterpreter {
  static func matrix(from operands: [COSObject]) -> CGAffineTransform? {
    guard operands.count >= 6 else {
      return nil
    }
    let base = operands.count - 6
    guard let matrixA = operands[base].realValue, let matrixB = operands[base + 1].realValue,
      let matrixC = operands[base + 2].realValue, let matrixD = operands[base + 3].realValue,
      let matrixE = operands[base + 4].realValue, let matrixF = operands[base + 5].realValue
    else {
      return nil
    }
    return CGAffineTransform(
      a: CGFloat(matrixA), b: CGFloat(matrixB), c: CGFloat(matrixC), d: CGFloat(matrixD),
      tx: CGFloat(matrixE), ty: CGFloat(matrixF)
    )
  }

  private static func applyTd(_ operands: [COSObject], context: InterpreterContext) {
    guard operands.count >= 2, let tx = operands[operands.count - 2].realValue,
      let ty = operands[operands.count - 1].realValue
    else {
      return
    }
    let translation = CGAffineTransform(translationX: CGFloat(tx), y: CGFloat(ty))
    context.tlm = translation.concatenating(context.tlm)
    context.tm = context.tlm
  }

  private static func applyTD(_ operands: [COSObject], context: InterpreterContext) {
    guard let ty = operands.last?.realValue, operands.count >= 2 else {
      return
    }
    context.state.text.leading = -CGFloat(ty)
    Self.applyTd(operands, context: context)
  }

  private static func applyTm(_ operands: [COSObject], context: InterpreterContext) {
    guard let matrix = Self.matrix(from: operands) else {
      return
    }
    context.tm = matrix
    context.tlm = matrix
  }

  static func applyTStar(context: InterpreterContext) {
    let translation = CGAffineTransform(translationX: 0, y: -context.state.text.leading)
    context.tlm = translation.concatenating(context.tlm)
    context.tm = context.tlm
  }

  private static func applyTf(
    _ operands: [COSObject], resources: ResolvedResources, context: InterpreterContext
  ) {
    guard operands.count >= 2, case let .name(name) = operands[operands.count - 2],
      let size = operands[operands.count - 1].realValue
    else {
      return
    }
    context.state.text.font = resources.fonts[name] ?? FontLoader.fallbackFont()
    context.state.text.fontSize = CGFloat(size)
  }
}
