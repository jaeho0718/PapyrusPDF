import Foundation
@testable import PapyrusCore
import PapyrusTestSupport
import Testing

// M2 xref/Document 테스트 공용 헬퍼. 파일 분리는 순수 조직적 이유(§5)다.

/// 수제 클래식 xref 행 20바이트(CRLF 종결)를 만든다.
func classicRow(offset: Int, generation: Int, type: Character) -> String {
  let offsetText = String(format: "%010d", offset)
  let generationText = String(format: "%05d", generation)
  return "\(offsetText) \(generationText) \(type)\r\n"
}

/// `warnings`에 지정된 케이스가 존재하는지 (연관값 무시) 검사한다.
func containsWarning(
  _ warnings: [OpenWarning], matching predicate: (OpenWarning) -> Bool
) -> Bool {
  warnings.contains(where: predicate)
}

/// 값을 `width`바이트 빅엔디언으로 인코딩한다.
func bigEndian(_ value: Int, width: Int) -> [UInt8] {
  var bytes: [UInt8] = []
  bytes.reserveCapacity(width)
  for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
    bytes.append(UInt8((value >> shift) & 0xFF))
  }
  return bytes
}

/// 수제 xref 스트림 객체(비압축, `/Filter` 없음) 바이트를 만든다. `/W`·`/Index`는 그대로
/// 기록하고 필터 없이 원문 그대로의 행 데이터를 페이로드로 쓴다(호출부가 인코딩 여부를 결정).
struct XRefStreamSnippetRow {
  let type: Int
  let field2: Int
  let field3: Int
}

// 이 헬퍼는 xref 스트림의 독립적인 시험 축(필드 폭·인덱스·크기·행 데이터·필터 옵션)을
// 그대로 노출해야 하는 테스트 전용 조립기라 매개변수 수 축소가 가독성을 해친다.
// swiftlint:disable function_parameter_count
/// 수제 xref 스트림 객체를 조립한다.
/// - Parameters:
///   - objectNumber: 객체 번호.
///   - widths: `/W` 값.
///   - index: `/Index` 값 (nil이면 생략, 파서가 `[0 size]` 기본 적용).
///   - size: `/Size` 값.
///   - rows: 인코딩 전 원시 행 데이터.
///   - extraDictText: 추가로 삽입할 딕셔너리 엔트리 원문 (예: `"/Type /XRef"`).
///   - applyFlate: true면 Flate로 인코딩하고 `/Filter /FlateDecode`를 추가한다.
///   - corruptPayload: true면 Flate 인코딩된 바이트를 훼손한다 (디코드 실패 유도).
func makeXRefStreamObjectBytes(
  objectNumber: Int, widths: [Int], index: [Int]?, size: Int, rows: [XRefStreamSnippetRow],
  extraDictText: String, applyFlate: Bool, corruptPayload: Bool = false
) -> Data {
  var raw: [UInt8] = []
  for row in rows {
    if widths[0] > 0 {
      raw.append(contentsOf: bigEndian(row.type, width: widths[0]))
    }
    raw.append(contentsOf: bigEndian(row.field2, width: widths[1]))
    raw.append(contentsOf: bigEndian(row.field3, width: widths[2]))
  }
  var payload = Data(raw)
  var filterText = ""
  if applyFlate {
    payload = PDFFilterEncoders.flate(payload)
    filterText = " /Filter /FlateDecode"
  }
  if corruptPayload {
    payload = Data([0xFF, 0xFE, 0xFD, 0xFC] + payload.suffix(max(0, payload.count - 4)))
  }

  let indexText = index.map { "/Index [\($0.map(String.init).joined(separator: " "))] " } ?? ""
  let widthsText = widths.map(String.init).joined(separator: " ")
  var text = "\(objectNumber) 0 obj\n<< \(extraDictText) /W [\(widthsText)] \(indexText)"
  text += "/Size \(size)\(filterText) /Length \(payload.count) >>\nstream\n"
  var bytes = Array(text.utf8)
  bytes.append(contentsOf: payload)
  bytes.append(contentsOf: Array("\nendstream\nendobj".utf8))
  return Data(bytes)
}

// swiftlint:enable function_parameter_count
