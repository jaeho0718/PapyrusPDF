import Foundation

// `PDFFixtureBuilder`의 M4 폰트 객체 기록(단순/Type0 공용). 파일 분리는 순수 조직적
// 이유(파일 길이 제한, §6)이며, `PDFFixtureBuilderTextAssembly.swift`와 동일한 타입·의미를
// 다룬다.

extension PDFFixtureBuilder {
  static func writeFontObjects(
    _ spec: TextFixtureSpec.FontFixtureSpec, plan: FontObjectPlan,
    into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int]
  ) {
    switch spec.kind {
    case let .simple(baseFont, baseEncoding, differences, firstChar, widths, toUnicode):
      let entries = toUnicode?.sorted { $0.key < $1.key }.map {
        (String(format: "%02X", $0.key), Self.utf16HexString($0.value))
      }
      let params = SimpleFontWriteParams(
        spec: spec, plan: plan, baseFont: baseFont, baseEncoding: baseEncoding,
        differences: differences, firstChar: firstChar, widths: widths, toUnicodeEntries: entries
      )
      Self.writeSimpleFont(params, into: &writer, objectOffsets: &objectOffsets)
    case let .type0IdentityH(baseFont, toUnicode, cidWidths, defaultWidth):
      let entries = toUnicode.isEmpty ? nil : toUnicode.sorted { $0.key < $1.key }.map {
        (String(format: "%04X", $0.key), Self.utf16HexString($0.value))
      }
      let params = Type0FontWriteParams(
        spec: spec, plan: plan, baseFont: baseFont, encodingText: "/Identity-H",
        cidWidths: cidWidths, defaultWidth: defaultWidth, toUnicodeEntries: entries,
        cmapSourceToWrite: nil
      )
      Self.writeType0Font(params, into: &writer, objectOffsets: &objectOffsets)
    case let .type0EmbeddedCMap(baseFont, cmapSource, toUnicode, defaultWidth):
      let entries = toUnicode?.sorted { $0.key < $1.key }.map {
        (String(format: "%04X", $0.key), Self.utf16HexString($0.value))
      }
      let params = Type0FontWriteParams(
        spec: spec, plan: plan, baseFont: baseFont,
        encodingText: "\(plan.cmapStreamNumber ?? 0) 0 R", cidWidths: [],
        defaultWidth: defaultWidth, toUnicodeEntries: entries, cmapSourceToWrite: cmapSource
      )
      Self.writeType0Font(params, into: &writer, objectOffsets: &objectOffsets)
    case let .type0Predefined(baseFont, cmapName):
      let params = Type0FontWriteParams(
        spec: spec, plan: plan, baseFont: baseFont, encodingText: "/\(cmapName)", cidWidths: [],
        defaultWidth: 1_000, toUnicodeEntries: nil, cmapSourceToWrite: nil
      )
      Self.writeType0Font(params, into: &writer, objectOffsets: &objectOffsets)
    }
  }

  /// ``writeSimpleFont(_:into:objectOffsets:)`` 입력 묶음 (매개변수 수 관리용).
  fileprivate struct SimpleFontWriteParams {
    let spec: TextFixtureSpec.FontFixtureSpec
    let plan: FontObjectPlan
    let baseFont: String
    let baseEncoding: String?
    let differences: [Int: String]
    let firstChar: Int
    let widths: [Int]
    let toUnicodeEntries: [(String, String)]?
  }

  fileprivate static func writeSimpleFont(
    _ params: SimpleFontWriteParams, into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int]
  ) {
    var parts = ["/Type /Font", "/Subtype /Type1", "/BaseFont /\(params.baseFont)"]
    if !params.widths.isEmpty {
      parts.append("/FirstChar \(params.firstChar)")
      parts.append("/LastChar \(params.firstChar + params.widths.count - 1)")
      parts.append("/Widths [\(params.widths.map(String.init).joined(separator: " "))]")
    }
    let encodingText = Self.simpleEncodingText(
      baseEncoding: params.baseEncoding, differences: params.differences
    )
    if let encodingText {
      parts.append("/Encoding \(encodingText)")
    }
    if let toUnicodeNumber = params.plan.toUnicodeNumber {
      parts.append("/ToUnicode \(toUnicodeNumber) 0 R")
    }
    if let descriptorNumber = params.plan.descriptorNumber {
      parts.append("/FontDescriptor \(descriptorNumber) 0 R")
    }
    Self.writeObject(
      params.plan.fontNumber, "<< \(parts.joined(separator: " ")) >>", into: &writer,
      objectOffsets: &objectOffsets
    )
    let descriptorNumber = params.plan.descriptorNumber
    if let descriptorNumber, let descriptor = params.spec.descriptor {
      Self.writeObject(
        descriptorNumber, Self.descriptorText(descriptor), into: &writer,
        objectOffsets: &objectOffsets
      )
    }
    let toUnicodeNumber = params.plan.toUnicodeNumber
    if let toUnicodeNumber, let toUnicodeEntries = params.toUnicodeEntries {
      let cmapText = Self.toUnicodeCMapSource(
        codespaceLo: "00", codespaceHi: "FF", entries: toUnicodeEntries
      )
      Self.writeStreamObject(
        toUnicodeNumber, cmapText, into: &writer, objectOffsets: &objectOffsets
      )
    }
  }

  /// ``writeType0Font(_:into:objectOffsets:)`` 입력 묶음 (매개변수 수 관리용).
  fileprivate struct Type0FontWriteParams {
    let spec: TextFixtureSpec.FontFixtureSpec
    let plan: FontObjectPlan
    let baseFont: String
    let encodingText: String
    let cidWidths: [TextFixtureSpec.FontFixtureSpec.CIDWidthRange]
    let defaultWidth: Int
    let toUnicodeEntries: [(String, String)]?
    let cmapSourceToWrite: String?
  }

  fileprivate static func writeType0Font(
    _ params: Type0FontWriteParams, into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int]
  ) {
    guard let descendantNumber = params.plan.descendantNumber else {
      return
    }
    Self.writeType0FontDictionaries(
      params, descendantNumber: descendantNumber, into: &writer, objectOffsets: &objectOffsets
    )
    Self.writeType0FontAuxiliaryObjects(params, into: &writer, objectOffsets: &objectOffsets)
  }

  /// 최상위 Type0 폰트 딕셔너리 + DescendantFonts[0] 딕셔너리를 기록한다.
  private static func writeType0FontDictionaries(
    _ params: Type0FontWriteParams, descendantNumber: Int, into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int]
  ) {
    var topParts = [
      "/Type /Font", "/Subtype /Type0", "/BaseFont /\(params.baseFont)",
      "/Encoding \(params.encodingText)", "/DescendantFonts [\(descendantNumber) 0 R]"
    ]
    if let toUnicodeNumber = params.plan.toUnicodeNumber {
      topParts.append("/ToUnicode \(toUnicodeNumber) 0 R")
    }
    Self.writeObject(
      params.plan.fontNumber, "<< \(topParts.joined(separator: " ")) >>", into: &writer,
      objectOffsets: &objectOffsets
    )

    var descendantParts = [
      "/Type /Font", "/Subtype /CIDFontType2", "/BaseFont /\(params.baseFont)",
      "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>",
      "/DW \(params.defaultWidth)"
    ]
    if !params.cidWidths.isEmpty {
      let widthsText = params.cidWidths.map { "\($0.first) \($0.last) \($0.width)" }
        .joined(separator: " ")
      descendantParts.append("/W [\(widthsText)]")
    }
    if let descriptorNumber = params.plan.descriptorNumber {
      descendantParts.append("/FontDescriptor \(descriptorNumber) 0 R")
    }
    Self.writeObject(
      descendantNumber, "<< \(descendantParts.joined(separator: " ")) >>", into: &writer,
      objectOffsets: &objectOffsets
    )
  }

  /// `/FontDescriptor`·`/ToUnicode`·임베디드 CMap 스트림 등 부속 객체를 기록한다.
  private static func writeType0FontAuxiliaryObjects(
    _ params: Type0FontWriteParams, into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int]
  ) {
    let descendantDescriptorNumber = params.plan.descriptorNumber
    if let descendantDescriptorNumber, let descriptor = params.spec.descriptor {
      Self.writeObject(
        descendantDescriptorNumber, Self.descriptorText(descriptor), into: &writer,
        objectOffsets: &objectOffsets
      )
    }
    let toUnicodeNumber = params.plan.toUnicodeNumber
    if let toUnicodeNumber, let toUnicodeEntries = params.toUnicodeEntries {
      let cmapText = Self.toUnicodeCMapSource(
        codespaceLo: "0000", codespaceHi: "FFFF", entries: toUnicodeEntries
      )
      Self.writeStreamObject(
        toUnicodeNumber, cmapText, into: &writer, objectOffsets: &objectOffsets
      )
    }
    let cmapStreamNumber = params.plan.cmapStreamNumber
    if let cmapStreamNumber, let cmapSourceToWrite = params.cmapSourceToWrite {
      Self.writeStreamObject(
        cmapStreamNumber, cmapSourceToWrite, into: &writer, objectOffsets: &objectOffsets
      )
    }
  }

  fileprivate static func descriptorText(
    _ descriptor: TextFixtureSpec.FontFixtureSpec.DescriptorSpec
  ) -> String {
    var parts = [
      "/Type /FontDescriptor", "/Ascent \(descriptor.ascent)", "/Descent \(descriptor.descent)"
    ]
    if let missingWidth = descriptor.missingWidth {
      parts.append("/MissingWidth \(missingWidth)")
    }
    return "<< \(parts.joined(separator: " ")) >>"
  }

  fileprivate static func simpleEncodingText(
    baseEncoding: String?, differences: [Int: String]
  ) -> String? {
    if differences.isEmpty {
      return baseEncoding.map { "/\($0)" }
    }
    var parts: [String] = []
    if let baseEncoding {
      parts.append("/BaseEncoding /\(baseEncoding)")
    }
    var diffParts: [String] = []
    for key in differences.keys.sorted() {
      diffParts.append("\(key)")
      diffParts.append("/\(differences[key] ?? "")")
    }
    parts.append("/Differences [\(diffParts.joined(separator: " "))]")
    return "<< \(parts.joined(separator: " ")) >>"
  }

  fileprivate static func toUnicodeCMapSource(
    codespaceLo: String, codespaceHi: String, entries: [(String, String)]
  ) -> String {
    var lines = [
      "/CIDInit /ProcSet findresource begin", "12 dict begin", "begincmap",
      "1 begincodespacerange", "<\(codespaceLo)> <\(codespaceHi)>", "endcodespacerange",
      "\(entries.count) beginbfchar"
    ]
    for (code, unicode) in entries {
      lines.append("<\(code)> <\(unicode)>")
    }
    lines.append("endbfchar")
    lines.append("endcmap")
    lines.append("CMapName currentdict /CMap defineresource pop")
    lines.append("end")
    lines.append("end")
    return lines.joined(separator: "\n")
  }

  fileprivate static func utf16HexString(_ value: String) -> String {
    value.utf16.map { String(format: "%04X", $0) }.joined()
  }

  fileprivate static func writeObject(
    _ number: Int, _ dictionaryText: String, into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int]
  ) {
    objectOffsets[number] = writer.offset
    writer.writeLine("\(number) 0 obj")
    writer.writeLine(dictionaryText)
    writer.writeLine("endobj")
  }

  fileprivate static func writeStreamObject(
    _ number: Int, _ content: String, into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int]
  ) {
    let bytes = Array(content.utf8)
    objectOffsets[number] = writer.offset
    writer.writeLine("\(number) 0 obj")
    writer.writeLine("<< /Length \(bytes.count) >>")
    writer.write("stream")
    writer.write(rawBytes: [0x0A])
    writer.write(rawBytes: bytes)
    writer.write(rawBytes: [0x0A])
    writer.writeLine("endstream")
    writer.writeLine("endobj")
  }
}
