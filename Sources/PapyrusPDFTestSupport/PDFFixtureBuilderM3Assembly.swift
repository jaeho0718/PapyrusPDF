import Foundation

// `PDFFixtureBuilder`의 M3 전체 조립(페이지 트리 + Info/XMP/목차/이름 목적지 + xref/트레일러).
// 파일 분리는 순수 조직적 이유(파일 길이 제한, §6)이며, 타입·의미는
// `PDFFixtureBuilderPageTree.swift`와 동일하다.

extension PDFFixtureBuilder {
  /// M3 부가 스펙(Info/XMP/목차/이름 목적지)의 계획 묶음 (매개변수 수 관리용).
  private struct M3AuxiliaryPlans {
    /// /Info 객체 계획 (미사용이면 `nil`).
    let infoPlan: M3ObjectPlan?
    /// XMP 스트림 객체 번호 (미사용이면 `nil`).
    let xmpNumber: Int?
    /// 목차 계획 (미사용이면 `nil`).
    let outlinePlan: OutlinePlan?
    /// 이름 목적지 계획 (미사용이면 `nil`).
    let namedDestinationsPlan: NamedDestinationsPlan?
  }

  /// M3 신규 스펙 경로의 최종 조립. `.classicTable` 단일 섹션만 기록한다.
  func buildM3Fixture() -> PDFFixture {
    var writer = PDFByteWriter()
    self.writeHeader(into: &writer)
    var objectOffsets: [Int: Int] = [:]

    // 1) 페이지 트리 번호 배치 (Catalog=1, 루트 Pages=2, 이하 3부터).
    let rootSpec = self.pageTree?.root ?? Self.defaultFlatPageTreeNode(
      pageCount: self.pageCount, width: self.pageWidth, height: self.pageHeight
    )
    guard case let .pages(rootAttributes, rootKids) = rootSpec else {
      preconditionFailure("PageTreeSpec.root는 반드시 .pages여야 한다.")
    }
    var next = 3
    let (pageTreePlan, pageObjectNumbers) = Self.planPageTree(
      rootAttributes: rootAttributes, rootKids: rootKids, next: &next
    )

    // 2) M3 부가 스펙(Info → XMP → Outlines → 이름 목적지) 계획.
    let auxiliary = self.planAuxiliaryObjects(pageObjectNumbers: pageObjectNumbers, next: &next)

    // 3) 카탈로그(1) — 다른 모든 번호가 정해진 뒤에 조립한다 (전방 참조 허용).
    self.writeCatalog(auxiliary, into: &writer, objectOffsets: &objectOffsets)

    // 4) 페이지 트리 본문.
    Self.writePageTreePlan(pageTreePlan, into: &writer, objectOffsets: &objectOffsets)

    // 5) Info / XMP.
    if let infoPlan = auxiliary.infoPlan {
      objectOffsets[infoPlan.number] = writer.offset
      writer.writeLine("\(infoPlan.number) 0 obj")
      writer.writeLine(infoPlan.text)
      writer.writeLine("endobj")
    }
    if let xmpNumber = auxiliary.xmpNumber, let xml = self.xmpMetadata {
      Self.writeXMPMetadataObject(
        number: xmpNumber, xml: xml, into: &writer, objectOffsets: &objectOffsets
      )
    }

    // 6) 목차.
    if let outlinePlan = auxiliary.outlinePlan {
      self.writeOutlinePlan(outlinePlan, into: &writer, objectOffsets: &objectOffsets)
    }

    // 7) 이름 목적지.
    if let namedDestinationsPlan = auxiliary.namedDestinationsPlan {
      for object in namedDestinationsPlan.objectsToWrite {
        objectOffsets[object.number] = writer.offset
        writer.writeLine("\(object.number) 0 obj")
        writer.writeLine(object.text)
        writer.writeLine("endobj")
      }
    }

    // 8) 클래식 xref 테이블(갭 없음) + 트레일러.
    let xrefOffset = self.writeXRefAndTrailer(
      highestNumber: next - 1, infoPlan: auxiliary.infoPlan, into: &writer,
      objectOffsets: objectOffsets
    )

    return PDFFixture(
      data: Data(writer.bytes), objectOffsets: objectOffsets, xrefOffset: xrefOffset,
      sectionOffsets: [xrefOffset]
    )
  }

  /// Info → XMP → Outlines → 이름 목적지 순으로 부가 객체 번호를 배치한다 (§2.8 규약).
  private func planAuxiliaryObjects(
    pageObjectNumbers: [Int], next: inout Int
  ) -> M3AuxiliaryPlans {
    let infoPlan = self.info.map { spec -> M3ObjectPlan in
      let number = next
      next += 1
      return M3ObjectPlan(number: number, text: Self.infoObjectText(spec))
    }
    let xmpNumber: Int? = self.xmpMetadata.map { _ in
      let number = next
      next += 1
      return number
    }
    let outlinePlan = self.outline.map {
      self.planOutline($0, next: &next, pageObjectNumbers: pageObjectNumbers)
    }
    let namedDestinationsPlan = self.namedDestinations.map {
      Self.planNamedDestinations($0, next: &next, pageObjectNumbers: pageObjectNumbers)
    }
    return M3AuxiliaryPlans(
      infoPlan: infoPlan, xmpNumber: xmpNumber, outlinePlan: outlinePlan,
      namedDestinationsPlan: namedDestinationsPlan
    )
  }

  /// 카탈로그(객체 1)를 기록한다. 다른 모든 번호가 정해진 뒤 호출되므로 전방 참조가
  /// 안전하다.
  private func writeCatalog(
    _ auxiliary: M3AuxiliaryPlans, into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int]
  ) {
    var parts = ["/Type /Catalog", "/Pages 2 0 R"]
    if let outlinePlan = auxiliary.outlinePlan {
      parts.append("/Outlines \(outlinePlan.rootNumber) 0 R")
    }
    if let xmpNumber = auxiliary.xmpNumber {
      parts.append("/Metadata \(xmpNumber) 0 R")
    }
    if let namedDestinationsPlan = auxiliary.namedDestinationsPlan {
      let entry = namedDestinationsPlan.catalogEntry
      parts.append("/\(entry.key) \(entry.valueText)")
    }
    objectOffsets[1] = writer.offset
    writer.writeLine("1 0 obj")
    writer.writeLine("<< \(parts.joined(separator: " ")) >>")
    writer.writeLine("endobj")
  }

  /// 클래식 xref 테이블(갭 없음) + 트레일러 + `startxref`/`%%EOF`를 기록한다.
  /// - Returns: `xref` 키워드 시작 오프셋(= `startxref` 대상).
  private func writeXRefAndTrailer(
    highestNumber: Int, infoPlan: M3ObjectPlan?, into writer: inout PDFByteWriter,
    objectOffsets: [Int: Int]
  ) -> Int {
    let xrefOffset = writer.offset
    writer.writeLine("xref")
    writer.writeLine("0 \(highestNumber + 1)")
    writer.write(Self.xrefEntry(offset: 0, generation: 65_535, type: "f"))
    writer.write(rawBytes: [0x0D, 0x0A])
    for number in 1...highestNumber {
      let offset = objectOffsets[number] ?? 0
      writer.write(Self.xrefEntry(offset: offset, generation: 0, type: "n"))
      writer.write(rawBytes: [0x0D, 0x0A])
    }

    writer.writeLine("trailer")
    var trailerParts = ["/Size \(highestNumber + 1)", "/Root 1 0 R"]
    if let infoPlan {
      trailerParts.append("/Info \(infoPlan.number) 0 R")
    }
    for key in self.extraTrailerEntries.keys.sorted() {
      trailerParts.append("/\(key) \(self.extraTrailerEntries[key] ?? "")")
    }
    writer.writeLine("<< \(trailerParts.joined(separator: " ")) >>")
    writer.writeLine("startxref")
    writer.writeLine("\(xrefOffset)")
    writer.write("%%EOF")
    return xrefOffset
  }

  /// `pageTree`가 `nil`일 때 기존 v0/v1 평탄 구조와 동등한 노드 트리를 만든다
  /// (M3 부가 스펙만 쓰는 경우에도 페이지 구조는 기존과 동일하게 유지하기 위함).
  private static func defaultFlatPageTreeNode(
    pageCount: Int, width: Double, height: Double
  ) -> PageTreeSpec.Node {
    let attributes = PageTreeSpec.NodeAttributes(mediaBox: PDFRectangleSpec(0, 0, width, height))
    let kids = (0..<pageCount).map { _ in PageTreeSpec.Node.page(attributes: attributes) }
    return .pages(attributes: .init(), kids: kids)
  }

  /// M3 부가 객체 하나(번호 + 기록할 원문)의 계획.
  struct M3ObjectPlan {
    /// 이 객체의 번호.
    let number: Int
    /// 객체 전체(헤더 제외 본문 또는 완결된 바이트열)를 위한 원문.
    let text: String
  }
}
