import CoreGraphics
import Foundation
import PapyrusPDFCore
@testable import PapyrusPDFUI
import Testing

/// `Highlight`/`HighlightColor`의 `Codable` 왕복과 JSON 합성 키 계약(설계 §5-1)을 검증한다.
struct HighlightCodableTests {
  /// 음수 좌표를 포함한 결정적 테스트 quad.
  private static func quad() -> Quad {
    Quad(
      bottomLeft: CGPoint(x: -10, y: 20), bottomRight: CGPoint(x: 30, y: 20),
      topRight: CGPoint(x: 30, y: -5), topLeft: CGPoint(x: -10, y: -5)
    )
  }

  // MARK: 왕복 — HighlightColor

  @Test func highlightColorRoundTripsThroughJSON() throws {
    let color = HighlightColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
    let data = try JSONEncoder().encode(color)
    let decoded = try JSONDecoder().decode(HighlightColor.self, from: data)
    #expect(decoded == color)
  }

  // MARK: 왕복 — Highlight (range 있음/없음)

  @Test func highlightWithRangeRoundTripsThroughJSON() throws {
    let highlight = Highlight(
      id: "h1", pageIndex: 3, quads: [Self.quad()], color: .yellow, range: 10..<24
    )
    let data = try JSONEncoder().encode(highlight)
    let decoded = try JSONDecoder().decode(Highlight.self, from: data)
    #expect(decoded == highlight)
  }

  @Test func highlightWithoutRangeRoundTripsThroughJSON() throws {
    let highlight = Highlight(id: "h2", pageIndex: 0, quads: [Self.quad()], color: .green)
    let data = try JSONEncoder().encode(highlight)
    let decoded = try JSONDecoder().decode(Highlight.self, from: data)
    #expect(decoded == highlight)
    #expect(decoded.range == nil)
  }

  // MARK: 합성 키 계약 고정 — 손으로 쓴 JSON 리터럴 디코드

  @Test func decodesHandWrittenLiteralJSONWithRange() throws {
    let json = """
    {
      "id": "abc",
      "pageIndex": 3,
      "quads": [
        {
          "bottomLeft": [-10, 20],
          "bottomRight": [30, 20],
          "topRight": [30, -5],
          "topLeft": [-10, -5]
        }
      ],
      "color": {"red": 1, "green": 0.9, "blue": 0.2, "alpha": 0.4},
      "range": [10, 24]
    }
    """
    let decoded = try JSONDecoder().decode(Highlight.self, from: Data(json.utf8))
    #expect(decoded.id == "abc")
    #expect(decoded.pageIndex == 3)
    #expect(decoded.quads == [Self.quad()])
    #expect(decoded.color == HighlightColor.yellow)
    #expect(decoded.range == 10..<24)
  }

  @Test func decodesHandWrittenLiteralJSONWithoutRangeKey() throws {
    let json = """
    {
      "id": "abc",
      "pageIndex": 0,
      "quads": [],
      "color": {"red": 0, "green": 0, "blue": 0, "alpha": 0}
    }
    """
    let decoded = try JSONDecoder().decode(Highlight.self, from: Data(json.utf8))
    #expect(decoded.range == nil)
  }

  @Test func encodingOmitsRangeKeyWhenNil() throws {
    let highlight = Highlight(id: "h3", pageIndex: 0, quads: [], color: .blue)
    let data = try JSONEncoder().encode(highlight)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["range"] == nil)
  }

  // MARK: 프리셋 5종 왕복

  @Test func allColorPresetsRoundTripThroughJSON() throws {
    let presets: [HighlightColor] = [.yellow, .green, .blue, .pink, .orange]
    for preset in presets {
      let data = try JSONEncoder().encode(preset)
      let decoded = try JSONDecoder().decode(HighlightColor.self, from: data)
      #expect(decoded == preset)
    }
  }
}
