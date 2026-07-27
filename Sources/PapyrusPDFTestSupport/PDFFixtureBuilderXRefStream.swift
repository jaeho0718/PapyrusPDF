import Foundation

// `PDFFixtureBuilder`의 xref 스트림/ObjStm/하이브리드 기록 로직. 파일 분리는 순수 조직적
// 이유(§6)이며, 타입·의미는 `PDFFixtureBuilder.swift`와 동일하다.

/// 픽스처 빌드 중간에 쓰는 엔트리 서술 (실제 `XRefEntry`가 아니라 빌더 전용 얕은 타입).
enum FixtureXRefEntry: Sendable, Equatable {
  /// free 엔트리 (증분 삭제 표현).
  case free
  /// 최상위 비압축 객체.
  case uncompressed(offset: Int)
  /// ObjStm 컨테이너 안에 압축된 객체.
  case compressed(containerNumber: Int, index: Int)
}

/// 객체 번호 배치 계획 (설계 §3.7 규약: Catalog=1, Pages=2, 페이지=3...N+2, 콘텐츠
/// 스트림=N+3, /Length 정수=N+4).
struct FixtureObjectPlan: Sendable {
  /// 카탈로그 객체 번호 (항상 1).
  let catalogNumber = 1
  /// 페이지 트리 객체 번호 (항상 2).
  let pagesNumber = 2
  /// 페이지 객체 번호 목록 (3...pageCount+2).
  let pageNumbers: [Int]
  /// 공유 콘텐츠 스트림 객체 번호 (콘텐츠 스트림이 없으면 `nil`).
  let contentsObjectNumber: Int?
  /// `/Length` 간접 정수 객체 번호 (직접 기록이면 `nil`).
  let lengthObjectNumber: Int?
  /// "기존 v0 스타일"(Catalog/Pages/Page/콘텐츠/렝스) 범위의 최고 객체 번호.
  let highestBaseNumber: Int
  /// `/Size` 값 (최고 번호 + 1) — 컨테이너/xref 스트림 객체를 얹기 전 기준.
  var size: Int {
    self.highestBaseNumber + 1
  }
}

extension PDFFixtureBuilder {
  /// 페이지 수·콘텐츠 스트림 설정으로부터 객체 번호 배치 계획을 만든다.
  func makeObjectNumberPlan() -> FixtureObjectPlan {
    let contentsObjectNumber = self.contentStream != nil ? self.pageCount + 3 : nil
    let needsLengthObject = self.contentStream?.lengthStyle == .indirect
    let lengthObjectNumber = needsLengthObject ? self.pageCount + 4 : nil
    var highest = self.pageCount + 2
    if contentsObjectNumber != nil {
      highest += 1
    }
    if lengthObjectNumber != nil {
      highest += 1
    }
    return FixtureObjectPlan(
      pageNumbers: Array(3..<(3 + self.pageCount)),
      contentsObjectNumber: contentsObjectNumber,
      lengthObjectNumber: lengthObjectNumber,
      highestBaseNumber: highest
    )
  }

  /// Catalog 딕셔너리 값 텍스트 (래퍼 없이).
  func catalogValueText() -> String {
    "<< /Type /Catalog /Pages 2 0 R >>"
  }

  /// Pages 딕셔너리 값 텍스트 (래퍼 없이).
  func pagesValueText(pageNumbers: [Int]) -> String {
    let kids = pageNumbers.map { "\($0) 0 R" }.joined(separator: " ")
    return "<< /Type /Pages /Kids [\(kids)] /Count \(self.pageCount) >>"
  }

  /// Page 딕셔너리 값 텍스트 (래퍼 없이). `width`/`height`를 지정하면 빌더 기본값 대신
  /// 그 값을 MediaBox에 반영한다 (증분 업데이트의 페이지 재기록용).
  func pageValueText(
    contentsObjectNumber: Int?, width: Double? = nil, height: Double? = nil
  ) -> String {
    let widthText = Self.formatCoordinate(width ?? self.pageWidth)
    let heightText = Self.formatCoordinate(height ?? self.pageHeight)
    let contentsEntry = contentsObjectNumber.map { " /Contents \($0) 0 R" } ?? ""
    return "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(widthText) \(heightText)]"
      + "\(contentsEntry) >>"
  }
}

// MARK: - ObjStm 컨테이너

extension PDFFixtureBuilder {
  /// 헤더(번호-오프셋 쌍) + 값 바이트를 조립해 Flate 인코딩한다.
  /// - Returns: 인코딩된 페이로드와 `/First` 값.
  static func encodeObjectStream(
    members: [(number: Int, valueText: String)]
  ) -> (encoded: Data, first: Int) {
    var headerParts: [String] = []
    var bodyBytes: [UInt8] = []
    var runningOffset = 0
    for member in members {
      headerParts.append("\(member.number) \(runningOffset)")
      let valueBytes = Array(member.valueText.utf8)
      bodyBytes.append(contentsOf: valueBytes)
      bodyBytes.append(UInt8(ascii: " "))
      runningOffset += valueBytes.count + 1
    }
    let headerText = headerParts.joined(separator: " ")
    let first = headerText.utf8.count + 1
    var payload = Array(headerText.utf8)
    payload.append(UInt8(ascii: " "))
    payload.append(contentsOf: bodyBytes)
    return (PDFFilterEncoders.flate(Data(payload)), first)
  }

  /// ObjStm 컨테이너 객체를 기록한다.
  /// - Returns: 컨테이너 객체의 시작 오프셋.
  @discardableResult
  func writeObjectStreamContainer(
    into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int],
    objectNumber: Int, members: [(number: Int, valueText: String)]
  ) -> Int {
    let (compressed, first) = Self.encodeObjectStream(members: members)
    let offset = writer.offset
    objectOffsets[objectNumber] = offset
    writer.writeLine("\(objectNumber) 0 obj")
    writer.writeLine(
      "<< /Type /ObjStm /N \(members.count) /First \(first) /Filter /FlateDecode "
        + "/Length \(compressed.count) >>"
    )
    writer.write("stream")
    writer.write(rawBytes: [0x0A])
    writer.write(rawBytes: [UInt8](compressed))
    writer.write(rawBytes: [0x0A])
    writer.writeLine("endstream")
    writer.writeLine("endobj")
    return offset
  }
}

// MARK: - xref 스트림 객체

extension PDFFixtureBuilder {
  /// `value`를 `width`바이트 빅엔디언으로 인코딩한다.
  private static func bigEndianBytes(_ value: Int, width: Int) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width)
    for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
      bytes.append(UInt8((value >> shift) & 0xFF))
    }
    return bytes
  }

  /// 연속된 번호들을 `(start, count)` 구간 목록으로 묶는다 (`/Index` 구성용).
  private static func computeIndexPairs(numbers: Set<Int>) -> [(start: Int, count: Int)] {
    let sorted = numbers.sorted()
    var pairs: [(start: Int, count: Int)] = []
    var index = 0
    while index < sorted.count {
      let start = sorted[index]
      var end = start
      while index + 1 < sorted.count, sorted[index + 1] == end + 1 {
        index += 1
        end = sorted[index]
      }
      pairs.append((start: start, count: end - start + 1))
      index += 1
    }
    return pairs
  }

  /// `/W [1 4 2]` 고정 행 폭으로 `indexPairs`가 선언하는 번호들의 xref 스트림 원시 행
  /// 데이터를 (구간 순서대로) 인코딩한다. 구간 안에서 `entries`에 없는 번호는 free(type 0)다.
  static func encodeXRefStreamRows(
    entries: [Int: FixtureXRefEntry], indexPairs: [(start: Int, count: Int)]
  ) -> Data {
    var raw: [UInt8] = []
    for pair in indexPairs {
      for number in pair.start..<(pair.start + pair.count) {
        switch entries[number] ?? .free {
        case let .uncompressed(offset):
          raw.append(1)
          raw.append(contentsOf: Self.bigEndianBytes(offset, width: 4))
          raw.append(contentsOf: Self.bigEndianBytes(0, width: 2))
        case let .compressed(containerNumber, index):
          raw.append(2)
          raw.append(contentsOf: Self.bigEndianBytes(containerNumber, width: 4))
          raw.append(contentsOf: Self.bigEndianBytes(index, width: 2))
        case .free:
          raw.append(0)
          raw.append(contentsOf: Self.bigEndianBytes(0, width: 4))
          raw.append(contentsOf: Self.bigEndianBytes(number == 0 ? 65_535 : 0, width: 2))
        }
      }
    }
    return Data(raw)
  }

  /// xref 스트림 객체 기록에 필요한 정보 묶음 (매개변수 수 관리용).
  struct XRefStreamWriteRequest {
    /// 이 xref 스트림 객체의 번호.
    let objectNumber: Int
    /// 자신을 제외한 엔트리들 (자기 오프셋은 기록 시점에 자동으로 채워진다).
    let otherEntries: [Int: FixtureXRefEntry]
    /// `/Size` 값.
    let size: Int
    /// `/Root` 대상 객체 번호.
    let root: Int
    /// `/Prev` 값 (없으면 `nil`).
    let prevOffset: Int?
    /// 트레일러에 추가할 원시 엔트리.
    let extraTrailerEntries: [String: String]
    /// 객체 0을 이 섹션의 선언 범위에 강제 포함할지 여부 (기본 `true` — 신규 문서 본체
    /// 전용. 증분 업데이트 섹션은 `false`로 생략한다).
    let includeFreeHead: Bool

    /// 요청을 생성한다.
    init(
      objectNumber: Int, otherEntries: [Int: FixtureXRefEntry], size: Int, root: Int,
      prevOffset: Int?, extraTrailerEntries: [String: String], includeFreeHead: Bool = true
    ) {
      self.objectNumber = objectNumber
      self.otherEntries = otherEntries
      self.size = size
      self.root = root
      self.prevOffset = prevOffset
      self.extraTrailerEntries = extraTrailerEntries
      self.includeFreeHead = includeFreeHead
    }
  }

  /// xref 스트림 객체를 기록한다 (Flate + PNG Up predictor(12), `/W [1 4 2]`).
  ///
  /// `request.otherEntries`에는 이 객체 자신의 엔트리를 포함하지 않는다 — 자기 오프셋은 이
  /// 함수가 알아내 자동으로 채운다. `/Index`는 `otherEntries`(+자신, +`includeFreeHead`이면
  /// 객체 0)가 선언하는 번호들만으로 구성된다 — 증분 업데이트가 무관한 번호를 실수로
  /// free 처리하는 것을 막는다.
  /// - Returns: 기록된 xref 스트림 객체의 시작 오프셋.
  @discardableResult
  func writeXRefStreamObject(
    into writer: inout PDFByteWriter, objectOffsets: inout [Int: Int],
    request: XRefStreamWriteRequest
  ) -> Int {
    let offset = writer.offset
    var entries = request.otherEntries
    entries[request.objectNumber] = .uncompressed(offset: offset)
    objectOffsets[request.objectNumber] = offset

    var declaredNumbers = Set(entries.keys)
    if request.includeFreeHead {
      declaredNumbers.insert(0)
    }
    let indexPairs = Self.computeIndexPairs(numbers: declaredNumbers)

    let rawRows = Self.encodeXRefStreamRows(entries: entries, indexPairs: indexPairs)
    let predicted = PDFFilterEncoders.pngPredictor(
      rawRows, filterType: 2, colors: 1, bitsPerComponent: 8, columns: 7
    )
    let encoded = PDFFilterEncoders.flate(predicted)

    let indexText = indexPairs.flatMap { [$0.start, $0.count] }
      .map(String.init).joined(separator: " ")
    writer.writeLine("\(request.objectNumber) 0 obj")
    var parts = [
      "/Type /XRef", "/Size \(request.size)", "/W [1 4 2]", "/Index [\(indexText)]",
      "/Root \(request.root) 0 R"
    ]
    if let prevOffset = request.prevOffset {
      parts.append("/Prev \(prevOffset)")
    }
    for key in request.extraTrailerEntries.keys.sorted() {
      parts.append("/\(key) \(request.extraTrailerEntries[key] ?? "")")
    }
    parts.append("/Filter /FlateDecode")
    parts.append("/DecodeParms << /Predictor 12 /Columns 7 /Colors 1 >>")
    parts.append("/Length \(encoded.count)")
    writer.writeLine("<< \(parts.joined(separator: " ")) >>")
    writer.write("stream")
    writer.write(rawBytes: [0x0A])
    writer.write(rawBytes: [UInt8](encoded))
    writer.write(rawBytes: [0x0A])
    writer.writeLine("endstream")
    writer.writeLine("endobj")
    return offset
  }
}
