import Foundation

// `PDFFixtureBuilder`의 M4 전체 조립(텍스트 픽스처: 페이지/폰트/Form XObject + xref/트레일러).
// 파일 분리는 순수 조직적 이유(파일 길이 제한, §6)이며, `PDFFixtureBuilderText.swift`와
// 동일한 타입·의미를 다룬다. 콘텐츠/Form 기록은 `PDFFixtureBuilderTextContent.swift`,
// 폰트 객체 기록은 `PDFFixtureBuilderTextFonts.swift`로 더 나눴다.

extension PDFFixtureBuilder {
  /// M4 텍스트 픽스처 경로의 최종 조립. `.classicTable` 단일 섹션만 기록한다.
  func buildM4Fixture() -> PDFFixture {
    guard let spec = self.textFixture else {
      preconditionFailure("textFixture가 설정되어 있어야 한다.")
    }
    var writer = PDFByteWriter()
    self.writeHeader(into: &writer)
    var objectOffsets: [Int: Int] = [:]

    let pageCount = spec.pages.count
    let pageNumbers = (0..<pageCount).map { 3 + $0 }
    var next = 3 + pageCount

    var fontRegistry: [(spec: TextFixtureSpec.FontFixtureSpec, plan: FontObjectPlan)] = []
    let pagePlans = Self.planPages(spec.pages, fontRegistry: &fontRegistry, next: &next)

    Self.writeCatalogAndPagesTree(
      pageNumbers: pageNumbers, into: &writer, objectOffsets: &objectOffsets
    )
    self.writePageDictionaries(
      pagePlans, pageNumbers: pageNumbers, into: &writer, objectOffsets: &objectOffsets
    )
    for plan in pagePlans {
      Self.writeContentSegments(plan.contentPlan, into: &writer, objectOffsets: &objectOffsets)
      for form in plan.forms {
        Self.writeFormXObject(form, into: &writer, objectOffsets: &objectOffsets)
      }
    }
    for (fontSpec, plan) in fontRegistry {
      Self.writeFontObjects(fontSpec, plan: plan, into: &writer, objectOffsets: &objectOffsets)
    }

    let xrefOffset = self.writeXrefAndTrailer(
      highestNumber: next - 1, into: &writer, objectOffsets: objectOffsets
    )
    return PDFFixture(
      data: Data(writer.bytes), objectOffsets: objectOffsets, xrefOffset: xrefOffset,
      sectionOffsets: [xrefOffset]
    )
  }

  /// 카탈로그(1)·루트 Pages(2)를 기록한다.
  private static func writeCatalogAndPagesTree(
    pageNumbers: [Int], into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int]
  ) {
    objectOffsets[1] = writer.offset
    writer.writeLine("1 0 obj")
    writer.writeLine("<< /Type /Catalog /Pages 2 0 R >>")
    writer.writeLine("endobj")

    objectOffsets[2] = writer.offset
    writer.writeLine("2 0 obj")
    let kids = pageNumbers.map { "\($0) 0 R" }.joined(separator: " ")
    writer.writeLine("<< /Type /Pages /Kids [\(kids)] /Count \(pageNumbers.count) >>")
    writer.writeLine("endobj")
  }

  /// 페이지 딕셔너리들을 기록한다.
  private func writePageDictionaries(
    _ pagePlans: [PageWritePlan], pageNumbers: [Int], into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int]
  ) {
    let widthText = Self.formatCoordinate(self.pageWidth)
    let heightText = Self.formatCoordinate(self.pageHeight)
    for (index, plan) in pagePlans.enumerated() {
      let pageNumber = pageNumbers[index]
      objectOffsets[pageNumber] = writer.offset
      writer.writeLine("\(pageNumber) 0 obj")
      let contentsEntry = Self.contentsEntryText(plan.contentPlan)
      let resourcesEntry = Self.resourcesEntryText(
        fontNameToNumber: plan.fontNameToNumber, formPlans: plan.forms
      )
      writer.writeLine(
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(widthText) \(heightText)] " +
          "\(contentsEntry) /Resources \(resourcesEntry) >>"
      )
      writer.writeLine("endobj")
    }
  }

  /// 클래식 xref 테이블 + 트레일러를 기록한다.
  /// - Returns: `xref` 키워드 시작 오프셋(= `startxref` 대상).
  private func writeXrefAndTrailer(
    highestNumber: Int, into writer: inout PDFByteWriter, objectOffsets: [Int: Int]
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
    self.writeTrailer(
      into: &writer, xrefOffset: xrefOffset, totalObjects: highestNumber + 1,
      extraTrailerEntries: self.extraTrailerEntries
    )
    return xrefOffset
  }
}

// MARK: - 계획 타입

/// 폰트 하나가 차지하는 객체 번호들 (스펙 동등성으로 dedupe된 뒤 1회만 생성).
struct FontObjectPlan {
  let fontNumber: Int
  let descriptorNumber: Int?
  let toUnicodeNumber: Int?
  let descendantNumber: Int?
  let cmapStreamNumber: Int?
}

/// 콘텐츠 세그먼트 계획 (분할 지점 적용 완료, 인코딩은 기록 시점에 적용).
struct ContentPlan {
  let objectNumbers: [Int]
  let rawSegments: [Data]
  let encodings: [PDFFixtureBuilder.ContentStreamSpec.Encoding]
}

/// Form XObject 하나의 기록 계획.
struct FormWritePlan {
  let resourceName: String
  let number: Int
  let spec: PDFFixtureBuilder.TextFixtureSpec.FormXObjectFixtureSpec
  let fontNameToNumber: [String: Int]
}

/// 페이지 하나의 기록 계획.
struct PageWritePlan {
  let contentPlan: ContentPlan
  let fontNameToNumber: [String: Int]
  let forms: [FormWritePlan]
}

// MARK: - 번호 배치

extension PDFFixtureBuilder {
  /// 전 페이지의 콘텐츠 세그먼트·폰트·Form 번호를 배치한다 (기록은 하지 않는다).
  fileprivate static func planPages(
    _ pageSpecs: [TextFixtureSpec.TextPageSpec],
    fontRegistry: inout [(spec: TextFixtureSpec.FontFixtureSpec, plan: FontObjectPlan)],
    next: inout Int
  ) -> [PageWritePlan] {
    pageSpecs.map { pageSpec in
      let contentPlan = Self.planContentSegments(pageSpec, next: &next)
      var fontNameToNumber: [String: Int] = [:]
      for fontSpec in pageSpec.fonts {
        fontNameToNumber[fontSpec.resourceName] = Self.registerFont(
          fontSpec, registry: &fontRegistry, next: &next
        )
      }
      var forms: [FormWritePlan] = []
      for formSpec in pageSpec.formXObjects {
        let formNumber = next
        next += 1
        var formFontNameToNumber: [String: Int] = [:]
        for fontSpec in formSpec.fonts {
          formFontNameToNumber[fontSpec.resourceName] = Self.registerFont(
            fontSpec, registry: &fontRegistry, next: &next
          )
        }
        forms.append(FormWritePlan(
          resourceName: formSpec.resourceName, number: formNumber, spec: formSpec,
          fontNameToNumber: formFontNameToNumber
        ))
      }
      return PageWritePlan(
        contentPlan: contentPlan, fontNameToNumber: fontNameToNumber, forms: forms
      )
    }
  }

  fileprivate static func planContentSegments(
    _ pageSpec: TextFixtureSpec.TextPageSpec, next: inout Int
  ) -> ContentPlan {
    let rawBytes = Array(pageSpec.operations.utf8)
    let breakPoints = Set(pageSpec.segmentBreaks.filter { $0 > 0 && $0 < rawBytes.count }).sorted()
    var segments: [Data] = []
    var previous = 0
    for breakPoint in breakPoints {
      segments.append(Data(rawBytes[previous..<breakPoint]))
      previous = breakPoint
    }
    segments.append(Data(rawBytes[previous...]))

    var objectNumbers: [Int] = []
    objectNumbers.reserveCapacity(segments.count)
    for _ in segments {
      objectNumbers.append(next)
      next += 1
    }
    return ContentPlan(
      objectNumbers: objectNumbers, rawSegments: segments, encodings: pageSpec.encodings
    )
  }

  /// 스펙 동등성으로 중복을 제거하며 폰트 객체 번호들을 배치한다. 이미 등록된 스펙이면
  /// 기존 폰트 딕셔너리 번호를 그대로 반환한다 (TC4 dedupe).
  fileprivate static func registerFont(
    _ spec: TextFixtureSpec.FontFixtureSpec,
    registry: inout [(spec: TextFixtureSpec.FontFixtureSpec, plan: FontObjectPlan)],
    next: inout Int
  ) -> Int {
    if let existing = registry.first(where: { $0.spec == spec }) {
      return existing.plan.fontNumber
    }
    let fontNumber = next
    next += 1
    var descriptorNumber: Int?
    if spec.descriptor != nil {
      descriptorNumber = next
      next += 1
    }
    var toUnicodeNumber: Int?
    var descendantNumber: Int?
    var cmapStreamNumber: Int?
    switch spec.kind {
    case let .simple(_, _, _, _, _, toUnicode):
      if let toUnicode, !toUnicode.isEmpty {
        toUnicodeNumber = next
        next += 1
      }
    case let .type0IdentityH(_, toUnicode, _, _):
      if !toUnicode.isEmpty {
        toUnicodeNumber = next
        next += 1
      }
      descendantNumber = next
      next += 1
    case let .type0EmbeddedCMap(_, _, toUnicode, _):
      if let toUnicode, !toUnicode.isEmpty {
        toUnicodeNumber = next
        next += 1
      }
      descendantNumber = next
      next += 1
      cmapStreamNumber = next
      next += 1
    case .type0Predefined:
      descendantNumber = next
      next += 1
    }
    let plan = FontObjectPlan(
      fontNumber: fontNumber, descriptorNumber: descriptorNumber, toUnicodeNumber: toUnicodeNumber,
      descendantNumber: descendantNumber, cmapStreamNumber: cmapStreamNumber
    )
    registry.append((spec, plan))
    return fontNumber
  }
}
