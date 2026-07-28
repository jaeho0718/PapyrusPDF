import Foundation

/// 퍼즈 시드 픽스처 카탈로그 — `PDFFixtureBuilder` 구성 매트릭스의 명명된 원소들.
/// 전부 결정적 빌드(빌더가 이미 결정적)이며, 케이스 ID의 `seed` 필드로 참조된다.
///
/// 선정 기준: xref 4변형 × {증분, 텍스트, 목차, ObjStm} 조합 중 코드 도달 표면이
/// 서로 다른 것들. 크기는 전부 수 KB — 뮤테이션 처리량이 우선이다.
package enum FuzzSeedFixture: String, CaseIterable, Sendable {
  /// 클래식 테이블, 페이지 1, 콘텐츠 없음 — 최소 구조 (헤더/xref/트레일러 집중 타격).
  case classicMinimal

  /// 클래식 테이블 + 목차 + 네임드 목적지 + Info/XMP 메타데이터.
  case classicOutlineMetadata

  /// xref 스트림 + 텍스트 콘텐츠(단순 콘텐츠 스트림) 4페이지.
  case xrefStreamText

  /// ObjStm 수납 + xref 스트림 + 텍스트 2페이지.
  case objectStreamsText

  /// 하이브리드(/XRefStm) + 증분 업데이트 2회(페이지 재기록 + free).
  case hybridIncremental

  /// 중간 크기: 32페이지 + 목차 (페이지 트리 평탄화·캐시 경로에 부피 부여).
  case mediumMixed

  /// 시드 픽스처를 빌드한다 (결정적 — 같은 케이스는 항상 같은 바이트).
  package func build() -> PDFFixture {
    switch self {
    case .classicMinimal:
      return Self.buildClassicMinimal()
    case .classicOutlineMetadata:
      return Self.buildClassicOutlineMetadata()
    case .xrefStreamText:
      return Self.buildXRefStreamText()
    case .objectStreamsText:
      return Self.buildObjectStreamsText()
    case .hybridIncremental:
      return Self.buildHybridIncremental()
    case .mediumMixed:
      return Self.buildMediumMixed()
    }
  }
}

// MARK: - 개별 빌드

extension FuzzSeedFixture {
  private static func buildClassicMinimal() -> PDFFixture {
    PDFFixtureBuilder(pageCount: 1).build()
  }

  private static func buildClassicOutlineMetadata() -> PDFFixture {
    PDFFixtureBuilder(
      pageCount: 2,
      outline: PDFFixtureBuilder.OutlineSpec(items: [
        .titled("Chapter 1", destination: .direct(pageIndex: 0)),
        .titled("Chapter 2", destination: .direct(pageIndex: 1))
      ]),
      namedDestinations: PDFFixtureBuilder.NamedDestinationsSpec(
        entries: [(name: "chap1", pageIndex: 0)], container: .destsDictionary
      ),
      info: PDFFixtureBuilder.InfoSpec(entries: [
        (key: "Title", rawValue: "(Fuzz Seed)"), (key: "Author", rawValue: "(PapyrusPDF)")
      ]),
      xmpMetadata: "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"></x:xmpmeta>"
    ).build()
  }

  private static func buildXRefStreamText() -> PDFFixture {
    PDFFixtureBuilder(
      pageCount: 4, xrefStyle: .xrefStream,
      contentStream: PDFFixtureBuilder.ContentStreamSpec(body: Data("BT (Hello) Tj ET".utf8))
    ).build()
  }

  private static func buildObjectStreamsText() -> PDFFixture {
    PDFFixtureBuilder(
      pageCount: 2, xrefStyle: .objectStreams,
      contentStream: PDFFixtureBuilder.ContentStreamSpec(body: Data("BT (Hi) Tj ET".utf8))
    ).build()
  }

  private static func buildHybridIncremental() -> PDFFixture {
    PDFFixtureBuilder(
      pageCount: 2, xrefStyle: .hybrid,
      updates: [
        .init(rewrittenPages: [0: (width: 300, height: 400)], xrefStyle: .classicTable),
        .init(freedObjects: [4], xrefStyle: .hybrid)
      ]
    ).build()
  }

  private static func buildMediumMixed() -> PDFFixture {
    PDFFixtureBuilder(
      pageCount: 32,
      outline: PDFFixtureBuilder.OutlineSpec(
        items: (0..<32).map { index in
          .titled("Page \(index)", destination: .direct(pageIndex: index))
        }
      )
    ).build()
  }
}
