import Foundation

/// 퍼즈 케이스 식별자. 이 값 하나가 케이스의 입력 바이트를 완전히 결정한다 —
/// 재현 = 같은 ID로 `makeInput()` 재호출.
package struct FuzzCaseID: Sendable, Hashable, CustomStringConvertible {
  /// 뮤테이션의 출발점이 되는 시드 픽스처.
  package let seed: FuzzSeedFixture

  /// 뮤테이터 PRNG 시드.
  package let mutationSeed: UInt64

  /// 적용할 뮤테이션 연산 수 (1...16 권장 — 0이면 원본 그대로).
  package let mutationCount: Int

  /// 케이스 식별자를 생성한다.
  /// - Parameters:
  ///   - seed: 뮤테이션의 출발점이 되는 시드 픽스처.
  ///   - mutationSeed: 뮤테이터 PRNG 시드.
  ///   - mutationCount: 적용할 뮤테이션 연산 수 (0이면 원본 그대로).
  package init(seed: FuzzSeedFixture, mutationSeed: UInt64, mutationCount: Int) {
    self.seed = seed
    self.mutationSeed = mutationSeed
    self.mutationCount = mutationCount
  }

  /// 재현 문자열: `"seed=xrefStreamText mut=0x1A2B3C4D5E6F7788 n=4"`.
  /// 실패 메시지·회귀 코퍼스 등재에 그대로 쓴다.
  package var description: String {
    "seed=\(self.seed.rawValue) mut=0x\(Self.hex16(self.mutationSeed)) n=\(self.mutationCount)"
  }

  /// 케이스 입력 바이트를 생성한다 (시드 빌드 → 뮤테이션 적용).
  package func makeInput() -> Data {
    let base = self.seed.build().data
    guard self.mutationCount != 0 else {
      return base
    }
    return FuzzMutator.mutate(base, seed: self.mutationSeed, count: self.mutationCount)
  }

  /// `value`를 16자리 대문자 16진 문자열로 zero-pad 포맷한다 (`String(format:)`의
  /// `UInt64` 플랫폼별 동작 불일치를 피하기 위해 수동 구현).
  private static func hex16(_ value: UInt64) -> String {
    let hex = String(value, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
  }
}
