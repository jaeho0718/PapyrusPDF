import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// 매트릭스 케이스 하나 (스타일 × 페이지 수 × 콘텐츠 스트림 유무).
struct TrailerResolverMatrixCase: Sendable, CustomTestStringConvertible {
  let style: PDFFixtureBuilder.XRefStyle
  let pageCount: Int
  let hasContentStream: Bool
  var testDescription: String {
    "\(self.style)/\(self.pageCount)/\(self.hasContentStream ? "content" : "noContent")"
  }
}

/// ``TrailerResolver``의 열기 플로우 전체를 검증한다 (설계 §3.1–§3.2, §5.3).
struct TrailerResolverTests {
  // MARK: TR1 — 매트릭스

  static let matrixCases: [TrailerResolverMatrixCase] = {
    var cases: [TrailerResolverMatrixCase] = []
    let styles: [PDFFixtureBuilder.XRefStyle] = [
      .classicTable, .xrefStream, .objectStreams, .hybrid
    ]
    for style in styles {
      for pageCount in [0, 1, 5] {
        for hasContentStream in [false, true] {
          cases.append(
            TrailerResolverMatrixCase(
              style: style, pageCount: pageCount, hasContentStream: hasContentStream
            )
          )
        }
      }
    }
    return cases
  }()

  /// TR1: 스타일 4종 × pageCount [0,1,5] × 콘텐츠 스트림 유무 → `resolve()` 성공, /Root 해소.
  /// `.classicTable`/`.xrefStream`은 추가로 경고 0을 요구한다.
  @Test(arguments: matrixCases)
  func matrixResolvesSuccessfully(_ testCase: TrailerResolverMatrixCase) throws {
    let contentStream = testCase.hasContentStream
      ? PDFFixtureBuilder.ContentStreamSpec(body: Data("BT ET".utf8)) : nil
    let fixture = PDFFixtureBuilder(
      pageCount: testCase.pageCount, xrefStyle: testCase.style, contentStream: contentStream
    ).build()
    let file = MappedFile(data: fixture.data)
    let resolution = try TrailerResolver(file: file).resolve()

    #expect(resolution.table.trailer[.root] == .reference(ObjectID(number: 1, generation: 0)))
    if testCase.style == .classicTable || testCase.style == .xrefStream {
      #expect(resolution.warnings.isEmpty)
    }
  }

  // MARK: TR2 — 증분 업데이트 최신 우선

  /// TR2: 페이지 크기를 두 번 재기록하는 체인 → 최신 MediaBox가 승리한다.
  @Test func incrementalUpdatesLatestMediaBoxWins() throws {
    let fixture = PDFFixtureBuilder(
      pageCount: 1,
      updates: [
        .init(rewrittenPages: [0: (width: 300, height: 400)]),
        .init(rewrittenPages: [0: (width: 500, height: 600)])
      ]
    ).build()
    let file = MappedFile(data: fixture.data)
    let resolution = try TrailerResolver(file: file).resolve()

    guard case let .uncompressed(offset, _) = resolution.table.entry(for: 3) else {
      Issue.record("페이지 객체가 uncompressed로 해소되지 않음")
      return
    }
    #expect(offset == fixture.objectOffsets[3])
    var parser = COSParser(file: file)
    let page = try parser.parseIndirectObject(at: offset)
    guard case let .dictionary(dict) = page.object,
      case let .array(mediaBox) = dict[COSName("MediaBox")]
    else {
      Issue.record("MediaBox를 찾지 못함")
      return
    }
    #expect(mediaBox[2].realValue == 500)
    #expect(mediaBox[3].realValue == 600)
  }

  // MARK: TR3 — 증분 삭제

  /// TR3: `freedObjects` → 해당 객체는 `.free`로 해소된다 (액터 `.null` 해소는 DC 스위트에서 확인).
  @Test func incrementalDeleteMarksObjectFree() throws {
    let fixture = PDFFixtureBuilder(
      pageCount: 2, updates: [.init(freedObjects: [4])]
    ).build()
    let file = MappedFile(data: fixture.data)
    let resolution = try TrailerResolver(file: file).resolve()
    #expect(resolution.table.entry(for: 4) == .free)
  }

  // MARK: TR4 — 혼합 스타일 체인

  /// TR4: 본체 `classicTable` + 업데이트 `xrefStream` — 재기록 페이지가 승리한다.
  @Test func mixedStyleChainResolvesSuccessfully() throws {
    let fixture = PDFFixtureBuilder(
      pageCount: 1, xrefStyle: .classicTable,
      updates: [.init(rewrittenPages: [0: (width: 111, height: 222)], xrefStyle: .xrefStream)]
    ).build()
    let file = MappedFile(data: fixture.data)
    let resolution = try TrailerResolver(file: file).resolve()

    guard case let .uncompressed(offset, _) = resolution.table.entry(for: 3) else {
      Issue.record("페이지 객체가 uncompressed로 해소되지 않음")
      return
    }
    var parser = COSParser(file: file)
    let page = try parser.parseIndirectObject(at: offset)
    guard case let .dictionary(dict) = page.object,
      case let .array(mediaBox) = dict[COSName("MediaBox")]
    else {
      Issue.record("MediaBox를 찾지 못함")
      return
    }
    #expect(mediaBox[2].realValue == 111)
    #expect(mediaBox[3].realValue == 222)
  }

  // MARK: TR5 — 하이브리드 우선순위

  /// TR5: `.hybrid` 픽스처 → Catalog가 type-2(압축)로 해소된다.
  @Test func hybridFixtureResolvesCompressedCatalog() throws {
    let fixture = PDFFixtureBuilder(pageCount: 1, xrefStyle: .hybrid).build()
    let file = MappedFile(data: fixture.data)
    let resolution = try TrailerResolver(file: file).resolve()
    guard case .compressed = resolution.table.entry(for: 1) else {
      let entry = String(describing: resolution.table.entry(for: 1))
      Issue.record("Catalog가 compressed로 해소되지 않음: \(entry)")
      return
    }
  }

  /// TR5: 클래식이 같은 번호(Catalog)를 free로 표기한 병적 하이브리드 변형 →
  /// XRefStm(압축) 선언이 승리하고, 복구 스캔 없이(정상 병합으로) 열린다.
  @Test func hybridPriorityFavorsXRefStreamOverConflictingClassicFree() throws {
    let data = Self.makeConflictingHybridFixture()
    let file = MappedFile(data: data)
    let resolution = try TrailerResolver(file: file).resolve()

    let rootEntry = resolution.table.entry(for: 1)
    guard case let .compressed(containerNumber, indexInContainer) = rootEntry else {
      Issue.record("Catalog가 compressed로 해소되지 않음: \(String(describing: rootEntry))")
      return
    }
    #expect(containerNumber == 10)
    #expect(indexInContainer == 0)
    #expect(!resolution.warnings.contains {
      if case .rebuiltViaRecoveryScan = $0 { return true }
      return false
    })
  }

  // MARK: TR6 — 순환

  /// TR6: `.cyclicPrevChain` → `.xrefChainCycle` 경고 + 읽은 부분으로 성공.
  @Test func cyclicPrevChainProducesWarningAndStillSucceeds() throws {
    let fixture = PDFFixtureBuilder(pageCount: 2).build()
    let corrupted = PDFFixtureCorruptor.apply([.cyclicPrevChain], to: fixture)
    let file = MappedFile(data: corrupted.data)
    let resolution = try TrailerResolver(file: file).resolve()

    #expect(resolution.table.trailer[.root] == .reference(ObjectID(number: 1, generation: 0)))
    #expect(resolution.warnings.contains {
      if case .xrefChainCycle = $0 { return true }
      return false
    })
  }

  // MARK: TR7 — 상호 순환(2섹션)

  /// TR7: 수제 2섹션 상호 순환(자기참조 아님) → 절단 경고 + 부분 수용으로 성공.
  @Test func mutualTwoSectionCycleIsTruncatedWithWarning() throws {
    let data = Self.makeMutualCycleFixture()
    let file = MappedFile(data: data)
    let resolution = try TrailerResolver(file: file).resolve()
    #expect(resolution.warnings.contains {
      if case .xrefChainCycle = $0 { return true }
      return false
    })
  }

  // MARK: TR8 — 정크 접두

  /// TR8: `.junkPrefix(byteCount: 512)` → `.junkBeforeHeader` + `.xrefOffsetsBiased` + 전 객체 해소 성공.
  @Test func junkPrefixTriggersBiasCorrection() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 3).build()
    let corrupted = PDFFixtureCorruptor.apply([.junkPrefix(byteCount: 512)], to: fixture)
    let file = MappedFile(data: corrupted.data)
    let resolution = try TrailerResolver(file: file).resolve()

    #expect(resolution.headerOffset == 512)
    #expect(resolution.warnings.contains {
      if case .junkBeforeHeader(512) = $0 { return true }
      return false
    })
    #expect(resolution.warnings.contains {
      if case .xrefOffsetsBiased(512) = $0 { return true }
      return false
    })

    let document = try await PDFDocumentCore.open(data: corrupted.data)
    for number in 1...5 {
      let value = try await document.object(for: ObjectID(number: number, generation: 0))
      #expect(!value.isNull)
    }
  }

  // MARK: TR9 — 헤더

  /// TR9: `%PDF` 부재 → `.notAPDF`.
  @Test func missingHeaderThrowsNotAPDF() {
    let file = MappedFile(data: Data("hello world, not a pdf".utf8))
    do {
      _ = try TrailerResolver(file: file).resolve()
      Issue.record("헤더 부재는 notAPDF여야 함")
    } catch {
      #expect(error == .notAPDF)
    }
  }

  /// TR9: 1KB 밖에 헤더가 있으면 `.notAPDF`.
  @Test func headerBeyondScanWindowThrowsNotAPDF() {
    let fixture = PDFFixtureBuilder(pageCount: 1).build()
    let corrupted = PDFFixtureCorruptor.apply([.junkPrefix(byteCount: 1_025)], to: fixture)
    let file = MappedFile(data: corrupted.data)
    do {
      _ = try TrailerResolver(file: file).resolve()
      Issue.record("1KB 밖 헤더는 notAPDF여야 함")
    } catch {
      #expect(error == .notAPDF)
    }
  }

  /// TR9: 버전 표기 훼손 → 1.4 폴백 + `.malformedVersion` 경고.
  @Test func malformedVersionFallsBackTo14() throws {
    let fixture = PDFFixtureBuilder(pageCount: 1).build()
    var bytes = [UInt8](fixture.data)
    let original = Array("%PDF-1.4".utf8)
    let replacement = Array("%PDF-X.Y".utf8)
    #expect(Array(bytes[0..<original.count]) == original)
    bytes.replaceSubrange(0..<original.count, with: replacement)

    let file = MappedFile(data: Data(bytes))
    let resolution = try TrailerResolver(file: file).resolve()
    #expect(resolution.version == PDFVersion(major: 1, minor: 4))
    #expect(resolution.warnings.contains {
      if case .malformedVersion = $0 { return true }
      return false
    })
  }

  /// TR9b: 부 버전 자릿수가 병적으로 긴 헤더(`%PDF-1.4999...`, 20+ 자리)도 `Int` 오버플로
  /// 트랩 없이 1.4 폴백 + 경고로 흡수한다 — M8 심층 퍼즈가 찾아낸 크래시의 회귀 테스트
  /// (`FuzzRegressionTests.knownFindings`의 `classicMinimal mut=0x6F0493424FF0288D n=10`와
  /// 동일 결함 부류).
  @Test func pathologicallyLongVersionDigitRunFallsBackWithoutOverflow() throws {
    let fixture = PDFFixtureBuilder(pageCount: 1).build()
    var bytes = [UInt8](fixture.data)
    let original = Array("%PDF-1.4".utf8)
    let replacement = Array("%PDF-1.\(String(repeating: "9", count: 25))".utf8)
    #expect(Array(bytes[0..<original.count]) == original)
    bytes.replaceSubrange(0..<original.count, with: replacement)

    let file = MappedFile(data: Data(bytes))
    let resolution = try TrailerResolver(file: file).resolve()
    #expect(resolution.version == PDFVersion(major: 1, minor: 4))
    #expect(resolution.warnings.contains {
      if case .malformedVersion = $0 { return true }
      return false
    })
  }

  // MARK: TR10 — 중간 섹션 훼손

  /// TR10: 업데이트 2회 중 가운데 xref 훼손 → `.xrefSectionUnreadable` + 성공(부분 수용
  /// 혹은 복구 스캔 — 둘 다 "실패하지 않는다"는 불변식을 만족한다).
  @Test func middleSectionCorruptionIsFlaggedAndStillOpens() throws {
    let fixture = PDFFixtureBuilder(
      pageCount: 1,
      updates: [
        .init(rewrittenPages: [0: (width: 10, height: 20)]),
        .init(rewrittenPages: [0: (width: 30, height: 40)])
      ]
    ).build()
    #expect(fixture.sectionOffsets.count == 3)

    var bytes = [UInt8](fixture.data)
    let corruptStart = fixture.sectionOffsets[1] + "xref\n".utf8.count
    for offset in 0..<4 {
      bytes[corruptStart + offset] = UInt8(ascii: "!")
    }

    let file = MappedFile(data: Data(bytes))
    let resolution = try TrailerResolver(file: file).resolve()
    #expect(resolution.table.trailer[.root] == .reference(ObjectID(number: 1, generation: 0)))
    #expect(resolution.warnings.contains {
      if case .xrefSectionUnreadable = $0 { return true }
      return false
    })
  }
}
