import Foundation

/// 테스트용 최소 유효 PDF를 바이트로 생성하는 빌더.
///
/// v0 범위: 클래식 xref 테이블 + 빈 페이지 N개. 콘텐츠 스트림·메타데이터 없음.
/// M2에서 ``XRefStyle`` 케이스 추가(xrefStream/objectStreams/hybrid),
/// 증분 업데이트, 손상 모드로 확장된다.
package struct PDFFixtureBuilder: Sendable {
  /// xref 섹션 기록 방식.
  ///
  /// v0는 클래식 테이블만 지원한다. M2에서 `.xrefStream`, `.objectStreams`,
  /// `.hybrid` 케이스가 추가된다 — 케이스 추가만으로 확장되도록 이 enum이 유일한 분기점이다.
  package enum XRefStyle: Sendable {
    /// PDF 1.0 클래식 `xref` 테이블 + `trailer` 딕셔너리.
    case classicTable
  }

  /// 생성할 페이지 수. 0 이상. (0이면 /Kids [] /Count 0 — 퇴화 케이스 테스트용)
  package var pageCount: Int

  /// 페이지 MediaBox 폭 (PDF 포인트). 기본 612 (US Letter).
  package var pageWidth: Double

  /// 페이지 MediaBox 높이 (PDF 포인트). 기본 792.
  package var pageHeight: Double

  /// xref 기록 방식. v0 기본이자 유일한 값은 `.classicTable`.
  package var xrefStyle: XRefStyle

  /// 전 페이지가 공유하는 콘텐츠 스트림. `nil`이면 v0와 동일한 바이트를 산출한다.
  package var contentStream: ContentStreamSpec?

  /// 빌더를 생성한다.
  /// - Parameters:
  ///   - pageCount: 생성할 페이지 수 (기본 1).
  ///   - pageWidth: 페이지 MediaBox 폭 (기본 612).
  ///   - pageHeight: 페이지 MediaBox 높이 (기본 792).
  ///   - xrefStyle: xref 기록 방식 (기본 `.classicTable`).
  ///   - contentStream: 전 페이지가 공유하는 콘텐츠 스트림 (기본 `nil` — v0와 바이트 동일).
  package init(
    pageCount: Int = 1,
    pageWidth: Double = 612,
    pageHeight: Double = 792,
    xrefStyle: XRefStyle = .classicTable,
    contentStream: ContentStreamSpec? = nil
  ) {
    self.pageCount = pageCount
    self.pageWidth = pageWidth
    self.pageHeight = pageHeight
    self.xrefStyle = xrefStyle
    self.contentStream = contentStream
  }

  /// 설정대로 PDF 바이트를 생성한다.
  ///
  /// 순수 함수 — 같은 설정이면 항상 동일한 바이트를 반환한다(결정성).
  /// - Precondition: `pageCount >= 0`, `pageWidth > 0`, `pageHeight > 0`.
  package func build() -> PDFFixture {
    precondition(self.pageCount >= 0, "pageCount는 0 이상이어야 한다.")
    precondition(self.pageWidth > 0, "pageWidth는 0보다 커야 한다.")
    precondition(self.pageHeight > 0, "pageHeight는 0보다 커야 한다.")

    var writer = PDFByteWriter()
    var objectOffsets: [Int: Int] = [:]

    // 객체 번호 배치(결정성): Catalog=1, Pages=2, 페이지=3...N+2, 공유 콘텐츠 스트림=N+3,
    // /Length 간접 시 정수 객체=N+4. contentStream이 nil이면 이 두 객체는 존재하지 않는다.
    let contentsObjectNumber = self.contentStream != nil ? self.pageCount + 3 : nil
    let needsLengthObject = self.contentStream?.lengthStyle == .indirect
    let lengthObjectNumber = needsLengthObject ? self.pageCount + 4 : nil

    self.writeHeader(into: &writer)
    self.writeBody(
      into: &writer, objectOffsets: &objectOffsets, contentsObjectNumber: contentsObjectNumber
    )
    if let contentStream, let contentsObjectNumber {
      self.writeContentStreamObject(
        into: &writer, objectOffsets: &objectOffsets, objectNumber: contentsObjectNumber,
        lengthObjectNumber: lengthObjectNumber, spec: contentStream
      )
    }

    let xrefOffset = writer.offset
    var totalObjects = self.pageCount + 3
    if contentsObjectNumber != nil {
      totalObjects += 1
    }
    if lengthObjectNumber != nil {
      totalObjects += 1
    }

    self.writeXRefTable(
      into: &writer,
      objectOffsets: objectOffsets,
      totalObjects: totalObjects
    )
    self.writeTrailer(into: &writer, xrefOffset: xrefOffset, totalObjects: totalObjects)

    return PDFFixture(
      data: Data(writer.bytes),
      objectOffsets: objectOffsets,
      xrefOffset: xrefOffset
    )
  }

  /// PDF 헤더(버전 + 바이너리 마커 주석)를 기록한다.
  private func writeHeader(into writer: inout PDFByteWriter) {
    writer.writeLine("%PDF-1.4")
    writer.write("%")
    writer.write(rawBytes: [0xE2, 0xE3, 0xCF, 0xD3])
    writer.write(rawBytes: [0x0A])
  }

  /// Catalog, Pages, 페이지 객체 N개를 순서대로 기록하며 각 시작 오프셋을 저장한다.
  ///
  /// `contentsObjectNumber`가 있으면 각 페이지 딕셔너리에 `/Contents N 0 R`를 추가한다
  /// (`nil`이면 v0와 바이트 동일 — 이 매개변수 자체가 조건부로만 출력에 영향을 준다).
  private func writeBody(
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
  private func writeContentStreamObject(
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

  /// 인코딩 하나를 순방향(인코딩 방향)으로 적용한다.
  private static func applyEncoding(
    _ encoding: ContentStreamSpec.Encoding, to data: Data
  ) -> Data {
    switch encoding {
    case .flate:
      return PDFFilterEncoders.flate(data)
    case .asciiHex:
      return PDFFilterEncoders.asciiHex(data)
    case .ascii85:
      return PDFFilterEncoders.ascii85(data)
    case .runLength:
      return PDFFilterEncoders.runLength(data)
    }
  }

  /// 인코딩 종류에 대응하는 PDF 표준 필터 이름.
  private static func filterName(for encoding: ContentStreamSpec.Encoding) -> String {
    switch encoding {
    case .flate:
      return "/FlateDecode"
    case .asciiHex:
      return "/ASCIIHexDecode"
    case .ascii85:
      return "/ASCII85Decode"
    case .runLength:
      return "/RunLengthDecode"
    }
  }

  /// `/Length`에 기록할 정수 값을 결정한다 (`.directWrong`은 의도적으로 어긋난 값).
  private static func declaredLength(
    for encoded: Data, style: ContentStreamSpec.LengthStyle
  ) -> Int {
    switch style {
    case .direct, .indirect:
      return encoded.count
    case let .directWrong(delta):
      return encoded.count + delta
    }
  }

  /// 클래식 xref 테이블(단일 서브섹션)을 기록한다. 엔트리는 CRLF 종결, 정확히 20바이트.
  private func writeXRefTable(
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
  private func writeTrailer(
    into writer: inout PDFByteWriter,
    xrefOffset: Int,
    totalObjects: Int
  ) {
    writer.writeLine("trailer")
    writer.writeLine("<< /Size \(totalObjects) /Root 1 0 R >>")
    writer.writeLine("startxref")
    writer.writeLine("\(xrefOffset)")
    writer.write("%%EOF")
  }

  /// 10자리 zero-pad 오프셋 + 5자리 zero-pad 세대 + 타입 문자로 구성된 xref 엔트리 본문을
  /// 만든다 (CRLF는 호출부에서 덧붙인다).
  private static func xrefEntry(offset: Int, generation: Int, type: Character) -> String {
    let offsetText = String(format: "%010d", offset)
    let generationText = String(format: "%05d", generation)
    return "\(offsetText) \(generationText) \(type)"
  }

  /// MediaBox 좌표를 결정적으로 포맷팅한다: 정수면 소수점 없이, 아니면 소수점 이하 최대
  /// 2자리(뒤따르는 0 제거). 로케일에 의존하지 않는 정수 연산으로 구현한다.
  private static func formatCoordinate(_ value: Double) -> String {
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
