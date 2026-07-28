import Foundation

/// `/ASCII85Decode` (`/A85`) 디코더.
package enum ASCII85Decode {
  /// base-85 텍스트를 바이트로 디코딩한다.
  ///
  /// 선행 `<~` 헤더(비표준 btoa 관용), `z` 축약(그룹 시작에서만), `~>` EOD를 지원한다.
  /// EOD 없이 입력이 소진되면 잔여 그룹을 EOD와 동일한 규칙으로 관용 수용한다.
  ///
  /// - Note: `~` 하나만 보면 그 즉시 EOD로 간주하고 종료한다 — 표준 EOD는 `~>` 2바이트지만,
  ///   `~` 직후 바이트가 실제로 `>`인지는 검증하지 않는다(있어도 없어도 무시). 이는 설계보다
  ///   관용적인 선택으로, `~` 뒤에 `>`가 아닌 쓰레기 바이트가 오는 손상 파일도 조용히
  ///   성공 처리한다는 뜻이다. 데이터 무결성에는 영향이 없다 — EOD 이후 바이트는 애초에
  ///   출력에 반영되지 않기 때문이다.
  /// - Parameter data: 인코딩된 바이트.
  /// - Throws: 알파벳 밖 문자·그룹 중간 `z`는 ``FilterError/Code/invalidCharacter``,
  ///   1문자 잔여 그룹은 `truncatedData`, 32비트 초과 그룹은 `corruptedData`.
  package static func decode(_ data: Data) throws(FilterError) -> Data {
    let bytes = Array(data)
    var index = Self.headerLength(in: bytes)
    var out: [UInt8] = []
    var group: [UInt8] = []
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      if byte == UInt8(ascii: "~") {
        break
      }
      try Self.consume(byte, group: &group, out: &out)
    }
    try Self.finalizeResidualGroup(&group, out: &out)
    return Data(out)
  }

  /// 선행 `<~` 헤더(비표준 btoa 관용)를 인식해 건너뛸 길이를 반환한다.
  private static func headerLength(in bytes: [UInt8]) -> Int {
    guard bytes.count >= 2, bytes[0] == UInt8(ascii: "<"), bytes[1] == UInt8(ascii: "~") else {
      return 0
    }
    return 2
  }

  /// 바이트 하나를 소비한다: 공백 무시, `z` 축약(그룹 시작에서만), 알파벳 문자는 그룹에
  /// 누적하고 5개가 차면 즉시 방출한다.
  private static func consume(
    _ byte: UInt8, group: inout [UInt8], out: inout [UInt8]
  ) throws(FilterError) {
    if Self.isWhitespace(byte) {
      return
    }
    if byte == UInt8(ascii: "z") {
      guard group.isEmpty else {
        throw FilterError(code: .invalidCharacter)
      }
      out.append(contentsOf: [0, 0, 0, 0])
      return
    }
    guard (33...117).contains(Int(byte)) else {
      throw FilterError(code: .invalidCharacter)
    }
    group.append(byte - 33)
    if group.count == 5 {
      try Self.flush(group, outputCount: 4, into: &out)
      group.removeAll(keepingCapacity: true)
    }
  }

  /// EOD(또는 EOF)에서 잔여 그룹을 `u`로 패딩해 방출한다. 1문자 잔여는 `truncatedData`.
  private static func finalizeResidualGroup(
    _ group: inout [UInt8], out: inout [UInt8]
  ) throws(FilterError) {
    guard !group.isEmpty else {
      return
    }
    guard group.count >= 2 else {
      throw FilterError(code: .truncatedData)
    }
    let outputCount = group.count - 1
    while group.count < 5 {
      group.append(84)
    }
    try Self.flush(group, outputCount: outputCount, into: &out)
  }

  /// 니블 5개(0...84)를 32비트 값으로 조립해 빅엔디언 바이트로 방출한다.
  private static func flush(
    _ group: [UInt8], outputCount: Int, into out: inout [UInt8]
  ) throws(FilterError) {
    var value: UInt64 = 0
    for digit in group {
      value = value * 85 + UInt64(digit)
    }
    guard value <= UInt64(UInt32.max) else {
      throw FilterError(code: .corruptedData)
    }
    let word = UInt32(value)
    let allBytes: [UInt8] = [
      UInt8((word >> 24) & 0xFF), UInt8((word >> 16) & 0xFF),
      UInt8((word >> 8) & 0xFF), UInt8(word & 0xFF)
    ]
    out.append(contentsOf: allBytes.prefix(outputCount))
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20:
      return true
    default:
      return false
    }
  }
}
