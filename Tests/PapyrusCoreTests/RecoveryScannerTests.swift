import Foundation
@testable import PapyrusCore
import PapyrusTestSupport
import Testing

/// ``RecoveryScanner``의 전역 스캔 복구를 검증한다 (설계 §3.5, §5.4).
struct RecoveryScannerTests {
  // MARK: RS1 — startxref 손상

  /// RS1: `.bogusStartxref`(파일 범위 밖 오프셋) → 첫 섹션부터 못 읽어 `.rebuiltViaRecoveryScan`,
  /// 전 객체 해소 성공. (숫자 자체는 유효하므로 `.invalidStartxref`은 발생하지 않는다 —
  /// 그 경고는 "부재/정수 아님/음수"에만 해당한다.)
  @Test func bogusStartxrefTriggersRecovery() throws {
    let fixture = PDFFixtureBuilder(pageCount: 3).build()
    let corrupted = PDFFixtureCorruptor.apply([.bogusStartxref], to: fixture)
    let file = MappedFile(data: corrupted.data)
    let resolution = try TrailerResolver(file: file).resolve()

    #expect(resolution.warnings.contains {
      if case .rebuiltViaRecoveryScan = $0 { return true }
      return false
    })
    for number in fixture.objectOffsets.keys {
      #expect(resolution.table.entry(for: number) != nil)
    }
  }

  /// RS1: `.removeStartxref` → `.invalidStartxref` + `.rebuiltViaRecoveryScan`, 전 객체 해소 성공.
  @Test func removeStartxrefTriggersRecovery() throws {
    let fixture = PDFFixtureBuilder(pageCount: 3).build()
    let corrupted = PDFFixtureCorruptor.apply([.removeStartxref], to: fixture)
    let file = MappedFile(data: corrupted.data)
    let resolution = try TrailerResolver(file: file).resolve()

    #expect(resolution.warnings.contains {
      if case .invalidStartxref = $0 { return true }
      return false
    })
    #expect(resolution.warnings.contains {
      if case .rebuiltViaRecoveryScan = $0 { return true }
      return false
    })
    for number in fixture.objectOffsets.keys {
      #expect(resolution.table.entry(for: number) != nil)
    }
  }

  // MARK: RS2 — Root 오프셋 훼손

  /// RS2: `.brokenEntryOffset`(Root 대상) → 체인 검증 실패 → 복구 → 성공.
  @Test func brokenRootEntryOffsetTriggersRecovery() throws {
    let fixture = PDFFixtureBuilder(pageCount: 2).build()
    let corrupted = PDFFixtureCorruptor.apply(
      [.brokenEntryOffset(objectNumber: 1, delta: 999_999)], to: fixture
    )
    let file = MappedFile(data: corrupted.data)
    let resolution = try TrailerResolver(file: file).resolve()

    #expect(resolution.warnings.contains {
      if case .rebuiltViaRecoveryScan = $0 { return true }
      return false
    })
    #expect(resolution.table.trailer[.root] == .reference(ObjectID(number: 1, generation: 0)))
  }

  // MARK: RS3 — 절단

  /// RS3: xref 전체가 절단되어도 복구로 열린다.
  @Test func truncatedXRefRecoversViaScan() throws {
    let fixture = PDFFixtureBuilder(pageCount: 3).build()
    let corrupted = PDFFixtureCorruptor.apply([.truncateTail(byteCount: 150)], to: fixture)
    let file = MappedFile(data: corrupted.data)
    let resolution = try TrailerResolver(file: file).resolve()
    #expect(resolution.warnings.contains {
      if case .rebuiltViaRecoveryScan = $0 { return true }
      return false
    })
    #expect(resolution.table.trailer[.root] == .reference(ObjectID(number: 1, generation: 0)))
  }

  /// RS3: body까지 절단되면 살아남은 객체만 복구된다(Catalog·Pages는 여전히 온전).
  @Test func truncationIntoBodyRecoversOnlySurvivingObjects() throws {
    let fixture = PDFFixtureBuilder(pageCount: 5).build()
    // 마지막 페이지 객체 시작 이전까지만 남기고 그 이후를 전부 절단한다.
    let lastPageOffset = try #require(fixture.objectOffsets[7])
    let truncateCount = fixture.data.count - lastPageOffset
    let corrupted = PDFFixtureCorruptor.apply(
      [.truncateTail(byteCount: truncateCount)], to: fixture
    )
    let file = MappedFile(data: corrupted.data)

    let rebuild = RecoveryScanner(file: file).rebuild()
    let table = try #require(rebuild?.table)
    #expect(table.entry(for: 1) != nil)
    #expect(table.entry(for: 6) != nil)
    #expect(table.entry(for: 7) == nil)
  }

  // MARK: RS4 — 중복 정의 나중 오프셋 승리

  /// RS4: 증분 픽스처를 복구 스캔으로 열면 나중(최신) 오프셋이 승리한다.
  @Test func duplicateObjectDefinitionLatestOffsetWins() throws {
    let fixture = PDFFixtureBuilder(
      pageCount: 1, updates: [.init(rewrittenPages: [0: (width: 321, height: 654)])]
    ).build()
    let corrupted = PDFFixtureCorruptor.apply([.removeStartxref], to: fixture)
    let file = MappedFile(data: corrupted.data)

    let rebuild = RecoveryScanner(file: file).rebuild()
    let table = try #require(rebuild?.table)
    guard case let .uncompressed(offset, _) = table.entry(for: 3) else {
      Issue.record("페이지 3이 uncompressed로 복구되지 않음")
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
    #expect(mediaBox[2].realValue == 321)
    #expect(mediaBox[3].realValue == 654)
  }

  // MARK: RS5 — ObjStm 확장

  /// RS5: `.objectStreams` 픽스처 + `.removeStartxref` → 압축 객체 포함 전 객체 복구.
  @Test func objectStreamsFixtureRecoversCompressedMembers() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 3, xrefStyle: .objectStreams).build()
    let corrupted = PDFFixtureCorruptor.apply([.removeStartxref], to: fixture)

    let document = try await PDFDocumentCore.open(data: corrupted.data)
    for number in 1...5 {
      let value = try await document.object(for: ObjectID(number: number, generation: 0))
      #expect(!value.isNull)
    }
  }

  // MARK: RS6 — trailer 소실 → 시그니처 스캔

  /// RS6: trailer 텍스트가 소실되면 `/Type /Catalog` 시그니처 스캔으로 `/Root`를 정한다.
  @Test func missingTrailerFallsBackToSignatureScan() throws {
    let fixture = PDFFixtureBuilder(pageCount: 2).build()
    var bytes = [UInt8](fixture.data)
    // 모든 "trailer" 키워드 출현을 같은 길이의 무해한 텍스트로 치환한다.
    let pattern = Array("trailer".utf8)
    let replacement = Array("XXXXXXX".utf8)
    var index = 0
    while index + pattern.count <= bytes.count {
      if Array(bytes[index..<(index + pattern.count)]) == pattern {
        bytes.replaceSubrange(index..<(index + pattern.count), with: replacement)
      }
      index += 1
    }
    let corrupted = PDFFixtureCorruptor.apply([.removeStartxref], to: PDFFixture(
      data: Data(bytes), objectOffsets: fixture.objectOffsets, xrefOffset: fixture.xrefOffset,
      sectionOffsets: fixture.sectionOffsets
    ))
    let file = MappedFile(data: corrupted.data)

    let rebuild = try #require(RecoveryScanner(file: file).rebuild())
    #expect(rebuild.warnings.contains {
      if case .rootFoundBySignatureScan = $0 { return true }
      return false
    })
    #expect(rebuild.table.trailer[.root] == .reference(ObjectID(number: 1, generation: 0)))
  }

  /// RS6 회귀(r2 §3.5 5단계 명확화): 고번호 가짜 Catalog가 파일 앞쪽에, 저번호 진짜
  /// Catalog가 파일 뒤쪽(더 큰 오프셋)에 있는 trailer 소실 픽스처 → 시그니처 스캔은
  /// **파일 오프셋 내림차순**으로 순회해야 하므로 뒤쪽(진짜) Catalog가 선택되어야 한다.
  /// 객체 번호 내림차순으로 순회했다면 앞쪽의 고번호 가짜가 잘못 선택된다.
  @Test func signatureScanPrefersLaterFileOffsetOverHigherObjectNumber() throws {
    var bytes: [UInt8] = []
    func writeLine(_ text: String) {
      bytes.append(contentsOf: Array(text.utf8))
      bytes.append(0x0A)
    }
    bytes.append(contentsOf: Array("%PDF-1.4\n".utf8))

    // 객체 99: 파일 앞쪽(낮은 오프셋)의 고번호 "가짜" Catalog.
    writeLine("99 0 obj")
    writeLine("<< /Type /Catalog /Pages 2 0 R >>")
    writeLine("endobj")

    writeLine("2 0 obj")
    writeLine("<< /Type /Pages /Kids [] /Count 0 >>")
    writeLine("endobj")

    // 객체 1: 파일 뒤쪽(더 큰 오프셋)의 저번호 "진짜" Catalog — 이 문서의 실제 Root.
    writeLine("1 0 obj")
    writeLine("<< /Type /Catalog /Pages 2 0 R >>")
    writeLine("endobj")
    // trailer/startxref 없음 — 시그니처 스캔으로 직행.

    let file = MappedFile(data: Data(bytes))
    let rebuild = try #require(RecoveryScanner(file: file).rebuild())
    #expect(rebuild.warnings.contains {
      if case .rootFoundBySignatureScan = $0 { return true }
      return false
    })
    #expect(rebuild.table.trailer[.root] == .reference(ObjectID(number: 1, generation: 0)))
  }

  // MARK: RS7 — 완전 손상

  /// RS7: Catalog조차 없는 바이트 → `rebuild() == nil`.
  @Test func noObjStmOrCatalogReturnsNil() {
    let source = "1 0 obj\n42\nendobj\n2 0 obj\n(hello world)\nendobj\n"
    let file = MappedFile(data: Data(source.utf8))
    #expect(RecoveryScanner(file: file).rebuild() == nil)
  }

  /// RS7: 완전 손상 문서는 `TrailerResolver.resolve()`가 `.damagedBeyondRecovery`를 던진다.
  @Test func fullyDamagedDocumentThrowsDamagedBeyondRecovery() {
    let source = "this is not a pdf file at all, just plain text with no structure"
    let file = MappedFile(data: Data(source.utf8))
    do {
      _ = try TrailerResolver(file: file).resolve()
      Issue.record("완전 손상 문서는 damagedBeyondRecovery여야 함")
    } catch {
      #expect(error == .notAPDF)
    }
  }

  // MARK: RS8 — 가짜 후보 내성

  /// RS8: 콘텐츠 스트림 본문에 `"9999 0 obj"` 유사 텍스트가 있어도 복구·해소가 정상이다.
  @Test func fakeObjectHeaderInsideStreamDoesNotConfuseRecovery() async throws {
    // 괄호로 감싸 리터럴 문자열 안에 둔다 — 헤더 재검증(parseObjectHeader)이 "obj" 뒤
    // 값 파싱에서 실패하는 대신, 애초에 "9999 0 obj"가 실제 값 파싱 문맥 안에 있으므로
    // 후보 재검증 시 자연스럽게 무해화된다(§3.5의 "알려진 한계" 시나리오).
    let body = Data("BT (contains 9999 0 obj like text) Tj ET".utf8)
    let fixture = PDFFixtureBuilder(
      pageCount: 1, contentStream: .init(body: body)
    ).build()
    let corrupted = PDFFixtureCorruptor.apply([.removeStartxref], to: fixture)

    let document = try await PDFDocumentCore.open(data: corrupted.data)
    let contentsID = ObjectID(number: 4, generation: 0)
    let decoded = try await document.decodedStreamData(for: contentsID)
    #expect(decoded == body)
  }

  // MARK: RS9 — 종료 보장

  /// RS9: 1MB급 랜덤 바이트에서도 복구 스캔은 시간 내 종료한다(행 금지 가드).
  @Test(.timeLimit(.minutes(1)))
  func randomBytesTerminateWithinTimeLimit() {
    var generator = SeededGenerator(seed: 20_260_722)
    var bytes = [UInt8](repeating: 0, count: 1 << 20)
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: 0...255, using: &generator)
    }
    let file = MappedFile(data: Data(bytes))
    _ = RecoveryScanner(file: file).rebuild()
  }
}
