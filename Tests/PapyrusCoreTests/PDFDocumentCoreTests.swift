import Foundation
@testable import PapyrusCore
import PapyrusTestSupport
import Testing

/// DC1 매트릭스 케이스 하나 (스타일 × 증분 횟수 × 손상 모드).
struct PDFDocumentCoreMatrixCase: Sendable, CustomTestStringConvertible {
  let style: PDFFixtureBuilder.XRefStyle
  let updateCount: Int
  let corruption: PDFFixtureCorruptor.Mode?
  let corruptionLabel: String
  var testDescription: String {
    "\(self.style)/updates=\(self.updateCount)/\(self.corruptionLabel)"
  }
}

/// ``PDFDocumentCore``의 열기·객체 해소·동시성을 검증한다 (설계 §3.4, §4, §5.6).
struct PDFDocumentCoreTests {
  // MARK: DC1 — 완료 기준 매트릭스

  static let matrixCases: [PDFDocumentCoreMatrixCase] = {
    var cases: [PDFDocumentCoreMatrixCase] = []
    let styles: [PDFFixtureBuilder.XRefStyle] = [
      .classicTable, .xrefStream, .objectStreams, .hybrid
    ]
    for style in styles {
      for updateCount in [0, 1, 2] {
        for (corruption, label) in Self.corruptionCases(for: style) {
          cases.append(
            PDFDocumentCoreMatrixCase(
              style: style, updateCount: updateCount, corruption: corruption,
              corruptionLabel: label
            )
          )
        }
      }
    }
    return cases
  }()

  /// 스타일별 손상 케이스 목록. `.classicTable`만 `malformedRowWidth`(클래식 전용)를 포함한다.
  private static func corruptionCases(
    for style: PDFFixtureBuilder.XRefStyle
  ) -> [(PDFFixtureCorruptor.Mode?, String)] {
    var cases: [(PDFFixtureCorruptor.Mode?, String)] = [
      (nil, "none"),
      (.bogusStartxref, "bogusStartxref"),
      (.junkPrefix(byteCount: 200), "junkPrefix")
    ]
    if style == .classicTable {
      cases.append((.malformedRowWidth(.nineteen), "malformedRow"))
    }
    return cases
  }

  /// DC1: 스타일 4종 × 증분 [0,1,2회] × 손상[없음, bogusStartxref, junkPrefix,
  /// malformedRow(클래식만)] — `open` 성공 + Catalog/Pages/전 페이지 객체 해소·형태 검증.
  @Test(arguments: matrixCases)
  func matrixOpensAndResolvesAllObjects(_ testCase: PDFDocumentCoreMatrixCase) async throws {
    let pageCount = 3
    var updates: [PDFFixtureBuilder.IncrementalUpdateSpec] = []
    for index in 0..<testCase.updateCount {
      updates.append(.init(rewrittenPages: [0: (width: 100 + Double(index), height: 200)]))
    }
    let fixture = PDFFixtureBuilder(
      pageCount: pageCount, xrefStyle: testCase.style, updates: updates
    ).build()
    let data: Data
    if let corruption = testCase.corruption {
      data = PDFFixtureCorruptor.apply([corruption], to: fixture).data
    } else {
      data = fixture.data
    }

    let document = try await PDFDocumentCore.open(data: data)
    let catalog = try await document.object(for: ObjectID(number: 1, generation: 0))
    guard case let .dictionary(catalogDict) = catalog else {
      Issue.record("Catalog가 딕셔너리가 아님: \(catalog)")
      return
    }
    #expect(catalogDict.reference(for: COSName("Pages")) == ObjectID(number: 2, generation: 0))

    let pages = try await document.object(for: ObjectID(number: 2, generation: 0))
    guard case let .dictionary(pagesDict) = pages else {
      Issue.record("Pages가 딕셔너리가 아님: \(pages)")
      return
    }
    #expect(pagesDict.integer(for: COSName("Count")) == pageCount)

    for pageNumber in 3...(pageCount + 2) {
      let page = try await document.object(for: ObjectID(number: pageNumber, generation: 0))
      guard case let .dictionary(pageDict) = page else {
        Issue.record("페이지 \(pageNumber)가 딕셔너리가 아님: \(page)")
        return
      }
      #expect(pageDict.name(for: .type) == COSName("Page"))
    }
  }

  // MARK: DC2 — object(for:) 관용

  /// DC2: 부재 번호 → `.null`; free → `.null`; 세대 불일치 → 정상 해소.
  @Test func objectForHandlesAbsentFreeAndGenerationMismatch() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 2, updates: [.init(freedObjects: [4])]).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)

    let absent = try await document.object(for: ObjectID(number: 9_999, generation: 0))
    #expect(absent == .null)

    let freed = try await document.object(for: ObjectID(number: 4, generation: 0))
    #expect(freed == .null)

    // 세대 번호는 조회 키에서 무시된다 (가정 5) — 실제 세대(0)와 다른 값을 지정해도 해소된다.
    let mismatched = try await document.object(for: ObjectID(number: 1, generation: 7))
    #expect(mismatched != .null)
  }

  // MARK: DC3 — resolve(_:) 참조 사슬

  /// DC3: 참조 사슬 2단계(R→R→정수) 해소, 순환(R↔R)은 `.null`로 절단.
  @Test func resolveFollowsChainAndBreaksCycles() async throws {
    let data = Self.makeChainFixture()
    let document = try await PDFDocumentCore.open(data: data)

    let resolved = try await document.resolve(.reference(ObjectID(number: 10, generation: 0)))
    #expect(resolved == .integer(42))

    let cyclic = try await document.resolve(.reference(ObjectID(number: 20, generation: 0)))
    #expect(cyclic == .null)
  }

  // MARK: DC4 — decodedStreamData

  /// DC4: 인코딩 4종 × lengthStyle 3종(direct/indirect/directWrong) → 원문 일치;
  /// `/Length` 간접(+resolver 경유)은 경고 없이 성공, `directWrong`은 endstream 스캔
  /// 폴백을 거쳐도(액터 경로에서) 원문이 정확히 복원된다.
  @Test(arguments: [
    PDFFixtureBuilder.ContentStreamSpec.Encoding.flate,
    .asciiHex, .ascii85, .runLength
  ])
  func decodedStreamDataMatchesOriginalForEachEncoding(
    _ encoding: PDFFixtureBuilder.ContentStreamSpec.Encoding
  ) async throws {
    let body = Data("BT /F1 12 Tf (Hello) Tj ET".utf8)
    let lengthStyles: [PDFFixtureBuilder.ContentStreamSpec.LengthStyle] = [
      .direct, .indirect, .directWrong(delta: 5)
    ]
    for lengthStyle in lengthStyles {
      let fixture = PDFFixtureBuilder(
        pageCount: 1,
        contentStream: .init(body: body, encodings: [encoding], lengthStyle: lengthStyle)
      ).build()
      let document = try await PDFDocumentCore.open(data: fixture.data)
      let decoded = try await document.decodedStreamData(for: ObjectID(number: 4, generation: 0))
      #expect(decoded == body)
    }
  }

  // MARK: DC5 — 동시 접근

  /// DC5: `TaskGroup`으로 전 객체 × 8회 병렬 해소 → 값 동일·크래시 없음.
  @Test func concurrentAccessAcrossAllObjectsIsConsistent() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 10, xrefStyle: .objectStreams).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let numbers = Array(1...12)

    try await withThrowingTaskGroup(of: (Int, COSObject).self) { group in
      for _ in 0..<8 {
        for number in numbers {
          group.addTask {
            let value = try await document.object(for: ObjectID(number: number, generation: 0))
            return (number, value)
          }
        }
      }
      var seen: [Int: COSObject] = [:]
      for try await (number, value) in group {
        if let existing = seen[number] {
          #expect(existing == value)
        } else {
          seen[number] = value
        }
      }
      #expect(seen.count == numbers.count)
    }
  }

  // MARK: DC6 — 객체 캐시 상한

  /// DC6: `objectCacheEntryCap` 관찰 — 통계로 상한이 유지됨을 확인한다.
  @Test func objectCacheStaysWithinEntryCap() async throws {
    let pageCount = CoreLimits.objectCacheEntryCap + 500
    let fixture = PDFFixtureBuilder(pageCount: pageCount).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)

    for pageNumber in 3...(pageCount + 2) {
      _ = try await document.object(for: ObjectID(number: pageNumber, generation: 0))
    }
    let stats = await document.cacheStatistics()
    #expect(stats.objectCacheCount <= CoreLimits.objectCacheEntryCap)
  }

  // MARK: DC7 — open(data:) / open(url:) 동등성

  /// DC7: `open(data:)`와 `open(url:)`(임시 파일)이 동일한 결과를 낸다.
  @Test func openDataAndOpenURLAreEquivalent() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 2).build()
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    try fixture.data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let dataDocument = try await PDFDocumentCore.open(data: fixture.data)
    let urlDocument = try await PDFDocumentCore.open(url: url)

    for number in 1...4 {
      let fromData = try await dataDocument.object(for: ObjectID(number: number, generation: 0))
      let fromURL = try await urlDocument.object(for: ObjectID(number: number, generation: 0))
      #expect(fromData == fromURL)
    }
  }

  /// DC7 부가: 존재하지 않는 파일은 `.ioError`.
  @Test func openURLForMissingFileThrowsIOError() async {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    do {
      _ = try await PDFDocumentCore.open(url: url)
      Issue.record("존재하지 않는 파일은 ioError여야 함")
    } catch {
      guard case .ioError = error else {
        Issue.record("예상치 못한 에러: \(error)")
        return
      }
    }
  }
}

// MARK: - 테스트 전용 픽스처

extension PDFDocumentCoreTests {
  /// DC3 전용: 객체 10 → 11(R) → 정수 42, 객체 20 ↔ 21(R↔R 순환) 참조 사슬.
  private static func makeChainFixture() -> Data {
    var bytes: [UInt8] = []
    func writeLine(_ text: String) {
      bytes.append(contentsOf: Array(text.utf8))
      bytes.append(0x0A)
    }
    bytes.append(contentsOf: Array("%PDF-1.4\n".utf8))

    var offsets: [Int: Int] = [:]
    offsets[1] = bytes.count
    writeLine("1 0 obj")
    writeLine("<< /Type /Catalog /Pages 2 0 R >>")
    writeLine("endobj")
    offsets[2] = bytes.count
    writeLine("2 0 obj")
    writeLine("<< /Type /Pages /Kids [] /Count 0 >>")
    writeLine("endobj")
    offsets[10] = bytes.count
    writeLine("10 0 obj")
    writeLine("11 0 R")
    writeLine("endobj")
    offsets[11] = bytes.count
    writeLine("11 0 obj")
    writeLine("42")
    writeLine("endobj")
    offsets[20] = bytes.count
    writeLine("20 0 obj")
    writeLine("21 0 R")
    writeLine("endobj")
    offsets[21] = bytes.count
    writeLine("21 0 obj")
    writeLine("20 0 R")
    writeLine("endobj")

    let xrefOffset = bytes.count
    writeLine("xref")
    let highest = offsets.keys.max()!
    writeLine("0 \(highest + 1)")
    for number in 0...highest {
      if number == 0 {
        writeLine("0000000000 65535 f")
      } else if let offset = offsets[number] {
        bytes.append(contentsOf: Array(String(format: "%010d 00000 n\n", offset).utf8))
      } else {
        writeLine("0000000000 00000 f")
      }
    }
    writeLine("trailer")
    writeLine("<< /Size \(highest + 1) /Root 1 0 R >>")
    writeLine("startxref")
    writeLine("\(xrefOffset)")
    bytes.append(contentsOf: Array("%%EOF".utf8))
    return Data(bytes)
  }
}
