extension PDFDocumentCore {
  /// 목차 트리를 반환한다. 첫 호출 시 /Outlines를 순회해 구축하고 영구 메모이즈.
  ///
  /// 내부에서 ``pageTree()``를 먼저 확보한다 (목적지 → 인덱스 역맵 필요).
  /// /Outlines 부재·비딕셔너리는 빈 배열 (에러 아님). 순환·캡 초과는 조용히 절단 (가정 2).
  /// - Throws: ``pageTree()``가 던지는 에러 (목차 자체의 이상은 전부 관용 흡수).
  /// - Returns: 목차 항목 목록 (최상위).
  package func outlineItems() async throws -> [OutlineItem] {
    if let task = self.outlineTask {
      return try await task.value
    }
    let task = Task { try await self.buildOutline() }
    self.outlineTask = task
    return try await task.value
  }
}

/// 목차 구축 1회 동안 유지되는 가변 상태 (`outlineChildren`의 파라미터 수 관리 겸용 —
/// 재귀 호출 전체가 액터 격리 컨텍스트 안에서만 공유되므로 참조 타입으로 충분하다).
private final class OutlineBuildState {
  /// /First·/Next 순회 중 이미 방문한 항목 객체 번호 (순환 절단).
  var visited: Set<Int> = []
  /// 누적 항목 수 (전역 캡 `maxOutlineItems` 판정용).
  var totalItems = 0
  /// 이름 목적지 조회 메모 (한 번의 목차 구축 동안 유지).
  var memo: [[UInt8]: Int?] = [:]
}

// MARK: - 구축 알고리즘 (§3.4)

extension PDFDocumentCore {
  /// /Outlines를 순회해 목차 트리를 구축한다.
  private func buildOutline() async throws -> [OutlineItem] {
    self.outlineBuildCount += 1
    let snapshot = try await self.pageTree()

    guard let rootValue = self.trailer[.root],
      case let .dictionary(catalog) = (try? await self.resolve(rootValue)) ?? .null,
      let outlinesValue = catalog[.outlines],
      case let .dictionary(outlinesDict) = (try? await self.resolve(outlinesValue)) ?? .null
    else {
      return []
    }

    let state = OutlineBuildState()
    return try await self.outlineChildren(
      of: outlinesDict, depth: 0, snapshot: snapshot, state: state
    )
  }

  /// /First·/Next 사슬을 순회해 형제 항목들을 구성한다.
  ///
  /// **재귀 사용 근거**: 깊이가 `maxOutlineDepth`(64) 상수로 유계라 입력 비례 재귀가
  /// 아니다 — 스택 프레임이 최대 64개로 제한된다 (§3.4).
  private func outlineChildren(
    of dictionary: COSDictionary, depth: Int, snapshot: PageTreeSnapshot, state: OutlineBuildState
  ) async throws -> [OutlineItem] {
    guard depth < CoreLimits.maxOutlineDepth else {
      return []
    }
    var items: [OutlineItem] = []
    var cursor = dictionary[.first]
    while case let .reference(id) = cursor {
      guard state.totalItems < CoreLimits.maxOutlineItems else {
        break
      }
      guard !state.visited.contains(id.number) else {
        break
      }
      state.visited.insert(id.number)
      state.totalItems += 1
      guard case let .dictionary(itemDictionary) = (try? await self.object(for: id)) ?? .null
      else {
        break
      }

      let title = await self.outlineItemTitle(itemDictionary, objectID: id)
      let pageIndex: Int? = (try? await self.resolveDestination(
        in: itemDictionary, snapshot: snapshot, memo: &state.memo
      )) ?? nil
      let children = try await self.outlineChildren(
        of: itemDictionary, depth: depth + 1, snapshot: snapshot, state: state
      )
      items.append(OutlineItem(
        title: title, destination: pageIndex.map(OutlineDestination.init), children: children
      ))
      cursor = itemDictionary[.next]
    }
    return items
  }

  /// /Title을 텍스트 문자열로 디코딩한다 (복호화 경유). 부재·비문자열은 `""`.
  private func outlineItemTitle(_ dictionary: COSDictionary, objectID: ObjectID) async -> String {
    guard let bytes = dictionary[.title]?.stringBytes else {
      return ""
    }
    let decrypted = (try? self.securityHandler.decryptString(bytes, objectID: objectID)) ?? bytes
    return PDFTextString.decode(decrypted)
  }
}
