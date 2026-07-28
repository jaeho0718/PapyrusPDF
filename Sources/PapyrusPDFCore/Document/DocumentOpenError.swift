/// 문서 열기 실패. M3에서 공개 `PapyrusPDFError`로 매핑된다 (§5.4 표).
package enum DocumentOpenError: Error, Sendable, Equatable {
  /// 앞 1KB에서 `%PDF-` 헤더를 찾지 못함.
  case notAPDF

  /// I/O 실패 (파일 열기·매핑).
  case ioError(MappedFileError)

  /// 트레일러에 /Encrypt 존재 — v1은 암호화 문서를 지원하지 않는다.
  /// `filterName`은 진단용 /Filter 이름 (해소 실패 시 nil).
  case encryptedDocument(filterName: String?)

  /// xref 체인·복구 스캔 모두 /Root를 확정하지 못함.
  case damagedBeyondRecovery
}
