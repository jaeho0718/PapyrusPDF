import Foundation

extension PDFFixtureBuilder {
  /// 증분 업데이트 하나의 명세.
  package struct IncrementalUpdateSpec: Sendable {
    /// 페이지 인덱스 → 새 MediaBox 크기. 해당 페이지 객체를 새 크기로 재기록한다
    /// (최신 우선 병합 검증의 관찰점 — M2 테스트는 재파싱한 MediaBox로 승자를 판정).
    package var rewrittenPages: [Int: (width: Double, height: Double)]

    /// 이 업데이트에서 free 처리할 객체 번호들 (증분 삭제 검증용).
    package var freedObjects: [Int]

    /// 이 업데이트의 xref 기록 방식. 본체와 다른 방식 혼용 가능
    /// (예: 본체 classicTable + 업데이트 xrefStream — 실세계 흔한 조합).
    package var xrefStyle: XRefStyle

    /// 업데이트 명세를 생성한다.
    /// - Parameters:
    ///   - rewrittenPages: 페이지 인덱스 → 새 MediaBox 크기 (기본 `[:]`).
    ///   - freedObjects: free 처리할 객체 번호들 (기본 `[]`).
    ///   - xrefStyle: 이 업데이트의 xref 기록 방식 (기본 `.classicTable`).
    package init(
      rewrittenPages: [Int: (width: Double, height: Double)] = [:],
      freedObjects: [Int] = [], xrefStyle: XRefStyle = .classicTable
    ) {
      self.rewrittenPages = rewrittenPages
      self.freedObjects = freedObjects
      self.xrefStyle = xrefStyle
    }
  }

  /// `updates`를 순서대로 적용해 최종 픽스처를 만든다.
  func applyUpdates(to base: PDFFixture) -> PDFFixture {
    let plan = self.makeObjectNumberPlan()
    var current = base
    var nextAuxiliaryNumber = (current.objectOffsets.keys.max() ?? plan.highestBaseNumber) + 1

    for update in self.updates {
      current = self.applyUpdate(
        update, to: current, plan: plan, nextAuxiliaryNumber: &nextAuxiliaryNumber
      )
    }
    return current
  }

  /// 증분 업데이트 하나를 `base` 뒤에 덧붙인다.
  private func applyUpdate(
    _ update: IncrementalUpdateSpec, to base: PDFFixture, plan: FixtureObjectPlan,
    nextAuxiliaryNumber: inout Int
  ) -> PDFFixture {
    for pageIndex in update.rewrittenPages.keys {
      precondition(
        pageIndex >= 0 && pageIndex < self.pageCount,
        "rewrittenPages 인덱스가 범위 밖: \(pageIndex)"
      )
    }

    var writer = PDFByteWriter(existingBytes: [UInt8](base.data))
    // 직전 섹션이 개행 없는 `%%EOF`로 끝나므로, 이어 붙이는 내용과 뒤섞이지 않도록
    // 경계 개행을 하나 넣는다 (RecoveryScanner의 "N G obj 직전 바이트" 경계 검사에도 필요).
    writer.write(rawBytes: [0x0A])
    var objectOffsets = base.objectOffsets

    var entries = self.writeRewrittenPagesBody(
      update, into: &writer, objectOffsets: &objectOffsets, plan: plan,
      nextAuxiliaryNumber: &nextAuxiliaryNumber
    )
    for objectNumber in update.freedObjects {
      entries[objectNumber] = .free
      objectOffsets.removeValue(forKey: objectNumber)
    }

    let context = UpdateXRefWriteContext(
      style: update.xrefStyle, catalogNumber: plan.catalogNumber, prevOffset: base.xrefOffset
    )
    let sectionOffset = self.writeUpdateXRefSection(
      entries: entries, into: &writer, objectOffsets: &objectOffsets, context: context,
      nextAuxiliaryNumber: &nextAuxiliaryNumber
    )

    return PDFFixture(
      data: Data(writer.bytes), objectOffsets: objectOffsets, xrefOffset: sectionOffset,
      sectionOffsets: base.sectionOffsets + [sectionOffset]
    )
  }

  /// 재기록 대상 페이지들을 스타일에 맞게 기록하고, 그로부터 만들어진 엔트리를 반환한다
  /// (free 처리는 호출부 소관).
  private func writeRewrittenPagesBody(
    _ update: IncrementalUpdateSpec, into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int], plan: FixtureObjectPlan, nextAuxiliaryNumber: inout Int
  ) -> [Int: FixtureXRefEntry] {
    var entries: [Int: FixtureXRefEntry] = [:]
    switch update.xrefStyle {
    case .classicTable, .xrefStream:
      for pageIndex in update.rewrittenPages.keys.sorted() {
        let size = update.rewrittenPages[pageIndex]!
        let pageNumber = 3 + pageIndex
        let offset = writer.offset
        writer.writeLine("\(pageNumber) 0 obj")
        writer.writeLine(
          self.pageValueText(
            contentsObjectNumber: plan.contentsObjectNumber, width: size.width, height: size.height
          )
        )
        writer.writeLine("endobj")
        objectOffsets[pageNumber] = offset
        entries[pageNumber] = .uncompressed(offset: offset)
      }
    case .objectStreams, .hybrid:
      let members = self.rewrittenPageMembers(update, plan: plan)
      if !members.isEmpty {
        let containerNumber = nextAuxiliaryNumber
        nextAuxiliaryNumber += 1
        let containerOffset = self.writeObjectStreamContainer(
          into: &writer, objectOffsets: &objectOffsets, objectNumber: containerNumber,
          members: members
        )
        entries[containerNumber] = .uncompressed(offset: containerOffset)
        for (index, member) in members.enumerated() {
          entries[member.number] = .compressed(containerNumber: containerNumber, index: index)
          objectOffsets.removeValue(forKey: member.number)
        }
      }
    }
    return entries
  }

  /// 재기록 대상 페이지들의 (번호, 값 텍스트) 목록을 만든다 (`.objectStreams`/`.hybrid` 전용).
  private func rewrittenPageMembers(
    _ update: IncrementalUpdateSpec, plan: FixtureObjectPlan
  ) -> [(number: Int, valueText: String)] {
    update.rewrittenPages.keys.sorted().map { pageIndex in
      let size = update.rewrittenPages[pageIndex]!
      return (
        3 + pageIndex,
        self.pageValueText(
          contentsObjectNumber: plan.contentsObjectNumber, width: size.width, height: size.height
        )
      )
    }
  }

  /// 증분 업데이트의 xref 섹션 기록에 필요한 정보 묶음 (매개변수 수 관리용).
  private struct UpdateXRefWriteContext {
    /// 이 업데이트의 xref 기록 방식.
    let style: XRefStyle
    /// `/Root` 대상 객체 번호.
    let catalogNumber: Int
    /// `/Prev` 값 (직전 섹션 오프셋).
    let prevOffset: Int?
  }

  /// 증분 업데이트의 xref 섹션(+트레일러)을 기록한다.
  /// - Returns: 이 섹션의 시작 오프셋(= `startxref` 대상).
  private func writeUpdateXRefSection(
    entries: [Int: FixtureXRefEntry], into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int], context: UpdateXRefWriteContext,
    nextAuxiliaryNumber: inout Int
  ) -> Int {
    switch context.style {
    case .classicTable:
      let sectionOffset = Self.writeClassicXRefSectionWithGaps(
        into: &writer, entries: entries, includeFreeHead: false
      )
      self.writeTrailer(
        into: &writer, xrefOffset: sectionOffset, totalObjects: nextAuxiliaryNumber,
        prevOffset: context.prevOffset, extraTrailerEntries: [:]
      )
      return sectionOffset
    case .xrefStream, .objectStreams:
      let xrefStreamNumber = nextAuxiliaryNumber
      nextAuxiliaryNumber += 1
      let request = XRefStreamWriteRequest(
        objectNumber: xrefStreamNumber, otherEntries: entries, size: nextAuxiliaryNumber,
        root: context.catalogNumber, prevOffset: context.prevOffset, extraTrailerEntries: [:],
        includeFreeHead: false
      )
      let sectionOffset = self.writeXRefStreamObject(
        into: &writer, objectOffsets: &objectOffsets, request: request
      )
      Self.writeStartxrefFooter(into: &writer, xrefOffset: sectionOffset)
      return sectionOffset
    case .hybrid:
      return self.writeHybridUpdateSection(
        entries: entries, into: &writer, objectOffsets: &objectOffsets, context: context,
        nextAuxiliaryNumber: &nextAuxiliaryNumber
      )
    }
  }

  /// `.hybrid` 증분 업데이트의 xref 스트림(`/XRefStm`) + 클래식 갭 테이블 + 트레일러를 기록한다.
  private func writeHybridUpdateSection(
    entries: [Int: FixtureXRefEntry], into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int], context: UpdateXRefWriteContext,
    nextAuxiliaryNumber: inout Int
  ) -> Int {
    let xrefStreamNumber = nextAuxiliaryNumber
    nextAuxiliaryNumber += 1
    let request = XRefStreamWriteRequest(
      objectNumber: xrefStreamNumber, otherEntries: entries, size: nextAuxiliaryNumber,
      root: context.catalogNumber, prevOffset: nil, extraTrailerEntries: [:],
      includeFreeHead: false
    )
    let xrefStreamOffset = self.writeXRefStreamObject(
      into: &writer, objectOffsets: &objectOffsets, request: request
    )
    var classicEntries = entries
    classicEntries[xrefStreamNumber] = .uncompressed(offset: xrefStreamOffset)
    let classicOffset = Self.writeClassicXRefSectionWithGaps(
      into: &writer, entries: classicEntries, includeFreeHead: false
    )
    self.writeHybridUpdateTrailer(
      into: &writer, size: nextAuxiliaryNumber, root: context.catalogNumber,
      prevOffset: context.prevOffset, xrefStreamOffset: xrefStreamOffset
    )
    Self.writeStartxrefFooter(into: &writer, xrefOffset: classicOffset)
    return classicOffset
  }

  /// 하이브리드 증분 업데이트 전용 `trailer` (+ `/XRefStm`) — `startxref`는 별도 기록.
  private func writeHybridUpdateTrailer(
    into writer: inout PDFByteWriter, size: Int, root: Int, prevOffset: Int?, xrefStreamOffset: Int
  ) {
    writer.writeLine("trailer")
    var parts = ["/Size \(size)", "/Root \(root) 0 R", "/XRefStm \(xrefStreamOffset)"]
    if let prevOffset {
      parts.append("/Prev \(prevOffset)")
    }
    writer.writeLine("<< \(parts.joined(separator: " ")) >>")
  }
}
