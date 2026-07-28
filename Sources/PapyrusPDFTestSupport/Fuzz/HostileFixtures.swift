import Foundation

/// 뮤테이션으로는 우연히 만들어지기 어려운, 구성상 적대적인 픽스처 생성기.
/// 구조가 "유효"해서 파서 깊숙이 도달한 뒤에야 병리가 드러나는 부류다.
///
/// 구현 방식: `PDFFixtureBuilder`의 기존 내부 조립 헬퍼(헤더 기록·xref 스트림 기록 등,
/// 전부 모듈 `internal`)를 재사용한다. `PapyrusPDFTestSupport`는 `PapyrusPDFCore`에 의존하지
/// 않으므로 이 파일도 원시 COS 바이트만 다룬다 — 파서 지식은 쓰지 않는다.
package enum HostileFixtures {
  /// `[[[[...]]]]` — 지정 깊이의 중첩 배열을 객체 하나에 담은 픽스처
  /// (`CoreLimits.maxNestingDepth` 경계 ±1 검증용).
  /// - Parameter depth: 중첩 배열 깊이.
  /// - Returns: Catalog 객체 자신이 `/Deep` 키에 깊이 `depth`의 중첩 배열을 담은 픽스처.
  package static func deepNesting(depth: Int) -> PDFFixture {
    precondition(depth >= 0, "deepNesting depth는 0 이상이어야 한다.")
    let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
    return Self.assembleClassicFixture(
      objects: [
        (1, "<< /Type /Catalog /Pages 2 0 R /Deep \(nested) >>"),
        (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>")
      ],
      rootNumber: 1
    )
  }

  /// /Length가 파일 크기보다 큰 스트림 (거짓 길이 → endstream 스캔 폴백 강제).
  /// - Returns: 콘텐츠 스트림의 `/Length`가 실제 바이트 수보다 1000만 크게 선언된 픽스처.
  package static func hugeClaimedLength() -> PDFFixture {
    PDFFixtureBuilder(
      pageCount: 1,
      contentStream: PDFFixtureBuilder.ContentStreamSpec(
        body: Data("BT ET".utf8), lengthStyle: .directWrong(delta: 10_000_000)
      )
    ).build()
  }

  /// 참조 사슬 `1 0 R → 2 0 R → ... → 1 0 R` 순환 (`maxReferenceChainLength` 검증).
  /// - Parameter length: 사슬을 구성하는 객체 수 (`/Root`는 항상 객체 1).
  /// - Returns: 각 객체의 본문이 다음 객체를 향한 순수 간접 참조뿐인, 순환하는 사슬 픽스처.
  package static func referenceCycle(length: Int) -> PDFFixture {
    precondition(length >= 1, "referenceCycle length는 1 이상이어야 한다.")
    let objects = (1...length).map { number -> (number: Int, body: String) in
      let next = number == length ? 1 : number + 1
      return (number, "\(next) 0 R")
    }
    return Self.assembleClassicFixture(objects: objects, rootNumber: 1)
  }

  /// /Count가 실제의 1,000배인 페이지 트리 (거짓 힌트 과대 할당 가드).
  /// - Returns: 실제 페이지는 1장이지만 `/Count 1000`으로 거짓 신고하는 페이지 트리 픽스처.
  package static func lyingPageCount() -> PDFFixture {
    Self.assembleClassicFixture(
      objects: [
        (1, "<< /Type /Catalog /Pages 2 0 R >>"),
        (2, "<< /Type /Pages /Kids [3 0 R] /Count 1000 >>"),
        (3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>")
      ],
      rootNumber: 1
    )
  }

  /// ObjStm 컨테이너가 자기 자신을 멤버로 주장하는 xref (type-2 자기 참조).
  ///
  /// 객체 4는 실제로는 최상위 ObjStm 컨테이너로 기록되지만, xref는 객체 4·5 둘 다
  /// "컨테이너 4 안에 압축됨"으로 선언한다 — 컨테이너 4의 바이트를 얻으려면 먼저
  /// 컨테이너 4(=자기 자신)를 풀어야 하는 모순을 만든다.
  /// - Returns: 자기 참조 ObjStm 컨테이너를 포함한 xref 스트림 픽스처.
  package static func selfReferentialObjectStream() -> PDFFixture {
    var writer = PDFByteWriter()
    var objectOffsets: [Int: Int] = [:]
    let builder = PDFFixtureBuilder()
    builder.writeHeader(into: &writer)

    Self.writeSimpleObject(
      1, "<< /Type /Catalog /Pages 2 0 R >>", into: &writer, objectOffsets: &objectOffsets
    )
    Self.writeSimpleObject(
      2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", into: &writer, objectOffsets: &objectOffsets
    )
    Self.writeSimpleObject(
      3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R >>",
      into: &writer, objectOffsets: &objectOffsets
    )
    builder.writeObjectStreamContainer(
      into: &writer, objectOffsets: &objectOffsets, objectNumber: 4, members: [(5, "42")]
    )

    let entries: [Int: FixtureXRefEntry] = [
      1: .uncompressed(offset: objectOffsets[1] ?? 0),
      2: .uncompressed(offset: objectOffsets[2] ?? 0),
      3: .uncompressed(offset: objectOffsets[3] ?? 0),
      4: .compressed(containerNumber: 4, index: 0), // 자기 참조 — 병적 거짓 신고.
      5: .compressed(containerNumber: 4, index: 0)
    ]
    let xrefOffset = builder.writeXRefStreamObject(
      into: &writer, objectOffsets: &objectOffsets,
      request: PDFFixtureBuilder.XRefStreamWriteRequest(
        objectNumber: 6, otherEntries: entries, size: 7, root: 1, prevOffset: nil,
        extraTrailerEntries: [:]
      )
    )
    PDFFixtureBuilder.writeStartxrefFooter(into: &writer, xrefOffset: xrefOffset)

    return PDFFixture(
      data: Data(writer.bytes), objectOffsets: objectOffsets, xrefOffset: xrefOffset,
      sectionOffsets: [xrefOffset]
    )
  }
}

// MARK: - 공용 조립 헬퍼

extension HostileFixtures {
  /// 최상위 비압축 객체 하나(딕셔너리 또는 순수 참조 본문)를 기록한다.
  private static func writeSimpleObject(
    _ number: Int, _ body: String, into writer: inout PDFByteWriter,
    objectOffsets: inout [Int: Int]
  ) {
    objectOffsets[number] = writer.offset
    writer.writeLine("\(number) 0 obj")
    writer.writeLine(body)
    writer.writeLine("endobj")
  }

  /// 클래식 xref 테이블 하나로 마무리되는 단순 픽스처를 조립한다 (헤더 + 주어진 객체들 +
  /// xref + 트레일러). 객체 번호는 `1...size-1`로 연속이어야 한다. hostile 픽스처들이
  /// 공유하는 최소 골격.
  /// - Parameters:
  ///   - objects: (객체 번호, 본문 원문) 목록 — 번호는 1부터 연속.
  ///   - rootNumber: 트레일러 `/Root`가 가리킬 객체 번호.
  private static func assembleClassicFixture(
    objects: [(number: Int, body: String)], rootNumber: Int
  ) -> PDFFixture {
    var writer = PDFByteWriter()
    var objectOffsets: [Int: Int] = [:]
    PDFFixtureBuilder().writeHeader(into: &writer)

    for object in objects {
      Self.writeSimpleObject(
        object.number, object.body, into: &writer, objectOffsets: &objectOffsets
      )
    }

    let size = (objects.map(\.number).max() ?? 0) + 1
    let xrefOffset = writer.offset
    writer.writeLine("xref")
    writer.writeLine("0 \(size)")
    writer.write(PDFFixtureBuilder.xrefEntry(offset: 0, generation: 65_535, type: "f"))
    writer.write(rawBytes: [0x0D, 0x0A])
    for number in 1..<size {
      writer.write(
        PDFFixtureBuilder.xrefEntry(offset: objectOffsets[number] ?? 0, generation: 0, type: "n")
      )
      writer.write(rawBytes: [0x0D, 0x0A])
    }
    writer.writeLine("trailer")
    writer.writeLine("<< /Size \(size) /Root \(rootNumber) 0 R >>")
    writer.writeLine("startxref")
    writer.writeLine("\(xrefOffset)")
    writer.write("%%EOF")

    return PDFFixture(
      data: Data(writer.bytes), objectOffsets: objectOffsets, xrefOffset: xrefOffset,
      sectionOffsets: [xrefOffset]
    )
  }
}
