import Foundation

/// `/RunLengthDecode` (`/RL`) 디코더 (PackBits 변형).
package enum RunLengthDecode {
  /// 런렝스 인코딩을 디코딩한다.
  ///
  /// 길이 바이트 `L`: `L <= 127`이면 다음 `L+1`바이트 리터럴 복사, `L >= 129`이면
  /// 다음 1바이트를 `257-L`회 반복, `L == 128`이면 EOD로 종료.
  /// - Parameters:
  ///   - data: 인코딩된 바이트.
  ///   - maxDecodedSize: 방출 바이트 상한 (압축 폭탄 가드).
  /// - Throws: EOD 이전 입력 소진 시 ``FilterError/Code/truncatedData``,
  ///   상한 초과 시 `outputLimitExceeded`.
  package static func decode(_ data: Data, maxDecodedSize: Int) throws(FilterError) -> Data {
    let bytes = Array(data)
    var index = 0
    var out: [UInt8] = []
    while true {
      guard index < bytes.count else {
        throw FilterError(code: .truncatedData)
      }
      let length = bytes[index]
      index += 1

      if length == 128 {
        return Data(out)
      }

      if length <= 127 {
        let count = Int(length) + 1
        guard index + count <= bytes.count else {
          throw FilterError(code: .truncatedData)
        }
        out.append(contentsOf: bytes[index..<(index + count)])
        index += count
      } else {
        guard index < bytes.count else {
          throw FilterError(code: .truncatedData)
        }
        let repeated = bytes[index]
        index += 1
        out.append(contentsOf: repeatElement(repeated, count: 257 - Int(length)))
      }

      if out.count > maxDecodedSize {
        throw FilterError(code: .outputLimitExceeded)
      }
    }
  }
}
