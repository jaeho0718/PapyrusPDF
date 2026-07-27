import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// ``XRefStreamParser``의 xref 스트림 파싱을 검증한다 (설계 §3.3.2, §5.2).
struct XRefStreamParserTests {
  // MARK: XS1 — 픽스처 골든

  /// XS1: 픽스처 `.xrefStream` 골든 — 엔트리·트레일러가 `objectOffsets`와 정합한다
  /// (predictor 12 경유 디코딩 검증 포함).
  @Test func fixtureGoldenMatchesObjectOffsets() throws {
    let fixture = PDFFixtureBuilder(pageCount: 2, xrefStyle: .xrefStream).build()
    let file = MappedFile(data: fixture.data)
    let result = try XRefStreamParser(file: file).parseSection(at: fixture.xrefOffset)

    // object 0(free 헤드)도 xref 스트림에서는 엔트리로 저장된다 — 클래식 테이블과의 차이.
    #expect(Set(result.section.entries.keys) == Set(fixture.objectOffsets.keys).union([0]))
    #expect(result.section.entries[0] == .free)
    for (number, offset) in fixture.objectOffsets {
      #expect(result.section.entries[number] == .uncompressed(offset: offset, generation: 0))
    }
    #expect(result.section.trailer[.root] == .reference(ObjectID(number: 1, generation: 0)))
    #expect(result.warnings.isEmpty)
  }

  // MARK: XS2 — /W 변형

  /// XS2: `[1 4 2]` 표준 — 필드가 그대로 해석된다.
  @Test func standardFieldWidthsDecodeAsGiven() throws {
    let bytes = makeXRefStreamObjectBytes(
      objectNumber: 1, widths: [1, 4, 2], index: nil, size: 2,
      rows: [
        XRefStreamSnippetRow(type: 0, field2: 0, field3: 0),
        XRefStreamSnippetRow(type: 1, field2: 500, field3: 7)
      ],
      extraDictText: "/Type /XRef", applyFlate: false
    )
    let file = MappedFile(data: bytes)
    let result = try XRefStreamParser(file: file).parseSection(at: 0)
    #expect(result.section.entries[1] == .uncompressed(offset: 500, generation: 7))
  }

  /// XS2: `[0 4 2]` — w1=0이면 타입은 항상 1(uncompressed) 기본값이다.
  @Test func zeroTypeWidthDefaultsToUncompressed() throws {
    let bytes = makeXRefStreamObjectBytes(
      objectNumber: 1, widths: [0, 4, 2], index: nil, size: 2,
      rows: [
        XRefStreamSnippetRow(type: 0, field2: 10, field3: 0),
        XRefStreamSnippetRow(type: 0, field2: 500, field3: 7)
      ],
      extraDictText: "/Type /XRef", applyFlate: false
    )
    let file = MappedFile(data: bytes)
    let result = try XRefStreamParser(file: file).parseSection(at: 0)
    #expect(result.section.entries[0] == .uncompressed(offset: 10, generation: 0))
    #expect(result.section.entries[1] == .uncompressed(offset: 500, generation: 7))
  }

  /// XS2: `[1 4 0]` — w3=0이면 필드3(세대)은 항상 0이다.
  @Test func zeroField3WidthDefaultsToZero() throws {
    let bytes = makeXRefStreamObjectBytes(
      objectNumber: 1, widths: [1, 4, 0], index: nil, size: 2,
      rows: [
        XRefStreamSnippetRow(type: 0, field2: 0, field3: 0),
        XRefStreamSnippetRow(type: 1, field2: 500, field3: 99)
      ],
      extraDictText: "/Type /XRef", applyFlate: false
    )
    let file = MappedFile(data: bytes)
    let result = try XRefStreamParser(file: file).parseSection(at: 0)
    #expect(result.section.entries[1] == .uncompressed(offset: 500, generation: 0))
  }

  /// XS2: `[2 8 2]` 광폭 필드 — 큰 오프셋도 정확히 복원된다.
  @Test func wideFieldWidthsDecodeLargeOffsets() throws {
    let bytes = makeXRefStreamObjectBytes(
      objectNumber: 1, widths: [2, 8, 2], index: nil, size: 2,
      rows: [
        XRefStreamSnippetRow(type: 0, field2: 0, field3: 0),
        XRefStreamSnippetRow(type: 1, field2: 123_456_789, field3: 3)
      ],
      extraDictText: "/Type /XRef", applyFlate: false
    )
    let file = MappedFile(data: bytes)
    let result = try XRefStreamParser(file: file).parseSection(at: 0)
    #expect(result.section.entries[1] == .uncompressed(offset: 123_456_789, generation: 3))
  }

  // MARK: XS3 — /Index 변형

  /// XS3: `/Index` 부재 → 기본 `[0 Size]`.
  @Test func missingIndexDefaultsToFullRange() throws {
    let bytes = makeXRefStreamObjectBytes(
      objectNumber: 1, widths: [1, 4, 2], index: nil, size: 2,
      rows: [
        XRefStreamSnippetRow(type: 0, field2: 0, field3: 0),
        XRefStreamSnippetRow(type: 1, field2: 42, field3: 0)
      ],
      extraDictText: "/Type /XRef", applyFlate: false
    )
    let file = MappedFile(data: bytes)
    let result = try XRefStreamParser(file: file).parseSection(at: 0)
    #expect(Set(result.section.entries.keys) == [0, 1])
    #expect(result.section.entries[0] == .free)
    #expect(result.section.entries[1] == .uncompressed(offset: 42, generation: 0))
  }

  /// XS3: 다중 구간 `[0 1 5 3]` — 객체 0, 5, 6, 7만 선언된다.
  @Test func multiRangeIndexDeclaresOnlyListedNumbers() throws {
    let bytes = makeXRefStreamObjectBytes(
      objectNumber: 5, widths: [1, 4, 2], index: [0, 1, 5, 3], size: 8,
      rows: [
        XRefStreamSnippetRow(type: 0, field2: 0, field3: 0),
        XRefStreamSnippetRow(type: 1, field2: 10, field3: 0),
        XRefStreamSnippetRow(type: 1, field2: 20, field3: 0),
        XRefStreamSnippetRow(type: 1, field2: 30, field3: 0)
      ],
      extraDictText: "/Type /XRef", applyFlate: false
    )
    let file = MappedFile(data: bytes)
    let result = try XRefStreamParser(file: file).parseSection(at: 0)
    #expect(Set(result.section.entries.keys) == [0, 5, 6, 7])
    #expect(result.section.entries[5] == .uncompressed(offset: 10, generation: 0))
    #expect(result.section.entries[6] == .uncompressed(offset: 20, generation: 0))
    #expect(result.section.entries[7] == .uncompressed(offset: 30, generation: 0))
  }

  /// XS3: 구간 합 ≠ 데이터(데이터 부족) → 행 단위 절단 수용 + `.xrefStreamTruncated`.
  @Test func indexSumExceedingDataTruncatesWithWarning() throws {
    let bytes = makeXRefStreamObjectBytes(
      objectNumber: 1, widths: [1, 4, 2], index: [0, 4], size: 4,
      rows: [
        XRefStreamSnippetRow(type: 0, field2: 0, field3: 0),
        XRefStreamSnippetRow(type: 1, field2: 42, field3: 0)
      ],
      extraDictText: "/Type /XRef", applyFlate: false
    )
    let file = MappedFile(data: bytes)
    let result = try XRefStreamParser(file: file).parseSection(at: 0)
    // /Index [0 4]는 객체 0...3을 선언하지만 데이터는 2행뿐 → 앞의 2행(0, 1)만 수용된다.
    #expect(Set(result.section.entries.keys) == [0, 1])
    #expect(containsWarning(result.warnings) {
      if case .xrefStreamTruncated = $0 { return true }
      return false
    })
  }

  // MARK: XS4 — 딕셔너리 위반

  /// XS4: `/W` 원소 9 → `fieldWidthTooLarge`.
  @Test func oversizedFieldWidthThrows() {
    let bytes = makeXRefStreamObjectBytes(
      objectNumber: 1, widths: [9, 4, 2], index: nil, size: 1, rows: [],
      extraDictText: "/Type /XRef", applyFlate: false
    )
    let file = MappedFile(data: bytes)
    do {
      _ = try XRefStreamParser(file: file).parseSection(at: 0)
      Issue.record("/W 9는 fieldWidthTooLarge여야 함")
    } catch {
      #expect(error.code == .fieldWidthTooLarge)
    }
  }

  /// XS4: `/W` 길이 ≠ 3 → `invalidStreamDictionary`.
  @Test func wrongWidthArrayLengthThrows() {
    let source = "1 0 obj\n<< /Type /XRef /W [1 4] /Size 1 /Length 0 >>\n"
      + "stream\n\nendstream\nendobj"
    let file = MappedFile(data: Data(source.utf8))
    do {
      _ = try XRefStreamParser(file: file).parseSection(at: 0)
      Issue.record("/W 길이 위반은 invalidStreamDictionary여야 함")
    } catch {
      #expect(error.code == .invalidStreamDictionary)
    }
  }

  /// XS4: `/Size` 부재 → `invalidStreamDictionary`.
  @Test func missingSizeThrows() {
    let source = "1 0 obj\n<< /Type /XRef /W [1 4 2] /Length 0 >>\nstream\n\nendstream\nendobj"
    let file = MappedFile(data: Data(source.utf8))
    do {
      _ = try XRefStreamParser(file: file).parseSection(at: 0)
      Issue.record("/Size 부재는 invalidStreamDictionary여야 함")
    } catch {
      #expect(error.code == .invalidStreamDictionary)
    }
  }

  // MARK: XS5 — 미지 타입·필드 오버플로

  /// XS5: 타입 3(미지) 행 → 엔트리 생략(에러 아님).
  @Test func unknownRowTypeIsSkippedWithoutError() throws {
    let bytes = makeXRefStreamObjectBytes(
      objectNumber: 1, widths: [1, 4, 2], index: nil, size: 2,
      rows: [
        XRefStreamSnippetRow(type: 0, field2: 0, field3: 0),
        XRefStreamSnippetRow(type: 3, field2: 1, field3: 1)
      ],
      extraDictText: "/Type /XRef", applyFlate: false
    )
    let file = MappedFile(data: bytes)
    let result = try XRefStreamParser(file: file).parseSection(at: 0)
    #expect(result.section.entries[1] == nil)
  }

  /// XS5: 필드 오버플로 오프셋(`UInt64.max`, 8바이트 폭) → 엔트리 폐기 + `.entryOutOfBounds`.
  @Test func fieldOverflowDiscardsEntryWithWarning() throws {
    var raw: [UInt8] = []
    raw.append(0)
    raw.append(contentsOf: bigEndian(0, width: 8))
    raw.append(contentsOf: bigEndian(0, width: 2))
    raw.append(1)
    raw.append(contentsOf: [UInt8](repeating: 0xFF, count: 8))
    raw.append(contentsOf: bigEndian(0, width: 2))
    let payload = Data(raw)

    let text = "1 0 obj\n<< /Type /XRef /W [1 8 2] /Size 2 /Length \(payload.count) >>\nstream\n"
    var bytes = Array(text.utf8)
    bytes.append(contentsOf: payload)
    bytes.append(contentsOf: Array("\nendstream\nendobj".utf8))
    let file = MappedFile(data: Data(bytes))

    let result = try XRefStreamParser(file: file).parseSection(at: 0)
    #expect(result.section.entries[1] == nil)
    #expect(containsWarning(result.warnings) {
      if case .entryOutOfBounds = $0 { return true }
      return false
    })
  }

  // MARK: XS6 — /Type 관용

  /// XS6: `/Type` 부재 + `/W` 유효 → 관용 수용.
  @Test func missingTypeWithValidWidthsIsAccepted() throws {
    let bytes = makeXRefStreamObjectBytes(
      objectNumber: 1, widths: [1, 4, 2], index: nil, size: 1,
      rows: [XRefStreamSnippetRow(type: 0, field2: 0, field3: 0)],
      extraDictText: "", applyFlate: false
    )
    let file = MappedFile(data: bytes)
    let result = try XRefStreamParser(file: file).parseSection(at: 0)
    #expect(result.section.entries[0] == .free)
  }

  /// XS6: `/Type` `/W` 둘 다 부재 → `notAnXRefSection`.
  @Test func missingTypeAndWidthsThrowsNotAnXRefSection() {
    let source = "1 0 obj\n<< /Size 1 /Length 0 >>\nstream\n\nendstream\nendobj"
    let file = MappedFile(data: Data(source.utf8))
    do {
      _ = try XRefStreamParser(file: file).parseSection(at: 0)
      Issue.record("/Type·/W 둘 다 부재는 notAnXRefSection이어야 함")
    } catch {
      #expect(error.code == .notAnXRefSection)
    }
  }

  // MARK: XS7 — 필터 실패

  /// XS7: 훼손된 Flate 페이로드 → `decodeFailed`.
  @Test func corruptedFlatePayloadThrowsDecodeFailed() {
    let bytes = makeXRefStreamObjectBytes(
      objectNumber: 1, widths: [1, 4, 2], index: nil, size: 1,
      rows: [XRefStreamSnippetRow(type: 0, field2: 0, field3: 0)],
      extraDictText: "/Type /XRef", applyFlate: true, corruptPayload: true
    )
    let file = MappedFile(data: bytes)
    do {
      _ = try XRefStreamParser(file: file).parseSection(at: 0)
      Issue.record("훼손된 Flate 페이로드는 decodeFailed여야 함")
    } catch {
      #expect(error.code == .decodeFailed)
    }
  }
}
