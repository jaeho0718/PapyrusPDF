import Foundation

/// 스트림 딕셔너리의 `/Filter`·`/DecodeParms`를 해석해 필터 체인을 순차 적용한다.
package enum FilterPipeline {
  /// 체인의 한 단계 (이름 + 매핑된 종류 + 파라미터). `kind == nil`이면 미지원 필터.
  package struct Stage: Sendable, Equatable {
    /// `/Filter`에 기록된 이름 그대로.
    package let name: COSName

    /// 매핑된 필터 종류. 미지원 필터면 `nil`.
    package let kind: FilterKind?

    /// 이 단계에 대응하는 `/DecodeParms` 딕셔너리. 없으면 `nil`.
    package let parameters: COSDictionary?

    /// 체인 단계를 생성한다.
    /// - Parameters:
    ///   - name: `/Filter`에 기록된 이름.
    ///   - kind: 매핑된 필터 종류.
    ///   - parameters: 이 단계의 `/DecodeParms`.
    package init(name: COSName, kind: FilterKind?, parameters: COSDictionary?) {
      self.name = name
      self.kind = kind
      self.parameters = parameters
    }
  }

  /// `/Filter`(이름 또는 배열)·`/DecodeParms`(`/DP`)를 정렬된 체인으로 해석한다.
  ///
  /// M5가 "이미지 필터에서 멈추기" 판단에 재사용할 수 있도록 디코딩과 분리 노출한다.
  /// - Parameter dictionary: 스트림 딕셔너리.
  /// - Throws: `/Filter`·`/DecodeParms`에 미해소 간접 참조가 있으면
  ///   ``FilterError/Code/indirectParameter``.
  package static func stages(from dictionary: COSDictionary) throws(FilterError) -> [Stage] {
    guard let filterValue = dictionary[.filter] else {
      return []
    }
    let names = try Self.filterNames(from: filterValue)
    let parametersList = try Self.decodeParmsList(from: dictionary, count: names.count)
    var result: [Stage] = []
    result.reserveCapacity(names.count)
    for index in 0..<names.count {
      let name = names[index]
      let stage = Stage(
        name: name, kind: FilterKind(name: name), parameters: parametersList[index]
      )
      result.append(stage)
    }
    return result
  }

  /// 원시 페이로드에 체인을 전부 적용한다.
  ///
  /// 미지원 필터를 만나면 `.unsupportedFilter`로 실패한다 (부분 디코딩 반환은 M5 필요시 확장).
  /// - Parameters:
  ///   - raw: 인코딩된 원본 페이로드.
  ///   - dictionary: 스트림 딕셔너리.
  ///   - maxDecodedSize: 단계별 방출 바이트 상한 (기본 ``CoreLimits/maxDecodedStreamBytes``).
  /// - Throws: 체인 해석·디코딩 실패 시 ``FilterError``.
  package static func decode(
    raw: Data, dictionary: COSDictionary, maxDecodedSize: Int = CoreLimits.maxDecodedStreamBytes
  ) throws(FilterError) -> Data {
    var current = raw
    for stage in try Self.stages(from: dictionary) {
      guard let kind = stage.kind else {
        throw FilterError(code: .unsupportedFilter(stage.name), filterName: stage.name)
      }
      current = try kind.decode(
        current, parameters: stage.parameters, maxDecodedSize: maxDecodedSize
      )
    }
    return current
  }

  /// `/Filter` 값(이름 또는 이름 배열)을 이름 목록으로 정규화한다.
  private static func filterNames(from value: COSObject) throws(FilterError) -> [COSName] {
    switch value {
    case let .name(name):
      return [name]
    case let .array(elements):
      var names: [COSName] = []
      names.reserveCapacity(elements.count)
      for element in elements {
        switch element {
        case let .name(name):
          names.append(name)
        case .reference:
          throw FilterError(code: .indirectParameter)
        default:
          throw FilterError(code: .corruptedData)
        }
      }
      return names
    case .reference:
      throw FilterError(code: .indirectParameter)
    default:
      throw FilterError(code: .corruptedData)
    }
  }

  /// `/DecodeParms`(또는 `/DP`)를 `count`개 필터와 병렬인 목록으로 정규화한다.
  ///
  /// 단일 딕셔너리는 첫 단계에만 대응하고, 배열의 부족분·`null` 엔트리는 `nil` 취급한다.
  private static func decodeParmsList(
    from dictionary: COSDictionary, count: Int
  ) throws(FilterError) -> [COSDictionary?] {
    guard let parmsValue = dictionary[.decodeParms] ?? dictionary[.dp] else {
      return [COSDictionary?](repeating: nil, count: count)
    }
    switch parmsValue {
    case let .dictionary(single):
      var result = [COSDictionary?](repeating: nil, count: count)
      if count > 0 {
        result[0] = single
      }
      return result
    case let .array(elements):
      var result: [COSDictionary?] = []
      result.reserveCapacity(count)
      for index in 0..<count {
        result.append(try Self.parmsElement(elements, at: index))
      }
      return result
    case .reference:
      throw FilterError(code: .indirectParameter)
    default:
      return [COSDictionary?](repeating: nil, count: count)
    }
  }

  /// `/DecodeParms` 배열의 `index`번째 원소를 하나의 파라미터 딕셔너리로 정규화한다.
  /// 부족분·`null`·기타 타입은 `nil` 취급하고, 간접 참조만 에러로 거부한다.
  private static func parmsElement(
    _ elements: [COSObject], at index: Int
  ) throws(FilterError) -> COSDictionary? {
    guard index < elements.count else {
      return nil
    }
    switch elements[index] {
    case let .dictionary(dict):
      return dict
    case .reference:
      throw FilterError(code: .indirectParameter)
    default:
      return nil
    }
  }
}
