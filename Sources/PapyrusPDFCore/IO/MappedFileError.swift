/// ``MappedFile`` 생성 실패.
package enum MappedFileError: Error, Sendable, Equatable {
  /// 파일을 열거나 매핑하지 못했다 (원인 메시지는 진단용).
  case openFailed(path: String, reason: String)
}
