import Foundation

// `PDFFixtureBuilder`의 M4 콘텐츠 세그먼트·`/Resources`·Form XObject 기록. 파일 분리는
// 순수 조직적 이유(파일 길이 제한, §6)이며, `PDFFixtureBuilderTextAssembly.swift`와 동일한
// 타입·의미를 다룬다.

extension PDFFixtureBuilder {
  static func contentsEntryText(_ plan: ContentPlan) -> String {
    guard plan.objectNumbers.count > 1 else {
      return "/Contents \(plan.objectNumbers.first ?? 0) 0 R"
    }
    let refs = plan.objectNumbers.map { "\($0) 0 R" }.joined(separator: " ")
    return "/Contents [\(refs)]"
  }

  static func writeContentSegments(
    _ plan: ContentPlan, into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int]
  ) {
    let filterNames = plan.encodings.reversed().map(Self.filterName(for:))
    let filterEntry = filterNames.isEmpty ? "" : " /Filter [\(filterNames.joined(separator: " "))]"
    for (segmentIndex, rawSegment) in plan.rawSegments.enumerated() {
      let encoded = plan.encodings.reduce(rawSegment) { partial, encoding in
        Self.applyEncoding(encoding, to: partial)
      }
      let number = plan.objectNumbers[segmentIndex]
      objectOffsets[number] = writer.offset
      writer.writeLine("\(number) 0 obj")
      writer.writeLine("<< /Length \(encoded.count)\(filterEntry) >>")
      writer.write("stream")
      writer.write(rawBytes: [0x0A])
      writer.write(rawBytes: [UInt8](encoded))
      writer.write(rawBytes: [0x0A])
      writer.writeLine("endstream")
      writer.writeLine("endobj")
    }
  }
}

// MARK: - /Resources 기록

extension PDFFixtureBuilder {
  static func resourcesEntryText(
    fontNameToNumber: [String: Int], formPlans: [FormWritePlan]
  ) -> String {
    var parts: [String] = []
    if !fontNameToNumber.isEmpty {
      let fontEntries = fontNameToNumber.keys.sorted()
        .map { "/\($0) \(fontNameToNumber[$0] ?? 0) 0 R" }.joined(separator: " ")
      parts.append("/Font << \(fontEntries) >>")
    }
    if !formPlans.isEmpty {
      let xObjectEntries = formPlans.map { "/\($0.resourceName) \($0.number) 0 R" }
        .joined(separator: " ")
      parts.append("/XObject << \(xObjectEntries) >>")
    }
    return "<< \(parts.joined(separator: " ")) >>"
  }
}

// MARK: - Form XObject 기록

extension PDFFixtureBuilder {
  static func writeFormXObject(
    _ plan: FormWritePlan, into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int]
  ) {
    let content = Array(plan.spec.operations.utf8)
    let matrixText = plan.spec.matrix.map(Self.formatCoordinate).joined(separator: " ")
    let resourcesText = Self.resourcesEntryText(
      fontNameToNumber: plan.fontNameToNumber, formPlans: []
    )
    objectOffsets[plan.number] = writer.offset
    writer.writeLine("\(plan.number) 0 obj")
    writer.writeLine(
      "<< /Type /XObject /Subtype /Form /BBox [0 0 1000 1000] /Matrix [\(matrixText)] " +
        "/Resources \(resourcesText) /Length \(content.count) >>"
    )
    writer.write("stream")
    writer.write(rawBytes: [0x0A])
    writer.write(rawBytes: content)
    writer.write(rawBytes: [0x0A])
    writer.writeLine("endstream")
    writer.writeLine("endobj")
  }
}
