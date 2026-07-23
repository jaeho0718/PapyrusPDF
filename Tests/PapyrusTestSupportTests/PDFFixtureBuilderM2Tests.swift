import Compression
import Foundation
import PapyrusTestSupport
import Testing

/// M2 회귀·신규 스타일 검증 (§5.8). `PDFFixtureBuilderTests`와 분리한 이유는 순수
/// 조직적(파일 길이 제한)이며, 같은 설계 절을 다룬다.
struct PDFFixtureBuilderM2Tests {
  /// F13: `updates`/`extraTrailerEntries` 기본값만 쓰면 명시적으로 전달한 것과 바이트가
  /// 완전히 동일하다 (M1 강화판 승계 회귀).
  @Test func m2DefaultsMatchExplicitEmptyValues() {
    let withDefaults = PDFFixtureBuilder(pageCount: 4).build()
    let withExplicit = PDFFixtureBuilder(
      pageCount: 4, updates: [], extraTrailerEntries: [:]
    ).build()
    #expect(withDefaults.data == withExplicit.data)
  }

  /// F13: `.xrefStream` 산출물을 테스트 코드가 직접(수동) `/W`·`/Index`·predictor 12로
  /// 디코딩해 엔트리가 `objectOffsets`와 일치함을 자가 검증한다.
  @Test func xrefStreamOutputSelfValidatesAgainstObjectOffsets() throws {
    let fixture = PDFFixtureBuilder(pageCount: 3, xrefStyle: .xrefStream).build()
    let bytes = [UInt8](fixture.data)

    // xref 스트림 객체의 stream 페이로드 구간을 텍스트 검색으로 찾는다.
    guard
      let streamKeywordIndex = offset(of: "stream\n", in: fixture.data, from: fixture.xrefOffset)
    else {
      Issue.record("stream 키워드를 찾지 못함")
      return
    }
    let payloadStart = streamKeywordIndex + "stream\n".utf8.count
    guard let endstreamIndex = offset(of: "\nendstream", in: fixture.data, from: payloadStart)
    else {
      Issue.record("endstream을 찾지 못함")
      return
    }
    let encoded = Data(bytes[payloadStart..<endstreamIndex])

    // Flate 압축 해제 + PNG Up predictor(12) 역적용은 대조 독립성을 위해 Compression
    // 프레임워크 기반 별도 헬퍼로 직접 구현한다(디코더 재사용 없음).
    let inflated = try inflateZlib(encoded)
    let unfiltered = unfilterPNGUp(inflated, rowBytes: 7)

    var decodedOffsets: [Int: Int] = [:]
    let rowCount = unfiltered.count / 7
    for row in 0..<rowCount {
      let base = row * 7
      let type = unfiltered[base]
      guard type == 1 else { continue }
      let offsetValue = (Int(unfiltered[base + 1]) << 24) | (Int(unfiltered[base + 2]) << 16)
        | (Int(unfiltered[base + 3]) << 8) | Int(unfiltered[base + 4])
      decodedOffsets[row] = offsetValue
    }

    for (number, expectedOffset) in fixture.objectOffsets {
      #expect(decodedOffsets[number] == expectedOffset)
    }
  }

  /// F13: `.hybrid` 산출물은 서브섹션 갭 구조(압축 객체 누락)와 `/XRefStm` 키를 갖는다.
  @Test func hybridOutputHasSubsectionGapsAndXRefStm() {
    let fixture = PDFFixtureBuilder(pageCount: 2, xrefStyle: .hybrid).build()
    #expect(offset(of: "/XRefStm ", in: fixture.data) != nil)
    // Catalog(1)는 압축 수납 대상이므로 클래식 테이블에 "1 0 obj" 최상위 정의가 없다
    // (본문에도 없고, 서브섹션에도 없다 — obj 1은 컨테이너 안에서만 존재).
    #expect(offset(of: "1 0 obj\n<< /Type /Catalog", in: fixture.data) == nil)
  }

  /// F13: 증분 업데이트 산출물의 `sectionOffsets`가 실제 파일 내 xref 시작 위치와
  /// 정합하고, `/Prev` 체인 값이 이전 섹션 오프셋과 일치한다.
  @Test func incrementalUpdateSectionOffsetsAndPrevChainAreConsistent() throws {
    let fixture = PDFFixtureBuilder(
      pageCount: 1,
      updates: [
        .init(rewrittenPages: [0: (width: 10, height: 20)]),
        .init(rewrittenPages: [0: (width: 30, height: 40)])
      ]
    ).build()
    #expect(fixture.sectionOffsets.count == 3)
    #expect(fixture.sectionOffsets.last == fixture.xrefOffset)

    for sectionOffset in fixture.sectionOffsets {
      let expectedPrefix = Array("xref".utf8)
      let actual = fixture.data[sectionOffset..<(sectionOffset + expectedPrefix.count)]
      #expect(Array(actual) == expectedPrefix)
    }

    // 두 번째·세 번째 섹션의 /Prev가 각각 직전 섹션 오프셋과 일치하는지 확인한다.
    for index in 1..<fixture.sectionOffsets.count {
      let sectionOffset = fixture.sectionOffsets[index]
      let expectedPrev = fixture.sectionOffsets[index - 1]
      guard
        let prevKeywordOffset = offset(
          of: "/Prev \(expectedPrev)", in: fixture.data, from: sectionOffset
        )
      else {
        Issue.record("섹션 \(index)에서 /Prev \(expectedPrev)를 찾지 못함")
        continue
      }
      #expect(prevKeywordOffset > sectionOffset)
    }
  }

  /// F13: `PDFFixtureCorruptor`의 각 모드는 결정적이다 (2회 적용 == 동일 바이트).
  @Test func corruptorModesAreDeterministic() {
    let fixture = PDFFixtureBuilder(pageCount: 3).build()
    let modes: [PDFFixtureCorruptor.Mode] = [
      .bogusStartxref, .removeStartxref, .truncateTail(byteCount: 20),
      .junkPrefix(byteCount: 64), .removeEOFMarker,
      .brokenEntryOffset(objectNumber: 1, delta: 5),
      .malformedRowWidth(.nineteen), .malformedRowWidth(.twentyOne), .cyclicPrevChain
    ]
    for mode in modes {
      let first = PDFFixtureCorruptor.apply([mode], to: fixture)
      let second = PDFFixtureCorruptor.apply([mode], to: fixture)
      #expect(first.data == second.data)
    }
  }
}

// MARK: - 대조 독립적 디코딩 헬퍼

/// F13 전용: zlib(RFC 1950) 래퍼를 벗기고 raw deflate를 압축 해제한다. `PapyrusCore`의
/// 디코더와 코드를 공유하지 않는 대조 독립적 구현 — Compression 프레임워크 직접 사용.
func inflateZlib(_ data: Data) throws -> Data {
  guard data.count > 6 else {
    return Data()
  }
  let raw = data.subdata(in: 2..<(data.count - 4))
  let capacity = max(4_096, raw.count * 20)
  var destination = [UInt8](repeating: 0, count: capacity)
  let rawBytes = [UInt8](raw)
  let decodedCount = rawBytes.withUnsafeBufferPointer { sourcePointer -> Int in
    destination.withUnsafeMutableBufferPointer { destinationPointer -> Int in
      guard let sourceBase = sourcePointer.baseAddress,
        let destinationBase = destinationPointer.baseAddress
      else {
        return 0
      }
      return compression_decode_buffer(
        destinationBase, capacity, sourceBase, rawBytes.count, nil, COMPRESSION_ZLIB
      )
    }
  }
  return Data(destination.prefix(decodedCount))
}

/// F13 전용: PNG "Up" predictor(태그 2)만 역적용한다(빌더가 항상 태그 2로만 인코딩하므로
/// 충분하다). 행 = 태그 1바이트 + `rowBytes`.
func unfilterPNGUp(_ data: Data, rowBytes: Int) -> [UInt8] {
  let bytes = [UInt8](data)
  let stride = rowBytes + 1
  let rowCount = bytes.count / stride
  var output: [UInt8] = []
  output.reserveCapacity(rowCount * rowBytes)
  var previousRow = [UInt8](repeating: 0, count: rowBytes)
  for row in 0..<rowCount {
    let rowStart = row * stride
    let tag = bytes[rowStart]
    var current = [UInt8](repeating: 0, count: rowBytes)
    for column in 0..<rowBytes {
      let raw = bytes[rowStart + 1 + column]
      current[column] = tag == 2 ? raw &+ previousRow[column] : raw
    }
    output.append(contentsOf: current)
    previousRow = current
  }
  return output
}
