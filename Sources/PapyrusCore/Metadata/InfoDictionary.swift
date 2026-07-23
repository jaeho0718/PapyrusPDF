import Foundation

/// /Info 딕셔너리의 표준 키 해석 결과 (병합 전 중간값).
package struct InfoProperties: Sendable, Equatable {
  /// /Title.
  package var title: String?
  /// /Author.
  package var author: String?
  /// /Subject.
  package var subject: String?
  /// /Keywords.
  package var keywords: String?
  /// /Creator.
  package var creator: String?
  /// /Producer.
  package var producer: String?
  /// /CreationDate.
  package var creationDate: Date?
  /// /ModDate.
  package var modificationDate: Date?

  /// 전 필드 `nil`로 생성한다.
  package init() {
    self.title = nil
    self.author = nil
    self.subject = nil
    self.keywords = nil
    self.creator = nil
    self.producer = nil
    self.creationDate = nil
    self.modificationDate = nil
  }
}

/// /Info 딕셔너리 파서 (순수 동기 — 값은 사전 해소된 직접값이어야 한다).
package enum InfoDictionaryParser {
  /// 표준 8키(/Title /Author /Subject /Keywords /Creator /Producer
  /// /CreationDate /ModDate)를 해석한다. 타입이 문자열이 아닌 값은 무시한다.
  /// - Parameters:
  ///   - dictionary: 값 참조가 사전 해소된 /Info 사본.
  ///   - objectID: /Info 간접 객체의 식별자 — `decryptString` 심 경유에 필요.
  ///     트레일러에 직접 내장된 스펙 위반 파일이면 `nil` (복호화 생략 — v1 항등이라 동작 동일).
  ///   - securityHandler: 문자열 복호화 심 (M2 규약 준수).
  /// - Returns: 해석된 속성 (부재·타입 오염 필드는 `nil`).
  package static func parse(
    _ dictionary: COSDictionary, objectID: ObjectID?, securityHandler: any SecurityHandler
  ) -> InfoProperties {
    var properties = InfoProperties()
    properties.title = Self.string(
      dictionary[.title], objectID: objectID, handler: securityHandler
    )
    properties.author = Self.string(
      dictionary[.author], objectID: objectID, handler: securityHandler
    )
    properties.subject = Self.string(
      dictionary[.subject], objectID: objectID, handler: securityHandler
    )
    properties.keywords = Self.string(
      dictionary[.keywords], objectID: objectID, handler: securityHandler
    )
    properties.creator = Self.string(
      dictionary[.creator], objectID: objectID, handler: securityHandler
    )
    properties.producer = Self.string(
      dictionary[.producer], objectID: objectID, handler: securityHandler
    )
    properties.creationDate = Self.date(
      dictionary[.creationDate], objectID: objectID, handler: securityHandler
    )
    properties.modificationDate = Self.date(
      dictionary[.modDate], objectID: objectID, handler: securityHandler
    )
    return properties
  }

  /// 값이 `.string`이면 (복호화 →) 텍스트 문자열로 디코딩한다. 그 외 타입은 `nil`.
  private static func string(
    _ value: COSObject?, objectID: ObjectID?, handler: any SecurityHandler
  ) -> String? {
    guard let bytes = value?.stringBytes else {
      return nil
    }
    let decrypted = Self.decrypt(bytes, objectID: objectID, handler: handler)
    return PDFTextString.decode(decrypted)
  }

  /// 값이 `.string`이면 (복호화 →) 텍스트 문자열 디코딩 후 PDF 날짜로 파싱한다.
  private static func date(
    _ value: COSObject?, objectID: ObjectID?, handler: any SecurityHandler
  ) -> Date? {
    guard let text = Self.string(value, objectID: objectID, handler: handler) else {
      return nil
    }
    return PDFDateParser.parse(text)
  }

  /// `objectID`가 있으면 보안 핸들러로 복호화한다 (실패 시 원본 바이트 그대로 — 관용).
  private static func decrypt(
    _ bytes: [UInt8], objectID: ObjectID?, handler: any SecurityHandler
  ) -> [UInt8] {
    guard let objectID else {
      return bytes
    }
    return (try? handler.decryptString(bytes, objectID: objectID)) ?? bytes
  }
}
