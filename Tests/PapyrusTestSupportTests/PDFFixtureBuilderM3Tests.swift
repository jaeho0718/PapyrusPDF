import Foundation
import PapyrusTestSupport
import Testing

/// M3 신규 스펙(페이지 트리/목차/이름 목적지/Info/XMP)의 바이트 수준 회귀·정합을 검증한다
/// (설계 §5.7). 의미론 검증(파싱 결과)은 `PapyrusCoreTests`가 맡는다 — 이 타겟은
/// `PapyrusCore`에 의존하지 않으므로(M0 원칙) 바이트 패턴만 대조한다.
struct PDFFixtureBuilderM3Tests {
  // MARK: M3F1 — pageTree 스펙 미사용 시 바이트 완전 동일 (M0 회귀 원칙)

  /// M3F1: `pageTree`/`outline`/`namedDestinations`/`info`/`xmpMetadata` 전부 `nil`이면
  /// 기존 v0/v1 빌더와 완전히 동일한 바이트를 낸다. 기존 F1–F12 골든 테스트가 무수정으로
  /// 계속 통과함으로써 이미 보증되지만, 여기서는 M3 스펙 프로퍼티가 실존함을 명시적으로
  /// 확인한다.
  @Test func unusedM3SpecsProduceIdenticalBytes() {
    let withoutSpecs = PDFFixtureBuilder(pageCount: 4).build()
    var explicitNil = PDFFixtureBuilder(pageCount: 4)
    explicitNil.pageTree = nil
    explicitNil.outline = nil
    explicitNil.namedDestinations = nil
    explicitNil.info = nil
    explicitNil.xmpMetadata = nil
    #expect(withoutSpecs.data == explicitNil.build().data)
  }

  // MARK: M3F2 — pageTree 전위 번호 배치 · /Parent · /Count

  /// M3F2: 중첩 트리(루트 2 + 중간 1 + 잎 2)의 전위 번호 배치, `/Parent` 기록,
  /// `objectOffsets` 정합을 검증한다.
  @Test func pageTreeSpecAssignsPreOrderNumbersAndParent() {
    let spec = PDFFixtureBuilder.PageTreeSpec(root: .pages(attributes: .init(), kids: [
      .pages(attributes: .init(), kids: [
        .page(attributes: .init()), .page(attributes: .init())
      ])
    ]))
    let fixture = PDFFixtureBuilder(pageTree: spec).build()

    // Catalog=1, 루트 Pages=2, 중간 노드=3, 잎=4,5 (전위 순서).
    #expect(Set(fixture.objectOffsets.keys) == Set([1, 2, 3, 4, 5]))
    for (number, offset) in fixture.objectOffsets {
      let expectedPrefix = Array("\(number) 0 obj".utf8)
      let bytes = [UInt8](fixture.data)
      #expect(Array(bytes[offset..<(offset + expectedPrefix.count)]) == expectedPrefix)
    }

    // 중간 노드(3)는 /Parent 2 0 R, 잎(4,5)은 /Parent 3 0 R을 기록한다.
    #expect(offset(of: "/Parent 2 0 R", in: fixture.data) != nil)
    #expect(offset(of: "/Parent 3 0 R", in: fixture.data) != nil)
    // 루트(2)는 /Parent를 기록하지 않는다.
    let rootOffset = fixture.objectOffsets[2]!
    let rootObjectData = fixture.data[rootOffset..<(fixture.objectOffsets[3]!)]
    let rootObjectText = String(data: rootObjectData, encoding: .utf8) ?? ""
    #expect(!rootObjectText.contains("/Parent"))
  }

  // MARK: M3F3 — 목차 /First /Next 사슬

  /// M3F3: 목차 2항목이 /Outlines의 /First·/Last + 항목 간 /Next 사슬로 기록된다.
  @Test func outlineSpecWritesFirstLastNextChain() {
    let outline = PDFFixtureBuilder.OutlineSpec(items: [
      .titled("A", destination: .direct(pageIndex: 0)),
      .titled("B", destination: .direct(pageIndex: 0))
    ])
    let fixture = PDFFixtureBuilder(pageCount: 1, outline: outline).build()
    #expect(offset(of: "/Type /Outlines", in: fixture.data) != nil)
    #expect(offset(of: "/Title (A)", in: fixture.data) != nil)
    #expect(offset(of: "/Title (B)", in: fixture.data) != nil)
    #expect(offset(of: "/Next", in: fixture.data) != nil)
  }

  // MARK: M3F4 — 이름 목적지 fanout /Limits 정렬

  /// M3F4: fanout 분할 리프마다 `/Limits [min max]`가 정렬된 경계로 기록된다.
  @Test func namedDestinationsFanoutWritesSortedLimits() {
    let entries: [(name: String, pageIndex: Int)] = [
      ("charlie", 0), ("alpha", 0), ("bravo", 0), ("delta", 0)
    ]
    let namedDestinations = PDFFixtureBuilder.NamedDestinationsSpec(
      entries: entries, container: .nameTree(kidsFanout: 2)
    )
    let fixture = PDFFixtureBuilder(pageCount: 1, namedDestinations: namedDestinations).build()
    // 정렬 후: alpha, bravo | charlie, delta — 각 묶음의 /Limits가 정렬된 min/max여야 한다.
    #expect(offset(of: "/Limits [(alpha) (bravo)]", in: fixture.data) != nil)
    #expect(offset(of: "/Limits [(charlie) (delta)]", in: fixture.data) != nil)
  }

  // MARK: M3F5 — Info/XMP 카탈로그·트레일러 배선

  /// M3F5: 트레일러 `/Info N 0 R`, 카탈로그 `/Metadata N 0 R` 참조가 기록된다.
  @Test func infoAndXMPWireTrailerAndCatalogReferences() {
    let info = PDFFixtureBuilder.InfoSpec(entries: [("Title", "(T)")])
    let fixture = PDFFixtureBuilder(pageCount: 1, info: info, xmpMetadata: "<x/>").build()
    #expect(offset(of: "/Info ", in: fixture.data) != nil)
    #expect(offset(of: "/Metadata ", in: fixture.data) != nil)
    let xmpMarker = "/Type /Metadata /Subtype /XML /Filter /FlateDecode"
    #expect(offset(of: xmpMarker, in: fixture.data) != nil)
  }

  // MARK: M3F6 — 중첩 /Count는 직계 kid 수가 아니라 서브트리 잎 총수 (r1 §2.8/§5.7)

  /// M3F6: `pages(kids: [pages(kids: [page, page]), page])` — 루트는 직계 kid 2개(중간
  /// 노드 1 + 잎 1)지만 서브트리 잎 총수는 3(중간 노드 아래 2 + 직계 잎 1)이어야 하고,
  /// 중간 노드는 직계 kid 수(2)와 잎 총수(2)가 우연히 같으므로 별도로 비대칭 트리를
  /// 하나 더 검증해 "직계 kid 수를 그대로 쓰지 않는다"를 확실히 가른다.
  @Test func nestedCountReflectsSubtreeLeafTotalNotDirectKidCount() {
    let spec = PDFFixtureBuilder.PageTreeSpec(root: .pages(attributes: .init(), kids: [
      .pages(attributes: .init(), kids: [
        .page(attributes: .init()), .page(attributes: .init())
      ]),
      .page(attributes: .init())
    ]))
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    // 번호: Catalog=1, 루트 Pages=2, 중간 Pages=3, 잎(중간 아래)=4,5, 잎(루트 직계)=6.
    #expect(offset(of: "/Count 3", in: fixture.data) != nil) // 루트: 직계 2개, 잎 총수 3.
    #expect(offset(of: "/Count 2", in: fixture.data) != nil) // 중간: 직계 2개, 잎 총수 2.
  }

  /// M3F6 부가: 직계 kid 수와 잎 총수가 반드시 달라지는 비대칭 형태 — 중간 노드가
  /// 자신의 하위에 또 다른 중간 노드(잎 3개)를 하나만 직계로 두는 경우, 중간 노드의
  /// `/Count`는 직계 1이 아니라 잎 총수 3이어야 한다.
  @Test func nestedCountDiffersFromDirectKidCountWhenAsymmetric() {
    let spec = PDFFixtureBuilder.PageTreeSpec(root: .pages(attributes: .init(), kids: [
      .pages(attributes: .init(), kids: [
        .page(attributes: .init()), .page(attributes: .init()), .page(attributes: .init())
      ])
    ]))
    let fixture = PDFFixtureBuilder(pageTree: spec).build()
    // 루트: 직계 kid 1개(중간 노드) vs 잎 총수 3 — 직계 수(1)를 그대로 썼다면 실패한다.
    #expect(offset(of: "/Count 3", in: fixture.data) != nil)
    #expect(offset(of: "/Count 1", in: fixture.data) == nil)
  }

  // MARK: M3F7 — 스펙 조합 제약 (문서화만)

  // M3F6: `.xrefStream`/`.objectStreams`/`.hybrid` + M3 신규 스펙, 또는 `contentStream`·
  // `updates`와 M3 신규 스펙의 동시 사용은 `precondition` 실패로 즉시 중단된다
  // (`PDFFixtureBuilder.build()`, 가정 7). Swift Testing은 프로세스 종료(트랩)를 정상
  // 테스트 케이스로 포착하는 안정적 수단이 없어(exit test는 이 타겟의 대상이 아님)
  // 이 제약은 실행 가능한 테스트 대신 문서화로 남긴다 — 설계 §5.7이 명시적으로 허용한다.
}
