import Foundation

// `PDFFixtureBuilder`의 M3 신규 스펙(목차/이름 목적지/Info/XMP) 명세 타입 + 기록 로직.
// 파일 분리는 순수 조직적 이유(§6)이며, `.classicTable` 전용이다(가정 7).
//
// 3단 중첩(PDFFixtureBuilder → OutlineSpec → Item/DestinationSpec)은 설계 문서(§2.8)가
// 명시한 구조를 그대로 따른다 — SwiftLint 기본 `nesting`(최대 1단) 규칙과 충돌하므로 이
// 파일 범위에서만 규칙을 끈다.
// swiftlint:disable nesting

extension PDFFixtureBuilder {
  /// 목차 픽스처 명세.
  package struct OutlineSpec: Sendable {
    /// 목차 항목.
    package struct Item: Sendable {
      /// 제목의 COS 원문 (예: `"(Chapter 1)"` 또는 `"<FEFF...>"` — 인코딩 픽스처용).
      package var rawTitle: String
      /// 목적지 명세.
      package var destination: DestinationSpec?
      /// 하위 항목.
      package var children: [Item]

      /// 항목을 생성한다.
      /// - Parameters:
      ///   - rawTitle: 제목의 COS 원문.
      ///   - destination: 목적지 명세 (기본 `nil`).
      ///   - children: 하위 항목 (기본 `[]`).
      package init(rawTitle: String, destination: DestinationSpec? = nil, children: [Item] = []) {
        self.rawTitle = rawTitle
        self.destination = destination
        self.children = children
      }

      /// ASCII 제목 편의 생성자 — `rawTitle` "(title)"로 변환.
      /// - Parameters:
      ///   - title: ASCII 제목 원문.
      ///   - destination: 목적지 명세 (기본 `nil`).
      ///   - children: 하위 항목 (기본 `[]`).
      /// - Returns: 생성된 항목.
      package static func titled(
        _ title: String, destination: DestinationSpec? = nil, children: [Item] = []
      ) -> Item {
        Item(rawTitle: "(\(title))", destination: destination, children: children)
      }
    }

    /// 목적지 기록 방식.
    package enum DestinationSpec: Sendable {
      /// `/Dest [P 0 R /XYZ null null null]` (P = pageIndex번째 페이지 객체).
      case direct(pageIndex: Int)
      /// `/Dest [P 0 R /Fit]` — 배열 변형 커버리지.
      case directFit(pageIndex: Int)
      /// `/Dest (name)` — 문자열 키. `namedDestinations`에 등재돼 있어야 해소된다.
      case namedString(String)
      /// `/Dest /name` — 이름 객체 키 (/Dests 딕셔너리 경로용).
      case namedName(String)
      /// `/A << /S /GoTo /D [P 0 R /XYZ null null null] >>`.
      case goToAction(pageIndex: Int)
      /// 원문 그대로 — 병적 픽스처용 (예: `"/Dest [999 0 R /Fit]"`).
      case raw(String)
    }

    /// 목차 항목 목록.
    package var items: [Item]

    /// 명세를 생성한다.
    /// - Parameter items: 목차 항목 목록.
    package init(items: [Item]) {
      self.items = items
    }
  }

  /// 이름 목적지 픽스처 명세.
  package struct NamedDestinationsSpec: Sendable {
    /// 저장 위치.
    package enum Container: Sendable {
      /// 카탈로그 /Dests 딕셔너리 (PDF 1.1 방식 — 이름 객체 키).
      case destsDictionary
      /// /Names /Dests 네임 트리. `kidsFanout == nil`이면 단일 리프(/Names만),
      /// 값이 있으면 그 크기로 묶은 리프들 + /Kids/​/Limits 중간 노드 구성.
      case nameTree(kidsFanout: Int?)
    }

    /// (키, 대상 페이지 인덱스) — 기록 시 키 바이트 사전순 정렬 (결정성 + /Limits 정합).
    package var entries: [(name: String, pageIndex: Int)]

    /// 저장 위치.
    package var container: Container

    /// 명세를 생성한다.
    /// - Parameters:
    ///   - entries: (키, 대상 페이지 인덱스) 목록.
    ///   - container: 저장 위치.
    package init(entries: [(name: String, pageIndex: Int)], container: Container) {
      self.entries = entries
      self.container = container
    }
  }

  /// /Info 픽스처 명세.
  package struct InfoSpec: Sendable {
    /// (키 이름, COS 원문 값) — 예: `("Title", "(Hello)")`, `("CreationDate", "(D:20240101)")`.
    package var entries: [(key: String, rawValue: String)]

    /// 명세를 생성한다.
    /// - Parameter entries: (키 이름, COS 원문 값) 목록.
    package init(entries: [(key: String, rawValue: String)]) {
      self.entries = entries
    }

    /// UTF-16BE 헥사 문자열 리터럴 헬퍼 — `"<FEFF...>"` 원문 생성.
    /// - Parameter text: 인코딩할 문자열.
    /// - Returns: `<FEFF...>` 형태의 COS hex 문자열 원문.
    package static func utf16BEHexLiteral(_ text: String) -> String {
      var hex = "FEFF"
      for unit in text.utf16 {
        hex += String(format: "%04X", unit)
      }
      return "<\(hex)>"
    }
  }
}

// swiftlint:enable nesting

// MARK: - Info / XMP 기록

extension PDFFixtureBuilder {
  /// /Info 딕셔너리 원문(래퍼 없이)을 만든다.
  static func infoObjectText(_ spec: InfoSpec) -> String {
    let parts = spec.entries.map { "/\($0.key) \($0.rawValue)" }
    return "<< \(parts.joined(separator: " ")) >>"
  }

  /// XMP 메타데이터 스트림 객체를 기록한다 (Flate 압축).
  static func writeXMPMetadataObject(
    number: Int, xml: String, into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int]
  ) {
    let encoded = PDFFilterEncoders.flate(Data(xml.utf8))
    objectOffsets[number] = writer.offset
    writer.writeLine("\(number) 0 obj")
    writer.writeLine(
      "<< /Type /Metadata /Subtype /XML /Filter /FlateDecode /Length \(encoded.count) >>"
    )
    writer.write("stream")
    writer.write(rawBytes: [0x0A])
    writer.write(rawBytes: [UInt8](encoded))
    writer.write(rawBytes: [0x0A])
    writer.writeLine("endstream")
    writer.writeLine("endobj")
  }
}

// MARK: - 목차 번호 배치 + 기록

/// 번호가 배치된 목차 항목 (기록 단계 전용 중간 표현). 목적지는 페이지 객체 번호를
/// 이미 반영한 완결 텍스트로 저장한다 (기록 단계에서 `pageObjectNumbers`를 다시 들고
/// 다닐 필요가 없도록).
struct NumberedOutlineItem {
  /// 이 항목의 객체 번호.
  let number: Int
  /// /Title 값의 COS 원문.
  let titleText: String
  /// /Dest 또는 /A 엔트리 (없으면 빈 배열).
  let destinationParts: [String]
  /// 하위 항목.
  let children: [NumberedOutlineItem]
}

extension PDFFixtureBuilder {
  /// 목차 항목 목록(및 하위 트리)에 전위 순서로 번호를 배치한다.
  private static func numberOutlineItems(
    _ items: [OutlineSpec.Item], next: inout Int, pageObjectNumbers: [Int]
  ) -> [NumberedOutlineItem] {
    items.map { item in
      let number = next
      next += 1
      let children = Self.numberOutlineItems(
        item.children, next: &next, pageObjectNumbers: pageObjectNumbers
      )
      return NumberedOutlineItem(
        number: number, titleText: item.rawTitle,
        destinationParts: Self.destinationEntries(
          for: item.destination, pageObjectNumbers: pageObjectNumbers
        ),
        children: children
      )
    }
  }

  /// 목적지 명세를 /Dest 또는 /A 딕셔너리 엔트리 텍스트로 변환한다.
  private static func destinationEntries(
    for spec: OutlineSpec.DestinationSpec?, pageObjectNumbers: [Int]
  ) -> [String] {
    guard let spec else {
      return []
    }
    switch spec {
    case let .direct(pageIndex):
      return ["/Dest [\(pageObjectNumbers[pageIndex]) 0 R /XYZ null null null]"]
    case let .directFit(pageIndex):
      return ["/Dest [\(pageObjectNumbers[pageIndex]) 0 R /Fit]"]
    case let .namedString(name):
      return ["/Dest (\(name))"]
    case let .namedName(name):
      return ["/Dest /\(name)"]
    case let .goToAction(pageIndex):
      return ["/A << /S /GoTo /D [\(pageObjectNumbers[pageIndex]) 0 R /XYZ null null null] >>"]
    case let .raw(text):
      return [text]
    }
  }

  /// 목차 전체(/Outlines 루트 + 항목들)의 번호 배치 결과.
  struct OutlinePlan {
    /// /Outlines 루트 객체 번호.
    let rootNumber: Int
    /// 최상위 항목들 (하위 항목은 각자 `children`에 중첩).
    let items: [NumberedOutlineItem]
  }

  /// 목차 명세에 번호를 배치한다 (Info → XMP 다음, 이름 목적지 이전 — §2.8 규약).
  func planOutline(
    _ spec: OutlineSpec, next: inout Int, pageObjectNumbers: [Int]
  ) -> OutlinePlan {
    let rootNumber = next
    next += 1
    let items = Self.numberOutlineItems(
      spec.items, next: &next, pageObjectNumbers: pageObjectNumbers
    )
    return OutlinePlan(rootNumber: rootNumber, items: items)
  }

  /// 번호 배치된 목차 전체를 기록한다.
  func writeOutlinePlan(
    _ plan: OutlinePlan, into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int]
  ) {
    var rootParts = ["/Type /Outlines"]
    if let first = plan.items.first {
      rootParts.append("/First \(first.number) 0 R")
    }
    if let last = plan.items.last {
      rootParts.append("/Last \(last.number) 0 R")
    }
    rootParts.append("/Count \(plan.items.count)")
    objectOffsets[plan.rootNumber] = writer.offset
    writer.writeLine("\(plan.rootNumber) 0 obj")
    writer.writeLine("<< \(rootParts.joined(separator: " ")) >>")
    writer.writeLine("endobj")

    self.writeOutlineItemSiblings(
      plan.items, parentNumber: plan.rootNumber, into: &writer, objectOffsets: &objectOffsets
    )
  }

  /// 형제 목록 하나(및 각자의 하위 트리)를 기록한다.
  private func writeOutlineItemSiblings(
    _ items: [NumberedOutlineItem], parentNumber: Int,
    into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int]
  ) {
    for (index, numbered) in items.enumerated() {
      var parts = ["/Title \(numbered.titleText)", "/Parent \(parentNumber) 0 R"]
      if index + 1 < items.count {
        parts.append("/Next \(items[index + 1].number) 0 R")
      }
      if index > 0 {
        parts.append("/Prev \(items[index - 1].number) 0 R")
      }
      if let first = numbered.children.first, let last = numbered.children.last {
        parts.append("/First \(first.number) 0 R")
        parts.append("/Last \(last.number) 0 R")
        parts.append("/Count \(numbered.children.count)")
      }
      parts.append(contentsOf: numbered.destinationParts)

      objectOffsets[numbered.number] = writer.offset
      writer.writeLine("\(numbered.number) 0 obj")
      writer.writeLine("<< \(parts.joined(separator: " ")) >>")
      writer.writeLine("endobj")

      self.writeOutlineItemSiblings(
        numbered.children, parentNumber: numbered.number, into: &writer,
        objectOffsets: &objectOffsets
      )
    }
  }
}

// MARK: - 이름 목적지 번호 배치 + 기록

extension PDFFixtureBuilder {
  /// 이름 목적지 전체(카탈로그 엔트리 + 기록할 객체들)의 계획.
  struct NamedDestinationsPlan {
    /// 카탈로그에 추가할 엔트리 (`/Dests N 0 R` 또는 `/Names N 0 R`).
    let catalogEntry: (key: String, valueText: String)
    /// 기록할 객체들 (번호, 딕셔너리 원문).
    let objectsToWrite: [(number: Int, text: String)]
  }

  /// 이름 목적지 명세에 번호를 배치하고 기록할 객체 목록을 만든다.
  static func planNamedDestinations(
    _ spec: NamedDestinationsSpec, next: inout Int, pageObjectNumbers: [Int]
  ) -> NamedDestinationsPlan {
    let sorted = spec.entries.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    switch spec.container {
    case .destsDictionary:
      let number = next
      next += 1
      let pairs = sorted.map { entry in
        "/\(entry.name) [\(pageObjectNumbers[entry.pageIndex]) 0 R /XYZ null null null]"
      }.joined(separator: " ")
      return NamedDestinationsPlan(
        catalogEntry: ("Dests", "\(number) 0 R"), objectsToWrite: [(number, "<< \(pairs) >>")]
      )
    case let .nameTree(kidsFanout):
      return Self.planNameTree(
        sorted, kidsFanout: kidsFanout, next: &next, pageObjectNumbers: pageObjectNumbers
      )
    }
  }

  /// `/Names /Dests` 네임 트리 경로 (단일 리프 또는 fanout 분할 + 중간 노드)를 계획한다.
  private static func planNameTree(
    _ sortedEntries: [(name: String, pageIndex: Int)], kidsFanout: Int?, next: inout Int,
    pageObjectNumbers: [Int]
  ) -> NamedDestinationsPlan {
    guard let fanout = kidsFanout, fanout > 0, sortedEntries.count > fanout else {
      var objects: [(number: Int, text: String)] = []
      let leafNumber = next
      next += 1
      let pairs = sortedEntries.map { entry in
        "(\(entry.name)) [\(pageObjectNumbers[entry.pageIndex]) 0 R /XYZ null null null]"
      }.joined(separator: " ")
      objects.append((leafNumber, "<< /Names [\(pairs)] >>"))
      let wrapperNumber = next
      next += 1
      objects.append((wrapperNumber, "<< /Dests \(leafNumber) 0 R >>"))
      return NamedDestinationsPlan(
        catalogEntry: ("Names", "\(wrapperNumber) 0 R"), objectsToWrite: objects
      )
    }

    var objects: [(number: Int, text: String)] = []
    var leafNumbers: [Int] = []
    var index = 0
    while index < sortedEntries.count {
      let end = min(index + fanout, sortedEntries.count)
      let chunk = Array(sortedEntries[index..<end])
      let leafNumber = next
      next += 1
      let pairs = chunk.map { entry in
        "(\(entry.name)) [\(pageObjectNumbers[entry.pageIndex]) 0 R /XYZ null null null]"
      }.joined(separator: " ")
      objects.append(
        (leafNumber, "<< /Limits [(\(chunk[0].name)) (\(chunk[chunk.count - 1].name))] " +
          "/Names [\(pairs)] >>")
      )
      leafNumbers.append(leafNumber)
      index = end
    }
    let rootNumber = next
    next += 1
    let kidsText = leafNumbers.map { "\($0) 0 R" }.joined(separator: " ")
    objects.append((rootNumber, "<< /Kids [\(kidsText)] >>"))
    let wrapperNumber = next
    next += 1
    objects.append((wrapperNumber, "<< /Dests \(rootNumber) 0 R >>"))
    return NamedDestinationsPlan(
      catalogEntry: ("Names", "\(wrapperNumber) 0 R"), objectsToWrite: objects
    )
  }
}
