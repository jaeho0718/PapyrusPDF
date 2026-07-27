import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// ``XRefTableParser``의 클래식 테이블 파싱을 검증한다 (설계 §3.3.1, §5.1).
struct XRefTableParserTests {
  // MARK: XT1 — 픽스처 골든

  /// XT1: 단일 서브섹션, 전 객체 `.uncompressed` 오프셋 == `objectOffsets`, trailer 정합.
  @Test func fixtureGoldenMatchesObjectOffsets() throws {
    let fixture = PDFFixtureBuilder(pageCount: 3).build()
    let file = MappedFile(data: fixture.data)
    let result = try XRefTableParser(file: file).parseSection(at: fixture.xrefOffset)

    for (number, offset) in fixture.objectOffsets {
      #expect(result.section.entries[number] == .uncompressed(offset: offset, generation: 0))
    }
    #expect(result.section.trailer[.root] == .reference(ObjectID(number: 1, generation: 0)))
    #expect(result.section.trailer.integer(for: .size) == fixture.objectCount + 1)
    #expect(result.warnings.isEmpty)
  }

  // MARK: XT2 — 다중 서브섹션 + 갭

  /// XT2: `3 2` / `10 1` 서브섹션 — 갭 번호(0,1,2,5...9)는 엔트리 부재.
  @Test func multipleSubsectionsLeaveGapsUndeclared() throws {
    let source = "xref\n3 2\n"
      + classicRow(offset: 100, generation: 0, type: "n")
      + classicRow(offset: 200, generation: 0, type: "n")
      + "10 1\n"
      + classicRow(offset: 300, generation: 0, type: "n")
      + "trailer\n<< /Size 11 /Root 1 0 R >>"
    let file = MappedFile(data: Data(source.utf8))
    let result = try XRefTableParser(file: file).parseSection(at: 0)

    #expect(Set(result.section.entries.keys) == [3, 4, 10])
    #expect(result.section.entries[3] == .uncompressed(offset: 100, generation: 0))
    #expect(result.section.entries[4] == .uncompressed(offset: 200, generation: 0))
    #expect(result.section.entries[10] == .uncompressed(offset: 300, generation: 0))
  }

  // MARK: XT3 — 19/21바이트 행

  /// XT3: 손상된 행 폭(19/21바이트) 양쪽 모두 파싱 성공 + `.malformedXRefRow` 경고,
  /// 오프셋 값은 원본과 정합한다.
  @Test(arguments: [
    PDFFixtureCorruptor.Mode.RowWidth.nineteen, PDFFixtureCorruptor.Mode.RowWidth.twentyOne
  ])
  func malformedRowWidthsRecoverWithWarning(_ width: PDFFixtureCorruptor.Mode.RowWidth) throws {
    let fixture = PDFFixtureBuilder(pageCount: 2).build()
    let corrupted = PDFFixtureCorruptor.apply([.malformedRowWidth(width)], to: fixture)
    let file = MappedFile(data: corrupted.data)
    let result = try XRefTableParser(file: file).parseSection(at: fixture.xrefOffset)

    for (number, offset) in fixture.objectOffsets {
      #expect(result.section.entries[number] == .uncompressed(offset: offset, generation: 0))
    }
    #expect(containsWarning(result.warnings) {
      if case .malformedXRefRow = $0 { return true }
      return false
    })
  }

  // MARK: XT4 — free 엔트리

  /// XT4: `f` 타입 → `.free`; 객체 0 헤드는 엔트리로 수록되지 않는다.
  @Test func freeEntriesAreRecordedAndObjectZeroExcluded() throws {
    let source = "xref\n0 3\n"
      + classicRow(offset: 0, generation: 65_535, type: "f")
      + classicRow(offset: 50, generation: 0, type: "n")
      + classicRow(offset: 0, generation: 0, type: "f")
      + "trailer\n<< /Size 3 /Root 1 0 R >>"
    let file = MappedFile(data: Data(source.utf8))
    let result = try XRefTableParser(file: file).parseSection(at: 0)

    #expect(result.section.entries[0] == nil)
    #expect(result.section.entries[1] == .uncompressed(offset: 50, generation: 0))
    #expect(result.section.entries[2] == .free)
  }

  // MARK: XT5 — 구조 위반

  /// XT5: 음수 count → `invalidSubsectionHeader`.
  @Test func negativeCountThrowsInvalidSubsectionHeader() {
    let source = "xref\n0 -1\ntrailer\n<< /Size 1 /Root 1 0 R >>"
    let file = MappedFile(data: Data(source.utf8))
    do {
      _ = try XRefTableParser(file: file).parseSection(at: 0)
      Issue.record("음수 count는 invalidSubsectionHeader여야 함")
    } catch {
      #expect(error.code == .invalidSubsectionHeader)
    }
  }

  /// XT5: start+count 오버플로 → `invalidSubsectionHeader`.
  @Test func overflowingHeaderThrowsInvalidSubsectionHeader() {
    let source = "xref\n\(Int.max) 10\ntrailer\n<< >>"
    let file = MappedFile(data: Data(source.utf8))
    do {
      _ = try XRefTableParser(file: file).parseSection(at: 0)
      Issue.record("오버플로 헤더는 invalidSubsectionHeader여야 함")
    } catch {
      #expect(error.code == .invalidSubsectionHeader)
    }
  }

  /// XT5: trailer 부재(EOF) → `missingTrailer`.
  @Test func missingTrailerThrows() {
    let source = "xref\n0 1\n" + classicRow(offset: 0, generation: 65_535, type: "f")
    let file = MappedFile(data: Data(source.utf8))
    do {
      _ = try XRefTableParser(file: file).parseSection(at: 0)
      Issue.record("trailer 부재는 missingTrailer여야 함")
    } catch {
      #expect(error.code == .missingTrailer)
    }
  }

  /// XT5: 행 중간 절단(EOF) → `malformedEntry`.
  @Test func truncatedRowThrowsMalformedEntry() {
    let source = "xref\n0 2\n" + classicRow(offset: 0, generation: 65_535, type: "f") + "0000000"
    let file = MappedFile(data: Data(source.utf8))
    do {
      _ = try XRefTableParser(file: file).parseSection(at: 0)
      Issue.record("행 중간 절단은 malformedEntry여야 함")
    } catch {
      #expect(error.code == .malformedEntry)
    }
  }

  // MARK: XT6 — 오프셋 자릿수 초과

  /// XT6: 오프셋 10자리 초과 → `malformedEntry`.
  @Test func overlongOffsetThrowsMalformedEntry() {
    let source = "xref\n0 1\n12345678901 65535 n\r\ntrailer\n<< /Size 1 /Root 1 0 R >>"
    let file = MappedFile(data: Data(source.utf8))
    do {
      _ = try XRefTableParser(file: file).parseSection(at: 0)
      Issue.record("10자리 초과 오프셋은 malformedEntry여야 함")
    } catch {
      #expect(error.code == .malformedEntry)
    }
  }

  /// XT6b: 오프셋 자릿수가 병적으로 긴 행(30자리)도 `Int` 오버플로 트랩 없이
  /// `malformedEntry`로 흡수한다 — `scanDigitRun`의 `multipliedReportingOverflow` 가드
  /// 회귀 테스트(M8 심층 퍼즈가 헤더 버전 파서에서 찾은 것과 같은 결함 부류).
  @Test func pathologicallyLongOffsetDigitRunThrowsMalformedEntryWithoutOverflow() {
    let digits = String(repeating: "9", count: 30)
    let source = "xref\n0 1\n\(digits) 65535 n\r\ntrailer\n<< /Size 1 /Root 1 0 R >>"
    let file = MappedFile(data: Data(source.utf8))
    do {
      _ = try XRefTableParser(file: file).parseSection(at: 0)
      Issue.record("30자리 오프셋은 malformedEntry여야 함")
    } catch {
      #expect(error.code == .malformedEntry)
    }
  }

  /// XT6c: generation 자릿수가 병적으로 긴 행(30자리)도 오버플로 없이 `malformedEntry`로
  /// 흡수한다 — generation 필드는 offset과 달리 폭 상한 검사가 없어 오버플로 가드 자체가
  /// 유일한 방어선이다.
  @Test func pathologicallyLongGenerationDigitRunThrowsMalformedEntryWithoutOverflow() {
    let digits = String(repeating: "9", count: 30)
    let source = "xref\n0 1\n0000000000 \(digits) n\r\ntrailer\n<< /Size 1 /Root 1 0 R >>"
    let file = MappedFile(data: Data(source.utf8))
    do {
      _ = try XRefTableParser(file: file).parseSection(at: 0)
      Issue.record("30자리 generation은 malformedEntry여야 함")
    } catch {
      #expect(error.code == .malformedEntry)
    }
  }
}
