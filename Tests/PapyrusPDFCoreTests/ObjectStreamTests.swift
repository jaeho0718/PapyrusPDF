import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// ``ObjectStreamDecoder``·``ObjectStreamCache``·ObjStm 경로 전반을 검증한다 (설계 §3.3.3,
/// §3.4, §4.1, §5.5).
struct ObjectStreamTests {
  // MARK: OS1 — 스타일 무관 동일성

  /// OS1: `.objectStreams` 픽스처의 압축 객체 값이 `.classicTable` 동일 설정과 동일하다.
  @Test func objectStreamsStyleMatchesClassicTableValues() async throws {
    let classic = PDFFixtureBuilder(pageCount: 3, xrefStyle: .classicTable).build()
    let packed = PDFFixtureBuilder(pageCount: 3, xrefStyle: .objectStreams).build()

    let classicDoc = try await PDFDocumentCore.open(data: classic.data)
    let packedDoc = try await PDFDocumentCore.open(data: packed.data)

    for number in 1...5 {
      let id = ObjectID(number: number, generation: 0)
      let classicValue = try await classicDoc.object(for: id)
      let packedValue = try await packedDoc.object(for: id)
      #expect(classicValue == packedValue)
    }
  }

  // MARK: OS2 — 디코더 단위

  /// OS2: `/N`·`/First` 위반 → `invalidStreamDictionary`(`XRefError`로 승격).
  @Test func invalidNOrFirstThrows() {
    let dictionary = COSDictionary([.nKey: .integer(-1), .first: .integer(0)])
    do {
      _ = try ObjectStreamDecoder.decode(raw: Data(), dictionary: dictionary, containerNumber: 1)
      Issue.record("음수 /N은 invalidStreamDictionary여야 함")
    } catch let error as XRefError {
      #expect(error.code == .invalidStreamDictionary)
    } catch {
      Issue.record("XRefError가 아닌 다른 에러: \(error)")
    }
  }

  /// OS2: `/Type` 부재 + `/N`·`/First` 유효 → 관용 수용 + 경고.
  @Test func missingTypeIsAcceptedWithWarning() throws {
    let payload = Data("1 0 42".utf8)
    let dictionary = COSDictionary([.nKey: .integer(1), .first: .integer(3)])
    let result = try ObjectStreamDecoder.decode(
      raw: payload, dictionary: dictionary, containerNumber: 7
    )
    #expect(result.warnings.contains {
      if case let .objectStreamMissingType(containerNumber) = $0 { return containerNumber == 7 }
      return false
    })
    #expect(result.container.members.count == 1)
  }

  /// OS2: 멤버 오프셋이 페이로드 범위 밖 → 해당 멤버만 폐기 + 경고(나머지는 유지).
  @Test func memberOutOfBoundsIsDiscardedButOthersSurvive() throws {
    // 헤더: "1 0 2 999" → 객체 1은 First+0(유효), 객체 2는 First+999(범위 밖).
    let header = "1 0 2 999"
    let first = header.utf8.count + 1
    let payload = Data((header + " 42").utf8)
    let dictionary = COSDictionary([
      .type: .name("ObjStm"), .nKey: .integer(2), .first: .integer(first)
    ])
    let result = try ObjectStreamDecoder.decode(
      raw: payload, dictionary: dictionary, containerNumber: 3
    )
    #expect(result.container.members.map(\.objectNumber) == [1])
    #expect(result.warnings.contains {
      if case let .objectStreamMemberOutOfBounds(containerNumber, objectNumber) = $0 {
        return containerNumber == 3 && objectNumber == 2
      }
      return false
    })
  }

  /// OS2: 헤더 정수 쌍이 `/N`에 못 미침 → `parseFailed`.
  @Test func insufficientHeaderPairsThrowsParseFailed() {
    let dictionary = COSDictionary([
      .type: .name("ObjStm"), .nKey: .integer(3), .first: .integer(10)
    ])
    do {
      _ = try ObjectStreamDecoder.decode(
        raw: Data("1 0".utf8), dictionary: dictionary, containerNumber: 1
      )
      Issue.record("헤더 정수 부족은 parseFailed여야 함")
    } catch let error as XRefError {
      #expect(error.code == .parseFailed)
    } catch {
      Issue.record("XRefError가 아닌 다른 에러: \(error)")
    }
  }

  // MARK: OS3 — 재귀 차단 가드

  /// OS3: 컨테이너 자신이 xref상 compressed로 표기된 수제 변형 → 멤버 해소는 `.null`.
  @Test func containerMarkedAsCompressedResolvesToNull() async throws {
    let data = Self.makeMaliciousContainerFixture()
    let document = try await PDFDocumentCore.open(data: data)
    let resolved = try await document.object(for: ObjectID(number: 5, generation: 0))
    #expect(resolved == .null)
  }

  // MARK: OS4 — LRU 예산

  /// OS4: 작은 예산으로 컨테이너 2개 초과 삽입 시 LRU 퇴거, 단일 초과 항목은 미삽입.
  @Test func lruBudgetEvictsLeastRecentlyUsed() {
    var cache = ObjectStreamCache(budget: 100)
    let small1 = DecodedObjectStream(payload: Data(repeating: 0, count: 40), members: [])
    let small2 = DecodedObjectStream(payload: Data(repeating: 0, count: 40), members: [])
    let small3 = DecodedObjectStream(payload: Data(repeating: 0, count: 40), members: [])

    cache.insert(small1, number: 1)
    cache.insert(small2, number: 2)
    #expect(cache.count == 2)

    cache.insert(small3, number: 3)
    #expect(cache.count == 2)
    #expect(cache.container(number: 1) == nil)
    #expect(cache.container(number: 2) != nil)
    #expect(cache.container(number: 3) != nil)

    let tooLarge = DecodedObjectStream(payload: Data(repeating: 0, count: 1_000), members: [])
    let beforeCount = cache.count
    let beforeCost = cache.totalCost
    cache.insert(tooLarge, number: 99)
    #expect(cache.count == beforeCount)
    #expect(cache.totalCost == beforeCost)
    #expect(cache.container(number: 99) == nil)
  }

  // MARK: OS5 — 캐시 dedupe

  /// OS5: 같은 컨테이너의 멤버 32개를 `TaskGroup` 동시 요청 → `containerDecodeCount == 1`.
  @Test func concurrentAccessDecodesContainerOnce() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 30, xrefStyle: .objectStreams).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)

    try await withThrowingTaskGroup(of: COSObject.self) { group in
      for number in 1...32 {
        group.addTask {
          try await document.object(for: ObjectID(number: number, generation: 0))
        }
      }
      for try await _ in group {}
    }

    let stats = await document.cacheStatistics()
    #expect(stats.containerDecodeCount == 1)
  }

  // MARK: OS6 — 캐시 히트

  /// OS6: 순차 재요청 → `containerDecodeCount` 불변.
  @Test func sequentialReaccessDoesNotRedecodeContainer() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 3, xrefStyle: .objectStreams).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)

    _ = try await document.object(for: ObjectID(number: 1, generation: 0))
    let firstCount = await document.cacheStatistics().containerDecodeCount
    #expect(firstCount == 1)

    for _ in 0..<5 {
      _ = try await document.object(for: ObjectID(number: 1, generation: 0))
    }
    let secondCount = await document.cacheStatistics().containerDecodeCount
    #expect(secondCount == firstCount)
  }
}

// MARK: - OS3 전용 픽스처

extension ObjectStreamTests {
  /// 컨테이너(10)의 xref 엔트리 자체를 compressed(존재하지 않는 컨테이너 999)로 표기한
  /// 수제 xref 스트림 픽스처. 객체 5는 컨테이너 10 안에 압축된 것으로 선언된다.
  private static func makeMaliciousContainerFixture() -> Data {
    var writer: [UInt8] = Array("%PDF-1.7\n".utf8)
    var objectOffsets: [Int: Int] = [:]
    Self.writeMaliciousContainerBody(writer: &writer, objectOffsets: &objectOffsets)
    Self.writeMaliciousXRefStream(writer: &writer, objectOffsets: objectOffsets)
    return Data(writer)
  }

  /// Catalog(1)·Pages(2)·ObjStm 컨테이너(10, 멤버로 객체 5 보유)를 기록한다.
  private static func writeMaliciousContainerBody(
    writer: inout [UInt8], objectOffsets: inout [Int: Int]
  ) {
    func writeLine(_ text: String) {
      writer.append(contentsOf: Array(text.utf8))
      writer.append(0x0A)
    }

    objectOffsets[1] = writer.count
    writeLine("1 0 obj")
    writeLine("<< /Type /Catalog /Pages 2 0 R >>")
    writeLine("endobj")

    objectOffsets[2] = writer.count
    writeLine("2 0 obj")
    writeLine("<< /Type /Pages /Kids [] /Count 0 >>")
    writeLine("endobj")

    let containerPayload = "5 0 42"
    objectOffsets[10] = writer.count
    writeLine("10 0 obj")
    writeLine("<< /Type /ObjStm /N 1 /First 4 /Length \(containerPayload.utf8.count) >>")
    writeLine("stream")
    writer.append(contentsOf: Array(containerPayload.utf8))
    writer.append(0x0A)
    writeLine("endstream")
    writeLine("endobj")
  }

  /// 객체 11(xref 스트림)을 기록한다: 1,2,10은 uncompressed, 5는 컨테이너 10 안에
  /// 압축(index 0)되어 있으나, 10 자신도 (악의적으로) 존재하지 않는 컨테이너 999 안에
  /// 압축된 것으로 표기한다.
  private static func writeMaliciousXRefStream(writer: inout [UInt8], objectOffsets: [Int: Int]) {
    func writeLine(_ text: String) {
      writer.append(contentsOf: Array(text.utf8))
      writer.append(0x0A)
    }

    let xrefStreamNumber = 11
    let size = xrefStreamNumber + 1
    var entries: [Int: XRefStreamSnippetRow] = [
      0: XRefStreamSnippetRow(type: 0, field2: 0, field3: 0),
      1: XRefStreamSnippetRow(type: 1, field2: objectOffsets[1]!, field3: 0),
      2: XRefStreamSnippetRow(type: 1, field2: objectOffsets[2]!, field3: 0),
      10: XRefStreamSnippetRow(type: 2, field2: 999, field3: 0),
      5: XRefStreamSnippetRow(type: 2, field2: 10, field3: 0)
    ]
    let selfOffset = writer.count
    entries[xrefStreamNumber] = XRefStreamSnippetRow(type: 1, field2: selfOffset, field3: 0)

    var rows: [UInt8] = []
    for number in 0..<size {
      let row = entries[number] ?? XRefStreamSnippetRow(type: 0, field2: 0, field3: 0)
      rows.append(UInt8(row.type))
      rows.append(contentsOf: bigEndian(row.field2, width: 4))
      rows.append(contentsOf: bigEndian(row.field3, width: 2))
    }
    let rowData = Data(rows)

    writeLine("\(xrefStreamNumber) 0 obj")
    writeLine(
      "<< /Type /XRef /W [1 4 2] /Size \(size) /Root 1 0 R /Length \(rowData.count) >>"
    )
    writeLine("stream")
    writer.append(contentsOf: rowData)
    writer.append(0x0A)
    writeLine("endstream")
    writeLine("endobj")
    writeLine("startxref")
    writeLine("\(selfOffset)")
    writer.append(contentsOf: Array("%%EOF".utf8))
  }
}
