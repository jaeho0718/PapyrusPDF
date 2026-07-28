import CoreGraphics
import Foundation

/// 콘텐츠 스트림 해석기. 순수 동기 함수 — 액터 상태·I/O에 접근하지 않는다.
package enum ContentStreamInterpreter {
  /// 페이지 입력을 해석해 원시 run 목록을 만든다. throw하지 않는다 —
  /// 모든 이상 입력은 무시·스킵으로 흡수한다 (손상 PDF 무크래시 불변식).
  /// - Parameter input: 사전 해소된 페이지 추출 입력.
  /// - Returns: 방출 순서의 원시 run 목록.
  package static func run(_ input: PageExtractionInput) -> [RawGlyphRun] {
    let context = InterpreterContext()
    let joined = Self.joinSegments(input.contentSegments)
    Self.execute(data: joined, resources: input.resources, context: context, depth: 0)
    return context.runs
  }

  /// 세그먼트를 공백 1바이트로 이어붙인다 (§3.1). 총량 상한 초과 세그먼트는 절단.
  private static func joinSegments(_ segments: [Data]) -> Data {
    guard !segments.isEmpty else {
      return Data()
    }
    var result = Data()
    var remainingBudget = CoreLimits.maxContentBytesPerPage
    for (index, segment) in segments.enumerated() {
      guard remainingBudget > 0 else {
        break
      }
      if index > 0 {
        result.append(0x20)
      }
      let allowed = min(segment.count, remainingBudget)
      result.append(segment.prefix(allowed))
      remainingBudget -= allowed
    }
    return result
  }
}

// MARK: - 인터프리터 상태

/// 텍스트 상태(Tc/Tw/Tz/TL/Ts/Tr + 현재 폰트/크기).
struct TextState {
  var font: LoadedFont?
  var fontSize: CGFloat = 0
  var charSpacing: CGFloat = 0
  var wordSpacing: CGFloat = 0
  var horizontalScale: CGFloat = 1
  var leading: CGFloat = 0
  var rise: CGFloat = 0
  var renderMode: Int = 0
}

/// 그래픽 상태(q/Q 스택 원소) — CTM + 텍스트 상태.
struct GraphicsState {
  var ctm: CGAffineTransform = .identity
  var text = TextState()
}

/// 해석 1회(`run(_:)` 호출 1건, 폼 재귀 포함) 동안 공유되는 가변 문맥.
///
/// 참조 타입 — 재귀(`Do`)와 헬퍼 함수 사이에 `inout` 매개변수를 뿌리지 않기 위함이다.
/// 순수히 `run(_:)` 실행 중에만 생존하며 외부로 탈출하지 않으므로 Sendable 불요.
/// 파일 분리(`ContentStreamInterpreter+Operators.swift`,
/// `ContentStreamInterpreter+ShowText.swift`)를 위해 `internal`로 노출한다.
final class InterpreterContext {
  var stateStack: [GraphicsState] = []
  var state = GraphicsState()
  var tm: CGAffineTransform = .identity
  var tlm: CGAffineTransform = .identity
  var runs: [RawGlyphRun] = []
  var glyphCount = 0
  var glyphCapReached = false
}

// MARK: - 실행 루프 (연산자 디스패치)

extension ContentStreamInterpreter {
  /// 콘텐츠 바이트 하나를 처음부터 끝까지 해석한다 (폼 XObject는 재귀 호출 — 깊이 캡 16).
  static func execute(
    data: Data, resources: ResolvedResources, context: InterpreterContext, depth: Int
  ) {
    var scanner = ContentStreamScanner(data: data)
    var operands: [COSObject] = []

    while let element = scanner.next() {
      switch element {
      case let .operand(value):
        operands.append(value)
        if operands.count > CoreLimits.maxContentOperands {
          operands.removeFirst()
        }
      case let .operator(op):
        if op == "BI" {
          scanner.skipInlineImage()
        } else {
          Self.perform(
            op, operands: operands, resources: resources, context: context, depth: depth
          )
        }
        operands.removeAll(keepingCapacity: true)
      }
      if context.glyphCapReached {
        return
      }
    }
  }
}
