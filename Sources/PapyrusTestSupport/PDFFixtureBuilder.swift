import Foundation

/// 테스트용 최소 유효 PDF를 바이트로 생성하는 빌더.
///
/// v0 범위: 클래식 xref 테이블 + 빈 페이지 N개. 콘텐츠 스트림·메타데이터 없음.
/// M2에서 ``XRefStyle`` 케이스 추가(xrefStream/objectStreams/hybrid),
/// 증분 업데이트, 손상 모드로 확장된다.
package struct PDFFixtureBuilder: Sendable {
  /// xref 섹션 기록 방식.
  ///
  /// 케이스 추가만으로 확장되도록 이 enum이 유일한 분기점이다.
  package enum XRefStyle: Sendable, Equatable {
    /// PDF 1.0 클래식 `xref` 테이블 + `trailer` 딕셔너리.
    case classicTable
    /// xref 스트림 (/Type /XRef, /W [1 4 2], Flate + PNG Up predictor(12), /Index 명시).
    /// 트레일러 키는 스트림 딕셔너리에 병합, `trailer` 키워드 없음.
    case xrefStream
    /// 비-스트림 객체(Catalog·Pages·Page들)를 ObjStm 컨테이너 하나에 압축 수납.
    /// xref는 필연적으로 스트림 방식 (type-2 엔트리는 클래식 테이블로 표현 불가).
    case objectStreams
    /// 클래식 테이블(압축 객체는 서브섹션 갭으로 누락) + /XRefStm 스트림 병기.
    /// 압축 수납 대상은 `.objectStreams`와 동일.
    case hybrid
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

  /// 증분 업데이트 목록 (순서 = 적용 순서). 각 항목이 body 추가분 + 새 xref 섹션
  /// (/Prev = 직전 섹션)을 원본 뒤에 덧붙인다. 빈 배열이면 기존 출력과 바이트 동일.
  package var updates: [IncrementalUpdateSpec]

  /// 트레일러(또는 xref 스트림 딕셔너리)에 추가할 원시 엔트리.
  /// 예: `["Encrypt": "<< /Filter /Standard /V 2 >>"]` — 값은 COS 구문 원문.
  /// 암호화 감지(M2)·/ID(M3) 등 트레일러 변형 테스트의 범용 주입점. 키는 이름(슬래시
  /// 제외)이며, 기록 시 키 이름 사전순으로 정렬해 결정적으로 출력한다.
  package var extraTrailerEntries: [String: String]

  /// 페이지 트리 형태 명세. `nil`이면 기존 평탄 구조 (바이트 동일). 설정 시 `pageCount`는
  /// 무시된다 (잎 수가 곧 페이지 수). `.classicTable` 전용 (가정 7).
  package var pageTree: PageTreeSpec?

  /// 목차 명세. `nil`이면 /Outlines 미기록 (바이트 동일). `.classicTable` 전용 (가정 7).
  package var outline: OutlineSpec?

  /// 이름 목적지 명세. `nil`이면 미기록. `.classicTable` 전용 (가정 7).
  package var namedDestinations: NamedDestinationsSpec?

  /// /Info 명세. `nil`이면 미기록. `.classicTable` 전용 (가정 7).
  package var info: InfoSpec?

  /// XMP 패킷 원문 (XML 문자열). 설정 시 Flate 스트림 + 카탈로그 /Metadata 참조 기록.
  /// `.classicTable` 전용 (가정 7).
  package var xmpMetadata: String?

  /// 빌더를 생성한다.
  /// - Parameters:
  ///   - pageCount: 생성할 페이지 수 (기본 1).
  ///   - pageWidth: 페이지 MediaBox 폭 (기본 612).
  ///   - pageHeight: 페이지 MediaBox 높이 (기본 792).
  ///   - xrefStyle: xref 기록 방식 (기본 `.classicTable`).
  ///   - contentStream: 전 페이지가 공유하는 콘텐츠 스트림 (기본 `nil` — v0와 바이트 동일).
  ///   - updates: 증분 업데이트 목록 (기본 `[]` — v0와 바이트 동일).
  ///   - extraTrailerEntries: 트레일러에 추가할 원시 엔트리 (기본 `[:]`).
  ///   - pageTree: 페이지 트리 형태 명세 (기본 `nil` — 기존 평탄 구조).
  ///   - outline: 목차 명세 (기본 `nil` — 미기록).
  ///   - namedDestinations: 이름 목적지 명세 (기본 `nil` — 미기록).
  ///   - info: /Info 명세 (기본 `nil` — 미기록).
  ///   - xmpMetadata: XMP 패킷 원문 (기본 `nil` — 미기록).
  package init(
    pageCount: Int = 1,
    pageWidth: Double = 612,
    pageHeight: Double = 792,
    xrefStyle: XRefStyle = .classicTable,
    contentStream: ContentStreamSpec? = nil,
    updates: [IncrementalUpdateSpec] = [],
    extraTrailerEntries: [String: String] = [:],
    pageTree: PageTreeSpec? = nil,
    outline: OutlineSpec? = nil,
    namedDestinations: NamedDestinationsSpec? = nil,
    info: InfoSpec? = nil,
    xmpMetadata: String? = nil
  ) {
    self.pageCount = pageCount
    self.pageWidth = pageWidth
    self.pageHeight = pageHeight
    self.xrefStyle = xrefStyle
    self.contentStream = contentStream
    self.updates = updates
    self.extraTrailerEntries = extraTrailerEntries
    self.pageTree = pageTree
    self.outline = outline
    self.namedDestinations = namedDestinations
    self.info = info
    self.xmpMetadata = xmpMetadata
  }

  /// 설정대로 PDF 바이트를 생성한다.
  ///
  /// 순수 함수 — 같은 설정이면 항상 동일한 바이트를 반환한다(결정성).
  /// - Precondition: `pageCount >= 0`, `pageWidth > 0`, `pageHeight > 0`. M3 신규 스펙
  ///   (`pageTree`/`outline`/`namedDestinations`/`info`/`xmpMetadata`) 중 하나라도 설정되면
  ///   `xrefStyle == .classicTable`, `contentStream == nil`, `updates.isEmpty`이어야 한다
  ///   (가정 7 — 타 스타일·contentStream·updates와 동시 사용 시 precondition 실패).
  package func build() -> PDFFixture {
    precondition(self.pageCount >= 0, "pageCount는 0 이상이어야 한다.")
    precondition(self.pageWidth > 0, "pageWidth는 0보다 커야 한다.")
    precondition(self.pageHeight > 0, "pageHeight는 0보다 커야 한다.")

    if self.usesM3Specs {
      precondition(self.xrefStyle == .classicTable, "M3 신규 스펙은 .classicTable 전용이다.")
      precondition(self.contentStream == nil, "M3 신규 스펙은 contentStream과 동시 사용할 수 없다.")
      precondition(self.updates.isEmpty, "M3 신규 스펙은 updates와 동시 사용할 수 없다.")
      return self.buildM3Fixture()
    }

    var writer = PDFByteWriter()
    var objectOffsets: [Int: Int] = [:]
    self.writeHeader(into: &writer)

    let plan = self.makeObjectNumberPlan()
    // 업데이트가 없으면 이 섹션이 최종본이므로 extraTrailerEntries를 여기 반영한다.
    let extraEntries = self.updates.isEmpty ? self.extraTrailerEntries : [:]
    let baseXRefOffset = self.writeBaseXRefSection(
      into: &writer, objectOffsets: &objectOffsets, plan: plan, extraEntries: extraEntries
    )

    let base = PDFFixture(
      data: Data(writer.bytes), objectOffsets: objectOffsets, xrefOffset: baseXRefOffset,
      sectionOffsets: [baseXRefOffset]
    )
    guard !self.updates.isEmpty else {
      return base
    }
    return self.applyUpdates(to: base)
  }

  /// `xrefStyle`에 따라 본문 + xref 섹션(+트레일러)을 기록한다.
  /// - Returns: 이 섹션의 시작 오프셋(= `startxref` 대상).
  private func writeBaseXRefSection(
    into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int], plan: FixtureObjectPlan,
    extraEntries: [String: String]
  ) -> Int {
    switch self.xrefStyle {
    case .classicTable:
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
      let xrefOffset = writer.offset
      self.writeXRefTable(into: &writer, objectOffsets: objectOffsets, totalObjects: plan.size)
      self.writeTrailer(
        into: &writer, xrefOffset: xrefOffset, totalObjects: plan.size,
        prevOffset: nil, extraTrailerEntries: extraEntries
      )
      return xrefOffset
    case .xrefStream:
      let xrefOffset = self.writeXRefStreamStyleBody(
        into: &writer, objectOffsets: &objectOffsets, plan: plan, prevOffset: nil,
        extraTrailerEntries: extraEntries
      )
      Self.writeStartxrefFooter(into: &writer, xrefOffset: xrefOffset)
      return xrefOffset
    case .objectStreams:
      let xrefOffset = self.writeObjectStreamsStyleBody(
        into: &writer, objectOffsets: &objectOffsets, plan: plan, prevOffset: nil,
        extraTrailerEntries: extraEntries
      )
      Self.writeStartxrefFooter(into: &writer, xrefOffset: xrefOffset)
      return xrefOffset
    case .hybrid:
      let xrefOffset = self.writeHybridStyleBody(
        into: &writer, objectOffsets: &objectOffsets, plan: plan, prevOffset: nil,
        extraTrailerEntries: extraEntries
      )
      Self.writeStartxrefFooter(into: &writer, xrefOffset: xrefOffset)
      return xrefOffset
    }
  }

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

// MARK: - M3 신규 스펙 조합 판정

extension PDFFixtureBuilder {
  /// M3 신규 스펙(페이지 트리/목차/이름 목적지/Info/XMP) 중 하나라도 설정되어 있는가.
  var usesM3Specs: Bool {
    self.pageTree != nil || self.outline != nil || self.namedDestinations != nil
      || self.info != nil || self.xmpMetadata != nil
  }
}

// MARK: - 헤더 기록 (struct 본체 길이 관리를 위해 extension으로 분리, 의미는 동일)

extension PDFFixtureBuilder {
  /// PDF 헤더(버전 + 바이너리 마커 주석)를 기록한다.
  func writeHeader(into writer: inout PDFByteWriter) {
    writer.writeLine("%PDF-1.4")
    writer.write("%")
    writer.write(rawBytes: [0xE2, 0xE3, 0xCF, 0xD3])
    writer.write(rawBytes: [0x0A])
  }
}
