import CoreGraphics

// `ContentStreamInterpreter`의 showText/TJ + 지오메트리(§3.5). 파일 분리는 순수 조직적
// 이유(파일 길이 제한)이며, `ContentStreamInterpreter.swift`와 동일한 타입·의미를 다룬다.

extension ContentStreamInterpreter {
  static func showTJ(_ elements: [COSObject], context: InterpreterContext) {
    for element in elements {
      if context.glyphCapReached {
        return
      }
      switch element {
      case let .string(bytes):
        Self.showText(bytes, context: context)
      default:
        guard let numberValue = element.realValue else {
          continue
        }
        Self.applyTJOffset(CGFloat(numberValue), context: context)
      }
    }
  }

  private static func applyTJOffset(_ value: CGFloat, context: InterpreterContext) {
    let fontSize = context.state.text.fontSize
    let isVertical = context.state.text.font.map { Self.isVerticalLayout($0.layout) } ?? false
    let delta = -value / 1_000 * fontSize
    if isVertical {
      context.tm = CGAffineTransform(translationX: 0, y: delta).concatenating(context.tm)
    } else {
      let scaled = delta * context.state.text.horizontalScale
      context.tm = CGAffineTransform(translationX: scaled, y: 0).concatenating(context.tm)
    }
  }

  /// 문자열 오퍼랜드 하나를 run 1개로 방출한다 (§3.5).
  static func showText(_ bytes: [UInt8], context: InterpreterContext) {
    guard !context.glyphCapReached else {
      return
    }
    let textState = context.state.text
    let font = textState.font ?? FontLoader.fallbackFont()
    let isVertical = Self.isVerticalLayout(font.layout)
    let fontSize = textState.fontSize

    let trm0 = CGAffineTransform(
      a: fontSize * textState.horizontalScale, b: 0, c: 0, d: fontSize, tx: 0, ty: textState.rise
    ).concatenating(context.tm).concatenating(context.state.ctm)
    // Tm × CTM (Tfs/Th/rise 리딩 행렬 제외) — tx/ty(전진량)는 스펙 공식상 이미 Tfs·Th가
    // 반영된 "Tm 공간" 수치이므로, 이 값을 그대로 변환하는 데는 trm0(Tfs·Th 중복 포함)가
    // 아니라 이 행렬을 써야 이중 스케일링을 피한다.
    let tmCtm = context.tm.concatenating(context.state.ctm)

    guard Self.isFiniteTransform(trm0), Self.isFiniteTransform(tmCtm) else {
      return
    }

    let advance = Self.advanceGlyphs(bytes, font: font, isVertical: isVertical, context: context)
    context.tm = advance.updatedTm
    guard !advance.utf16.isEmpty else {
      return
    }

    let quadParameters = RunQuadParameters(
      font: font, fontSize: fontSize, rise: textState.rise,
      textSpaceAdvance: advance.textSpaceAdvance, isVertical: isVertical, tmCtm: tmCtm
    )
    guard let quad = Self.runQuad(quadParameters) else {
      return
    }

    let baselineDirection = Self.normalizedDirection(trm0, isVertical: isVertical)
    let effectiveFontSize = max(hypot(trm0.a, trm0.b), hypot(trm0.c, trm0.d))
    let isInvisible = textState.renderMode == 3 || textState.renderMode == 7

    context.runs.append(RawGlyphRun(
      utf16: advance.utf16, advances: advance.advances, quad: quad,
      origin: CGPoint(x: trm0.tx, y: trm0.ty), baselineDirection: baselineDirection,
      effectiveFontSize: effectiveFontSize, isInvisible: isInvisible, isVertical: isVertical
    ))
  }

  /// 코드별 글리프 전진 루프의 결과 (utf16/advances 누적 + 갱신된 tm).
  private struct GlyphAdvanceResult {
    var utf16: [UInt16]
    var advances: [CGFloat]
    var textSpaceAdvance: CGFloat
    var updatedTm: CGAffineTransform
  }

  /// 코드 시퀀스를 순회하며 utf16/advances를 누적하고 tm을 전진시킨다 (글리프 캡 준수).
  private static func advanceGlyphs(
    _ bytes: [UInt8], font: LoadedFont, isVertical: Bool, context: InterpreterContext
  ) -> GlyphAdvanceResult {
    let textState = context.state.text
    let fontSize = textState.fontSize
    let codes = font.decodeCodes(bytes)
    var utf16: [UInt16] = []
    var advances: [CGFloat] = []
    var textSpaceAdvance: CGFloat = 0
    var currentTm = context.tm
    let tmCtm = context.tm.concatenating(context.state.ctm)

    for code in codes {
      guard context.glyphCount < CoreLimits.maxGlyphsPerPage else {
        context.glyphCapReached = true
        break
      }
      context.glyphCount += 1

      let unicodeString = font.unicode(for: code)
      let unicodeUnits = unicodeString.isEmpty ? [UInt16(0xFFFD)] : Array(unicodeString.utf16)
      let width0 = font.width(for: code) / 1_000

      let tx: CGFloat
      let ty: CGFloat
      if isVertical {
        tx = 0
        ty = -(1.0 * fontSize + textState.charSpacing)
      } else {
        let wordSpacing = (code.byteLength == 1 && code.value == 32) ? textState.wordSpacing : 0
        tx = (width0 * fontSize + textState.charSpacing + wordSpacing) * textState.horizontalScale
        ty = 0
      }

      let dxPage = tx * tmCtm.a + ty * tmCtm.c
      let dyPage = tx * tmCtm.b + ty * tmCtm.d
      let advanceLength = (dxPage * dxPage + dyPage * dyPage).squareRoot()

      utf16.append(contentsOf: unicodeUnits)
      advances.append(advanceLength)
      if unicodeUnits.count > 1 {
        advances.append(contentsOf: repeatElement(0, count: unicodeUnits.count - 1))
      }

      textSpaceAdvance += isVertical ? ty : tx
      let step = CGAffineTransform(translationX: isVertical ? 0 : tx, y: isVertical ? ty : 0)
      currentTm = step.concatenating(currentTm)
    }

    return GlyphAdvanceResult(
      utf16: utf16, advances: advances, textSpaceAdvance: textSpaceAdvance, updatedTm: currentTm
    )
  }

  /// ``runQuad(_:)`` 입력 묶음 (매개변수 수 관리용).
  private struct RunQuadParameters {
    let font: LoadedFont
    let fontSize: CGFloat
    let rise: CGFloat
    let textSpaceAdvance: CGFloat
    let isVertical: Bool
    let tmCtm: CGAffineTransform
  }

  /// run의 ascent/descent 박스를 `tmCtm`(Tm×CTM, 리딩 행렬 제외) 기준 페이지 공간
  /// 사변형으로 변환한다. ascent/descent는 이미 폰트 크기가 반영된 값이므로 `rise`만
  /// 별도로 더한다(리딩 행렬의 rise는 스케일되지 않은 채 더해지는 성분이라 §3.5 근거).
  /// NaN/무한대 좌표가 나오면 `nil` (호출부가 run을 폐기).
  private static func runQuad(_ parameters: RunQuadParameters) -> Quad? {
    let ascentY = parameters.font.ascent / 1_000 * parameters.fontSize + parameters.rise
    let descentY = parameters.font.descent / 1_000 * parameters.fontSize + parameters.rise
    let bottomLeft: CGPoint
    let bottomRight: CGPoint
    let topRight: CGPoint
    let topLeft: CGPoint
    if parameters.isVertical {
      bottomLeft = CGPoint(x: descentY, y: 0)
      bottomRight = CGPoint(x: ascentY, y: 0)
      topRight = CGPoint(x: ascentY, y: parameters.textSpaceAdvance)
      topLeft = CGPoint(x: descentY, y: parameters.textSpaceAdvance)
    } else {
      bottomLeft = CGPoint(x: 0, y: descentY)
      bottomRight = CGPoint(x: parameters.textSpaceAdvance, y: descentY)
      topRight = CGPoint(x: parameters.textSpaceAdvance, y: ascentY)
      topLeft = CGPoint(x: 0, y: ascentY)
    }
    let tmCtm = parameters.tmCtm
    let quad = Quad(
      bottomLeft: bottomLeft.applying(tmCtm), bottomRight: bottomRight.applying(tmCtm),
      topRight: topRight.applying(tmCtm), topLeft: topLeft.applying(tmCtm)
    )
    guard Self.isFiniteQuad(quad) else {
      return nil
    }
    return quad
  }

  static func isVerticalLayout(_ layout: LoadedFont.CodeLayout) -> Bool {
    switch layout {
    case .simple:
      return false
    case let .identity(vertical):
      return vertical
    case let .embeddedCMap(_, vertical):
      return vertical
    case let .unsupportedPredefined(vertical):
      return vertical
    }
  }

  /// 읽기 진행 방향의 페이지 공간 단위벡터. 수평은 텍스트공간 (1,0), 수직은 진행 방향인
  /// (0,-1)(아래로 진행)의 상을 `trm`의 선형부로 변환해 정규화한다.
  private static func normalizedDirection(
    _ trm: CGAffineTransform, isVertical: Bool
  ) -> CGVector {
    let vector = isVertical
      ? CGVector(dx: -trm.c, dy: -trm.d) : CGVector(dx: trm.a, dy: trm.b)
    let length = hypot(vector.dx, vector.dy)
    guard length > 0.000_1 else {
      return CGVector(dx: 1, dy: 0)
    }
    return CGVector(dx: vector.dx / length, dy: vector.dy / length)
  }

  private static func isFiniteTransform(_ transform: CGAffineTransform) -> Bool {
    transform.a.isFinite && transform.b.isFinite && transform.c.isFinite
      && transform.d.isFinite && transform.tx.isFinite && transform.ty.isFinite
  }

  private static func isFiniteQuad(_ quad: Quad) -> Bool {
    [quad.bottomLeft, quad.bottomRight, quad.topRight, quad.topLeft].allSatisfy {
      $0.x.isFinite && $0.y.isFinite
    }
  }
}
