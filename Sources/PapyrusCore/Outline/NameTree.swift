extension PDFDocumentCore {
  /// 네임 트리(/Names/Dests 등)에서 키에 대응하는 값을 찾는다. **지연 탐색** —
  /// 트리 전체를 로드하지 않고 /Limits 기반으로 한 경로만 하강한다 (ARCHITECTURE.md).
  ///
  /// 리프의 /Names 배열 안에서는 **선형 탐색**한다 — 실파일의 정렬 위반에 안전하고,
  /// 목차 해소의 조회 횟수(항목 수 이하)에서 이진 탐색 이득이 무의미하다
  /// (대안: 정렬 가정 이진 탐색 — 손상 파일 오답 리스크로 기각).
  /// - Parameters:
  ///   - root: 네임 트리 루트 값 (미해소 원값 — `/Names/Dests` 등).
  ///   - key: 조회할 키 바이트열.
  /// - Throws: 개별 객체 해소 실패(`object(for:)`와 동일 도메인).
  /// - Returns: 찾은 값 (미해소 원값). 부재·구조 이상은 `nil`.
  func nameTreeValue(root: COSObject, key: [UInt8]) async throws -> COSObject? {
    guard case var .dictionary(node) = try await self.resolve(root) else {
      return nil
    }
    var depth = 0
    var resolvedNodes = 0

    while true {
      depth += 1
      guard depth <= CoreLimits.maxNameTreeDepth else {
        return nil
      }

      if let namesValue = node[.names],
        case let .array(names) = try await self.resolve(namesValue) {
        return try await self.scanNameTreeLeaf(names, key: key)
      }

      guard let kidsValue = node[.kids],
        case let .array(kids) = try await self.resolve(kidsValue)
      else {
        return nil
      }

      guard let nextNode = try await self.descendNameTree(
        kids: kids, key: key, resolvedNodes: &resolvedNodes
      ) else {
        return nil
      }
      node = nextNode
    }
  }

  /// 리프의 `/Names` 배열을 (키, 값) 쌍으로 선형 스캔한다. 홀수 길이는 마지막 원소 무시.
  private func scanNameTreeLeaf(_ names: [COSObject], key: [UInt8]) async throws -> COSObject? {
    var index = 0
    while index + 1 < names.count {
      guard let candidateKey = try await self.resolve(names[index]).stringBytes else {
        index += 2
        continue
      }
      if candidateKey == key {
        return names[index + 1]
      }
      index += 2
    }
    return nil
  }

  /// `/Kids` 중 키를 포함하는(또는 한계가 없는 첫) kid로 하강한다.
  private func descendNameTree(
    kids: [COSObject], key: [UInt8], resolvedNodes: inout Int
  ) async throws -> COSDictionary? {
    var fallbackCandidate: COSDictionary?
    for kid in kids {
      resolvedNodes += 1
      guard resolvedNodes <= CoreLimits.maxNameTreeNodesPerLookup else {
        return nil
      }
      guard case let .dictionary(kidDictionary) = try await self.resolve(kid) else {
        continue
      }
      guard let limitsValue = kidDictionary[.limits],
        case let .array(limits) = try await self.resolve(limitsValue), limits.count >= 2,
        let minKey = try await self.resolve(limits[0]).stringBytes,
        let maxKey = try await self.resolve(limits[1]).stringBytes
      else {
        if fallbackCandidate == nil {
          fallbackCandidate = kidDictionary
        }
        continue
      }
      if NameTreeKeyOrder.contains(key: key, min: minKey, max: maxKey) {
        return kidDictionary
      }
    }
    return fallbackCandidate
  }
}

/// 네임 트리 키 비교 (스펙: 바이트 단위 무부호 사전식).
package enum NameTreeKeyOrder {
  /// `lhs < rhs` (바이트 사전식).
  /// - Parameters:
  ///   - lhs: 비교할 왼쪽 바이트열.
  ///   - rhs: 비교할 오른쪽 바이트열.
  /// - Returns: `lhs`가 `rhs`보다 사전식으로 앞서면 `true`.
  package static func isOrderedBefore(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    for (left, right) in zip(lhs, rhs) where left != right {
      return left < right
    }
    return lhs.count < rhs.count
  }

  /// /Limits `[min max]` 구간에 키가 들어가는가 (경계 포함).
  /// - Parameters:
  ///   - key: 검사할 키.
  ///   - min: 구간 하한.
  ///   - max: 구간 상한.
  /// - Returns: `min <= key <= max`이면 `true`.
  package static func contains(key: [UInt8], min: [UInt8], max: [UInt8]) -> Bool {
    !Self.isOrderedBefore(key, min) && !Self.isOrderedBefore(max, key)
  }
}
