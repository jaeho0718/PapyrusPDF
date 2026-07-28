import CoreGraphics

extension PDFDocumentCore {
  /// 페이지 트리 스냅숏을 반환한다. 첫 호출 시 한 번에 평탄화하고 영구 메모이즈한다
  /// (실패도 메모이즈 — 입력이 불변이라 재시도가 무의미하다, §4.1).
  ///
  /// 관용 규칙: 순환·댕글링·타입 오류 kid는 조용히 스킵한다 (가정 2 — 경고 미축적).
  /// - Throws: /Root 또는 /Pages 루트 노드 자체를 해소하지 못할 때만
  ///   `COSParseError`/`XRefError`/`FilterError` (개별 페이지 이상은 스킵으로 흡수).
  /// - Returns: 평탄화된 페이지 트리 스냅숏.
  package func pageTree() async throws -> PageTreeSnapshot {
    if let task = self.pageTreeTask {
      return try await task.value
    }
    let task = Task { try await self.buildPageTree() }
    self.pageTreeTask = task
    return try await task.value
  }
}

// MARK: - 평탄화 알고리즘 (§3.1)

extension PDFDocumentCore {
  /// 명시적 스택 DFS의 프레임 하나.
  private struct PageTreeFrame {
    /// 이 노드의 딕셔너리 (사전 해소 완료).
    let dictionary: COSDictionary
    /// 이 노드의 객체 번호 (인라인 kid면 `nil`).
    let number: Int?
    /// 부모로부터 하향 전파된 상속 속성 (이 노드 자신의 값으로 아직 덮어쓰기 전).
    let inherited: PageInheritedAttributes
    /// 루트로부터의 깊이 (루트 = 0).
    let depth: Int
  }

  /// /Root → /Pages를 반복 순회로 평탄화한다. 재귀 없음 — 명시적 스택 + `visited` +
  /// `maxPages`/`maxPageTreeDepth` 캡으로 종료를 보장한다.
  private func buildPageTree() async throws -> PageTreeSnapshot {
    self.pageTreeBuildCount += 1
    let (pagesRoot, rootNumber) = try await self.resolveRootPages()

    var records: [PageRecord] = []
    var indexByNumber: [Int: Int] = [:]
    var visited: Set<Int> = []
    if let rootNumber {
      visited.insert(rootNumber)
    }
    if let countHint = pagesRoot.integer(for: .count) {
      records.reserveCapacity(max(0, min(countHint, CoreLimits.maxPageCountHint)))
    }

    var stack: [PageTreeFrame] = [
      PageTreeFrame(
        dictionary: pagesRoot, number: rootNumber, inherited: PageInheritedAttributes(), depth: 0
      )
    ]

    while let frame = stack.popLast() {
      guard records.count < CoreLimits.maxPages else {
        break
      }
      let merged = try await self.mergedAttributes(for: frame)
      guard self.isIntermediateNode(frame.dictionary) else {
        self.appendLeafRecord(
          dictionary: frame.dictionary, number: frame.number, merged: merged, records: &records,
          indexByNumber: &indexByNumber
        )
        continue
      }
      try await self.pushChildren(of: frame, merged: merged, stack: &stack, visited: &visited)
    }

    return PageTreeSnapshot(records: records, pageIndexByObjectNumber: indexByNumber)
  }

  /// /Root → /Pages를 해소한다. 이 단계의 실패만 throw로 승격된다(§3.1 에러 경계).
  private func resolveRootPages() async throws -> (pagesRoot: COSDictionary, rootNumber: Int?) {
    guard let rootValue = self.trailer[.root],
      case let .dictionary(catalog) = try await self.resolve(rootValue)
    else {
      throw XRefError(code: .parseFailed, offset: 0)
    }
    guard let pagesValue = catalog[.pages],
      case let .dictionary(pagesRoot) = try await self.resolve(pagesValue)
    else {
      throw XRefError(code: .parseFailed, offset: 0)
    }
    return (pagesRoot, pagesValue.referenceValue?.number)
  }

  /// 중간 노드의 자식들을 해소해 스택에 push한다 (문서 순서 보존을 위해 역순 push).
  /// 개별 kid의 순환·댕글링·타입 오류는 조용히 스킵한다 (가정 2).
  private func pushChildren(
    of frame: PageTreeFrame, merged: PageInheritedAttributes,
    stack: inout [PageTreeFrame], visited: inout Set<Int>
  ) async throws {
    guard frame.depth + 1 <= CoreLimits.maxPageTreeDepth else {
      return
    }
    let kids = try await self.resolvedKids(of: frame.dictionary)
    for kid in kids.reversed() {
      switch kid {
      case let .reference(id):
        guard !visited.contains(id.number) else {
          continue
        }
        visited.insert(id.number)
        guard let kidObject = try? await self.object(for: id),
          case let .dictionary(kidDict) = kidObject
        else {
          continue
        }
        stack.append(Self.makeFrame(
          dictionary: kidDict, number: id.number, inherited: merged, depth: frame.depth + 1
        ))
      case let .dictionary(inlineDict):
        stack.append(Self.makeFrame(
          dictionary: inlineDict, number: nil, inherited: merged, depth: frame.depth + 1
        ))
      default:
        continue
      }
    }
  }

  /// `PageTreeFrame` 생성 헬퍼 (긴 인라인 생성 호출의 줄 길이 관리용).
  private static func makeFrame(
    dictionary: COSDictionary, number: Int?, inherited: PageInheritedAttributes, depth: Int
  ) -> PageTreeFrame {
    PageTreeFrame(dictionary: dictionary, number: number, inherited: inherited, depth: depth)
  }

  /// 잎 노드의 최종 `PageRecord`를 조립해 추가한다 (MediaBox 기본값·CropBox 교집합 관용 포함).
  ///
  /// `/Contents`는 잎 노드 자신에서만 읽는다 (상속 속성이 아니다 — M4 가정 1).
  private func appendLeafRecord(
    dictionary: COSDictionary, number: Int?, merged: PageInheritedAttributes,
    records: inout [PageRecord], indexByNumber: inout [Int: Int]
  ) {
    let mediaBox = merged.mediaBox ?? PageGeometry.defaultMediaBox
    var cropBox = merged.cropBox.map { $0.intersection(mediaBox) } ?? mediaBox
    if cropBox.isNull || cropBox.width <= 0 || cropBox.height <= 0 {
      cropBox = mediaBox
    }
    let record = PageRecord(
      objectNumber: number, mediaBox: mediaBox, cropBox: cropBox,
      rotationDegrees: PageGeometry.normalizedRotation(merged.rotationDegrees),
      resources: merged.resources, contents: dictionary[.contents]
    )
    if let number {
      indexByNumber[number] = records.count
    }
    records.append(record)
  }

  /// 노드 자신의 직접 속성(1레벨 해소)으로 상속 속성을 덮어쓴다. /Resources는 의도적으로
  /// 미해소 원값 그대로 전파한다 (M4 텍스트 파이프라인 소비 대상).
  private func mergedAttributes(for frame: PageTreeFrame) async throws -> PageInheritedAttributes {
    let mediaBox = try await self.rectAttribute(frame.dictionary[.mediaBox])
    let cropBox = try await self.rectAttribute(frame.dictionary[.cropBox])
    let rotationDegrees = try await self.rotationAttribute(frame.dictionary[.rotate])
    return frame.inherited.overriding(
      mediaBox: mediaBox, cropBox: cropBox, rotationDegrees: rotationDegrees,
      resources: frame.dictionary[.resources]
    )
  }

  /// 사각형 속성값(/MediaBox, /CropBox)을 1레벨 해소 후 정규화한다.
  private func rectAttribute(_ value: COSObject?) async throws -> CGRect? {
    guard let value else {
      return nil
    }
    guard case let .array(elements) = try await self.resolve(value) else {
      return nil
    }
    return PageGeometry.rectangle(from: elements)
  }

  /// /Rotate 속성값을 1레벨 해소한다. 정수·실수(반올림) 둘 다 수용한다.
  private func rotationAttribute(_ value: COSObject?) async throws -> Int? {
    guard let value else {
      return nil
    }
    let resolved = try await self.resolve(value)
    if let intValue = resolved.integerValue {
      return intValue
    }
    if let realValue = resolved.realValue {
      return Int(realValue.rounded())
    }
    return nil
  }

  /// 노드가 중간 노드(/Pages)인지 판별한다. /Type 부재·미인식은 /Kids 존재 여부로 관용
  /// 분류한다 (실파일의 /Type 누락 대응).
  private func isIntermediateNode(_ dictionary: COSDictionary) -> Bool {
    switch dictionary.name(for: .type) {
    case .some(.pages):
      return true
    case .some(.page):
      return false
    default:
      return dictionary[.kids] != nil
    }
  }

  /// /Kids를 1레벨 해소해 배열 원소를 반환한다 (비배열이면 자식 없음으로 취급).
  private func resolvedKids(of dictionary: COSDictionary) async throws -> [COSObject] {
    guard let kidsValue = dictionary[.kids] else {
      return []
    }
    guard case let .array(elements) = try await self.resolve(kidsValue) else {
      return []
    }
    return elements
  }
}
