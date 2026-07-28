import CoreGraphics
import PapyrusPDFCore
import PapyrusPDFUI
import Testing

/// ``ReaderSelectablePageStore``를 검증한다 (설계 §6-1).
@MainActor
struct SelectablePageStoreTests {
  /// 간단한 1-run 텍스트 콘텐츠를 만든다.
  private static func makeContent(pageIndex: Int, text: String = "Hello") -> PageTextContent {
    let run = TextRun.uniform(
      range: 0..<text.utf16.count,
      quad: Quad(
        bottomLeft: CGPoint(x: 0, y: 10), bottomRight: CGPoint(x: 50, y: 10),
        topRight: CGPoint(x: 50, y: 0), topLeft: CGPoint(x: 0, y: 0)
      )
    )
    return PageTextContent(pageIndex: pageIndex, string: text, runs: [run])
  }

  private static func makeStore(
    provider: any PageTextProvider
  ) -> ReaderSelectablePageStore {
    ReaderSelectablePageStore(provider: provider, displayTransform: { _ in .identity })
  }

  // MARK: 캐시 히트/미스, 도착 콜백

  @Test func requestPageLoadsAndFiresOnContentReady() async throws {
    let provider = DictionaryTextProvider(contents: [0: Self.makeContent(pageIndex: 0)])
    let store = Self.makeStore(provider: provider)
    var readyPages: [Int] = []
    store.onContentReady = { readyPages.append($0) }

    #expect(store.geometry(forPage: 0) == nil)
    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }

    #expect(readyPages == [0])
    #expect(store.geometry(forPage: 0)?.isEmpty == false)
  }

  // MARK: 중복 요청 dedupe

  @Test func requestPageDedupesConcurrentRequests() async throws {
    let gated = GatedTextProvider(contents: [0: Self.makeContent(pageIndex: 0)])
    let store = Self.makeStore(provider: gated)
    var readyCount = 0
    store.onContentReady = { _ in readyCount += 1 }

    store.requestPage(0)
    store.requestPage(0) // 중복 — 두 번째 호출은 무시되어야 한다.
    gated.open(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }

    #expect(readyCount == 1)
  }

  // MARK: prefetch 창 퇴거 + 보호 집합 생존

  @Test func prefetchEvictsOutsideWindowButKeepsProtected() async throws {
    let provider = DictionaryTextProvider(contents: [
      0: Self.makeContent(pageIndex: 0), 1: Self.makeContent(pageIndex: 1),
      2: Self.makeContent(pageIndex: 2), 3: Self.makeContent(pageIndex: 3)
    ])
    let store = Self.makeStore(provider: provider)
    store.prefetch(range: 0..<4, protecting: [])
    try await UITestSupport.waitUntil { store.geometry(forPage: 3) != nil }

    // 새 창은 1..<3, 페이지 0은 보호 집합에 있으므로 생존, 3은 보호 밖이라 퇴거.
    store.prefetch(range: 1..<3, protecting: [0])

    #expect(store.geometry(forPage: 0) != nil) // 보호됨.
    #expect(store.geometry(forPage: 1) != nil) // 창 안.
    #expect(store.geometry(forPage: 2) != nil) // 창 안.
    #expect(store.geometry(forPage: 3) == nil) // 퇴거됨.
  }

  // MARK: 인플라이트 퇴거 취소

  @Test func prefetchCancelsInFlightRequestOutsideWindow() async throws {
    let gated = GatedTextProvider(contents: [5: Self.makeContent(pageIndex: 5)])
    let store = Self.makeStore(provider: gated)
    var readyCount = 0
    store.onContentReady = { _ in readyCount += 1 }

    store.requestPage(5) // 인플라이트 시작(게이트로 대기).
    store.prefetch(range: 0..<2, protecting: []) // 5는 창·보호 밖 — 인플라이트 취소.
    gated.open(5) // 게이트 해제 — 취소된 요청이 캐시에 기록되면 안 된다.

    // 취소가 반영될 시간을 준다 (부정 조건이라 폴링 대신 짧은 유예 후 검사).
    try await Task.sleep(for: .milliseconds(50))
    #expect(store.geometry(forPage: 5) == nil)
    #expect(readyCount == 0)
  }

  // MARK: invalidateAll 후 게이트 해제 — 캐시 미기록·콜백 미발화 (세대 가드)

  @Test func invalidateAllDiscardsLateArrivingLoad() async throws {
    let gated = GatedTextProvider(contents: [0: Self.makeContent(pageIndex: 0)])
    let store = Self.makeStore(provider: gated)
    var readyCount = 0
    store.onContentReady = { _ in readyCount += 1 }

    store.requestPage(0)
    store.invalidateAll()
    gated.open(0)
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.geometry(forPage: 0) == nil)
    #expect(readyCount == 0)
  }

  // MARK: throw 페이지 → 빈 지오메트리 캐시

  @Test func throwingPageCachesAsEmptyGeometry() async throws {
    let provider = DictionaryTextProvider(contents: [:], throwingPages: [0])
    let store = Self.makeStore(provider: provider)

    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }

    #expect(store.geometry(forPage: 0)?.isEmpty == true)
  }

  // MARK: pageString 캐시 우선 · 미스 직행

  @Test func pageStringPrefersCacheThenFallsBackToProvider() async throws {
    let provider = DictionaryTextProvider(contents: [
      0: Self.makeContent(pageIndex: 0, text: "Cached"),
      1: Self.makeContent(pageIndex: 1, text: "Direct")
    ])
    let store = Self.makeStore(provider: provider)
    store.requestPage(0)
    try await UITestSupport.waitUntil { store.geometry(forPage: 0) != nil }

    let cachedString = await store.pageString(forPage: 0)
    let directString = await store.pageString(forPage: 1)
    let missingString = await store.pageString(forPage: 99)

    #expect(cachedString == "Cached")
    #expect(directString == "Direct")
    #expect(store.geometry(forPage: 1) == nil) // pageString은 캐시에 넣지 않는다.
    #expect(missingString == "") // 실패 페이지는 빈 문자열.
  }
}
