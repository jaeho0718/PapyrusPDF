import Foundation
@testable import PapyrusCore
import Testing

/// ``MappedFile``의 경계 검사·재배치·매핑 왕복을 검증한다.
struct MappedFileTests {
  // MARK: MF1 — 기본 접근 정합성

  /// MF1: `init(data:)` 후 `count`·`byte(at:)`가 원본과 정합하고, 범위 밖 오프셋은 `nil`.
  @Test func byteAccessMatchesSourceAndRejectsOutOfRange() {
    let bytes: [UInt8] = [0x10, 0x20, 0x30, 0x40]
    let file = MappedFile(data: Data(bytes))

    #expect(file.count == bytes.count)
    for (index, expected) in bytes.enumerated() {
      #expect(file.byte(at: index) == expected)
    }
    #expect(file.byte(at: -1) == nil)
    #expect(file.byte(at: bytes.count) == nil)
    #expect(file.byte(at: bytes.count + 100) == nil)
  }

  // MARK: MF2 — bytes(in:) 경계

  /// MF2: 정상 구간은 값이 일치하고, 상한 초과·역전 구간은 `nil`, 빈 구간은 빈 `Data`.
  @Test func bytesInRangeHandlesBoundaries() {
    let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
    let file = MappedFile(data: Data(bytes))

    #expect(file.bytes(in: 1..<4) == Data([0x02, 0x03, 0x04]))
    #expect(file.bytes(in: 0..<5) == Data(bytes))
    #expect(file.bytes(in: 2..<2) == Data())
    #expect(file.bytes(in: 0..<6) == nil)
    #expect(file.bytes(in: -1..<3) == nil)
  }

  // MARK: MF3 — 비-0 startIndex 슬라이스 재배치

  /// MF3: `data.dropFirst(k)`로 만든 슬라이스도 0 기반으로 동작한다.
  @Test func nonZeroStartIndexSliceIsRebased() {
    let bytes: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE]
    let slice = Data(bytes).dropFirst(2)
    #expect(slice.startIndex != 0)

    let file = MappedFile(data: slice)
    #expect(file.count == 3)
    #expect(file.byte(at: 0) == 0xCC)
    #expect(file.byte(at: 2) == 0xEE)
    #expect(file.byte(at: 3) == nil)
    #expect(file.bytes(in: 0..<3) == Data([0xCC, 0xDD, 0xEE]))
  }

  // MARK: MF4 — 파일 왕복

  /// MF4: 임시 파일을 왕복해 열고, 존재하지 않는 경로는 `openFailed`로 실패한다.
  @Test func fileRoundTripsAndReportsOpenFailure() throws {
    let bytes: [UInt8] = Array("hello mapped file".utf8)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("bin")
    try Data(bytes).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let file = try MappedFile(url: url)
    #expect(file.count == bytes.count)
    #expect(file.bytes(in: 0..<bytes.count) == Data(bytes))

    let missingURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("missing")
    do {
      _ = try MappedFile(url: missingURL)
      Issue.record("존재하지 않는 경로에서 열기가 성공했다")
    } catch {
      guard case .openFailed = error else {
        Issue.record("예상치 못한 에러: \(error)")
        return
      }
    }
  }

  // MARK: MF5 — withUnsafeBytes 정합성

  /// MF5: `withUnsafeBytes`로 읽은 내용이 `byte(at:)` 순회 결과와 일치한다.
  @Test func withUnsafeBytesMatchesByteTraversal() {
    let bytes: [UInt8] = (0..<64).map { UInt8($0 * 3 % 256) }
    let file = MappedFile(data: Data(bytes))

    let viaUnsafe = file.withUnsafeBytes { buffer in
      Array(buffer.bindMemory(to: UInt8.self))
    }
    let viaByteAt = (0..<file.count).map { file.byte(at: $0)! }
    #expect(viaUnsafe == viaByteAt)
  }
}
