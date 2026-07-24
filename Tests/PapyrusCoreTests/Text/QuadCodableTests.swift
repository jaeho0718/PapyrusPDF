import CoreGraphics
import Foundation
@testable import PapyrusCore
import Testing

/// ``Quad``의 합성 `Codable` 인코딩 형식·왕복을 검증한다 (설계 §0.3 가정 2 — 신규 공개
/// conformance 커버리지 공백 보완, 리뷰 S2).
struct QuadCodableTests {
  /// 왕복(encode→decode)이 원본과 동일한 값을 복원하는지 검증한다.
  @Test func codableRoundTripsAllVertices() throws {
    let quad = Quad(
      bottomLeft: CGPoint(x: 1, y: 2), bottomRight: CGPoint(x: 3, y: 4),
      topRight: CGPoint(x: 5, y: 6), topLeft: CGPoint(x: 7, y: 8)
    )
    let data = try JSONEncoder().encode(quad)
    let decoded = try JSONDecoder().decode(Quad.self, from: data)
    #expect(decoded == quad)
  }

  /// 인코딩 결과가 설계 §0.3 가정 2에 명시된 형식(`{"bottomLeft": [x, y], …}` — 꼭짓점 키
  /// + 좌표 `[x, y]` 2원소 배열)과 일치하는지 검증한다. `CGPoint`의 합성 Codable이 unkeyed
  /// `[x, y]` 배열로 인코딩되는 데 의존하므로, 이 형식이 조용히 바뀌는 회귀를 잡는다.
  @Test func encodedFormatMatchesDesignDocumentedShape() throws {
    let quad = Quad(
      bottomLeft: CGPoint(x: 1, y: 2), bottomRight: CGPoint(x: 3, y: 4),
      topRight: CGPoint(x: 5, y: 6), topLeft: CGPoint(x: 7, y: 8)
    )
    let data = try JSONEncoder().encode(quad)
    let rawObject = try JSONSerialization.jsonObject(with: data)
    let object = try #require(rawObject as? [String: Any])

    #expect(Set(object.keys) == Set(["bottomLeft", "bottomRight", "topRight", "topLeft"]))

    let vertices: [(key: String, point: CGPoint)] = [
      ("bottomLeft", quad.bottomLeft), ("bottomRight", quad.bottomRight),
      ("topRight", quad.topRight), ("topLeft", quad.topLeft)
    ]
    for vertex in vertices {
      let array = try #require(object[vertex.key] as? [Double])
      #expect(array == [Double(vertex.point.x), Double(vertex.point.y)])
    }
  }
}
