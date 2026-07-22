/// COS 딕셔너리. `[COSName: COSObject]` 래퍼 — 타입드 접근자를 제공한다.
package struct COSDictionary: Sendable, Equatable {
  /// 내부 저장소.
  private var storage: [COSName: COSObject]

  /// 빈 딕셔너리를 생성한다.
  package init() {
    self.storage = [:]
  }

  /// 기존 저장소로부터 생성한다.
  /// - Parameter storage: 초기 키-값 쌍.
  package init(_ storage: [COSName: COSObject]) {
    self.storage = storage
  }

  /// 키에 대한 값을 읽거나 쓴다.
  package subscript(key: COSName) -> COSObject? {
    get {
      self.storage[key]
    }
    set {
      self.storage[key] = newValue
    }
  }

  /// 엔트리 수.
  package var count: Int {
    self.storage.count
  }

  /// 저장된 모든 키.
  package var keys: some Collection<COSName> {
    self.storage.keys
  }

  /// `.integer` 값을 갖는 엔트리 조회. 값이 정수가 아니거나 부재하면 `nil`.
  /// - Parameter key: 조회할 키.
  package func integer(for key: COSName) -> Int? {
    self.storage[key]?.integerValue
  }

  /// `.name` 값을 갖는 엔트리 조회. 값이 이름이 아니거나 부재하면 `nil`.
  /// - Parameter key: 조회할 키.
  package func name(for key: COSName) -> COSName? {
    self.storage[key]?.nameValue
  }

  /// `.array` 값을 갖는 엔트리 조회. 값이 배열이 아니거나 부재하면 `nil`.
  /// - Parameter key: 조회할 키.
  package func array(for key: COSName) -> [COSObject]? {
    self.storage[key]?.arrayValue
  }

  /// `.dictionary` 값을 갖는 엔트리 조회. 값이 딕셔너리가 아니거나 부재하면 `nil`.
  /// - Parameter key: 조회할 키.
  package func dictionary(for key: COSName) -> COSDictionary? {
    self.storage[key]?.dictionaryValue
  }

  /// `.reference` 값을 갖는 엔트리 조회. 값이 참조가 아니거나 부재하면 `nil`.
  /// - Parameter key: 조회할 키.
  package func reference(for key: COSName) -> ObjectID? {
    self.storage[key]?.referenceValue
  }
}
