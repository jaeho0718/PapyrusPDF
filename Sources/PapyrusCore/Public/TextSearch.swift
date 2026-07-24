import Foundation

/// 텍스트 검색 옵션입니다.
///
/// 기본값은 대소문자·발음 구별 부호 무시입니다 (뷰어 검색 관례).
public struct SearchOptions: Sendable, Equatable {
  /// 대소문자를 구별합니다 (기본 `false`).
  public var caseSensitive: Bool

  /// 발음 구별 부호(diacritic)를 구별합니다 (기본 `false` — `"cafe"`가 `"café"`에 매치).
  public var diacriticSensitive: Bool

  /// 검색 옵션을 생성합니다.
  /// - Parameters:
  ///   - caseSensitive: 대소문자 구별 여부입니다 (기본 `false`).
  ///   - diacriticSensitive: 발음 구별 부호 구별 여부입니다 (기본 `false`).
  public init(caseSensitive: Bool = false, diacriticSensitive: Bool = false) {
    self.caseSensitive = caseSensitive
    self.diacriticSensitive = diacriticSensitive
  }
}

/// 검색 매치 하나의 스냅숏입니다.
public struct SearchResult: Sendable, Equatable {
  /// 매치가 있는 페이지 인덱스입니다 (0 기반).
  public let pageIndex: Int

  /// 해당 페이지 ``PageTextContent/string``의 UTF-16 코드유닛 구간입니다 (원문 오프셋 —
  /// 대소문자·발음 부호 폴딩으로 길이가 변해도 이 구간은 원문 좌표계를 유지합니다).
  public let range: Range<Int>

  /// PDF 페이지 공간 quad들입니다 — 교차한 run당 1개 (줄바꿈을 걸치면 여러 개).
  /// 매치가 조립 삽입 공백·줄바꿈에만 걸리면 빈 배열일 수 있습니다.
  public let quads: [Quad]

  /// 매치 전후 문맥 발췌입니다 (개행·탭은 공백으로 치환, 문자 경계 스냅).
  public let snippet: String

  /// `snippet` 안에서 매치가 차지하는 UTF-16 구간입니다 (UI 강조용).
  public let snippetMatchRange: Range<Int>

  /// 검색 매치 스냅숏을 생성합니다.
  /// - Parameters:
  ///   - pageIndex: 매치가 있는 페이지 인덱스입니다 (0 기반).
  ///   - range: 페이지 문자열 안의 UTF-16 코드유닛 구간입니다.
  ///   - quads: PDF 페이지 공간 quad들입니다.
  ///   - snippet: 매치 전후 문맥 발췌입니다.
  ///   - snippetMatchRange: `snippet` 안에서 매치가 차지하는 UTF-16 구간입니다.
  public init(
    pageIndex: Int, range: Range<Int>, quads: [Quad], snippet: String,
    snippetMatchRange: Range<Int>
  ) {
    self.pageIndex = pageIndex
    self.range = range
    self.quads = quads
    self.snippet = snippet
    self.snippetMatchRange = snippetMatchRange
  }
}

extension PapyrusDocument {
  /// 문서 전체에서 `query`를 검색합니다. 결과는 **페이지 오름차순, 페이지 안에서는
  /// 위치 오름차순**으로 방출됩니다. 텍스트 추출은 내부적으로 병렬 워밍업됩니다.
  ///
  /// - 공백뿐이거나 빈 query는 결과 없이 즉시 종료합니다.
  /// - 페이지 하나의 추출 실패(손상·미지원 필터)는 그 페이지만 건너뜁니다.
  ///   문서 수준 실패(페이지 트리 해소 불가)만 스트림을 throw로 종료합니다.
  /// - 소비자가 for-await를 이탈(취소)하면 내부 작업도 취소됩니다.
  /// - Parameters:
  ///   - query: 검색어입니다.
  ///   - options: 검색 옵션입니다 (기본값 — 대소문자·발음 부호 무시).
  /// - Throws(스트림 종료 에러): ``PapyrusError`` (`Error`로 소거 — AsyncThrowingStream
  ///   실패 타입 제약. 실제 타입은 항상 `PapyrusError`임을 문서화합니다).
  /// - Returns: 매치를 순서대로 방출하는 비동기 스트림입니다.
  public func search(
    _ query: String, options: SearchOptions = SearchOptions()
  ) -> AsyncThrowingStream<SearchResult, Error> {
    self.search(query, options: options, provider: DocumentTextProvider(document: self))
  }

  /// `provider`가 공급한 텍스트 위에서 검색합니다. 방출 순서·캡·취소 등 그 외 계약은
  /// ``search(_:options:)``와 동일합니다.
  ///
  /// 프로바이더가 throw한 페이지는 건너뜁니다. 반환 콘텐츠는 위생 검사를 거치므로
  /// (범위 이탈 클램프·비유한 폐기·상한), 잘못된 프로바이더 값이 크래시를 일으키지
  /// 않습니다. 페이지 수는 이 문서 기준입니다.
  /// - Parameters:
  ///   - query: 검색어입니다.
  ///   - options: 검색 옵션입니다 (기본값 — 대소문자·발음 부호 무시).
  ///   - provider: 텍스트 콘텐츠 공급원입니다.
  /// - Throws(스트림 종료 에러): ``PapyrusError`` (`Error`로 소거 — AsyncThrowingStream
  ///   실패 타입 제약. 실제 타입은 항상 `PapyrusError`임을 문서화합니다).
  /// - Returns: 매치를 순서대로 방출하는 비동기 스트림입니다.
  public func search(
    _ query: String, options: SearchOptions = SearchOptions(), provider: any PageTextProvider
  ) -> AsyncThrowingStream<SearchResult, Error> {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
      return AsyncThrowingStream { continuation in
        continuation.finish()
      }
    }

    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let pageCount = try await self.pageCount
          await Self.driveSearch(
            query: trimmedQuery, options: options, pageCount: pageCount, provider: provider,
            continuation: continuation
          )
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  /// 검색 스트림 드라이버 본체 — 슬라이딩 윈도 병렬 워밍업 + 순서 복원 방출.
  ///
  /// 완료는 무순서로 도착하지만 `pending` 버퍼 + `nextEmit` 커서로 페이지 오름차순
  /// 방출을 보장한다. 페이지 1장의 추출 실패는 `try?`로 흡수해 그 페이지만 건너뛴다.
  /// 위생 검사는 태스크 그룹 자식(병렬) 안에서 수행한다 — 방출 루프는 비블로킹이다.
  /// - Parameters:
  ///   - query: 다듬어진(빈 문자열 아님) 검색어.
  ///   - options: 검색 옵션.
  ///   - pageCount: 문서 페이지 수.
  ///   - provider: 텍스트 콘텐츠 공급원.
  ///   - continuation: 매치를 방출할 스트림 continuation.
  private static func driveSearch(
    query: String, options: SearchOptions, pageCount: Int, provider: any PageTextProvider,
    continuation: AsyncThrowingStream<SearchResult, Error>.Continuation
  ) async {
    guard pageCount > 0 else {
      return
    }
    let width = max(
      1,
      min(
        CoreLimits.maxSearchWarmupWidth, ProcessInfo.processInfo.activeProcessorCount, pageCount
      )
    )
    var totalCount = 0
    var nextStart = 0
    var nextEmit = 0
    var pending: [Int: PageTextContent?] = [:]

    await withTaskGroup(of: (Int, PageTextContent?).self) { group in
      // 페이지 1장 워밍업 태스크 추가 — 추출 실패는 `nil`로 흡수한다 (§4.2).
      func addTask(_ pageIndex: Int) {
        group.addTask {
          guard let raw = try? await provider.textContent(forPage: pageIndex) else {
            return (pageIndex, nil)
          }
          return (pageIndex, PageContentSanitizer.sanitize(raw, expectedPageIndex: pageIndex))
        }
      }

      for _ in 0..<width where nextStart < pageCount {
        addTask(nextStart)
        nextStart += 1
      }

      while let (index, content) = await group.next() {
        guard !Task.isCancelled else {
          group.cancelAll()
          return
        }
        pending[index] = content
        let hitCap = Self.drainPending(
          &pending, from: &nextEmit, totalCount: &totalCount, search: (query, options),
          continuation: continuation
        )
        if hitCap {
          group.cancelAll()
          return
        }
        if nextStart < pageCount {
          addTask(nextStart)
          nextStart += 1
        }
      }
    }
  }

  /// `pending` 버퍼에서 `nextEmit` 순번이 연속으로 채워진 만큼 매치를 방출한다
  /// (`driveSearch`의 방출 루프 추출 — 함수 길이 축소, 동작 동일).
  /// - Parameters:
  ///   - pending: 페이지별 위생 검사 완료 콘텐츠 버퍼 (방출한 항목은 제거된다).
  ///   - nextEmit: 다음에 방출할 페이지 인덱스 (방출한 만큼 전진한다).
  ///   - totalCount: 누적 방출 매치 수 (방출한 만큼 증가한다).
  ///   - search: 다듬어진 검색어와 검색 옵션의 묶음 (파라미터 수 축소용).
  ///   - continuation: 매치를 방출할 스트림 continuation.
  /// - Returns: 총량 캡에 도달해 검색을 즉시 종료해야 하면 `true`.
  private static func drainPending(
    _ pending: inout [Int: PageTextContent?], from nextEmit: inout Int, totalCount: inout Int,
    search: (query: String, options: SearchOptions),
    continuation: AsyncThrowingStream<SearchResult, Error>.Continuation
  ) -> Bool {
    while let maybeContent = pending.removeValue(forKey: nextEmit) {
      if let content = maybeContent {
        for match in SearchMatcher.matches(
          in: content, query: search.query, options: search.options
        ) {
          totalCount += 1
          continuation.yield(match)
          if totalCount >= CoreLimits.maxSearchTotalMatches {
            return true
          }
        }
      }
      nextEmit += 1
    }
    return false
  }
}
