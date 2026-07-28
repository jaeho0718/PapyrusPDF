/// ASCII 기반 PDF 바이트 조립기. 현재 오프셋을 추적한다.
struct PDFByteWriter {
  /// 지금까지 기록된 바이트.
  private(set) var bytes: [UInt8]

  /// 빈 조립기를 생성한다.
  init() {
    self.bytes = []
  }

  /// 기존 바이트 뒤에 이어 기록할 조립기를 생성한다 (증분 업데이트 덧붙임용).
  /// - Parameter existingBytes: 이미 기록된 바이트.
  init(existingBytes: [UInt8]) {
    self.bytes = existingBytes
  }

  /// 현재 기록 위치(= bytes.count). xref 오프셋 기록에 사용.
  var offset: Int {
    self.bytes.count
  }

  /// ASCII 문자열을 기록한다. 비ASCII 스칼라는 프로그래머 오류 — precondition으로 잡는다.
  mutating func write(_ ascii: String) {
    for scalar in ascii.unicodeScalars {
      precondition(scalar.isASCII, "PDFByteWriter.write는 ASCII 문자열만 허용한다: \(ascii)")
      self.bytes.append(UInt8(scalar.value))
    }
  }

  /// ASCII 문자열 + LF 를 기록한다.
  mutating func writeLine(_ ascii: String) {
    self.write(ascii)
    self.bytes.append(0x0A)
  }

  /// 원시 바이트를 기록한다 (헤더의 바이너리 마커 주석용).
  mutating func write(rawBytes: [UInt8]) {
    self.bytes.append(contentsOf: rawBytes)
  }
}
