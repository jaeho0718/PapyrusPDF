import CoreGraphics

/// 해석된 문자 코드 하나 (원시 값 + 원본 바이트 수 — Tw 적용 판단에 필요).
package struct CharacterCode: Sendable, Equatable {
  /// 원시 코드 값 (단순 폰트는 바이트값, Type0은 code 자체 — CID 아님).
  package let value: UInt32

  /// 이 코드를 구성한 원본 바이트 수.
  package let byteLength: Int

  /// 문자 코드를 생성한다.
  /// - Parameters:
  ///   - value: 원시 코드 값.
  ///   - byteLength: 원본 바이트 수.
  package init(value: UInt32, byteLength: Int) {
    self.value = value
    self.byteLength = byteLength
  }
}

/// `/W` 배열 해석 결과 — 겹치지 않게 정규화·정렬된 구간 테이블.
package struct CIDWidthTable: Sendable {
  /// 구간 하나 — 균일 폭 또는 개별 폭 배열 중 하나만 채워진다.
  fileprivate struct Entry: Sendable {
    let lo: UInt32
    let hi: UInt32
    let uniformWidth: CGFloat?
    let widths: [CGFloat]?
  }

  /// `lo` 오름차순 정렬된 구간 목록.
  private let entries: [Entry]

  private init(entries: [Entry]) {
    self.entries = entries.sorted { $0.lo < $1.lo }
  }

  /// CID에 대응하는 1000단위 폭을 이진 탐색으로 조회한다.
  /// - Parameter cid: 조회할 CID.
  /// - Returns: 매핑된 폭, 구간에 속하지 않으면 `nil`.
  package func width(forCID cid: UInt32) -> CGFloat? {
    var low = 0
    var high = self.entries.count - 1
    while low <= high {
      let mid = (low + high) / 2
      let entry = self.entries[mid]
      if cid < entry.lo {
        high = mid - 1
      } else if cid > entry.hi {
        low = mid + 1
      } else if let uniform = entry.uniformWidth {
        return uniform
      } else {
        return entry.widths?[Int(cid - entry.lo)]
      }
    }
    return nil
  }

  /// 정규화(겹침 제거) 단계의 O(n²) 비용을 방어하는 원시 구간 개수 상한. 정상적인 `/W`
  /// 배열은 이 규모에 크게 못 미친다(수천 CID도 보통 배열형 소수 구간으로 표현된다) —
  /// 상한 도달 이후의 구간은 조용히 무시한다(관용, 병적 `/W`의 폭주 가드).
  private static let maxRawEntryCountForNormalization = 4_096

  /// `/W` 배열(해소 완료)을 해석한다. `[c [w1 w2 …]]`(개별 구간)와 `[c1 c2 w]`(균일
  /// 구간)를 함께 지원하며, 형식이 어긋난 원소는 스킵한다.
  ///
  /// 겹치는 구간은 배열에 **나중에 등장한 구간이 우선**하도록 정규화한다(COSDictionary의
  /// "중복 키는 마지막 값이 승리" 관례와 동일선상의 결정 규칙) — 그래야 `width(forCID:)`의
  /// 이진 탐색이 어떤 겹침 입력에도 결정적으로 동작한다.
  /// - Parameter elements: 해소된 `/W` 배열 원소.
  /// - Returns: 겹치지 않도록 정규화되고 정렬된 구간 테이블.
  package static func build(from elements: [COSObject]) -> CIDWidthTable {
    let rawEntries = Self.parseRawEntries(from: elements)
    return CIDWidthTable(entries: Self.normalizingOverlaps(rawEntries))
  }

  /// `/W` 배열을 원본 등장 순서 그대로(겹침 미정규화) 구간 목록으로 파싱한다.
  ///
  /// CID 값은 COS 정수(`Int`, 64비트)로 파싱되지만 `Entry.lo`/`hi`는 `UInt32`다 — 음수는
  /// 물론, `UInt32` 표현 범위(0...4294967295)를 벗어나는 값(예: `5_000_000_000`)도 손상·
  /// 적대적 입력으로 간주해 `UInt32(exactly:)`로 검증하고, 실패하면 해당 원소는 건너뛴다
  /// (강제 변환 트랩 금지 — 무크래시 불변식).
  private static func parseRawEntries(from elements: [COSObject]) -> [Entry] {
    var entries: [Entry] = []
    var registered = 0
    var index = 0
    while index < elements.count, registered < CoreLimits.maxCMapEntries,
      entries.count < Self.maxRawEntryCountForNormalization {
      guard let firstValue = elements[index].integerValue, let first = UInt32(exactly: firstValue)
      else {
        index += 1
        continue
      }
      guard index + 1 < elements.count else {
        break
      }
      if case let .array(widthObjects) = elements[index + 1] {
        let widths = widthObjects.compactMap { $0.realValue.map { CGFloat($0) } }
        let (hi, overflowed) = first.addingReportingOverflow(UInt32(clamping: widths.count - 1))
        if !widths.isEmpty, !overflowed {
          entries.append(Entry(lo: first, hi: hi, uniformWidth: nil, widths: widths))
          registered += widths.count
        }
        index += 2
      } else if index + 2 < elements.count, let secondValue = elements[index + 1].integerValue,
        let second = UInt32(exactly: secondValue), second >= first,
        let width = elements[index + 2].realValue {
        entries.append(Entry(lo: first, hi: second, uniformWidth: CGFloat(width), widths: nil))
        registered += 1
        index += 3
      } else {
        index += 1
      }
    }
    return entries
  }

  /// 등장 순서대로 각 신규 구간을 누적하며, 기존에 수락된 구간 중 신규 구간과 겹치는
  /// 부분은 잘라낸다(나중 구간 우선). 결과는 서로 겹치지 않는 구간 집합.
  private static func normalizingOverlaps(_ rawEntries: [Entry]) -> [Entry] {
    var accepted: [Entry] = []
    for newEntry in rawEntries {
      guard newEntry.lo <= newEntry.hi else {
        continue
      }
      var clipped: [Entry] = []
      clipped.reserveCapacity(accepted.count)
      for existing in accepted {
        clipped.append(contentsOf: Self.subtract(existing, removing: newEntry.lo...newEntry.hi))
      }
      clipped.append(newEntry)
      accepted = clipped
    }
    return accepted
  }

  /// `entry`에서 `range`와 겹치는 부분을 제거한다. 겹치지 않으면 `[entry]`, 완전히
  /// 덮이면 `[]`, 부분 겹침이면 겹치지 않는 좌/우 조각(최대 2개)을 반환한다.
  private static func subtract(_ entry: Entry, removing range: ClosedRange<UInt32>) -> [Entry] {
    guard entry.lo <= range.upperBound, entry.hi >= range.lowerBound else {
      return [entry]
    }
    var pieces: [Entry] = []
    if entry.lo < range.lowerBound {
      pieces.append(Self.slice(entry, lo: entry.lo, hi: range.lowerBound - 1))
    }
    if entry.hi > range.upperBound {
      pieces.append(Self.slice(entry, lo: range.upperBound + 1, hi: entry.hi))
    }
    return pieces
  }

  /// `entry`를 `[lo, hi]`(원 구간의 부분집합) 조각으로 슬라이스한다. `widths` 형은
  /// 대응 부분 배열로 자르고, 균일 폭은 값을 그대로 유지한다.
  private static func slice(_ entry: Entry, lo: UInt32, hi: UInt32) -> Entry {
    guard let widths = entry.widths else {
      return Entry(lo: lo, hi: hi, uniformWidth: entry.uniformWidth, widths: nil)
    }
    let startOffset = Int(lo - entry.lo)
    let endOffset = Int(hi - entry.lo)
    guard startOffset >= 0, endOffset < widths.count, startOffset <= endOffset else {
      return Entry(lo: lo, hi: hi, uniformWidth: nil, widths: [])
    }
    return Entry(lo: lo, hi: hi, uniformWidth: nil, widths: Array(widths[startOffset...endOffset]))
  }
}

/// 로딩 완료된 폰트의 불변 스냅숏. 문서 전역 캐시 대상 (객체 번호 키).
package struct LoadedFont: Sendable {
  /// 코드 해석 방식.
  package enum CodeLayout: Sendable {
    /// 단순 폰트 — 1바이트 코드.
    case simple
    /// Type0 Identity-H/V — 고정 2바이트, code == CID.
    case identity(vertical: Bool)
    /// Type0 + 임베디드 CMap — 코드스페이스 기반 가변 바이트.
    case embeddedCMap(EmbeddedCIDMap, vertical: Bool)
    /// Type0 + 사전정의 CMap (v1 미지원) — 고정 2바이트 가정, 전 글리프 U+FFFD (가정 7).
    case unsupportedPredefined(vertical: Bool)
  }

  /// 코드 해석 방식.
  package let layout: CodeLayout

  /// ToUnicode 매핑 (코드 키). 최우선 순위.
  package let toUnicode: ToUnicodeMap?

  /// 단순 폰트의 코드→유니코드 폴백 테이블 (기본 인코딩+/Differences+AGL 해소 완료, 256).
  package let simpleEncoding: [String?]?

  /// 단순 폰트 폭 (256, 1000 글리프 단위·Type3는 FontMatrix 반영 완료). 부재 항목은 `nil`.
  package let simpleWidths: [CGFloat?]?

  /// Type0 CID 폭 (`/W` 해석 결과. 조회는 정렬 구간 이진 탐색).
  package let cidWidths: CIDWidthTable?

  /// Type0 기본 폭 `/DW` (기본 1000).
  package let defaultWidth: CGFloat

  /// `/MissingWidth` 폴백 (기본 0).
  package let missingWidth: CGFloat

  /// 1000 단위 어센트 (기본 800).
  package let ascent: CGFloat

  /// 1000 단위 디센트 (음수, 기본 -200).
  package let descent: CGFloat

  /// 폰트 스냅숏을 생성한다.
  package init(
    layout: CodeLayout, toUnicode: ToUnicodeMap?, simpleEncoding: [String?]?,
    simpleWidths: [CGFloat?]?, cidWidths: CIDWidthTable?, defaultWidth: CGFloat,
    missingWidth: CGFloat, ascent: CGFloat, descent: CGFloat
  ) {
    self.layout = layout
    self.toUnicode = toUnicode
    self.simpleEncoding = simpleEncoding
    self.simpleWidths = simpleWidths
    self.cidWidths = cidWidths
    self.defaultWidth = defaultWidth
    self.missingWidth = missingWidth
    self.ascent = ascent
    self.descent = descent
  }

  /// 바이트열을 (코드, 소비 바이트 수) 시퀀스로 해석한다 (§3.3).
  /// - Parameter bytes: `Tj`/`TJ` 문자열 오퍼랜드의 원시 바이트.
  /// - Returns: 해석된 문자 코드 목록.
  package func decodeCodes(_ bytes: [UInt8]) -> [CharacterCode] {
    switch self.layout {
    case .simple:
      return bytes.map { CharacterCode(value: UInt32($0), byteLength: 1) }
    case .identity, .unsupportedPredefined:
      return Self.decodeFixedTwoByte(bytes)
    case let .embeddedCMap(map, _):
      return Self.decodeEmbedded(bytes, map: map)
    }
  }

  /// 코드 하나의 유니코드 문자열. 매핑 불가면 U+FFFD (§3.4 우선순위).
  /// - Parameter code: 해석된 문자 코드.
  /// - Returns: 매핑된 유니코드 문자열 (최소 1 코드유닛).
  package func unicode(for code: CharacterCode) -> String {
    if let toUnicode, let mapped = toUnicode.unicode(for: code.value) {
      return mapped
    }
    if case .simple = self.layout, let simpleEncoding, code.value < UInt32(simpleEncoding.count),
      let mapped = simpleEncoding[Int(code.value)] {
      return mapped
    }
    return "\u{FFFD}"
  }

  /// 코드 하나의 1000 단위 폭 (§3.5 폴백 사슬).
  /// - Parameter code: 해석된 문자 코드.
  /// - Returns: 1000 단위 폭.
  package func width(for code: CharacterCode) -> CGFloat {
    switch self.layout {
    case .simple:
      if let simpleWidths, code.value < UInt32(simpleWidths.count),
        let width = simpleWidths[Int(code.value)] {
        return width
      }
      return self.missingWidth
    case .identity:
      return self.cidWidths?.width(forCID: code.value) ?? self.defaultWidth
    case let .embeddedCMap(map, _):
      guard let cid = map.cid(for: code.value, byteLength: code.byteLength) else {
        return self.defaultWidth
      }
      return self.cidWidths?.width(forCID: cid) ?? self.defaultWidth
    case .unsupportedPredefined:
      return self.defaultWidth
    }
  }
}

// MARK: - 코드 디코딩 헬퍼

extension LoadedFont {
  /// 고정 2바이트 빅엔디언 해석. 홀수 꼬리 1바이트는 그 자체로 상위 바이트 취급(관용).
  private static func decodeFixedTwoByte(_ bytes: [UInt8]) -> [CharacterCode] {
    var result: [CharacterCode] = []
    result.reserveCapacity((bytes.count + 1) / 2)
    var index = 0
    while index < bytes.count {
      if index + 1 < bytes.count {
        let value = UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
        result.append(CharacterCode(value: value, byteLength: 2))
        index += 2
      } else {
        result.append(CharacterCode(value: UInt32(bytes[index]), byteLength: 1))
        index += 1
      }
    }
    return result
  }

  /// 임베디드 CMap 코드스페이스 기반 가변 바이트 해석. 불일치 시 1바이트 소비(관용).
  private static func decodeEmbedded(_ bytes: [UInt8], map: EmbeddedCIDMap) -> [CharacterCode] {
    var result: [CharacterCode] = []
    var index = 0
    while index < bytes.count {
      let remaining = bytes[index...]
      let length = map.matchByteLength(startingAt: remaining) ?? 1
      let consumable = min(length, bytes.count - index)
      let value = Self.bigEndianValue(bytes, from: index, length: consumable)
      result.append(CharacterCode(value: value, byteLength: consumable))
      index += consumable
    }
    return result
  }

  private static func bigEndianValue(_ bytes: [UInt8], from start: Int, length: Int) -> UInt32 {
    var value: UInt32 = 0
    for offset in 0..<length {
      value = (value << 8) | UInt32(bytes[start + offset])
    }
    return value
  }
}
