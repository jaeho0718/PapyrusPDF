import Foundation

// `PDFFixtureBuilder`의 스타일별 본문 조립 로직(클래식 갭 테이블 + xrefStream/objectStreams/
// hybrid 본문). 파일 분리는 순수 조직적 이유(파일 길이 제한)이며, 타입·의미는
// `PDFFixtureBuilderXRefStream.swift`와 동일하다.

// MARK: - 클래식 테이블 (갭 허용, 하이브리드 전용)

extension PDFFixtureBuilder {
  /// 클래식 xref 테이블을 기록하되, `entries`에 없는 객체 번호는 서브섹션 갭으로
  /// 생략한다 (하이브리드에서 압축 객체를 누락시키는 표현, 증분 업데이트에서 미변경
  /// 객체를 누락시키는 표현 둘 다에 재사용).
  /// - Parameters:
  ///   - writer: 기록 대상 바이트 조립기.
  ///   - entries: 기록할 엔트리 (없는 번호는 갭으로 생략).
  ///   - includeFreeHead: 객체 0(free 헤드)을 항상 포함할지 여부 (기본 `true` — 신규
  ///     문서 본체 전용. 증분 업데이트 섹션은 `false`로 생략한다).
  /// - Returns: `xref` 키워드 시작 오프셋.
  @discardableResult
  static func writeClassicXRefSectionWithGaps(
    into writer: inout PDFByteWriter, entries: [Int: FixtureXRefEntry],
    includeFreeHead: Bool = true
  ) -> Int {
    let offset = writer.offset
    writer.writeLine("xref")

    var numbers = Set(entries.keys)
    if includeFreeHead {
      numbers.insert(0)
    }
    guard !numbers.isEmpty else {
      return offset
    }
    let sorted = numbers.sorted()
    var index = 0
    while index < sorted.count {
      let start = sorted[index]
      var end = start
      while index + 1 < sorted.count, sorted[index + 1] == end + 1 {
        index += 1
        end = sorted[index]
      }
      writer.writeLine("\(start) \(end - start + 1)")
      for number in start...end {
        if number == 0, entries[0] == nil {
          writer.write(Self.xrefEntry(offset: 0, generation: 65_535, type: "f"))
        } else {
          switch entries[number] ?? .free {
          case let .uncompressed(entryOffset):
            writer.write(Self.xrefEntry(offset: entryOffset, generation: 0, type: "n"))
          case .compressed, .free:
            writer.write(Self.xrefEntry(offset: 0, generation: 0, type: "f"))
          }
        }
        writer.write(rawBytes: [0x0D, 0x0A])
      }
      index += 1
    }
    return offset
  }
}

// MARK: - 스타일별 본문 조립

extension PDFFixtureBuilder {
  /// `.xrefStream` 스타일: 전 객체 최상위 + xref 스트림 하나.
  /// - Returns: xref 스트림 객체(= `startxref` 대상)의 시작 오프셋.
  func writeXRefStreamStyleBody(
    into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int], plan: FixtureObjectPlan,
    prevOffset: Int?, extraTrailerEntries: [String: String]
  ) -> Int {
    self.writeBody(
      into: &writer, objectOffsets: &objectOffsets,
      contentsObjectNumber: plan.contentsObjectNumber
    )
    if let contentStream, let contentsObjectNumber = plan.contentsObjectNumber {
      self.writeContentStreamObject(
        into: &writer, objectOffsets: &objectOffsets, objectNumber: contentsObjectNumber,
        lengthObjectNumber: plan.lengthObjectNumber, spec: contentStream
      )
    }

    var entries: [Int: FixtureXRefEntry] = [:]
    for number in 1...plan.highestBaseNumber {
      if let offset = objectOffsets[number] {
        entries[number] = .uncompressed(offset: offset)
      }
    }
    let xrefStreamNumber = plan.highestBaseNumber + 1
    let request = XRefStreamWriteRequest(
      objectNumber: xrefStreamNumber, otherEntries: entries, size: xrefStreamNumber + 1,
      root: plan.catalogNumber, prevOffset: prevOffset, extraTrailerEntries: extraTrailerEntries
    )
    return self.writeXRefStreamObject(
      into: &writer, objectOffsets: &objectOffsets, request: request
    )
  }

  /// Catalog·Pages·Page를 ObjStm 컨테이너에 수납하고, 콘텐츠 스트림 등은 최상위로 유지한
  /// 공통 본문. `.objectStreams`/`.hybrid`가 공유한다.
  struct PackedBody {
    /// 컨테이너 객체 번호.
    let containerNumber: Int
    /// 컨테이너 + 콘텐츠/렝스(최상위) + 압축 멤버 전부를 담은 엔트리 맵.
    let entries: [Int: FixtureXRefEntry]
    /// 다음에 배치할 xref 스트림 객체 번호.
    let xrefStreamNumber: Int
  }

  /// `PackedBody`를 조립한다 (xref/트레일러 기록은 호출부 소관).
  func writePackedBody(
    into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int], plan: FixtureObjectPlan
  ) -> PackedBody {
    var members: [(number: Int, valueText: String)] = [
      (plan.catalogNumber, self.catalogValueText()),
      (plan.pagesNumber, self.pagesValueText(pageNumbers: plan.pageNumbers))
    ]
    for pageNumber in plan.pageNumbers {
      members.append(
        (pageNumber, self.pageValueText(contentsObjectNumber: plan.contentsObjectNumber))
      )
    }

    let containerNumber = plan.highestBaseNumber + 1
    let containerOffset = self.writeObjectStreamContainer(
      into: &writer, objectOffsets: &objectOffsets, objectNumber: containerNumber, members: members
    )

    if let contentStream, let contentsObjectNumber = plan.contentsObjectNumber {
      self.writeContentStreamObject(
        into: &writer, objectOffsets: &objectOffsets, objectNumber: contentsObjectNumber,
        lengthObjectNumber: plan.lengthObjectNumber, spec: contentStream
      )
    }

    var entries: [Int: FixtureXRefEntry] = [
      containerNumber: .uncompressed(offset: containerOffset)
    ]
    for (index, member) in members.enumerated() {
      entries[member.number] = .compressed(containerNumber: containerNumber, index: index)
    }
    if let contentsObjectNumber = plan.contentsObjectNumber,
      let offset = objectOffsets[contentsObjectNumber] {
      entries[contentsObjectNumber] = .uncompressed(offset: offset)
    }
    if let lengthObjectNumber = plan.lengthObjectNumber,
      let offset = objectOffsets[lengthObjectNumber] {
      entries[lengthObjectNumber] = .uncompressed(offset: offset)
    }

    return PackedBody(
      containerNumber: containerNumber, entries: entries, xrefStreamNumber: containerNumber + 1
    )
  }

  /// `.objectStreams` 스타일: 패킹된 본문 + xref 스트림 하나(트레일러 겸용).
  /// - Returns: xref 스트림 객체(= `startxref` 대상)의 시작 오프셋.
  func writeObjectStreamsStyleBody(
    into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int], plan: FixtureObjectPlan,
    prevOffset: Int?, extraTrailerEntries: [String: String]
  ) -> Int {
    let packed = self.writePackedBody(into: &writer, objectOffsets: &objectOffsets, plan: plan)
    let request = XRefStreamWriteRequest(
      objectNumber: packed.xrefStreamNumber, otherEntries: packed.entries,
      size: packed.xrefStreamNumber + 1, root: plan.catalogNumber, prevOffset: prevOffset,
      extraTrailerEntries: extraTrailerEntries
    )
    return self.writeXRefStreamObject(
      into: &writer, objectOffsets: &objectOffsets, request: request
    )
  }

  /// `.hybrid` 스타일: 패킹된 본문 + xref 스트림(`/XRefStm` 대상) + 클래식 테이블(서브섹션
  /// 갭 + `/XRefStm` 트레일러 키). `startxref`는 클래식 테이블을 가리킨다.
  /// - Returns: 클래식 xref 테이블(= `startxref` 대상)의 시작 오프셋.
  func writeHybridStyleBody(
    into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int], plan: FixtureObjectPlan,
    prevOffset: Int?, extraTrailerEntries: [String: String]
  ) -> Int {
    let packed = self.writePackedBody(into: &writer, objectOffsets: &objectOffsets, plan: plan)
    let streamRequest = XRefStreamWriteRequest(
      objectNumber: packed.xrefStreamNumber, otherEntries: packed.entries,
      size: packed.xrefStreamNumber + 1, root: plan.catalogNumber, prevOffset: nil,
      extraTrailerEntries: [:]
    )
    let xrefStreamOffset = self.writeXRefStreamObject(
      into: &writer, objectOffsets: &objectOffsets, request: streamRequest
    )

    var classicEntries: [Int: FixtureXRefEntry] = [:]
    for (number, entry) in packed.entries where Self.isUncompressed(entry) {
      classicEntries[number] = entry
    }
    classicEntries[packed.xrefStreamNumber] = .uncompressed(offset: xrefStreamOffset)

    let classicOffset = Self.writeClassicXRefSectionWithGaps(
      into: &writer, entries: classicEntries
    )
    let trailerContext = HybridTrailerContext(
      size: packed.xrefStreamNumber + 1, root: plan.catalogNumber, prevOffset: prevOffset,
      xrefStreamOffset: xrefStreamOffset
    )
    self.writeHybridTrailer(
      into: &writer, context: trailerContext, extraTrailerEntries: extraTrailerEntries
    )
    return classicOffset
  }

  /// 엔트리가 `.uncompressed`인지 여부.
  private static func isUncompressed(_ entry: FixtureXRefEntry) -> Bool {
    if case .uncompressed = entry {
      return true
    }
    return false
  }

  /// 하이브리드 전용 트레일러 기록에 필요한 정보 묶음 (매개변수 수 관리용).
  private struct HybridTrailerContext {
    /// `/Size` 값.
    let size: Int
    /// `/Root` 대상 객체 번호.
    let root: Int
    /// `/Prev` 값 (없으면 `nil`).
    let prevOffset: Int?
    /// `/XRefStm` 값 (xref 스트림 객체 오프셋).
    let xrefStreamOffset: Int
  }

  /// 하이브리드 전용 `trailer` (+ `/XRefStm`)를 기록한다. `startxref`는 호출부가 이미
  /// 알고 있는 클래식 테이블 오프셋을 별도로 기록하므로 여기서는 트레일러까지만 담당한다.
  private func writeHybridTrailer(
    into writer: inout PDFByteWriter, context: HybridTrailerContext,
    extraTrailerEntries: [String: String]
  ) {
    writer.writeLine("trailer")
    var parts = [
      "/Size \(context.size)", "/Root \(context.root) 0 R",
      "/XRefStm \(context.xrefStreamOffset)"
    ]
    if let prevOffset = context.prevOffset {
      parts.append("/Prev \(prevOffset)")
    }
    for key in extraTrailerEntries.keys.sorted() {
      parts.append("/\(key) \(extraTrailerEntries[key] ?? "")")
    }
    writer.writeLine("<< \(parts.joined(separator: " ")) >>")
  }
}
