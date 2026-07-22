import Compression
import Foundation

/// RFC 1950(zlib) 래핑된 DEFLATE 디코더. Apple Compression 프레임워크 기반.
///
/// `COMPRESSION_ZLIB` 알고리즘은 zlib 래퍼(2바이트 헤더 + Adler-32 트레일러)가 아닌
/// **raw deflate**만 처리하므로, zlib 헤더는 여기서 직접 검사·제거하고 트레일러는 무시한다.
package enum FlateDecode {
  /// 화이트스페이스로 시작할 수 있는 zlib 스트림을 디코딩한다.
  /// - Parameters:
  ///   - data: 인코딩된 바이트 (선행 공백 관용).
  ///   - maxDecodedSize: 방출 바이트 상한 (압축 폭탄 가드).
  /// - Throws: 구조적 손상·절단·출력 상한 초과 시 ``FilterError``.
  package static func decode(_ data: Data, maxDecodedSize: Int) throws(FilterError) -> Data {
    let trimmed = Self.dropLeadingWhitespace(data)
    guard !trimmed.isEmpty else {
      return Data()
    }
    let payload = try Self.stripZlibHeader(trimmed)
    return try Self.inflate(payload, maxDecodedSize: maxDecodedSize)
  }

  /// 선행 ASCII 공백 바이트를 건너뛴다 (Length 오프바이원으로 EOL이 섞인 실파일 관용).
  private static func dropLeadingWhitespace(_ data: Data) -> Data {
    var start = data.startIndex
    while start < data.endIndex, Self.isWhitespace(data[start]) {
      start += 1
    }
    return data[start...]
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20:
      return true
    default:
      return false
    }
  }

  /// zlib 헤더(CM=deflate, FCHECK 정합)를 검사해 제거한다.
  ///
  /// 헤더 패턴이 아니면 원본을 그대로 반환한다 — 실파일 관용(raw deflate로 간주).
  /// FDICT 비트가 설정돼 있으면 (프리셋 사전은 PDF에서 불법) 즉시 실패한다.
  private static func stripZlibHeader(_ data: Data) throws(FilterError) -> Data {
    guard data.count >= 2 else {
      return data
    }
    let b0 = data[data.startIndex]
    let b1 = data[data.startIndex + 1]
    guard b0 & 0x0F == 8, (UInt16(b0) << 8 | UInt16(b1)) % 31 == 0 else {
      return data
    }
    guard b1 & 0x20 == 0 else {
      throw FilterError(code: .corruptedData)
    }
    return data.dropFirst(2)
  }

  /// `compression_stream`으로 raw deflate 바이트열을 해제한다.
  private static func inflate(_ data: Data, maxDecodedSize: Int) throws(FilterError) -> Data {
    guard !data.isEmpty else {
      return Data()
    }

    var stream = try Self.makeDecodeStream()
    defer { compression_stream_destroy(&stream) }

    var output = Data()
    var outputBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
    // 입력 전체를 한 번에 공급하므로 항상 FINALIZE를 설정한다 — 그래야 손상·절단된
    // 스트림에서 디코더가 OK를 무한 반환하지 않고 END/ERROR로 확정 응답한다.
    let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
    var thrown: FilterError?

    data.withUnsafeBytes { (rawInput: UnsafeRawBufferPointer) in
      guard let inputBase = rawInput.bindMemory(to: UInt8.self).baseAddress else {
        return
      }
      stream.src_ptr = inputBase
      stream.src_size = rawInput.count
      thrown = Self.runDecodeLoop(
        stream: &stream, outputBuffer: &outputBuffer, flags: flags,
        maxDecodedSize: maxDecodedSize, output: &output
      )
    }

    if let thrown {
      throw thrown
    }
    return output
  }

  /// 자리표시자로 초기화한 뒤 DECODE용으로 `compression_stream_init`한다.
  ///
  /// `dst_ptr`/`src_ptr`는 non-optional이라 init 시점에 유효한 포인터가 필요하다 —
  /// 실제 처리 전에 호출부가 진짜 버퍼로 즉시 덮어쓴다.
  private static func makeDecodeStream() throws(FilterError) -> compression_stream {
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
      &stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB
    ) == COMPRESSION_STATUS_OK else {
      throw FilterError(code: .corruptedData)
    }
    return stream
  }

  /// `stream.src_ptr`/`src_size`가 이미 설정된 상태에서 END/ERROR까지 반복 방출한다.
  /// - Returns: 실패 사유. 성공적으로 END에 도달하면 `nil`.
  private static func runDecodeLoop(
    stream: inout compression_stream, outputBuffer: inout [UInt8], flags: Int32,
    maxDecodedSize: Int, output: inout Data
  ) -> FilterError? {
    let bufferSize = outputBuffer.count
    while true {
      var status = COMPRESSION_STATUS_OK
      var produced = 0
      outputBuffer.withUnsafeMutableBytes { (rawOutput: UnsafeMutableRawBufferPointer) in
        guard let outputBase = rawOutput.bindMemory(to: UInt8.self).baseAddress else {
          status = COMPRESSION_STATUS_ERROR
          return
        }
        stream.dst_ptr = outputBase
        stream.dst_size = bufferSize
        status = compression_stream_process(&stream, flags)
        produced = bufferSize - stream.dst_size
        if produced > 0 {
          output.append(outputBase, count: produced)
        }
      }

      if output.count > maxDecodedSize {
        return FilterError(code: .outputLimitExceeded)
      }

      switch status {
      case COMPRESSION_STATUS_OK:
        // dst 버퍼가 가득 차 잘려 나온 것뿐일 수 있으므로(produced > 0), 그 경우는 다음
        // 호출로 계속 방출한다. "진전 없음"(produced == 0)이면서 남은 입력도 없을
        // 때만 완결되지 못한 스트림으로 판단한다.
        if produced == 0, stream.src_size == 0 {
          return FilterError(code: .truncatedData)
        }
      case COMPRESSION_STATUS_END:
        return nil
      default:
        return FilterError(code: .corruptedData)
      }
    }
  }
}
