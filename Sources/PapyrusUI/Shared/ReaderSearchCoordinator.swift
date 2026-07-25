import CoreGraphics
import PapyrusCore

/// 코디네이터 → 코어 이벤트 (MainActor에서 전달).
package enum SearchEvent: Equatable {
  /// 새 검색이 시작됐다 (이전 상태 전부 무효).
  case began(query: String)
  /// 페이지 하나의 결과 (표시 공간 변환 완료). 페이지 오름차순으로 도착한다.
  case pageResults(pageIndex: Int, highlights: PageSearchHighlights)
  /// 정상 완료.
  case finished
  /// 문서 수준 실패.
  case failed(PapyrusError)
}

/// 검색 스트림 소비 + 좌표 변환 전담 (`@MainActor` — 콜백·상태 모두 메인).
///
/// 문서 참조는 여기만 갖는다 — `ReaderCore`는 계속 문서를 모른다 (M6 구조 유지).
@MainActor
package final class ReaderSearchCoordinator {
  /// 이벤트 수신부 (`ReaderCore`가 설정).
  package var onEvent: ((SearchEvent) -> Void)?

  /// 검색 대상 문서 (페이지 수·표시 변환의 원천 — 텍스트는 provider 소관).
  private let document: PapyrusDocument

  /// 검색 텍스트 공급원 (세션 조립 시 해소된 단일 인스턴스).
  private let provider: any PageTextProvider

  /// 진행 중 소비 태스크.
  private var task: Task<Void, Never>?

  /// 세대 토큰 — `start`마다 증가. 늦게 도착한 구세대 이벤트를 폐기하는 데 쓴다.
  private var generation = 0

  /// 페이지별 표시 변환 memoize (cropBox·rotation은 세션 내내 불변).
  private var transformCache: [Int: CGAffineTransform] = [:]

  /// 코디네이터를 만든다.
  /// - Parameters:
  ///   - document: 검색 대상 문서 (페이지 수·표시 변환 공급).
  ///   - provider: 검색할 텍스트 공급원 (기본 공급원이면 호출자가
  ///     `DocumentTextProvider`를 만들어 전달한다 — 폴백 해소는 조립 1곳 원칙).
  package init(document: PapyrusDocument, provider: any PageTextProvider) {
    self.document = document
    self.provider = provider
  }

  /// 검색을 시작한다. 진행 중 검색은 취소·대체된다.
  /// - Parameters:
  ///   - query: 검색어.
  ///   - options: 검색 옵션.
  package func start(query: String, options: SearchOptions) {
    self.generation += 1
    let generation = self.generation
    self.task?.cancel()
    self.transformCache.removeAll()
    self.onEvent?(.began(query: query))

    let stream = self.document.search(query, options: options, provider: self.provider)
    self.task = Task { [weak self] in
      await self?.consume(stream: stream, generation: generation)
    }
  }

  /// 진행 중 검색을 취소하고 idle로 돌린다 (`.began("")`류 이벤트는 안 보낸다 —
  /// 상태 정리는 코어의 clear 경로가 담당).
  package func cancel() {
    self.generation += 1
    self.task?.cancel()
    self.task = nil
  }

  /// 스트림을 소비해 페이지 단위로 배치된 이벤트를 방출한다.
  /// - Parameters:
  ///   - stream: 소비할 검색 결과 스트림.
  ///   - generation: 이 소비 루프가 속한 세대.
  private func consume(
    stream: AsyncThrowingStream<SearchResult, Error>, generation: Int
  ) async {
    var pendingPageIndex: Int?
    var pendingMatches: [[Quad]] = []
    do {
      for try await result in stream {
        guard self.generation == generation else {
          return
        }
        if pendingPageIndex != result.pageIndex {
          self.flush(pageIndex: pendingPageIndex, matches: pendingMatches, generation: generation)
          pendingPageIndex = result.pageIndex
          pendingMatches = []
        }
        let transform = await self.displayTransform(forPage: result.pageIndex)
        pendingMatches.append(result.quads.map { PageDisplayTransform.apply(transform, to: $0) })
      }
      guard self.generation == generation else {
        return
      }
      self.flush(pageIndex: pendingPageIndex, matches: pendingMatches, generation: generation)
      self.onEvent?(.finished)
    } catch {
      guard self.generation == generation else {
        return
      }
      self.onEvent?(.failed((error as? PapyrusError) ?? .damagedDocument))
    }
  }

  /// 누적된 페이지 하나의 매치를 이벤트로 방출한다 (누적분이 없으면 무시).
  /// - Parameters:
  ///   - pageIndex: 방출할 페이지 인덱스 (`nil`이면 무시).
  ///   - matches: 누적된 매치별 표시 공간 quad 배열.
  ///   - generation: 방출을 요청한 세대 (구세대면 무시).
  private func flush(pageIndex: Int?, matches: [[Quad]], generation: Int) {
    guard self.generation == generation, let pageIndex, !matches.isEmpty else {
      return
    }
    let highlights = PageSearchHighlights(matches: matches)
    self.onEvent?(.pageResults(pageIndex: pageIndex, highlights: highlights))
  }

  /// 페이지의 표시 변환을 조회한다 (memoize, 실패 시 항등 변환 폴백).
  /// - Parameter pageIndex: 대상 페이지 인덱스.
  /// - Returns: PDF 페이지 공간 → 표시 공간 변환.
  private func displayTransform(forPage pageIndex: Int) async -> CGAffineTransform {
    if let cached = self.transformCache[pageIndex] {
      return cached
    }
    guard let info = try? await self.document.page(at: pageIndex) else {
      return .identity
    }
    let transform = PageDisplayTransform.transform(cropBox: info.cropBox, rotation: info.rotation)
    self.transformCache[pageIndex] = transform
    return transform
  }
}
