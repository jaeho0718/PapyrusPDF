import Foundation

// `PDFFixtureBuilder`의 v0/v1 클래식 본문·xref·트레일러 기록 로직. 파일 분리는 순수
// 조직적 이유(파일 길이 제한, §6)이며, `PDFFixtureBuilder.swift`와 동일한 타입·의미를
// 다룬다.

extension PDFFixtureBuilder {
  /// Catalog, Pages, 페이지 객체 N개를 순서대로 기록하며 각 시작 오프셋을 저장한다.
  ///
  /// `contentsObjectNumber`가 있으면 각 페이지 딕셔너리에 `/Contents N 0 R`를 추가한다
  /// (`nil`이면 v0와 바이트 동일 — 이 매개변수 자체가 조건부로만 출력에 영향을 준다).
  func writeBody(
    into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int],
    contentsObjectNumber: Int?
  ) {
    objectOffsets[1] = writer.offset
    writer.writeLine("1 0 obj")
    writer.writeLine("<< /Type /Catalog /Pages 2 0 R >>")
    writer.writeLine("endobj")

    objectOffsets[2] = writer.offset
    writer.writeLine("2 0 obj")
    let kids = (0..<self.pageCount).map { "\(3 + $0) 0 R" }.joined(separator: " ")
    writer.writeLine("<< /Type /Pages /Kids [\(kids)] /Count \(self.pageCount) >>")
    writer.writeLine("endobj")

    let widthText = Self.formatCoordinate(self.pageWidth)
    let heightText = Self.formatCoordinate(self.pageHeight)
    let contentsEntry = contentsObjectNumber.map { " /Contents \($0) 0 R" } ?? ""
    for index in 0..<self.pageCount {
      let objectNumber = 3 + index
      objectOffsets[objectNumber] = writer.offset
      writer.writeLine("\(objectNumber) 0 obj")
      let mediaBox = "[0 0 \(widthText) \(heightText)]"
      writer.writeLine(
        "<< /Type /Page /Parent 2 0 R /MediaBox \(mediaBox)\(contentsEntry) >>"
      )
      writer.writeLine("endobj")
    }
  }

  /// 공유 콘텐츠 스트림 객체(및 `/Length`가 간접이면 그 정수 객체)를 기록한다.
  func writeContentStreamObject(
    into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int],
    objectNumber: Int,
    lengthObjectNumber: Int?,
    spec: ContentStreamSpec
  ) {
    let encoded = spec.encodings.reduce(spec.body) { partial, encoding in
      Self.applyEncoding(encoding, to: partial)
    }
    let filterNames = spec.encodings.reversed().map(Self.filterName(for:))
    let filterEntry = filterNames.isEmpty ? "" : " /Filter [\(filterNames.joined(separator: " "))]"
    let length = Self.declaredLength(for: encoded, style: spec.lengthStyle)
    let lengthEntry: String
    switch spec.lengthStyle {
    case .direct, .directWrong:
      lengthEntry = "/Length \(length)"
    case .indirect:
      lengthEntry = "/Length \(lengthObjectNumber ?? 0) 0 R"
    }

    objectOffsets[objectNumber] = writer.offset
    writer.writeLine("\(objectNumber) 0 obj")
    writer.writeLine("<< \(lengthEntry)\(filterEntry) >>")
    writer.write("stream")
    writer.write(rawBytes: spec.streamEOL.bytes)
    writer.write(rawBytes: [UInt8](encoded))
    writer.write(rawBytes: [0x0A])
    writer.writeLine("endstream")
    writer.writeLine("endobj")

    if let lengthObjectNumber {
      objectOffsets[lengthObjectNumber] = writer.offset
      writer.writeLine("\(lengthObjectNumber) 0 obj")
      writer.writeLine("\(encoded.count)")
      writer.writeLine("endobj")
    }
  }

  /// 클래식 xref 테이블(단일 서브섹션)을 기록한다. 엔트리는 CRLF 종결, 정확히 20바이트.
  func writeXRefTable(
    into writer: inout PDFByteWriter,
    objectOffsets: [Int: Int],
    totalObjects: Int
  ) {
    writer.writeLine("xref")
    writer.writeLine("0 \(totalObjects)")

    writer.write(Self.xrefEntry(offset: 0, generation: 65_535, type: "f"))
    writer.write(rawBytes: [0x0D, 0x0A])

    // pageCount >= 0 (build()의 precondition)이므로 highestObjectNumber >= 2 — 범위는 항상 유효하다.
    let highestObjectNumber = totalObjects - 1
    for objectNumber in 1...highestObjectNumber {
      let offset = objectOffsets[objectNumber] ?? 0
      writer.write(Self.xrefEntry(offset: offset, generation: 0, type: "n"))
      writer.write(rawBytes: [0x0D, 0x0A])
    }
  }

  /// trailer, startxref, %%EOF 를 기록한다.
  /// - Parameters:
  ///   - writer: 기록 대상 바이트 조립기.
  ///   - xrefOffset: `startxref`가 가리킬 오프셋.
  ///   - totalObjects: `/Size` 값.
  ///   - prevOffset: 증분 업데이트의 `/Prev` 값 (없으면 `nil`).
  ///   - extraTrailerEntries: 트레일러에 덧붙일 원시 엔트리 (키 사전순 기록).
  func writeTrailer(
    into writer: inout PDFByteWriter,
    xrefOffset: Int,
    totalObjects: Int,
    prevOffset: Int? = nil,
    extraTrailerEntries: [String: String] = [:]
  ) {
    writer.writeLine("trailer")
    var parts = ["/Size \(totalObjects)", "/Root 1 0 R"]
    if let prevOffset {
      parts.append("/Prev \(prevOffset)")
    }
    for key in extraTrailerEntries.keys.sorted() {
      parts.append("/\(key) \(extraTrailerEntries[key] ?? "")")
    }
    writer.writeLine("<< \(parts.joined(separator: " ")) >>")
    writer.writeLine("startxref")
    writer.writeLine("\(xrefOffset)")
    writer.write("%%EOF")
  }

  /// `startxref`·오프셋·`%%EOF`만 기록한다 (트레일러가 없는 xref 스트림 스타일 전용 —
  /// 클래식 스타일은 `writeTrailer(into:xrefOffset:totalObjects:prevOffset:extraTrailerEntries:)`가
  /// 이 세 줄까지 포함해 기록한다).
  static func writeStartxrefFooter(into writer: inout PDFByteWriter, xrefOffset: Int) {
    writer.writeLine("startxref")
    writer.writeLine("\(xrefOffset)")
    writer.write("%%EOF")
  }

  /// 10자리 zero-pad 오프셋 + 5자리 zero-pad 세대 + 타입 문자로 구성된 xref 엔트리 본문을
  /// 만든다 (CRLF는 호출부에서 덧붙인다).
  static func xrefEntry(offset: Int, generation: Int, type: Character) -> String {
    let offsetText = String(format: "%010d", offset)
    let generationText = String(format: "%05d", generation)
    return "\(offsetText) \(generationText) \(type)"
  }

  /// MediaBox 좌표를 결정적으로 포맷팅한다: 정수면 소수점 없이, 아니면 소수점 이하 최대
  /// 2자리(뒤따르는 0 제거). 로케일에 의존하지 않는 정수 연산으로 구현한다.
  static func formatCoordinate(_ value: Double) -> String {
    let sign = value < 0 ? "-" : ""
    let scaled = (abs(value) * 100).rounded()
    let integerPart = Int64(scaled) / 100
    let fractionPart = Int64(scaled) % 100

    guard fractionPart != 0 else {
      return "\(sign)\(integerPart)"
    }

    var fractionText = String(fractionPart)
    if fractionText.count == 1 {
      fractionText = "0" + fractionText
    }
    while fractionText.hasSuffix("0") {
      fractionText.removeLast()
    }
    return "\(sign)\(integerPart).\(fractionText)"
  }
}
