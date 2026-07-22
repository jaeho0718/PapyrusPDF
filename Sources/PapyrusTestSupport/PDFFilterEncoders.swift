import Compression
import Foundation

/// 필터 라운드트립 테스트용 독립 인코더 모음.
///
/// 검증 대상(PapyrusCore 디코더)과 코드를 공유하지 않는다 — 대조 독립성 확보.
package enum PDFFilterEncoders {
  /// zlib(RFC 1950) 래퍼 포함 Flate 인코딩 (2바이트 헤더 + raw deflate + Adler-32).
  /// - Parameter data: 원본 바이트.
  package static func flate(_ data: Data) -> Data {
    var output = Data([0x78, 0x9C])
    output.append(Self.deflateRaw(data))
    let checksum = Self.adler32(data)
    output.append(UInt8((checksum >> 24) & 0xFF))
    output.append(UInt8((checksum >> 16) & 0xFF))
    output.append(UInt8((checksum >> 8) & 0xFF))
    output.append(UInt8(checksum & 0xFF))
    return output
  }

  /// `z` 축약 없이 인코딩, `~>` EOD 포함.
  /// - Parameter data: 원본 바이트.
  package static func ascii85(_ data: Data) -> Data {
    var out: [UInt8] = []
    let bytes = Array(data)
    var index = 0
    while index < bytes.count {
      let chunkSize = min(4, bytes.count - index)
      var word: UInt32 = 0
      for offset in 0..<4 {
        let byteValue = offset < chunkSize ? bytes[index + offset] : 0
        word = (word << 8) | UInt32(byteValue)
      }
      var digits = [UInt8](repeating: 0, count: 5)
      var value = word
      for position in stride(from: 4, through: 0, by: -1) {
        digits[position] = UInt8(value % 85)
        value /= 85
      }
      let emitCount = chunkSize == 4 ? 5 : chunkSize + 1
      out.append(contentsOf: digits[0..<emitCount].map { $0 + 33 })
      index += chunkSize
    }
    out.append(contentsOf: [UInt8(ascii: "~"), UInt8(ascii: ">")])
    return Data(out)
  }

  /// `>` EOD 포함, 대문자 hex.
  /// - Parameter data: 원본 바이트.
  package static func asciiHex(_ data: Data) -> Data {
    let hexDigits = Array("0123456789ABCDEF".utf8)
    var out: [UInt8] = []
    out.reserveCapacity(data.count * 2 + 1)
    for byte in data {
      out.append(hexDigits[Int(byte >> 4)])
      out.append(hexDigits[Int(byte & 0x0F)])
    }
    out.append(UInt8(ascii: ">"))
    return Data(out)
  }

  /// 리터럴/반복 런 + EOD(128) 포함.
  /// - Parameter data: 원본 바이트.
  package static func runLength(_ data: Data) -> Data {
    let bytes = Array(data)
    var out: [UInt8] = []
    var index = 0
    while index < bytes.count {
      let runLength = Self.repeatRunLength(in: bytes, from: index)
      if runLength >= 2 {
        out.append(UInt8(257 - runLength))
        out.append(bytes[index])
        index += runLength
        continue
      }
      var literalEnd = index + 1
      while literalEnd < bytes.count, literalEnd - index < 128,
        Self.repeatRunLength(in: bytes, from: literalEnd) < 2 {
        literalEnd += 1
      }
      out.append(UInt8(literalEnd - index - 1))
      out.append(contentsOf: bytes[index..<literalEnd])
      index = literalEnd
    }
    out.append(128)
    return Data(out)
  }

  /// PNG 행 필터 태그를 지정해 순방향 필터링 (디코더의 역적용 검증용).
  /// - Parameters:
  ///   - data: 원본(필터 미적용) 샘플 바이트.
  ///   - filterType: PNG 태그 0(None)...4(Paeth).
  ///   - colors: 픽셀당 색상 성분 수.
  ///   - bitsPerComponent: 성분당 비트 수.
  ///   - columns: 행당 픽셀 수.
  package static func pngPredictor(
    _ data: Data, filterType: UInt8, colors: Int, bitsPerComponent: Int, columns: Int
  ) -> Data {
    let bitsPerRow = colors * bitsPerComponent * columns
    let rowBytes = (bitsPerRow + 7) / 8
    guard rowBytes > 0, data.count % rowBytes == 0 else {
      return Data()
    }
    let bpp = max(1, colors * bitsPerComponent / 8)
    let bytes = Array(data)
    let rowCount = bytes.count / rowBytes
    var out: [UInt8] = []
    out.reserveCapacity(rowCount * (rowBytes + 1))
    var previousRow = [UInt8](repeating: 0, count: rowBytes)

    for row in 0..<rowCount {
      let rowStart = row * rowBytes
      let currentRow = Array(bytes[rowStart..<(rowStart + rowBytes)])
      out.append(filterType)
      for column in 0..<rowBytes {
        out.append(Self.filterByte(
          currentRow: currentRow, previousRow: previousRow, column: column,
          bpp: bpp, filterType: filterType
        ))
      }
      previousRow = currentRow
    }
    return Data(out)
  }
}

// MARK: - 내부 헬퍼

extension PDFFilterEncoders {
  /// `index`부터 동일 바이트가 연속되는 길이(최대 128)를 센다.
  private static func repeatRunLength(in bytes: [UInt8], from index: Int) -> Int {
    guard index < bytes.count else {
      return 0
    }
    var length = 1
    while index + length < bytes.count, bytes[index + length] == bytes[index], length < 128 {
      length += 1
    }
    return length
  }

  private static func filterByte(
    currentRow: [UInt8], previousRow: [UInt8], column: Int, bpp: Int, filterType: UInt8
  ) -> UInt8 {
    let raw = currentRow[column]
    let left = column >= bpp ? currentRow[column - bpp] : 0
    let up = previousRow[column]
    let upperLeft = column >= bpp ? previousRow[column - bpp] : 0
    switch filterType {
    case 0:
      return raw
    case 1:
      return raw &- left
    case 2:
      return raw &- up
    case 3:
      return raw &- UInt8((Int(left) + Int(up)) / 2)
    default:
      return raw &- Self.paeth(left: left, above: up, upperLeft: upperLeft)
    }
  }

  /// PNG 스펙 표준 Paeth 예측자.
  private static func paeth(left: UInt8, above: UInt8, upperLeft: UInt8) -> UInt8 {
    let estimate = Int(left) + Int(above) - Int(upperLeft)
    let distanceToLeft = abs(estimate - Int(left))
    let distanceToAbove = abs(estimate - Int(above))
    let distanceToUpperLeft = abs(estimate - Int(upperLeft))
    if distanceToLeft <= distanceToAbove, distanceToLeft <= distanceToUpperLeft {
      return left
    }
    if distanceToAbove <= distanceToUpperLeft {
      return above
    }
    return upperLeft
  }

  /// RFC 1950 Adler-32 체크섬.
  private static func adler32(_ data: Data) -> UInt32 {
    var lowSum: UInt32 = 1
    var highSum: UInt32 = 0
    let modAdler: UInt32 = 65_521
    for byte in data {
      lowSum = (lowSum + UInt32(byte)) % modAdler
      highSum = (highSum + lowSum) % modAdler
    }
    return (highSum << 16) | lowSum
  }

  /// Compression 프레임워크로 raw deflate 바이트열을 만든다 (zlib 래퍼 없음).
  private static func deflateRaw(_ data: Data) -> Data {
    let placeholderOutput = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    let placeholderInput = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    defer {
      placeholderOutput.deallocate()
      placeholderInput.deallocate()
    }
    var stream = compression_stream(
      dst_ptr: placeholderOutput, dst_size: 0, src_ptr: placeholderInput, src_size: 0, state: nil
    )
    guard compression_stream_init(
      &stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB
    ) == COMPRESSION_STATUS_OK else {
      return Data()
    }
    defer { compression_stream_destroy(&stream) }

    var output = Data()
    let bufferSize = 64 * 1_024
    var outputBuffer = [UInt8](repeating: 0, count: bufferSize)
    let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

    data.withUnsafeBytes { (rawInput: UnsafeRawBufferPointer) in
      guard let inputBase = rawInput.bindMemory(to: UInt8.self).baseAddress else {
        return
      }
      stream.src_ptr = inputBase
      stream.src_size = rawInput.count
      while true {
        var status = COMPRESSION_STATUS_OK
        outputBuffer.withUnsafeMutableBytes { (rawOutput: UnsafeMutableRawBufferPointer) in
          guard let outputBase = rawOutput.bindMemory(to: UInt8.self).baseAddress else {
            status = COMPRESSION_STATUS_ERROR
            return
          }
          stream.dst_ptr = outputBase
          stream.dst_size = bufferSize
          status = compression_stream_process(&stream, flags)
          let produced = bufferSize - stream.dst_size
          if produced > 0 {
            output.append(outputBase, count: produced)
          }
        }
        if status != COMPRESSION_STATUS_OK {
          break
        }
      }
    }
    return output
  }
}
