import CoreGraphics
import Foundation
@testable import PapyrusUI
import Testing

/// ``ReaderPosition`` Codable 왕복과 모델 보류 명령 재생을 검증한다 (설계 §6 RP1).
@MainActor
struct ReaderPositionTests {
  /// RP1 (a): `ReaderPosition`은 JSON 인코딩·디코딩을 왕복해도 동일하다.
  @Test func codableRoundTripsExactly() throws {
    let position = ReaderPosition(pageIndex: 42, normalizedOffset: 0.37, zoomScale: 2.5)
    let data = try JSONEncoder().encode(position)
    let decoded = try JSONDecoder().decode(ReaderPosition.self, from: data)
    #expect(decoded == position)
  }

  /// RP1 (b): 연결 전 `goToPage` 호출은 보류되고, `attach(core:)` 직후 1회 재생된다.
  @Test func pendingGoToPageReplaysExactlyOnceAfterAttach() async throws {
    let model = PapyrusReaderModel()
    #expect(model.loadState == .loading)

    // 연결 전 호출 — 코어가 없으므로 보류된다.
    model.goToPage(6, animated: false)

    let core = try await UITestSupport.makeReaderCore(
      pageCount: 10, pageWidth: 200, pageHeight: 200
    )
    let host = MockScrollHost()
    host.viewportSize = CGSize(width: 300, height: 300)
    host.visibleContentRect = CGRect(x: 0, y: 0, width: 300, height: 300)
    core.attach(to: host)
    host.scrollToCalls.removeAll() // attach 자체의 초기 scrollTo는 배제하고 관찰.

    model.attach(core: core)

    #expect(model.loadState == .ready)
    #expect(model.pageCount == 10)
    let frame = try #require(core.layout.pageFrame(at: 6))
    let call = try #require(host.scrollToCalls.last)
    #expect(abs(call.contentY - max(0, frame.minY - ReaderLayoutMetrics.pageSpacing / 2)) < 0.001)

    // 재생은 1회만 — 재차 연결해도 같은 명령이 다시 재생되지 않는다.
    let callCountAfterFirstAttach = host.scrollToCalls.count
    model.attach(core: core)
    #expect(host.scrollToCalls.count == callCountAfterFirstAttach)
  }
}
