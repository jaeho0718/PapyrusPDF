import Foundation

/// 텍스트 검색 옵션.
///
/// 기본값은 대소문자·발음 구별 부호 무시다 (뷰어 검색 관례).
public struct SearchOptions: Sendable, Equatable {
  /// 대소문자를 구별한다 (기본 `false`).
  public var caseSensitive: Bool

  /// 발음 구별 부호(diacritic)를 구별한다 (기본 `false` — `"cafe"`가 `"café"`에 매치).
  public var diacriticSensitive: Bool

  /// 검색 옵션을 생성한다.
  /// - Parameters:
  ///   - caseSensitive: 대소문자 구별 여부 (기본 `false`).
  ///   - diacriticSensitive: 발음 구별 부호 구별 여부 (기본 `false`).
  public init(caseSensitive: Bool = false, diacriticSensitive: Bool = false) {
    self.caseSensitive = caseSensitive
    self.diacriticSensitive = diacriticSensitive
  }
}

/// 검색 매치 하나의 스냅숏.
public struct SearchResult: Sendable, Equatable {
  /// 매치가 있는 페이지 인덱스 (0 기반).
  public let pageIndex: Int

  /// 해당 페이지 ``PageTextContent/string``의 UTF-16 코드유닛 구간 (원문 오프셋 —
  /// 대소문자·발음 부호 폴딩으로 길이가 변해도 이 구간은 원문 좌표계를 유지한다).
  public let range: Range<Int>

  /// PDF 페이지 공간 quad들 — 교차한 run당 1개 (줄바꿈을 걸치면 여러 개).
  /// 매치가 조립 삽입 공백·줄바꿈에만 걸리면 빈 배열일 수 있다.
  public let quads: [Quad]

  /// 매치 전후 문맥 발췌 (개행·탭은 공백으로 치환, 문자 경계 스냅).
  public let snippet: String

  /// `snippet` 안에서 매치가 차지하는 UTF-16 구간 (UI 강조용).
  public let snippetMatchRange: Range<Int>

  /// 검색 매치 스냅숏을 생성한다.
  /// - Parameters:
  ///   - pageIndex: 매치가 있는 페이지 인덱스 (0 기반).
  ///   - range: 페이지 문자열 안의 UTF-16 코드유닛 구간.
  ///   - quads: PDF 페이지 공간 quad들.
  ///   - snippet: 매치 전후 문맥 발췌.
  ///   - snippetMatchRange: `snippet` 안에서 매치가 차지하는 UTF-16 구간.
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
  /// 문서 전체에서 `query`를 검색한다. 결과는 **페이지 오름차순, 페이지 안에서는
  /// 위치 오름차순**으로 방출된다. 텍스트 추출은 내부적으로 병렬 워밍업된다.
  ///
  /// - 공백뿐이거나 빈 query는 결과 없이 즉시 종료한다.
  /// - 페이지 하나의 추출 실패(손상·미지원 필터)는 그 페이지만 건너뛴다.
  ///   문서 수준 실패(페이지 트리 해소 불가)만 스트림을 throw로 종료한다.
  /// - 소비자가 for-await를 이탈(취소)하면 내부 작업도 취소된다.
  /// - Parameters:
  ///   - query: 검색어.
  ///   - options: 검색 옵션 (기본값 — 대소문자·발음 부호 무시).
  /// - Throws(스트림 종료 에러): ``PapyrusError`` (`Error`로 소거 — AsyncThrowingStream
  ///   실패 타입 제약. 실제 타입은 항상 `PapyrusError`임을 문서화).
  /// - Returns: 매치를 순서대로 방출하는 비동기 스트림.
  public func search(
    _ query: String, options: SearchOptions = SearchOptions()
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
          await self.driveSearch(
            query: trimmedQuery, options: options, pageCount: pageCount, continuation: continuation
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
  /// - Parameters:
  ///   - query: 다듬어진(빈 문자열 아님) 검색어.
  ///   - options: 검색 옵션.
  ///   - pageCount: 문서 페이지 수.
  ///   - continuation: 매치를 방출할 스트림 continuation.
  private func driveSearch(
    query: String, options: SearchOptions, pageCount: Int,
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
          (pageIndex, try? await self.text(forPage: pageIndex))
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
        while let maybeContent = pending.removeValue(forKey: nextEmit) {
          if let content = maybeContent {
            for match in SearchMatcher.matches(in: content, query: query, options: options) {
              totalCount += 1
              continuation.yield(match)
              if totalCount >= CoreLimits.maxSearchTotalMatches {
                group.cancelAll()
                return
              }
            }
          }
          nextEmit += 1
        }
        if nextStart < pageCount {
          addTask(nextStart)
          nextStart += 1
        }
      }
    }
  }
}
