import Foundation

/// 결정론적 바이트 뮤테이터. PDF 구조 지식이 얕은 범용 연산 + PDF 토큰 사전의 조합이다.
///
/// `PapyrusPDFTestSupport`는 `PapyrusPDFCore`에 의존하지 않으므로(기존 원칙) 파서 지식을
/// 쓸 수 없고 쓸 필요도 없다 — 구조적 손상은 `PDFFixtureCorruptor`가, 비구조적
/// 탐색은 이 뮤테이터가 맡는 역할 분담이다.
///
/// - Important: 계약 — 기존 연산의 의미·순서를 바꾸면 `FuzzRegressionTests`에 등재된
///   트리플이 더는 같은 바이트를 재현하지 못한다. 새 연산 추가는 허용하되(뒤에 추가),
///   기존 연산의 동작은 절대 변경하지 않는다.
package enum FuzzMutator {
  /// `count`개 연산을 순서대로 적용한 결과를 돌려준다.
  /// 출력 크기는 `입력 * 2 + 4KB`를 넘지 않는다 (삽입·복제 연산의 누적 상한).
  /// - Parameters:
  ///   - data: 뮤테이션 대상 원본 바이트.
  ///   - seed: 뮤테이터 PRNG 시드 (연산 종류·위치·길이를 전부 이 시드에서 뽑는다).
  ///   - count: 적용할 연산 수. 0 이하면 원본을 그대로 반환한다.
  /// - Returns: 뮤테이션이 적용된 바이트.
  package static func mutate(_ data: Data, seed: UInt64, count: Int) -> Data {
    guard !data.isEmpty, count > 0 else {
      return data
    }
    var bytes = [UInt8](data)
    let cap = data.count * 2 + 4_096
    var rng = SplitMix64(seed: seed)
    for _ in 0..<count {
      guard !bytes.isEmpty else {
        break
      }
      Self.applyRandomOperation(to: &bytes, cap: cap, rng: &rng)
    }
    return Data(bytes)
  }

  /// 뮤테이터 연산 종류. PRNG가 균등 선택한다.
  enum Operation: CaseIterable {
    /// 임의 위치 1바이트 XOR(1<<임의비트) — 렉서 문자 클래스 경계.
    case flipByte
    /// 임의 위치를 흥미 바이트 하나로 치환 — 문자열/딕셔너리 짝 붕괴, 주석 오염.
    case setInterestingByte
    /// 가장 가까운 숫자 런에 자릿수 추가/부호 삽입/앞자리 치환 — 오프셋·/Length·/Count 거짓말.
    case corruptNumber
    /// 꼬리 1..25% 절단 — 불완전 파일, endstream 부재.
    case truncate
    /// 임의 구간(≤256B) 삭제 — 키워드 소실, 구조 어긋남.
    case deleteRange
    /// 임의 구간(≤256B)을 임의 위치에 복제 삽입 — 중복 객체 헤더, 오프셋 전위.
    case duplicateRange
    /// 비중첩 두 구간(≤64B) 교환 — 섹션 순서 붕괴.
    case swapRanges
    /// 사전 토큰을 임의 위치에 삽입 — 조기 `endobj`/`trailer`, 가짜 `startxref`.
    case insertToken
    /// 사전 토큰으로 임의 위치 덮어쓰기(길이 보존) — 위와 동일 + 길이 보존 변형.
    case overwriteToken
  }

  /// PDF 토큰 사전 — `insertToken`/`overwriteToken`이 여기서 균등 선택한다.
  static let tokens: [String] = [
    "obj", "endobj", "stream", "endstream", "xref", "trailer", "startxref", "%%EOF",
    "%PDF-1.7", "R", "null", "true", "false", "/Prev", "/Root", "/Length", "/Filter",
    "/FlateDecode", "/LZWDecode", "/Type", "/ObjStm", "/XRef", "/Kids", "/Count", "/First",
    "/N", "/W", "/Index", "/Encrypt", "<<", ">>", "[", "]", "(", ")", "0", "-1", "2147483647",
    "9999999999999999999"
  ]

  /// `setInterestingByte`가 균등 선택하는 바이트 사전 (문자열/딕셔너리 짝·주석 경계).
  private static let interestingBytes: [UInt8] = [
    0x00, 0xFF, 0x0A, 0x0D, UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"),
    UInt8(ascii: ">"), UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "%"), UInt8(ascii: "/")
  ]

  /// 연산 하나를 뽑아 적용한다.
  private static func applyRandomOperation(
    to bytes: inout [UInt8], cap: Int, rng: inout SplitMix64
  ) {
    switch Operation.allCases.randomElement(using: &rng) ?? .flipByte {
    case .flipByte:
      Self.flipByte(&bytes, rng: &rng)
    case .setInterestingByte:
      Self.setInterestingByte(&bytes, rng: &rng)
    case .corruptNumber:
      Self.corruptNumber(&bytes, cap: cap, rng: &rng)
    case .truncate:
      Self.truncate(&bytes, rng: &rng)
    case .deleteRange:
      Self.deleteRange(&bytes, rng: &rng)
    case .duplicateRange:
      Self.duplicateRange(&bytes, cap: cap, rng: &rng)
    case .swapRanges:
      Self.swapRanges(&bytes, rng: &rng)
    case .insertToken:
      Self.insertToken(&bytes, cap: cap, rng: &rng)
    case .overwriteToken:
      Self.overwriteToken(&bytes, rng: &rng)
    }
  }
}

// MARK: - 범용 바이트 연산

extension FuzzMutator {
  private static func flipByte(_ bytes: inout [UInt8], rng: inout SplitMix64) {
    let index = Int.random(in: 0..<bytes.count, using: &rng)
    let bit = UInt8(1 << Int.random(in: 0...7, using: &rng))
    bytes[index] ^= bit
  }

  private static func setInterestingByte(_ bytes: inout [UInt8], rng: inout SplitMix64) {
    let index = Int.random(in: 0..<bytes.count, using: &rng)
    bytes[index] = Self.interestingBytes.randomElement(using: &rng) ?? 0x00
  }

  private static func truncate(_ bytes: inout [UInt8], rng: inout SplitMix64) {
    let maxCut = max(1, bytes.count / 4)
    let cut = Int.random(in: 1...maxCut, using: &rng)
    bytes.removeLast(min(cut, bytes.count))
  }

  private static func deleteRange(_ bytes: inout [UInt8], rng: inout SplitMix64) {
    let start = Int.random(in: 0..<bytes.count, using: &rng)
    let maxLength = min(256, bytes.count - start)
    guard maxLength > 0 else {
      return
    }
    let length = Int.random(in: 1...maxLength, using: &rng)
    bytes.removeSubrange(start..<(start + length))
  }

  private static func duplicateRange(_ bytes: inout [UInt8], cap: Int, rng: inout SplitMix64) {
    let start = Int.random(in: 0..<bytes.count, using: &rng)
    let maxLength = min(256, bytes.count - start)
    guard maxLength > 0 else {
      return
    }
    let length = Int.random(in: 1...maxLength, using: &rng)
    guard bytes.count + length <= cap else {
      return // 상한 초과 — no-op (§3.2 출력 상한).
    }
    let slice = Array(bytes[start..<(start + length)])
    let insertAt = Int.random(in: 0...bytes.count, using: &rng)
    bytes.insert(contentsOf: slice, at: insertAt)
  }

  private static func swapRanges(_ bytes: inout [UInt8], rng: inout SplitMix64) {
    let maxLength = min(64, bytes.count / 2)
    guard maxLength > 0 else {
      return
    }
    let length = Int.random(in: 1...maxLength, using: &rng)
    let firstStart = Int.random(in: 0...(bytes.count - 2 * length), using: &rng)
    let secondStart = Int.random(in: (firstStart + length)...(bytes.count - length), using: &rng)
    for offset in 0..<length {
      bytes.swapAt(firstStart + offset, secondStart + offset)
    }
  }

  private static func insertToken(_ bytes: inout [UInt8], cap: Int, rng: inout SplitMix64) {
    let token = Array((Self.tokens.randomElement(using: &rng) ?? "obj").utf8)
    guard bytes.count + token.count <= cap else {
      return // 상한 초과 — no-op (§3.2 출력 상한).
    }
    let insertAt = Int.random(in: 0...bytes.count, using: &rng)
    bytes.insert(contentsOf: token, at: insertAt)
  }

  private static func overwriteToken(_ bytes: inout [UInt8], rng: inout SplitMix64) {
    let token = Array((Self.tokens.randomElement(using: &rng) ?? "obj").utf8)
    let start = Int.random(in: 0..<bytes.count, using: &rng)
    let writable = min(token.count, bytes.count - start)
    for index in 0..<writable {
      bytes[start + index] = token[index]
    }
  }
}

// MARK: - corruptNumber (숫자 런 탐색 + 변형)

extension FuzzMutator {
  private static func corruptNumber(_ bytes: inout [UInt8], cap: Int, rng: inout SplitMix64) {
    let start = Int.random(in: 0..<bytes.count, using: &rng)
    guard let run = Self.nearestDigitRun(in: bytes, from: start) else {
      return // 숫자가 전혀 없는 입력 — no-op.
    }
    switch Int.random(in: 0...2, using: &rng) {
    case 0: // 자릿수 추가
      guard bytes.count + 1 <= cap else {
        return // 상한 초과 — no-op (§3.2 출력 상한).
      }
      let digit = UInt8(ascii: "0") &+ UInt8(Int.random(in: 0...9, using: &rng))
      bytes.insert(digit, at: run.upperBound)
    case 1: // 부호 삽입
      guard bytes.count + 1 <= cap else {
        return // 상한 초과 — no-op (§3.2 출력 상한).
      }
      bytes.insert(UInt8(ascii: "-"), at: run.lowerBound)
    default: // 앞자리 치환
      let digit = UInt8(ascii: "0") &+ UInt8(Int.random(in: 0...9, using: &rng))
      bytes[run.lowerBound] = digit
    }
  }

  /// `start`에서 바깥쪽으로(오른쪽 우선) 탐색해 가장 가까운 숫자 런을 찾는다.
  private static func nearestDigitRun(in bytes: [UInt8], from start: Int) -> Range<Int>? {
    for distance in 0..<bytes.count {
      let right = start + distance
      if right < bytes.count, Self.isDigit(bytes[right]) {
        return Self.expandDigitRun(bytes, around: right)
      }
      let left = start - distance
      if distance > 0, left >= 0, Self.isDigit(bytes[left]) {
        return Self.expandDigitRun(bytes, around: left)
      }
    }
    return nil
  }

  /// `index`를 포함하는 연속 숫자 구간으로 좌우 확장한다.
  private static func expandDigitRun(_ bytes: [UInt8], around index: Int) -> Range<Int> {
    var lower = index
    while lower > 0, Self.isDigit(bytes[lower - 1]) {
      lower -= 1
    }
    var upper = index + 1
    while upper < bytes.count, Self.isDigit(bytes[upper]) {
      upper += 1
    }
    return lower..<upper
  }

  private static func isDigit(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte)
  }
}
