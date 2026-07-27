/// COS(Carousel Object System) 값. PDF 파일의 모든 구문 객체를 표현한다.
package enum COSObject: Sendable, Equatable {
  /// `null` 키워드.
  case null

  /// `true`/`false` 키워드.
  case boolean(Bool)

  /// 정수 숫자.
  case integer(Int)

  /// 실수 숫자.
  case real(Double)

  /// 원시 바이트 문자열 (텍스트 디코딩은 M3 소관).
  case string([UInt8])

  /// `/Name` 형식의 이름 객체.
  case name(COSName)

  /// `[...]` 배열.
  case array([COSObject])

  /// `<< ... >>` 딕셔너리.
  case dictionary(COSDictionary)

  /// 스트림 객체 (딕셔너리 + 페이로드 위치).
  case stream(COSStream)

  /// `N G R` 간접 참조.
  case reference(ObjectID)
}

/// 타입 좁히기 편의 접근자 (전부 non-resolving — 참조 해소는 M2 액터 소관).
extension COSObject {
  /// `.integer` 값. 그 외 케이스는 `nil`.
  package var integerValue: Int? {
    guard case let .integer(value) = self else {
      return nil
    }
    return value
  }

  /// `.real` 값. `.integer`도 Double로 승격해 반환한다 (스펙: 정수는 실수 문맥에서 호환).
  package var realValue: Double? {
    switch self {
    case let .real(value):
      return value
    case let .integer(value):
      return Double(value)
    default:
      return nil
    }
  }

  /// `.boolean` 값. 그 외 케이스는 `nil`.
  package var booleanValue: Bool? {
    guard case let .boolean(value) = self else {
      return nil
    }
    return value
  }

  /// `.string` 바이트. 그 외 케이스는 `nil`.
  package var stringBytes: [UInt8]? {
    guard case let .string(value) = self else {
      return nil
    }
    return value
  }

  /// `.name` 값. 그 외 케이스는 `nil`.
  package var nameValue: COSName? {
    guard case let .name(value) = self else {
      return nil
    }
    return value
  }

  /// `.array` 값. 그 외 케이스는 `nil`.
  package var arrayValue: [COSObject]? {
    guard case let .array(value) = self else {
      return nil
    }
    return value
  }

  /// `.dictionary` 값. 그 외 케이스는 `nil`.
  package var dictionaryValue: COSDictionary? {
    guard case let .dictionary(value) = self else {
      return nil
    }
    return value
  }

  /// `.stream` 값. 그 외 케이스는 `nil`.
  package var streamValue: COSStream? {
    guard case let .stream(value) = self else {
      return nil
    }
    return value
  }

  /// `.reference` 값. 그 외 케이스는 `nil`.
  package var referenceValue: ObjectID? {
    guard case let .reference(value) = self else {
      return nil
    }
    return value
  }

  /// `.null` 여부.
  package var isNull: Bool {
    if case .null = self {
      return true
    }
    return false
  }
}
