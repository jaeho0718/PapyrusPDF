import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// ``PDFDocumentCore/outlineItems()``의 순회·목적지 해소를 검증한다 (설계 §5.4 OL1-OL14).
struct OutlineTests {
  // MARK: OL1 — 평면 3항목

  /// OL1: 평면 3항목 `.direct` → 제목·pageIndex 정합.
  @Test func flatThreeItemsResolveTitlesAndDestinations() async throws {
    let outline = PDFFixtureBuilder.OutlineSpec(items: [
      .titled("First", destination: .direct(pageIndex: 0)),
      .titled("Second", destination: .direct(pageIndex: 1)),
      .titled("Third", destination: .direct(pageIndex: 2))
    ])
    let fixture = PDFFixtureBuilder(pageCount: 3, outline: outline).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let items = try await document.outlineItems()

    #expect(items.map(\.title) == ["First", "Second", "Third"])
    #expect(items.map { $0.destination?.pageIndex } == [0, 1, 2])
    #expect(items.map(\.children.isEmpty) == [true, true, true])
  }

  // MARK: OL2 — 3레벨 중첩

  /// OL2: 3레벨 중첩 children 구조 보존.
  @Test func threeLevelNestingPreservesChildrenStructure() async throws {
    let outline = PDFFixtureBuilder.OutlineSpec(items: [
      .titled("Chapter 1", destination: .direct(pageIndex: 0), children: [
        .titled("Section 1.1", destination: .direct(pageIndex: 0), children: [
          .titled("Subsection 1.1.1", destination: .direct(pageIndex: 0))
        ])
      ])
    ])
    let fixture = PDFFixtureBuilder(pageCount: 1, outline: outline).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let items = try await document.outlineItems()

    #expect(items.count == 1)
    #expect(items[0].title == "Chapter 1")
    #expect(items[0].children.count == 1)
    #expect(items[0].children[0].title == "Section 1.1")
    #expect(items[0].children[0].children.count == 1)
    #expect(items[0].children[0].children[0].title == "Subsection 1.1.1")
  }

  // MARK: OL3 — .namedName + /Dests 딕셔너리

  /// OL3: `.namedName` + `/Dests` 딕셔너리 경로 해소.
  @Test func namedNameResolvesViaDestsDictionary() async throws {
    let outline = PDFFixtureBuilder.OutlineSpec(items: [
      .titled("Named", destination: .namedName("Target"))
    ])
    let namedDestinations = PDFFixtureBuilder.NamedDestinationsSpec(
      entries: [("Target", 1)], container: .destsDictionary
    )
    let fixture = PDFFixtureBuilder(
      pageCount: 3, outline: outline, namedDestinations: namedDestinations
    ).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let items = try await document.outlineItems()
    #expect(items[0].destination?.pageIndex == 1)
  }

  // MARK: OL4 — .namedString + 네임 트리(단일 리프)

  /// OL4: `.namedString` + 네임 트리(단일 리프) 해소.
  @Test func namedStringResolvesViaSingleLeafNameTree() async throws {
    let outline = PDFFixtureBuilder.OutlineSpec(items: [
      .titled("Named", destination: .namedString("chapter2"))
    ])
    let namedDestinations = PDFFixtureBuilder.NamedDestinationsSpec(
      entries: [("chapter2", 1)], container: .nameTree(kidsFanout: nil)
    )
    let fixture = PDFFixtureBuilder(
      pageCount: 3, outline: outline, namedDestinations: namedDestinations
    ).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let items = try await document.outlineItems()
    #expect(items[0].destination?.pageIndex == 1)
  }

  // MARK: OL5 — 네임 트리 중첩(fanout)

  /// OL5: 네임 트리 중첩(fanout 2, 엔트리 8) → /Limits 하강 경로 해소.
  @Test func fanoutNameTreeResolvesViaLimitsDescent() async throws {
    let entries: [(name: String, pageIndex: Int)] = (0..<8).map { ("key\($0)", $0 % 3) }
    let namedDestinations = PDFFixtureBuilder.NamedDestinationsSpec(
      entries: entries, container: .nameTree(kidsFanout: 2)
    )
    let outline = PDFFixtureBuilder.OutlineSpec(items:
      entries.map { .titled($0.name, destination: .namedString($0.name)) }
    )
    let fixture = PDFFixtureBuilder(
      pageCount: 3, outline: outline, namedDestinations: namedDestinations
    ).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let items = try await document.outlineItems()

    #expect(items.count == 8)
    for (index, entry) in entries.enumerated() {
      #expect(items[index].destination?.pageIndex == entry.pageIndex)
    }
  }

  // MARK: OL6 — GoTo 액션 / 비-GoTo 액션

  /// OL6: `.goToAction` 해소; 비-GoTo 액션(raw `/A << /S /URI ... >>`) → destination nil.
  @Test func goToActionResolvesAndNonGoToActionYieldsNil() async throws {
    let outline = PDFFixtureBuilder.OutlineSpec(items: [
      .titled("GoTo", destination: .goToAction(pageIndex: 1)),
      .titled("URI", destination: .raw("/A << /S /URI /URI (https://example.com) >>"))
    ])
    let fixture = PDFFixtureBuilder(pageCount: 3, outline: outline).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let items = try await document.outlineItems()

    #expect(items[0].destination?.pageIndex == 1)
    #expect(items[1].destination == nil)
  }

  // MARK: OL7 — 댕글링 목적지

  /// OL7: 댕글링 목적지(raw `/Dest [999 0 R /Fit]`) → destination nil, 항목 유지.
  @Test func danglingDestinationYieldsNilButKeepsItem() async throws {
    let outline = PDFFixtureBuilder.OutlineSpec(items: [
      .titled("Dangling", destination: .raw("/Dest [999 0 R /Fit]"))
    ])
    let fixture = PDFFixtureBuilder(pageCount: 1, outline: outline).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let items = try await document.outlineItems()
    #expect(items.count == 1)
    #expect(items[0].title == "Dangling")
    #expect(items[0].destination == nil)
  }

  // MARK: OL8 — /Next 순환

  /// OL8: /Next 순환(raw 형제 상호 참조) → 유한 절단.
  @Test func nextCycleTerminatesFinitely() async throws {
    // 정상 스펙으로 3항목을 만든 뒤, /Next 사슬을 순환시키는 raw 손상 후처리 픽스처를
    // 직접 구성한다(스펙 표면은 항상 유효한 사슬만 만들므로).
    let data = Self.rawFixtureWithCyclicOutline()
    let document = try await PDFDocumentCore.open(data: data)
    let items = try await document.outlineItems()
    #expect(items.count <= 2)
  }

  // MARK: OL9 — 깊이 캡

  /// OL9: 100중첩 항목 → 64에서 절단, 크래시 없음.
  @Test func depthCapTruncatesAt64WithoutCrashing() async throws {
    var innermost = PDFFixtureBuilder.OutlineSpec.Item.titled("Leaf")
    for depth in 0..<100 {
      innermost = .titled("Depth \(depth)", children: [innermost])
    }
    let outline = PDFFixtureBuilder.OutlineSpec(items: [innermost])
    let fixture = PDFFixtureBuilder(pageCount: 1, outline: outline).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let items = try await document.outlineItems()

    var depth = 0
    var cursor = items
    while let first = cursor.first {
      depth += 1
      cursor = first.children
    }
    #expect(depth <= CoreLimits.maxOutlineDepth)
  }

  // MARK: OL10 — /Title 부재

  /// OL10: /Title 부재(키 자체가 없음) → title "", 항목 유지. 픽스처 빌더 스펙은 항상
  /// /Title을 기록하므로 raw 픽스처로 직접 구성한다.
  @Test func missingTitleYieldsEmptyStringButKeepsItem() async throws {
    let data = Self.rawFixture(objects: [
      (1, "<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R >>"),
      (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
      (3, "<< /Type /Page >>"),
      (4, "<< /Type /Outlines /First 5 0 R /Last 5 0 R /Count 1 >>"),
      (5, "<< /Parent 4 0 R /Dest [3 0 R /XYZ null null null] >>")
    ])
    let document = try await PDFDocumentCore.open(data: data)
    let items = try await document.outlineItems()
    #expect(items.count == 1)
    #expect(items[0].title == "")
  }

  // MARK: OL11 — 정수 목적지

  /// OL11: 정수 목적지 `[2 /Fit]`(범위 내) → pageIndex 2; 범위 밖 정수 → nil.
  @Test func integerDestinationWithinRangeResolvesOutOfRangeIsNil() async throws {
    let outline = PDFFixtureBuilder.OutlineSpec(items: [
      .titled("InRange", destination: .raw("/Dest [2 /Fit]")),
      .titled("OutOfRange", destination: .raw("/Dest [99 /Fit]"))
    ])
    let fixture = PDFFixtureBuilder(pageCount: 3, outline: outline).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let items = try await document.outlineItems()
    #expect(items[0].destination?.pageIndex == 2)
    #expect(items[1].destination == nil)
  }

  // MARK: OL12 — /Outlines 부재

  /// OL12: /Outlines 부재 → `[]`, throw 없음.
  @Test func missingOutlinesProducesEmptyArray() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 1).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let items = try await document.outlineItems()
    #expect(items.isEmpty)
  }

  // MARK: OL13 — 딕셔너리 목적지(네임 트리 값 형태)

  /// OL13: 값 딕셔너리 목적지(`<< /D [...] >>`) → 해소.
  @Test func dictionaryFormDestinationValueResolves() async throws {
    let data = Self.rawFixtureWithDictionaryFormDestination()
    let document = try await PDFDocumentCore.open(data: data)
    let items = try await document.outlineItems()
    #expect(items[0].destination?.pageIndex == 0)
  }

  // MARK: OL14 — dedupe

  /// OL14: 동시 호출 → `outlineBuildCount == 1`; outline 선호출이 pageTree도 1회만 유발.
  @Test func concurrentOutlineCallsBuildOnlyOnceAndSharePageTree() async throws {
    let outline = PDFFixtureBuilder.OutlineSpec(items: [
      .titled("Item", destination: .direct(pageIndex: 0))
    ])
    let fixture = PDFFixtureBuilder(pageCount: 5, outline: outline).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<16 {
        group.addTask {
          _ = try await document.outlineItems()
        }
      }
      try await group.waitForAll()
    }
    let stats = await document.cacheStatistics()
    #expect(stats.outlineBuildCount == 1)
    #expect(stats.pageTreeBuildCount == 1)
  }
}

// MARK: - 테스트 전용 헬퍼

extension OutlineTests {
  /// 3항목을 만들되 두 번째·세 번째 항목의 /Next가 서로를 가리키게(순환) 손상시킨
  /// raw 픽스처. 스펙 표면(항상 유효한 /Next 사슬)으로는 표현 불가능해 직접 조립한다.
  private static func rawFixtureWithCyclicOutline() -> Data {
    Self.rawFixture(objects: [
      (1, "<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R >>"),
      (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
      (3, "<< /Type /Page >>"),
      (4, "<< /Type /Outlines /First 5 0 R /Last 6 0 R /Count 2 >>"),
      (5, "<< /Title (First) /Parent 4 0 R /Next 6 0 R >>"),
      // 6의 /Next가 5를 다시 가리켜(순환) 무한 루프를 유발할 수 있는 손상 픽스처.
      (6, "<< /Title (Second) /Parent 4 0 R /Prev 5 0 R /Next 5 0 R >>")
    ])
  }

  /// 목적지가 이름 목적지 조회 결과 배열이 아니라 `<< /D [...] >>` 딕셔너리 형태(네임
  /// 트리 값 관용형)인 raw 픽스처. `/Dest (key)` → 네임 트리 → 값이 배열이 아니라
  /// `/D`를 담은 딕셔너리인 경로(§3.4 `lookupNamed` 마지막 단계)를 검증한다.
  private static func rawFixtureWithDictionaryFormDestination() -> Data {
    Self.rawFixture(objects: [
      (1, "<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R /Names 7 0 R >>"),
      (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
      (3, "<< /Type /Page >>"),
      (4, "<< /Type /Outlines /First 5 0 R /Last 5 0 R /Count 1 >>"),
      (5, "<< /Title (Item) /Parent 4 0 R /Dest (key) >>"),
      (7, "<< /Dests 8 0 R >>"),
      (8, "<< /Names [(key) 9 0 R] >>"),
      (9, "<< /D [3 0 R /XYZ null null null] >>")
    ])
  }

  /// 최소 클래식 xref PDF를 (객체 번호, 본문) 목록으로부터 직접 조립한다.
  private static func rawFixture(objects: [(number: Int, body: String)]) -> Data {
    var bytes: [UInt8] = []
    func writeLine(_ text: String) {
      bytes.append(contentsOf: Array(text.utf8))
      bytes.append(0x0A)
    }
    bytes.append(contentsOf: Array("%PDF-1.4\n".utf8))

    var offsets: [Int: Int] = [:]
    for object in objects.sorted(by: { $0.number < $1.number }) {
      offsets[object.number] = bytes.count
      writeLine("\(object.number) 0 obj")
      writeLine(object.body)
      writeLine("endobj")
    }

    let xrefOffset = bytes.count
    writeLine("xref")
    let highest = offsets.keys.max() ?? 0
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
