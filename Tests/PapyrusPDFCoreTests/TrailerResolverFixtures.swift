import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

// `TrailerResolverTests`의 수제 픽스처 빌더. 파일 분리는 순수 조직적 이유(파일 길이 제한)다.

extension TrailerResolverTests {
  /// TR7 전용: 섹션 A(전체 정의) → 섹션 B(페이지 재기록, `/Prev`=A) → A의 `/Prev`를
  /// 사후 패치해 B를 가리키게 함으로써 A↔B 상호 순환을 만든다. 고정폭(10자리) 플레이스홀더를
  /// 써서 사후 패치가 바이트 길이를 바꾸지 않게 한다(오프셋 재계산 불필요).
  static func makeMutualCycleFixture() -> Data {
    var bytes: [UInt8] = []
    func writeLine(_ text: String) {
      bytes.append(contentsOf: Array(text.utf8))
      bytes.append(0x0A)
    }

    bytes.append(contentsOf: Array("%PDF-1.4\n".utf8))
    let o1 = bytes.count
    writeLine("1 0 obj")
    writeLine("<< /Type /Catalog /Pages 2 0 R >>")
    writeLine("endobj")
    let o2 = bytes.count
    writeLine("2 0 obj")
    writeLine("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    writeLine("endobj")
    let o3 = bytes.count
    writeLine("3 0 obj")
    writeLine("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>")
    writeLine("endobj")

    let sectionAOffset = bytes.count
    writeLine("xref")
    writeLine("0 4")
    writeLine("0000000000 65535 f")
    writeLine(String(format: "%010d 00000 n", o1))
    writeLine(String(format: "%010d 00000 n", o2))
    writeLine(String(format: "%010d 00000 n", o3))
    writeLine("trailer")
    let prevPlaceholderPrefix = "<< /Size 4 /Root 1 0 R /Prev "
    bytes.append(contentsOf: Array(prevPlaceholderPrefix.utf8))
    let prevDigitsStart = bytes.count
    bytes.append(contentsOf: Array("0000000000".utf8))
    bytes.append(contentsOf: Array(" >>\n".utf8))
    writeLine("startxref")
    writeLine("\(sectionAOffset)")
    bytes.append(contentsOf: Array("%%EOF\n".utf8))

    let o3Rewritten = bytes.count
    writeLine("3 0 obj")
    writeLine("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 50 60] >>")
    writeLine("endobj")

    let sectionBOffset = bytes.count
    writeLine("xref")
    writeLine("3 1")
    writeLine(String(format: "%010d 00000 n", o3Rewritten))
    writeLine("trailer")
    writeLine("<< /Size 4 /Root 1 0 R /Prev \(sectionAOffset) >>")
    writeLine("startxref")
    writeLine("\(sectionBOffset)")
    bytes.append(contentsOf: Array("%%EOF".utf8))

    let prevText = String(format: "%010d", sectionBOffset)
    bytes.replaceSubrange(prevDigitsStart..<(prevDigitsStart + 10), with: Array(prevText.utf8))

    return Data(bytes)
  }

  /// TR5 병적 변형: 컨테이너(10) 안에 Catalog를 압축 수납하고, xref 스트림(11)은 이를
  /// 정확히 선언하지만, 병기된 클래식 테이블은 같은 번호(1)를 명시적으로 free로 선언한다.
  static func makeConflictingHybridFixture() -> Data {
    var writer: [UInt8] = Array("%PDF-1.7\n".utf8)
    let (containerOffset, pagesOffset) = Self.writeConflictingHybridBody(writer: &writer)
    Self.writeConflictingHybridXRefSections(
      writer: &writer, containerOffset: containerOffset, pagesOffset: pagesOffset
    )
    return Data(writer)
  }

  /// ObjStm 컨테이너(10, Catalog 멤버)와 Pages(2)를 기록한다.
  /// - Returns: (컨테이너 오프셋, Pages 오프셋).
  private static func writeConflictingHybridBody(writer: inout [UInt8]) -> (Int, Int) {
    func writeLine(_ text: String) {
      writer.append(contentsOf: Array(text.utf8))
      writer.append(0x0A)
    }

    let containerPayload = "1 0 << /Type /Catalog /Pages 2 0 R >>"
    let containerOffset = writer.count
    writeLine("10 0 obj")
    writeLine("<< /Type /ObjStm /N 1 /First 4 /Length \(containerPayload.utf8.count) >>")
    writeLine("stream")
    writer.append(contentsOf: Array(containerPayload.utf8))
    writer.append(0x0A)
    writeLine("endstream")
    writeLine("endobj")

    let pagesOffset = writer.count
    writeLine("2 0 obj")
    writeLine("<< /Type /Pages /Kids [] /Count 0 >>")
    writeLine("endobj")
    return (containerOffset, pagesOffset)
  }

  /// xref 스트림(11, Catalog를 compressed로 정확히 선언) + 클래식 갭 테이블(Catalog를
  /// 병적으로 free 재선언) + `/XRefStm` 트레일러를 기록한다.
  private static func writeConflictingHybridXRefSections(
    writer: inout [UInt8], containerOffset: Int, pagesOffset: Int
  ) {
    func writeLine(_ text: String) {
      writer.append(contentsOf: Array(text.utf8))
      writer.append(0x0A)
    }

    let xrefStreamNumber = 11
    let size = xrefStreamNumber + 1
    var entries: [Int: XRefStreamSnippetRow] = [
      0: XRefStreamSnippetRow(type: 0, field2: 0, field3: 0),
      1: XRefStreamSnippetRow(type: 2, field2: 10, field3: 0),
      2: XRefStreamSnippetRow(type: 1, field2: pagesOffset, field3: 0),
      10: XRefStreamSnippetRow(type: 1, field2: containerOffset, field3: 0)
    ]
    let xrefStreamOffset = writer.count
    entries[xrefStreamNumber] = XRefStreamSnippetRow(type: 1, field2: xrefStreamOffset, field3: 0)

    var rows: [UInt8] = []
    for number in 0..<size {
      let row = entries[number] ?? XRefStreamSnippetRow(type: 0, field2: 0, field3: 0)
      rows.append(UInt8(row.type))
      rows.append(contentsOf: bigEndian(row.field2, width: 4))
      rows.append(contentsOf: bigEndian(row.field3, width: 2))
    }
    let rowData = Data(rows)
    writeLine("\(xrefStreamNumber) 0 obj")
    writeLine(
      "<< /Type /XRef /W [1 4 2] /Size \(size) /Root 1 0 R /Length \(rowData.count) >>"
    )
    writeLine("stream")
    writer.append(contentsOf: rowData)
    writer.append(0x0A)
    writeLine("endstream")
    writeLine("endobj")

    // 클래식 테이블: 0(free 헤드), 1(병적으로 free 재선언), 2, 10, 11 — XRefStm 병기.
    let classicOffset = writer.count
    writeLine("xref")
    writeLine("0 3")
    writer.append(contentsOf: Array("0000000000 65535 f\r\n".utf8))
    writer.append(contentsOf: Array("0000000000 00000 f\r\n".utf8))
    let pagesRow = String(format: "%010d 00000 n\r\n", pagesOffset)
    writer.append(contentsOf: Array(pagesRow.utf8))
    writeLine("10 2")
    let containerRow = String(format: "%010d 00000 n\r\n", containerOffset)
    writer.append(contentsOf: Array(containerRow.utf8))
    let xrefStreamRow = String(format: "%010d 00000 n\r\n", xrefStreamOffset)
    writer.append(contentsOf: Array(xrefStreamRow.utf8))
    writeLine("trailer")
    writeLine("<< /Size \(size) /Root 1 0 R /XRefStm \(xrefStreamOffset) >>")
    writeLine("startxref")
    writeLine("\(classicOffset)")
    writer.append(contentsOf: Array("%%EOF".utf8))
  }
}
