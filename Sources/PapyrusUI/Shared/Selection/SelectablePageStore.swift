import CoreGraphics
import PapyrusCore

/// 페이지 텍스트 콘텐츠 캐시 + prefetch + 세대 토큰.
///
/// `ReaderSearchCoordinator`와 동형의 `@MainActor` 클래스 — 문서 접근(프로바이더·변환)은
/// 여기서 끝나고 `ReaderCore`는 계속 문서를 모른다.
@MainActor
package final class ReaderSelectablePageStore {
  /// 페이지 콘텐츠가 캐시에 도착했다 (메인 액터 — 컨트롤러가 구독).
  package var onContentReady: ((Int) -> Void)?

  /// 텍스트 공급원.
  private let provider: any PageTextProvider

  /// 페이지 표시 변환 공급 클로저 (실패 시 `.identity` 반환 계약).
  private let displayTransform: @Sendable (Int) async -> CGAffineTransform

  /// 페이지별 캐시된 히트테스트 인덱스.
  private var cache: [Int: SelectionGeometry] = [:]

  /// 진행 중 로드 태스크 (페이지 인덱스 → 태스크).
  private var inFlight: [Int: Task<Void, Never>] = [:]

  /// 세대 토큰 — `invalidateAll`마다 증가. 구세대 도착을 폐기하는 데 쓴다.
  private var generation = 0

  /// 페이지별 표시 변환 memoize (세션 내 불변 — 재로드마다 재계산 방지).
  private var transformCache: [Int: CGAffineTransform] = [:]

  /// 스토어를 만든다.
  /// - Parameters:
  ///   - provider: 텍스트 공급원 (현재는 항상 `DocumentTextProvider` — 다른 공급원 주입은
  ///     향후 일반화될 확장점이다).
  ///   - displayTransform: 페이지 표시 변환 공급 클로저 (실패 시 `.identity` 반환 계약 —
  ///     테스트에서 문서 없이 주입 가능하도록 클로저로 둔다).
  package init(
    provider: any PageTextProvider,
    displayTransform: @escaping @Sendable (Int) async -> CGAffineTransform
  ) {
    self.provider = provider
    self.displayTransform = displayTransform
  }

  /// 동기 캐시 조회 (미보유 시 `nil` — 로드는 시작하지 않는다).
  /// - Parameter pageIndex: 조회할 페이지 인덱스.
  /// - Returns: 캐시된 히트테스트 인덱스, 미보유면 `nil`.
  package func geometry(forPage pageIndex: Int) -> SelectionGeometry? {
    self.cache[pageIndex]
  }

  /// 미보유·비인플라이트면 비동기 로드를 시작한다 (중복 요청 무시).
  /// - Parameter pageIndex: 로드할 페이지 인덱스.
  package func requestPage(_ pageIndex: Int) {
    guard self.cache[pageIndex] == nil, self.inFlight[pageIndex] == nil else {
      return
    }
    let generation = self.generation
    let provider = self.provider
    let transformProvider: @Sendable (Int) async -> CGAffineTransform
    if let cached = self.transformCache[pageIndex] {
      transformProvider = { _ in cached }
    } else {
      transformProvider = self.displayTransform
    }

    self.inFlight[pageIndex] = Task { [weak self] in
      let result = await Self.loadGeometry(
        page: pageIndex, provider: provider, transform: transformProvider
      )
      guard let self, !Task.isCancelled, self.generation == generation else {
        return
      }
      self.inFlight[pageIndex] = nil
      self.cache[pageIndex] = result.geometry
      self.transformCache[pageIndex] = result.transform
      self.onContentReady?(pageIndex)
    }
  }

  /// 캐시 창을 갱신한다: `range` 안의 미보유 페이지를 요청하고, `range ∪ protected`
  /// 밖의 캐시·인플라이트를 퇴거한다.
  /// - Parameters:
  ///   - range: 유지할 페이지 범위.
  ///   - protected: 범위 밖이어도 유지할 페이지 (드래그 중 앵커·포커스 페이지).
  package func prefetch(range: Range<Int>, protecting protected: Set<Int>) {
    for pageIndex in range where self.cache[pageIndex] == nil && self.inFlight[pageIndex] == nil {
      self.requestPage(pageIndex)
    }

    let keep = Set(range).union(protected)
    let staleCache = self.cache.keys.filter { !keep.contains($0) }
    for pageIndex in staleCache {
      self.cache.removeValue(forKey: pageIndex)
    }
    let staleInFlight = self.inFlight.keys.filter { !keep.contains($0) }
    for pageIndex in staleInFlight {
      self.inFlight[pageIndex]?.cancel()
      self.inFlight.removeValue(forKey: pageIndex)
    }
  }

  /// 페이지 문자열을 비동기로 얻는다 (캐시 우선, 미스면 프로바이더 직행 —
  /// 캐시에 넣지 않는다: 복사 경로의 일회성 소비가 창 정책을 어지럽히지 않게).
  /// 실패 페이지는 빈 문자열이다.
  /// - Parameter pageIndex: 조회할 페이지 인덱스.
  /// - Returns: 페이지 문자열 (실패 시 빈 문자열).
  package func pageString(forPage pageIndex: Int) async -> String {
    if let cached = self.cache[pageIndex] {
      return cached.content.string
    }
    return (try? await self.provider.textContent(forPage: pageIndex))?.string ?? ""
  }

  /// 페이지 표시 변환의 동기 조회 (memoize 캐시 전용 — 미보유면 `nil`, 로드는 시작하지
  /// 않는다). 변환 캐시는 창 퇴거 대상이 아니다 — 세션 수명 동안 단조 증가(페이지당
  /// 48바이트, 5,000페이지 240KB 유계). `invalidateAll`도 변환을 남긴다 — 변환은 문서
  /// 기하의 순수 함수라 세대와 무관하게 유효하기 때문이다.
  /// - Parameter pageIndex: 조회할 페이지 인덱스.
  /// - Returns: 캐시된 표시 변환, 미보유면 `nil`.
  package func displayTransform(forPage pageIndex: Int) -> CGAffineTransform? {
    self.transformCache[pageIndex]
  }

  /// 전부 무효화: 세대 증가, 인플라이트 취소, 캐시 비움 (teardown 경로).
  package func invalidateAll() {
    self.generation += 1
    for task in self.inFlight.values {
      task.cancel()
    }
    self.inFlight.removeAll()
    self.cache.removeAll()
  }

  /// 페이지 하나의 히트테스트 인덱스를 구축한다 (제네릭 실행자에서 실행 — 메인 비블로킹).
  ///
  /// 추출 실패(throw)는 빈 콘텐츠로 대체해 빈 지오메트리를 만든다 — "그 페이지는 선택
  /// 불가"가 캐시 상태로 표현되고, 매 히트마다 재시도 폭주가 없다.
  /// - Parameters:
  ///   - pageIndex: 대상 페이지 인덱스.
  ///   - provider: 텍스트 공급원.
  ///   - transform: 페이지 표시 변환 공급 클로저.
  /// - Returns: 구축된 히트테스트 인덱스와 사용된 표시 변환.
  private nonisolated static func loadGeometry(
    page pageIndex: Int, provider: any PageTextProvider,
    transform: @Sendable (Int) async -> CGAffineTransform
  ) async -> (geometry: SelectionGeometry, transform: CGAffineTransform) {
    let resolvedTransform = await transform(pageIndex)
    let content =
      (try? await provider.textContent(forPage: pageIndex))
      ?? PageTextContent(pageIndex: pageIndex, string: "", runs: [])
    let geometry = SelectionGeometry.build(
      content: content, pageIndex: pageIndex, transform: resolvedTransform
    )
    return (geometry, resolvedTransform)
  }
}
