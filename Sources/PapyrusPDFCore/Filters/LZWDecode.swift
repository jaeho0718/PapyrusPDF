import Foundation

/// PDF 가변폭 LZW 디코더 (9~12비트, MSB-first, `/EarlyChange` 지원).
package enum LZWDecode {
  /// LZW 스트림을 디코딩한다.
  ///
  /// 관용 규칙: EOD(257) 없이 입력이 소진되면 누적 출력을 그대로 반환한다
  /// (실파일 다수가 EOD 생략). 테이블이 4096에 도달하면 신규 등록만 중단하고
  /// 기존 코드는 계속 디코딩한다.
  /// - Parameters:
  ///   - data: 인코딩된 바이트.
  ///   - earlyChange: 코드 폭을 한 코드 이르게 늘리는가 (`/EarlyChange`, 기본 `true`).
  ///   - maxDecodedSize: 방출 바이트 상한 (압축 폭탄 가드).
  /// - Throws: 미등록 코드 참조(> next) 시 ``FilterError/Code/corruptedData``,
  ///   상한 초과 시 `outputLimitExceeded`.
  package static func decode(
    _ data: Data, earlyChange: Bool, maxDecodedSize: Int
  ) throws(FilterError) -> Data {
    var reader = BitReader(data)
    var table = CodeTable()
    var width = 9
    var prev: Int?
    var output: [UInt8] = []

    while let code = reader.readBits(width) {
      if code == Self.clearCode {
        table.reset()
        width = 9
        prev = nil
        continue
      }
      if code == Self.eodCode {
        break
      }
      guard code <= table.next, code != table.next || prev != nil else {
        throw FilterError(code: .corruptedData)
      }

      let entry = try Self.resolveEntry(code: code, prev: prev, table: table)
      output.append(contentsOf: entry)
      guard output.count <= maxDecodedSize else {
        throw FilterError(code: .outputLimitExceeded)
      }

      if let prev, table.next < 4_096 {
        table.register(prefix: prev, firstByte: entry[0])
      }
      if width < 12, table.next + (earlyChange ? 1 : 0) == 1 << width {
        width += 1
      }
      prev = code
    }
    return Data(output)
  }

  /// 테이블 리셋 코드 (256).
  private static let clearCode = 256

  /// 종료(EOD) 코드 (257).
  private static let eodCode = 257

  /// 현재 코드에 대응하는 바이트열을 결정한다 (리터럴/등록된 코드/KwKwK).
  private static func resolveEntry(
    code: Int, prev: Int?, table: CodeTable
  ) throws(FilterError) -> [UInt8] {
    if code < 256 {
      return [UInt8(code)]
    }
    if code < table.next {
      return table.expand(code)
    }
    guard let prev else {
      throw FilterError(code: .corruptedData)
    }
    let prevExpansion = table.expand(prev)
    return prevExpansion + [prevExpansion[0]]
  }
}

// MARK: - 코드 테이블 (258..<4096)

extension LZWDecode {
  /// LZW 사전 테이블 — prefix 체인 + 마지막 바이트 + 체인 길이를 배열 3개로 보관한다.
  private struct CodeTable {
    /// 다음에 등록될 코드 번호.
    private(set) var next = 258

    /// `code`의 접두 코드 (`code < 256`이면 접두 없음 — 인덱스 미사용).
    private var prefix = [UInt16](repeating: 0, count: 4_096)

    /// `code`가 자신의 접두에 덧붙이는 마지막 바이트.
    private var suffix = [UInt8](repeating: 0, count: 4_096)

    /// `code`가 나타내는 바이트열의 총 길이.
    private var length = [Int32](repeating: 0, count: 4_096)

    /// 테이블을 초기 상태(258, 등록 없음)로 되돌린다.
    mutating func reset() {
      self.next = 258
    }

    /// `prefix`의 바이트열 뒤에 `firstByte`를 덧붙인 새 엔트리를 등록한다.
    mutating func register(prefix: Int, firstByte: UInt8) {
      self.prefix[self.next] = UInt16(prefix)
      self.suffix[self.next] = firstByte
      self.length[self.next] = Int32(self.lengthOf(prefix)) + 1
      self.next += 1
    }

    /// `code`가 나타내는 바이트열을 접두 체인을 따라 복원한다.
    ///
    /// `length`를 선계산해 두었으므로 정확한 크기로 1회 할당하고, 뒤에서부터
    /// 채워나가는 O(출력 길이) 알고리즘이다 (재귀 없음).
    func expand(_ code: Int) -> [UInt8] {
      let count = self.lengthOf(code)
      var buffer = [UInt8](repeating: 0, count: count)
      var current = code
      var index = count - 1
      while current >= 256 {
        buffer[index] = self.suffix[current]
        index -= 1
        current = Int(self.prefix[current])
      }
      buffer[index] = UInt8(current)
      return buffer
    }

    /// `code`가 나타내는 바이트열의 길이 (리터럴은 항상 1).
    private func lengthOf(_ code: Int) -> Int {
      code < 256 ? 1 : Int(self.length[code])
    }
  }
}

// MARK: - MSB-first 비트 리더

extension LZWDecode {
  /// 바이트 배열에서 MSB-first로 `width`비트씩 읽는 리더.
  private struct BitReader {
    private let bytes: [UInt8]
    private var byteIndex = 0
    private var bitBuffer: UInt32 = 0
    private var bitCount = 0

    init(_ data: Data) {
      self.bytes = Array(data)
    }

    /// `width`비트를 읽는다. 잔여 비트가 부족하면 `nil` (관용 종료 신호).
    mutating func readBits(_ width: Int) -> Int? {
      while self.bitCount < width, self.byteIndex < self.bytes.count {
        self.bitBuffer = (self.bitBuffer << 8) | UInt32(self.bytes[self.byteIndex])
        self.byteIndex += 1
        self.bitCount += 8
      }
      guard self.bitCount >= width else {
        return nil
      }
      let shift = self.bitCount - width
      let mask: UInt32 = width >= 32 ? .max : (1 << width) - 1
      let value = Int((self.bitBuffer >> shift) & mask)
      self.bitCount -= width
      self.bitBuffer &= self.bitCount >= 32 ? .max : (1 << self.bitCount) - 1
      return value
    }
  }
}
