import CoreGraphics
import Foundation
@testable import PapyrusCore
import PapyrusTestSupport
import Testing

/// ``PDFDocumentCore/pageTree()``의 평탄화·상속·관용 처리를 검증한다 (설계 §5.1 PT1-PT14).
struct PageTreeTests {
  // MARK: PT1 — 평탄 5페이지

  /// PT1: 기존(평탄) 빌더로 만든 5페이지 — pageCount, 순서, mediaBox, 역맵 정합.
  @Test func flatFivePagesMatchExpectedRecords() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 5, pageWidth: 300, pageHeight: 400).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let snapshot = try await document.pageTree()

    #expect(snapshot.pageCount == 5)
    for (index, record) in snapshot.records.enumerated() {
      #expect(record.objectNumber == 3 + index)
      #expect(record.mediaBox == CGRect(x: 0, y: 0, width: 300, height: 400))
      #expect(snapshot.pageIndexByObjectNumber[3 + index] == index)
    }
  }

  // MARK: PT2 — 중첩 스펙 3레벨

  /// PT2: 2-3-N 형태의 중첩 트리 — 잎 순서가 전위 순회 순서와 일치한다.
  @Test func nestedThreeLevelTreeFlattensInPreOrder() async throws {
    let leafAttrs = PDFFixtureBuilder.PageTreeSpec.NodeAttributes(
      mediaBox: .init(0, 0, 200, 300)
    )
    let spec = PDFFixtureBuilder.PageTreeSpec(root: .pages(attributes: .init(), kids: [
      .pages(attributes: .init(), kids: [
        .page(attributes: leafAttrs), .page(attributes: leafAttrs), .page(attributes: leafAttrs)
      ]),
      .pages(attributes: .init(), kids: [
        .page(attributes: leafAttrs), .page(attributes: leafAttrs)
      ])
    ]))
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let snapshot = try await document.pageTree()

    #expect(snapshot.pageCount == 5)
    for record in snapshot.records {
      #expect(record.mediaBox == CGRect(x: 0, y: 0, width: 200, height: 300))
    }
  }

  // MARK: PT3 — 상속 매트릭스

  /// PT3: MediaBox 루트만 / CropBox 중간 노드 / Rotate 중간+잎 오버라이드 / Resources 상속.
  @Test func inheritanceMatrixResolvesAllAttributes() async throws {
    let rootAttrs = PDFFixtureBuilder.PageTreeSpec.NodeAttributes(
      mediaBox: .init(0, 0, 600, 800)
    )
    let midAttrs = PDFFixtureBuilder.PageTreeSpec.NodeAttributes(
      cropBox: .init(50, 50, 550, 750), rotate: 90, resourcesRaw: "10 0 R"
    )
    let leaf2Attrs = PDFFixtureBuilder.PageTreeSpec.NodeAttributes(rotate: 180)
    let spec = PDFFixtureBuilder.PageTreeSpec(root: .pages(attributes: rootAttrs, kids: [
      .pages(attributes: midAttrs, kids: [
        .page(attributes: .init()),
        .page(attributes: leaf2Attrs)
      ])
    ]))
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let snapshot = try await document.pageTree()

    #expect(snapshot.pageCount == 2)
    let leaf1 = snapshot.records[0]
    #expect(leaf1.mediaBox == CGRect(x: 0, y: 0, width: 600, height: 800))
    #expect(leaf1.cropBox == CGRect(x: 50, y: 50, width: 500, height: 700))
    #expect(leaf1.rotationDegrees == 90)
    #expect(leaf1.resources == .reference(ObjectID(number: 10, generation: 0)))

    let leaf2 = snapshot.records[1]
    #expect(leaf2.rotationDegrees == 180)
  }

  // MARK: PT4 — 회전 정규화

  /// PT4: -90→270, 450→90, 45→0, 부재→0.
  @Test(arguments: [
    (rotate: -90, expected: 270), (rotate: 450, expected: 90), (rotate: 45, expected: 0)
  ])
  func rotationNormalizesIntegerValues(_ testCase: (rotate: Int, expected: Int)) async throws {
    let attrs = PDFFixtureBuilder.PageTreeSpec.NodeAttributes(rotate: testCase.rotate)
    let spec = PDFFixtureBuilder.PageTreeSpec(
      root: .pages(attributes: .init(), kids: [.page(attributes: attrs)])
    )
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let snapshot = try await document.pageTree()
    #expect(snapshot.records[0].rotationDegrees == testCase.expected)
  }

  /// PT4 부가: /Rotate 부재 → 0.
  @Test func missingRotateNormalizesToZero() async throws {
    let spec = PDFFixtureBuilder.PageTreeSpec(
      root: .pages(attributes: .init(), kids: [.page(attributes: .init())])
    )
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let snapshot = try await document.pageTree()
    #expect(snapshot.records[0].rotationDegrees == 0)
  }

  /// PT4 부가: 실수 `90.0` → 반올림 수용 (0.5도 미만 오차 없음).
  @Test func realRotateValueRoundsToNearestInteger() async throws {
    let data = Self.rawFixture(objects: [
      (1, "<< /Type /Catalog /Pages 2 0 R >>"),
      (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
      (3, "<< /Type /Page /Rotate 90.0 >>")
    ])
    let document = try await PDFDocumentCore.open(data: data)
    let snapshot = try await document.pageTree()
    #expect(snapshot.records[0].rotationDegrees == 90)
  }

  // MARK: PT5 — MediaBox 기본값 / CropBox 교집합

  /// PT5: MediaBox 전역 부재 → 기본값; CropBox가 밖 → 교집합; 교집합 공집합 → mediaBox 폴백.
  @Test func mediaBoxDefaultAndCropBoxIntersectionRules() async throws {
    let partialCropAttrs = PDFFixtureBuilder.PageTreeSpec.NodeAttributes(
      cropBox: .init(300, 300, 900, 900)
    )
    let emptyCropAttrs = PDFFixtureBuilder.PageTreeSpec.NodeAttributes(
      cropBox: .init(700, 700, 900, 900)
    )
    let spec = PDFFixtureBuilder.PageTreeSpec(root: .pages(attributes: .init(), kids: [
      .page(attributes: .init()),
      .page(attributes: partialCropAttrs),
      .page(attributes: emptyCropAttrs)
    ]))
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let snapshot = try await document.pageTree()

    let defaultBox = PageGeometry.defaultMediaBox
    #expect(snapshot.records[0].mediaBox == defaultBox)
    #expect(snapshot.records[0].cropBox == defaultBox)

    #expect(snapshot.records[1].mediaBox == defaultBox)
    #expect(snapshot.records[1].cropBox == CGRect(x: 300, y: 300, width: 312, height: 492))

    #expect(snapshot.records[2].mediaBox == defaultBox)
    #expect(snapshot.records[2].cropBox == defaultBox)
  }

  // MARK: PT6 — 순환

  /// PT6: 루트 자기참조(`rawKid("2 0 R")`) → 유한 종료, 정상 잎만 수록.
  @Test func selfReferencingRootKidTerminatesFinitely() async throws {
    let spec = PDFFixtureBuilder.PageTreeSpec(root: .pages(attributes: .init(), kids: [
      .rawKid("2 0 R"),
      .page(attributes: .init())
    ]))
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let snapshot = try await document.pageTree()
    #expect(snapshot.pageCount == 1)
  }

  // MARK: PT7 — 댕글링·비참조 kid

  /// PT7: 댕글링 kid("999 0 R") → 스킵; 비참조 kid("7") → 스킵.
  @Test func danglingAndNonReferenceKidsAreSkipped() async throws {
    let spec = PDFFixtureBuilder.PageTreeSpec(root: .pages(attributes: .init(), kids: [
      .rawKid("999 0 R"),
      .rawKid("7"),
      .page(attributes: .init())
    ]))
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let snapshot = try await document.pageTree()
    #expect(snapshot.pageCount == 1)
  }

  // MARK: PT8 — /Type 부재 노드의 관용 분류

  /// PT8: /Type 부재 노드 — /Kids 있으면 중간, 없으면 잎으로 관용 분류.
  @Test func missingTypeNodesAreClassifiedByKidsPresence() async throws {
    let data = Self.rawFixture(objects: [
      (1, "<< /Type /Catalog /Pages 2 0 R >>"),
      (2, "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>"),
      (3, "<< /Kids [5 0 R] >>"),
      (5, "<< /Type /Page >>"),
      (4, "<< /MediaBox [0 0 200 300] >>")
    ])
    let document = try await PDFDocumentCore.open(data: data)
    let snapshot = try await document.pageTree()

    #expect(snapshot.pageCount == 2)
    #expect(snapshot.records[0].mediaBox == PageGeometry.defaultMediaBox)
    #expect(snapshot.records[1].mediaBox == CGRect(x: 0, y: 0, width: 200, height: 300))
  }

  // MARK: PT9 — 거짓 /Count

  /// PT9: 거짓 /Count(100 주장, 실제 3) → pageCount 3 (실측 우선).
  @Test func falseCountHintIsIgnored() async throws {
    let data = Self.rawFixture(objects: [
      (1, "<< /Type /Catalog /Pages 2 0 R >>"),
      (2, "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 100 >>"),
      (3, "<< /Type /Page >>"),
      (4, "<< /Type /Page >>"),
      (5, "<< /Type /Page >>")
    ])
    let document = try await PDFDocumentCore.open(data: data)
    let snapshot = try await document.pageTree()
    #expect(snapshot.pageCount == 3)
  }

  // MARK: PT10 — 퇴화 케이스

  /// PT10: pageCount 0(/Kids []) → 0, 에러 없음.
  @Test func emptyKidsProducesZeroPagesWithoutError() async throws {
    let spec = PDFFixtureBuilder.PageTreeSpec(root: .pages(attributes: .init(), kids: []))
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let snapshot = try await document.pageTree()
    #expect(snapshot.pageCount == 0)
  }

  // MARK: PT11 — 인라인 딕셔너리 kid

  /// PT11: 인라인 딕셔너리 kid → 페이지로 수용, objectNumber nil, 역맵 미등재.
  @Test func inlineDictionaryKidIsAcceptedWithoutObjectNumber() async throws {
    let spec = PDFFixtureBuilder.PageTreeSpec(root: .pages(attributes: .init(), kids: [
      .rawKid("<< /Type /Page /MediaBox [0 0 50 50] >>"),
      .page(attributes: .init())
    ]))
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let snapshot = try await document.pageTree()

    #expect(snapshot.pageCount == 2)
    #expect(snapshot.records[0].objectNumber == nil)
    #expect(snapshot.records[0].mediaBox == CGRect(x: 0, y: 0, width: 50, height: 50))
    #expect(!snapshot.pageIndexByObjectNumber.values.contains(0))
  }

  // MARK: PT12 — dedupe

  /// PT12: TaskGroup 16-way 동시 `pageTree()` → `pageTreeBuildCount == 1`.
  @Test func concurrentPageTreeCallsBuildOnlyOnce() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 50).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<16 {
        group.addTask {
          _ = try await document.pageTree()
        }
      }
      try await group.waitForAll()
    }
    let stats = await document.cacheStatistics()
    #expect(stats.pageTreeBuildCount == 1)
  }

  // MARK: PT13 — 깊이 캡

  /// PT13: 단일 사슬 300중첩 → 크래시 없이 절단, 잎 미도달 수용.
  @Test func depthCapTruncatesBeforeReachingLeaf() async throws {
    let spec = PDFFixtureBuilder.PageTreeSpec(root: Self.chainedPagesNode(depth: 300))
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    let document = try await PDFDocumentCore.open(data: fixture.data)
    let snapshot = try await document.pageTree()
    #expect(snapshot.pageCount == 0)
  }

  // MARK: PT14 — 루트 구조 해소 불능

  /// PT14: /Pages가 해소 불능(댕글링) → throw.
  @Test func unresolvablePagesRootThrows() async throws {
    let data = Self.rawFixture(objects: [
      (1, "<< /Type /Catalog /Pages 999 0 R >>")
    ])
    let document = try await PDFDocumentCore.open(data: data)
    await #expect(throws: (any Error).self) {
      _ = try await document.pageTree()
    }
  }
}

// MARK: - 테스트 전용 헬퍼

extension PageTreeTests {
  /// `depth`개의 `.pages` 래퍼로 감싼 단일 잎 (깊이 캡 테스트용).
  private static func chainedPagesNode(depth: Int) -> PDFFixtureBuilder.PageTreeSpec.Node {
    var node = PDFFixtureBuilder.PageTreeSpec.Node.page(attributes: .init())
    for _ in 0..<depth {
      node = .pages(attributes: .init(), kids: [node])
    }
    return node
  }

  /// 최소 클래식 xref PDF를 (객체 번호, 본문) 목록으로부터 직접 조립한다.
  /// 픽스처 빌더의 스펙 표면 밖의 병적 구조(원값 /Rotate real, /Type 부재, 댕글링
  /// /Pages 등)를 정확히 만들기 위한 바이트 수준 헬퍼.
  private static func rawFixture(
    objects: [(number: Int, body: String)], rootNumber: Int = 1
  ) -> Data {
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
    writeLine("<< /Size \(highest + 1) /Root \(rootNumber) 0 R >>")
    writeLine("startxref")
    writeLine("\(xrefOffset)")
    bytes.append(contentsOf: Array("%%EOF".utf8))
    return Data(bytes)
  }
}
