/// 결정론적 64비트 PRNG (SplitMix64). 퍼즈 케이스 재현의 기반 —
/// 같은 시드는 어느 플랫폼·어느 실행에서든 같은 수열을 낸다.
///
/// `SystemRandomNumberGenerator`를 쓰지 않는 이유: 재현 불가.
package struct SplitMix64: RandomNumberGenerator, Sendable {
  /// 내부 상태 (매 호출마다 골든비 상수만큼 전진한다).
  private var state: UInt64

  /// 시드로 생성한다.
  /// - Parameter seed: 초기 상태. 같은 값이면 항상 같은 수열을 낸다.
  package init(seed: UInt64) {
    self.state = seed
  }

  /// 다음 64비트 값.
  ///
  /// 표준 SplitMix64 알고리즘(Vigna) — 상태를 골든비 상수로 전진시킨 뒤 3단 비트
  /// 혼합(xor-shift + 곱셈)으로 출력을 만든다.
  package mutating func next() -> UInt64 {
    self.state = self.state &+ 0x9E37_79B9_7F4A_7C15
    var mixed = self.state
    mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
    mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
    return mixed ^ (mixed >> 31)
  }
}
