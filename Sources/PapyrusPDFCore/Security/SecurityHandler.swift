import Foundation

/// 문자열·스트림 복호화 심(seam). v1은 항등 구현만 존재한다.
///
/// 모든 스트림 페이로드는 필터 적용 **전에**, 모든 문자열 바이트는 텍스트 디코딩 전에
/// 반드시 이 프로토콜을 경유한다 — 이후 표준 핸들러(RC4/AES)를 추가할 때
/// 다른 계층이 무수정이어야 한다 (ARCHITECTURE.md 암호화 절).
package protocol SecurityHandler: Sendable {
  /// 간접 객체에 속한 문자열 바이트를 복호화한다.
  /// - Parameters:
  ///   - bytes: 암호화된 원본 문자열 바이트.
  ///   - objectID: 문자열이 속한 간접 객체 (암호화 키 유도에 필요).
  /// - Throws: 복호화 실패 시 구현체가 정의한 에러.
  /// - Returns: 복호화된 문자열 바이트.
  func decryptString(_ bytes: [UInt8], objectID: ObjectID) throws -> [UInt8]

  /// 스트림의 인코딩 전(raw) 페이로드를 복호화한다.
  /// - Parameters:
  ///   - data: 암호화된 원본 스트림 바이트.
  ///   - objectID: 스트림이 속한 간접 객체 (암호화 키 유도에 필요).
  /// - Throws: 복호화 실패 시 구현체가 정의한 에러.
  /// - Returns: 복호화된 스트림 바이트.
  func decryptStream(_ data: Data, objectID: ObjectID) throws -> Data
}

/// 암호화 없는 문서용 항등 핸들러 — v1의 유일한 구현.
///
/// **근거:** v1에서 `/Encrypt` 문서는 열기 자체가 실패하므로 항등 핸들러가 항상 올바르다.
/// 그럼에도 파이프라인이 핸들러를 경유하는 구조를 지금 만드는 것이 이 심의 존재 이유다.
package struct IdentitySecurityHandler: SecurityHandler {
  /// 항등 핸들러를 생성한다.
  package init() {}

  /// 입력을 그대로 반환한다.
  /// - Parameters:
  ///   - bytes: 문자열 바이트.
  ///   - objectID: 문자열이 속한 간접 객체.
  /// - Returns: `bytes` 그대로.
  package func decryptString(_ bytes: [UInt8], objectID: ObjectID) throws -> [UInt8] {
    bytes
  }

  /// 입력을 그대로 반환한다.
  /// - Parameters:
  ///   - data: 스트림 바이트.
  ///   - objectID: 스트림이 속한 간접 객체.
  /// - Returns: `data` 그대로.
  package func decryptStream(_ data: Data, objectID: ObjectID) throws -> Data {
    data
  }
}
