extension PDFDocumentCore {
  /// 목차 항목 딕셔너리에서 목적지를 해소한다 (§3.4 알고리즘).
  /// - Parameters:
  ///   - itemDictionary: 목차 항목 (값 미해소 원본).
  ///   - snapshot: 페이지 역맵 소유자.
  ///   - memo: 이름 목적지 조회 메모 (한 번의 목차 구축 동안 유지 — 반복 조회 회피).
  /// - Throws: 개별 객체 해소 실패(`object(for:)`와 동일 도메인).
  /// - Returns: 해소된 페이지 인덱스. 실패는 전부 `nil` (관용).
  func resolveDestination(
    in itemDictionary: COSDictionary,
    snapshot: PageTreeSnapshot,
    memo: inout [[UInt8]: Int?]
  ) async throws -> Int? {
    if let destValue = itemDictionary[.dest] {
      return try await self.resolveDestinationValue(destValue, snapshot: snapshot, memo: &memo)
    }
    guard let actionValue = itemDictionary[.aKey],
      case let .dictionary(action) = (try? await self.resolve(actionValue)) ?? .null,
      action.name(for: .sKey) == .goTo,
      let destinationValue = action[.dKey]
    else {
      return nil
    }
    return try await self.resolveDestinationValue(
      destinationValue, snapshot: snapshot, memo: &memo
    )
  }
}

extension PDFDocumentCore {
  /// /Dest(또는 /A의 /D) 원값을 배열/이름/문자열 케이스로 분기해 페이지 인덱스로 해소한다.
  private func resolveDestinationValue(
    _ value: COSObject, snapshot: PageTreeSnapshot, memo: inout [[UInt8]: Int?]
  ) async throws -> Int? {
    let resolved = (try? await self.resolve(value)) ?? .null
    switch resolved {
    case let .array(elements):
      return Self.resolveDestinationArray(elements, snapshot: snapshot)
    case let .name(name):
      return try await self.lookupNamed(
        bytes: Array(name.rawValue.utf8), nameForm: true, snapshot: snapshot, memo: &memo
      )
    case let .string(bytes):
      return try await self.lookupNamed(
        bytes: bytes, nameForm: false, snapshot: snapshot, memo: &memo
      )
    default:
      return nil
    }
  }

  /// 배열 목적지의 첫 원소("페이지 참조 자체")를 페이지 인덱스로 대응시킨다 — 해소하지
  /// 않는다 (참조면 역맵 조회, 정수면 범위 검사 그대로 수용 — 로컬 목적지 정수는 스펙
  /// 위반이나 실파일 관용).
  private static func resolveDestinationArray(
    _ elements: [COSObject], snapshot: PageTreeSnapshot
  ) -> Int? {
    guard let first = elements.first else {
      return nil
    }
    switch first {
    case let .reference(id):
      return snapshot.pageIndexByObjectNumber[id.number]
    case let .integer(index):
      return (0..<snapshot.pageCount).contains(index) ? index : nil
    default:
      return nil
    }
  }

  /// 이름 목적지를 조회한다 (한 번의 목차 구축 동안 유지되는 `memo`로 반복 조회를 피한다).
  private func lookupNamed(
    bytes: [UInt8], nameForm: Bool, snapshot: PageTreeSnapshot, memo: inout [[UInt8]: Int?]
  ) async throws -> Int? {
    if let cached = memo[bytes] {
      return cached
    }
    let index = try await self.resolveNamedDestinationIndex(
      bytes: bytes, nameForm: nameForm, snapshot: snapshot
    )
    memo[bytes] = index
    return index
  }

  /// PDF 1.1 `/Dests` 딕셔너리(이름 폼일 때만) → `/Names/Dests` 네임 트리 순으로 조회한다.
  private func resolveNamedDestinationIndex(
    bytes: [UInt8], nameForm: Bool, snapshot: PageTreeSnapshot
  ) async throws -> Int? {
    guard let catalog = try await self.resolvedCatalog() else {
      return nil
    }
    var result: COSObject?
    if nameForm, let destsValue = catalog[.dests],
      case let .dictionary(destsDict) = (try? await self.resolve(destsValue)) ?? .null {
      // [UInt8](Data 아님)의 의도적 손상 복구(U+FFFD) 디코딩 — 이름 키 자체는 항상 유효
      // UTF-8이나 관용 경로를 통일한다.
      // swiftlint:disable:next optional_data_string_conversion
      result = destsDict[COSName(String(decoding: bytes, as: UTF8.self))]
    }
    if result == nil, let namesValue = catalog[.names],
      case let .dictionary(namesDict) = (try? await self.resolve(namesValue)) ?? .null,
      let destsRoot = namesDict[.dests] {
      result = try? await self.nameTreeValue(root: destsRoot, key: bytes)
    }
    guard let result, let elements = try await self.destinationArrayElements(from: result) else {
      return nil
    }
    return Self.resolveDestinationArray(elements, snapshot: snapshot)
  }

  /// 이름 목적지 값(배열 또는 `/D` 배열을 담은 딕셔너리)에서 목적지 배열 원소를 뽑는다.
  private func destinationArrayElements(from value: COSObject) async throws -> [COSObject]? {
    let resolved = (try? await self.resolve(value)) ?? .null
    switch resolved {
    case let .array(elements):
      return elements
    case let .dictionary(dictionary):
      guard let destArrayValue = dictionary[.dKey],
        case let .array(elements) = (try? await self.resolve(destArrayValue)) ?? .null
      else {
        return nil
      }
      return elements
    default:
      return nil
    }
  }

  /// 트레일러의 /Root를 딕셔너리로 해소한다 (실패는 `nil`).
  private func resolvedCatalog() async throws -> COSDictionary? {
    guard let rootValue = self.trailer[.root],
      case let .dictionary(catalog) = (try? await self.resolve(rootValue)) ?? .null
    else {
      return nil
    }
    return catalog
  }
}
