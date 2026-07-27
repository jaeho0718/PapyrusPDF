/// 스트림 객체. 디코딩된 바이트가 아니라 **원본 내 위치**만 보유한다 (온디맨드 디코딩).
package struct COSStream: Sendable, Equatable {
  /// 스트림 딕셔너리 (/Length, /Filter, /DecodeParms ...).
  package let dictionary: COSDictionary

  /// 인코딩된 페이로드의 위치.
  package let payload: Payload

  /// 페이로드 위치 표현. M2에서 `.objectStreamSlice(container:range:)` 케이스가 추가된다.
  package enum Payload: Sendable, Equatable {
    /// MappedFile 내 절대 바이트 구간 (인코딩 상태 그대로).
    case fileRange(Range<Int>)
  }

  /// 스트림을 생성한다.
  /// - Parameters:
  ///   - dictionary: 스트림 딕셔너리.
  ///   - payload: 인코딩된 페이로드의 위치.
  package init(dictionary: COSDictionary, payload: Payload) {
    self.dictionary = dictionary
    self.payload = payload
  }
}
