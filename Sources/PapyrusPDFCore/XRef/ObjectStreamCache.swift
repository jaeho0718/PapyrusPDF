import Foundation

/// 압축 해제된 ObjStm 컨테이너 하나.
package struct DecodedObjectStream: Sendable {
  /// 디코딩된 전체 페이로드 (헤더 쌍 영역 + 객체 영역).
  package let payload: Data

  /// 멤버 목록: (객체 번호, `payload` 내 절대 오프셋 — /First 반영 완료).
  /// 인덱스가 곧 xref type-2 엔트리의 `indexInContainer`다.
  package let members: [(objectNumber: Int, offset: Int)]

  /// LRU 비용 (payload 바이트 + 멤버 오버헤드 근사).
  package var cost: Int {
    self.payload.count + self.members.count * 16
  }

  /// 디코딩된 ObjStm 컨테이너를 생성한다.
  /// - Parameters:
  ///   - payload: 디코딩된 전체 페이로드.
  ///   - members: 멤버 목록 (객체 번호, payload 내 절대 오프셋).
  package init(payload: Data, members: [(objectNumber: Int, offset: Int)]) {
    self.payload = payload
    self.members = members
  }
}

/// ObjStm 컨테이너 LRU 캐시. **액터 격리 하에서만 사용** — 자체 잠금 없음, 비-Sendable.
///
/// 예산은 `CoreLimits.maxObjectStreamCacheBytes` (~16MB). 컨테이너 단위 통삽입/통퇴거.
package struct ObjectStreamCache {
  /// 내부 LRU 저장소.
  private var storage: LRUCache<Int, DecodedObjectStream>

  /// 캐시를 생성한다.
  /// - Parameter budget: 비용(바이트) 예산.
  package init(budget: Int = CoreLimits.maxObjectStreamCacheBytes) {
    self.storage = LRUCache(costBudget: budget)
  }

  /// 조회 (LRU touch 포함).
  /// - Parameter number: 컨테이너 번호.
  package mutating func container(number: Int) -> DecodedObjectStream? {
    self.storage.value(for: number)
  }

  /// 삽입. 예산 초과분은 LRU 순서로 퇴거한다. 단일 항목이 예산을 초과하면
  /// 캐시에 넣지 않고 그대로 버린다 (호출자는 반환값으로 이미 사용 중).
  /// - Parameters:
  ///   - container: 저장할 컨테이너.
  ///   - number: 컨테이너 번호.
  package mutating func insert(_ container: DecodedObjectStream, number: Int) {
    self.storage.insert(container, cost: container.cost, for: number)
  }

  /// 현재 적재 바이트 합 (테스트 관찰용).
  package var totalCost: Int {
    self.storage.totalCost
  }

  /// 적재 컨테이너 수 (테스트 관찰용).
  package var count: Int {
    self.storage.count
  }
}

/// ObjStm 스트림 객체를 압축 해제·헤더 파싱해 ``DecodedObjectStream``으로 만든다.
package enum ObjectStreamDecoder {
  /// 컨테이너 스트림을 디코딩한다.
  ///
  /// - Note: `containerNumber` 파라미터는 설계 문서 r1(§2.3 개정 이력)에 반영된
  ///   시그니처다 — 반환하는 ``CoreOpenWarning/objectStreamMissingType(containerNumber:)`` /
  ///   ``CoreOpenWarning/objectStreamMemberOutOfBounds(containerNumber:objectNumber:)``가
  ///   컨테이너 번호를 요구하기 때문이다.
  /// - Parameters:
  ///   - raw: 컨테이너 스트림의 인코딩된 페이로드.
  ///   - dictionary: 컨테이너 스트림 딕셔너리 (/N /First /Filter /DecodeParms —
  ///     간접 참조는 호출자가 사전 해소한 사본이어야 한다).
  ///   - containerNumber: 경고 메시지에 담을 컨테이너 객체 번호.
  /// - Throws: 필터 실패는 `FilterError`, 헤더 구조 위반은 ``XRefError``.
  /// - Returns: 디코딩된 컨테이너 + 축적 경고.
  package static func decode(
    raw: Data, dictionary: COSDictionary, containerNumber: Int
  ) throws -> (container: DecodedObjectStream, warnings: [CoreOpenWarning]) {
    guard let memberCount = dictionary.integer(for: .nKey), memberCount >= 0,
      memberCount <= CoreLimits.maxObjectsPerObjectStream,
      let first = dictionary.integer(for: .first), first >= 0
    else {
      throw XRefError(code: .invalidStreamDictionary, offset: 0)
    }

    var warnings: [CoreOpenWarning] = []
    if dictionary.name(for: .type) == nil {
      warnings.append(.objectStreamMissingType(containerNumber: containerNumber))
    }

    let payload = try FilterPipeline.decode(raw: raw, dictionary: dictionary)
    let headerPairs = try Self.readHeaderPairs(payload: payload, count: memberCount)
    let members = Self.resolveMembers(
      headerPairs: headerPairs, first: first, payloadCount: payload.count,
      containerNumber: containerNumber, warnings: &warnings
    )

    return (DecodedObjectStream(payload: payload, members: members), warnings)
  }

  /// 페이로드 선두에서 `(objectNumber, relativeOffset)` 쌍 `count`개를 스캔한다.
  private static func readHeaderPairs(
    payload: Data, count: Int
  ) throws -> [(objectNumber: Int, relativeOffset: Int)] {
    var lexer = COSLexer(file: MappedFile(data: payload), offset: 0)
    var pairs: [(objectNumber: Int, relativeOffset: Int)] = []
    pairs.reserveCapacity(count)
    for _ in 0..<count {
      guard let numberToken = (try? lexer.nextToken()) ?? nil,
        case let .integer(objectNumber) = numberToken.token,
        let offsetToken = (try? lexer.nextToken()) ?? nil,
        case let .integer(relativeOffset) = offsetToken.token
      else {
        throw XRefError(code: .parseFailed, offset: lexer.offset)
      }
      pairs.append((objectNumber: objectNumber, relativeOffset: relativeOffset))
    }
    return pairs
  }

  /// 헤더 쌍을 절대 오프셋 멤버 목록으로 변환한다. 범위 밖 멤버는 폐기 + 경고한다.
  private static func resolveMembers(
    headerPairs: [(objectNumber: Int, relativeOffset: Int)], first: Int, payloadCount: Int,
    containerNumber: Int, warnings: inout [CoreOpenWarning]
  ) -> [(objectNumber: Int, offset: Int)] {
    var members: [(objectNumber: Int, offset: Int)] = []
    members.reserveCapacity(headerPairs.count)
    for pair in headerPairs {
      let (absoluteOffset, overflowed) = first.addingReportingOverflow(pair.relativeOffset)
      guard !overflowed, absoluteOffset >= 0, absoluteOffset < payloadCount else {
        warnings.append(
          .objectStreamMemberOutOfBounds(
            containerNumber: containerNumber, objectNumber: pair.objectNumber
          )
        )
        continue
      }
      members.append((objectNumber: pair.objectNumber, offset: absoluteOffset))
    }
    return members
  }
}
