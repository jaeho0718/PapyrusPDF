import CoreGraphics
import Foundation

// `PDFDocumentCore`의 텍스트 추출 경로. 파일 분리는 순수 조직적 이유 — ObjStm 분리 파일과
// 동일한 조직 원칙(§4.1)이다.

extension PDFDocumentCore {
  /// 페이지 텍스트를 반환한다. LRU 캐시 → in-flight 합류 → 입력 구축(액터) →
  /// `@concurrent` 추출 순. 결과는 UTF-16 길이×2 + run당 상수 비용으로 LRU 적재.
  /// - Parameter index: 페이지 인덱스 (0 기반, 호출부가 사전 검증).
  /// - Throws: 페이지 트리 해소 실패 전파 + 가정 4의 unsupportedFilter.
  /// - Returns: 페이지 텍스트 스냅숏.
  package func pageText(at index: Int) async throws -> PageTextContent {
    if let cached = self.textPageCache.value(for: index) {
      return cached
    }
    if let existingTask = self.inflightTextPages[index] {
      return try await existingTask.value
    }

    let task = Task<PageTextContent, Error> {
      let input = try await self.buildExtractionInput(pageIndex: index)
      return await TextPageExtractor.extract(input)
    }
    self.inflightTextPages[index] = task
    defer {
      self.inflightTextPages[index] = nil
    }

    let result = try await task.value
    self.textExtractionCount += 1
    let cost = result.string.utf16.count * 2 + result.runs.count * 96
    self.textPageCache.insert(result, cost: cost, for: index)
    return result
  }

  /// 폰트를 로딩한다 (객체 번호 키 캐시 + in-flight dedupe). 실패 시 throw하지 않고
  /// `FontLoader.fallbackFont()`를 캐시에 넣는다 (가정 11 — 침묵 관용).
  /// - Parameter id: 폰트 딕셔너리의 객체 식별자.
  /// - Returns: 로딩 완료된 폰트 (실패 시 폴백).
  package func loadedFont(for id: ObjectID) async -> LoadedFont {
    if let cached = self.fontCache.value(for: id.number) {
      return cached
    }
    if let existingTask = self.inflightFonts[id.number] {
      return await existingTask.value
    }

    let task = Task<LoadedFont, Never> {
      let inputs = await self.buildFontInputs(objectID: id)
      return inputs.map(FontLoader.build) ?? FontLoader.fallbackFont()
    }
    self.inflightFonts[id.number] = task
    defer {
      self.inflightFonts[id.number] = nil
    }

    let font = await task.value
    self.fontBuildCount += 1
    self.fontCache.insert(font, cost: 1, for: id.number)
    return font
  }
}

// MARK: - 입력 수집 (§3.1)

extension PDFDocumentCore {
  /// 페이지 하나의 추출 입력을 수집한다 — 콘텐츠 세그먼트 + 리소스(폰트·Form) 사전 해소.
  private func buildExtractionInput(pageIndex: Int) async throws -> PageExtractionInput {
    let snapshot = try await self.pageTree()
    guard snapshot.records.indices.contains(pageIndex) else {
      return PageExtractionInput(
        contentSegments: [], resources: ResolvedResources(), pageIndex: pageIndex
      )
    }
    let record = snapshot.records[pageIndex]
    let segments = try await self.contentSegments(from: record.contents)
    var visited: Set<Int> = []
    let resources = await self.resolveResources(record.resources, depth: 0, visited: &visited)
    return PageExtractionInput(
      contentSegments: segments, resources: resources, pageIndex: pageIndex
    )
  }
}

// MARK: - /Contents 해소 (가정 4의 관용 규칙)

extension PDFDocumentCore {
  /// `/Contents` 원값(단일 ref | ref 배열 | 인라인 배열)을 세그먼트 목록으로 해소한다.
  private func contentSegments(from contentsValue: COSObject?) async throws -> [Data] {
    guard let contentsValue else {
      return []
    }
    switch contentsValue {
    case let .reference(id):
      guard let resolvedObject = try? await self.object(for: id) else {
        return []
      }
      switch resolvedObject {
      case .stream:
        guard let segment = try await self.contentSegment(for: id) else {
          return []
        }
        return [segment]
      case let .array(elements):
        return try await self.contentSegmentsFromArray(elements)
      default:
        return []
      }
    case let .array(elements):
      return try await self.contentSegmentsFromArray(elements)
    default:
      return []
    }
  }

  private func contentSegmentsFromArray(_ elements: [COSObject]) async throws -> [Data] {
    var segments: [Data] = []
    for element in elements {
      guard case let .reference(id) = element else {
        continue
      }
      if let segment = try await self.contentSegment(for: id) {
        segments.append(segment)
      }
    }
    return segments
  }

  /// 세그먼트 하나를 디코딩한다. `unsupportedFilter`만 throw로 승격(가정 4),
  /// 그 외 실패(손상·절단·비스트림)는 `nil`(스킵).
  private func contentSegment(for id: ObjectID) async throws -> Data? {
    do {
      return try await self.decodedStreamData(for: id)
    } catch let error as FilterError {
      if case .unsupportedFilter = error.code {
        throw error
      }
      return nil
    } catch {
      return nil
    }
  }
}

// MARK: - 리소스 사전 해소 (폰트·Form XObject, §3.6)

extension PDFDocumentCore {
  /// `/Resources`에서 텍스트 추출에 필요한 부분(`/Font`, Form `/XObject`)만 해소한다.
  /// 깊이 캡 16, 순환은 방문 객체번호 집합으로 절단.
  private func resolveResources(
    _ value: COSObject?, depth: Int, visited: inout Set<Int>
  ) async -> ResolvedResources {
    guard depth <= CoreLimits.maxFormXObjectDepth, let value,
      case let .dictionary(resourcesDict) = (try? await self.resolve(value)) ?? .null
    else {
      return ResolvedResources()
    }
    let fonts = await self.resolveFonts(resourcesDict[.font])
    let formXObjects = await self.resolveFormXObjects(
      resourcesDict[.xObject], depth: depth, visited: &visited
    )
    return ResolvedResources(fonts: fonts, formXObjects: formXObjects)
  }

  /// `/Font` 서브딕셔너리 전 항목을 로딩한다. 인라인 폰트 딕셔너리(비참조)는 캐시를
  /// 우회해 즉석으로 빌드한다 (§4.1).
  private func resolveFonts(_ value: COSObject?) async -> [COSName: LoadedFont] {
    guard let value else {
      return [:]
    }
    guard case let .dictionary(fontDictionary) = (try? await self.resolve(value)) ?? .null else {
      return [:]
    }
    var result: [COSName: LoadedFont] = [:]
    for name in fontDictionary.keys {
      guard let entry = fontDictionary[name] else {
        continue
      }
      switch entry {
      case let .reference(id):
        result[name] = await self.loadedFont(for: id)
      case let .dictionary(inlineDictionary):
        result[name] = FontLoader.build(await self.fontInputs(from: inlineDictionary))
      default:
        result[name] = FontLoader.fallbackFont()
      }
    }
    return result
  }

  /// `/XObject` 중 `/Subtype /Form`만 골라 재귀 해소한다.
  private func resolveFormXObjects(
    _ value: COSObject?, depth: Int, visited: inout Set<Int>
  ) async -> [COSName: FormXObjectInput] {
    guard let value else {
      return [:]
    }
    let resolved = (try? await self.resolve(value)) ?? .null
    guard case let .dictionary(xObjectDictionary) = resolved else {
      return [:]
    }
    var result: [COSName: FormXObjectInput] = [:]
    for name in xObjectDictionary.keys {
      guard let entry = xObjectDictionary[name] else {
        continue
      }
      if let input = await self.resolveFormXObjectEntry(entry, depth: depth, visited: &visited) {
        result[name] = input
      }
    }
    return result
  }

  /// Form XObject 하나를 디코딩+재귀 해소한다. 참조는 방문 집합으로 순환 절단, 인라인
  /// 딕셔너리는 방문 추적 없이 깊이 캡만 적용된다.
  private func resolveFormXObjectEntry(
    _ value: COSObject, depth: Int, visited: inout Set<Int>
  ) async -> FormXObjectInput? {
    var streamObjectID: ObjectID?
    let resolvedObject: COSObject
    if case let .reference(id) = value {
      guard !visited.contains(id.number) else {
        return nil
      }
      visited.insert(id.number)
      streamObjectID = id
      guard let object = try? await self.object(for: id) else {
        return nil
      }
      resolvedObject = object
    } else {
      resolvedObject = value
    }
    guard case let .stream(stream) = resolvedObject, stream.dictionary.name(for: .subtype) == .form
    else {
      return nil
    }
    guard let streamObjectID, let content = try? await self.decodedStreamData(for: streamObjectID)
    else {
      return nil
    }
    let matrix = Self.affineTransform(from: stream.dictionary[.matrix]) ?? .identity
    let resources = await self.resolveResources(
      stream.dictionary[.resources], depth: depth + 1, visited: &visited
    )
    return FormXObjectInput(content: content, matrix: matrix, resources: resources)
  }

  /// `/Matrix` 6원소 배열을 `CGAffineTransform`으로 해석한다. 형식 위반은 `nil`.
  private static func affineTransform(from value: COSObject?) -> CGAffineTransform? {
    guard case let .array(elements) = value, elements.count >= 6,
      let matrixA = elements[0].realValue, let matrixB = elements[1].realValue,
      let matrixC = elements[2].realValue, let matrixD = elements[3].realValue,
      let matrixE = elements[4].realValue, let matrixF = elements[5].realValue
    else {
      return nil
    }
    return CGAffineTransform(
      a: CGFloat(matrixA), b: CGFloat(matrixB), c: CGFloat(matrixC), d: CGFloat(matrixD),
      tx: CGFloat(matrixE), ty: CGFloat(matrixF)
    )
  }
}

// MARK: - 폰트 입력 조립

extension PDFDocumentCore {
  /// 객체 번호로 폰트 딕셔너리를 해소해 `FontLoader.Inputs`를 만든다. 해소 실패는 `nil`.
  private func buildFontInputs(objectID: ObjectID) async -> FontLoader.Inputs? {
    guard case let .dictionary(fontDictionary) = (try? await self.object(for: objectID)) ?? .null
    else {
      return nil
    }
    return await self.fontInputs(from: fontDictionary)
  }

  /// 폰트 딕셔너리(이미 해소됨)로부터 `FontLoader.Inputs`를 조립한다.
  private func fontInputs(from fontDictionary: COSDictionary) async -> FontLoader.Inputs {
    let descriptor = await self.resolvedDictionary(fontDictionary[.fontDescriptor])
    let toUnicodeData = await self.resolvedStreamData(fontDictionary[.toUnicode])
    let encodingObject = await self.resolveShallowValue(fontDictionary[.encoding])
    let descendant = await self.buildDescendantInputs(fontDictionary[.descendantFonts])
    return FontLoader.Inputs(
      fontDictionary: fontDictionary, descriptor: descriptor, toUnicodeData: toUnicodeData,
      encodingObject: encodingObject, descendant: descendant
    )
  }

  /// `/DescendantFonts[0]`을 해소해 `DescendantInputs`를 조립한다 (Type0 전용).
  private func buildDescendantInputs(
    _ value: COSObject?
  ) async -> FontLoader.Inputs.DescendantInputs? {
    guard let value, case let .array(elements) = (try? await self.resolve(value)) ?? .null,
      let first = elements.first,
      case let .dictionary(descendantDictionary) = (try? await self.resolve(first)) ?? .null
    else {
      return nil
    }
    let descriptor = await self.resolvedDictionary(descendantDictionary[.fontDescriptor])
    let widthsArray = await self.resolvedWidthsArray(descendantDictionary[.wKey])
    let (encodingName, embeddedCMapData) = await self.resolveType0Encoding(
      descendantDictionary[.encoding]
    )
    return FontLoader.Inputs.DescendantInputs(
      fontDictionary: descendantDictionary, descriptor: descriptor, widthsArray: widthsArray,
      embeddedCMapData: embeddedCMapData, encodingName: encodingName
    )
  }

  /// Type0 `/Encoding`(이름 또는 임베디드 CMap 스트림 참조)을 해소한다.
  private func resolveType0Encoding(
    _ value: COSObject?
  ) async -> (name: COSName?, cmapData: Data?) {
    guard let value else {
      return (nil, nil)
    }
    switch value {
    case let .name(name):
      return (name, nil)
    case let .reference(id):
      if let data = try? await self.decodedStreamData(for: id) {
        return (nil, data)
      }
      if case let .name(name) = (try? await self.object(for: id)) ?? .null {
        return (name, nil)
      }
      return (nil, nil)
    default:
      return (nil, nil)
    }
  }

  /// 값을 1레벨 해소해 딕셔너리로 좁힌다 (`/FontDescriptor` 등).
  private func resolvedDictionary(_ value: COSObject?) async -> COSDictionary? {
    guard let value, case let .dictionary(dictionary) = (try? await self.resolve(value)) ?? .null
    else {
      return nil
    }
    return dictionary
  }

  /// 스트림 참조를 디코딩한다 (`/ToUnicode` 등). 스트림이 아니거나 해소 실패면 `nil`.
  private func resolvedStreamData(_ value: COSObject?) async -> Data? {
    guard let value, case let .reference(id) = value else {
      return nil
    }
    return try? await self.decodedStreamData(for: id)
  }

  /// 값 자체(참조면 1레벨 해소)를 반환한다. `.null`은 `nil`로 정규화한다.
  private func resolveShallowValue(_ value: COSObject?) async -> COSObject? {
    guard let value, let resolved = try? await self.resolve(value), !resolved.isNull else {
      return nil
    }
    return resolved
  }

  /// `/W` 배열을 1레벨 해소한다 (원소별 참조도 해소).
  private func resolvedWidthsArray(_ value: COSObject?) async -> [COSObject]? {
    guard let value, case let .array(elements) = (try? await self.resolve(value)) ?? .null else {
      return nil
    }
    var resolved: [COSObject] = []
    resolved.reserveCapacity(elements.count)
    for element in elements {
      if case .reference = element, let value = try? await self.resolve(element) {
        resolved.append(value)
      } else {
        resolved.append(element)
      }
    }
    return resolved
  }
}
