import Foundation
@testable import PapyrusPDFCore
import PapyrusPDFTestSupport
import Testing

/// 트레일러 `/Encrypt` 감지와 `SecurityHandler` 심을 검증한다 (설계 §3.6, §5.7).
struct EncryptionDetectionTests {
  // MARK: ED1 — 직접 딕셔너리

  /// ED1: `extraTrailerEntries["Encrypt": ...]` → `.encryptedDocument(filterName: "Standard")`.
  @Test func directEncryptDictionaryIsDetected() async throws {
    let fixture = PDFFixtureBuilder(
      pageCount: 1, extraTrailerEntries: ["Encrypt": "<< /Filter /Standard /V 2 >>"]
    ).build()
    do {
      _ = try await PDFDocumentCore.open(data: fixture.data)
      Issue.record("/Encrypt 존재 시 encryptedDocument여야 함")
    } catch {
      guard case let .encryptedDocument(filterName) = error else {
        Issue.record("예상치 못한 에러: \(error)")
        return
      }
      #expect(filterName == "Standard")
    }
  }

  // MARK: ED2 — 간접 참조

  /// ED2: `/Encrypt`가 간접 참조인 변형 → 감지 + filterName 해소.
  @Test func indirectEncryptReferenceIsDetectedAndResolved() async throws {
    let data = Self.makeIndirectEncryptFixture()
    do {
      _ = try await PDFDocumentCore.open(data: data)
      Issue.record("/Encrypt 존재 시 encryptedDocument여야 함")
    } catch {
      guard case let .encryptedDocument(filterName) = error else {
        Issue.record("예상치 못한 에러: \(error)")
        return
      }
      #expect(filterName == "Standard")
    }
  }

  // MARK: ED3 — 복구 경로에서도 감지

  /// ED3: 복구 경로(손상 모드 결합) + `/Encrypt` → `damaged`가 아닌 `.encryptedDocument`.
  @Test func encryptionDetectedEvenAfterRecoveryScan() async throws {
    let fixture = PDFFixtureBuilder(
      pageCount: 1, extraTrailerEntries: ["Encrypt": "<< /Filter /Standard /V 2 >>"]
    ).build()
    let corrupted = PDFFixtureCorruptor.apply([.removeStartxref], to: fixture)
    do {
      _ = try await PDFDocumentCore.open(data: corrupted.data)
      Issue.record("복구 후에도 /Encrypt 존재 시 encryptedDocument여야 함")
    } catch {
      guard case let .encryptedDocument(filterName) = error else {
        Issue.record("damaged가 아닌 encryptedDocument여야 하는데: \(error)")
        return
      }
      #expect(filterName == "Standard")
    }
  }

  // MARK: ED4 — 항등 핸들러

  /// ED4: `IdentitySecurityHandler`는 문자열·스트림 바이트를 그대로 반환한다.
  @Test func identitySecurityHandlerIsPassthrough() throws {
    let handler = IdentitySecurityHandler()
    let id = ObjectID(number: 5, generation: 0)

    let stringBytes: [UInt8] = [0x01, 0x02, 0x03, 0xFF]
    #expect(try handler.decryptString(stringBytes, objectID: id) == stringBytes)

    let streamData = Data([0xAA, 0xBB, 0xCC])
    #expect(try handler.decryptStream(streamData, objectID: id) == streamData)
  }
}

// MARK: - 테스트 전용 픽스처

extension EncryptionDetectionTests {
  /// ED2 전용: `/Encrypt`가 간접 참조(`5 0 R`)이고, 객체 5가 `/Filter /Standard`를 갖는
  /// 딕셔너리인 최소 픽스처.
  private static func makeIndirectEncryptFixture() -> Data {
    var bytes: [UInt8] = []
    func writeLine(_ text: String) {
      bytes.append(contentsOf: Array(text.utf8))
      bytes.append(0x0A)
    }
    bytes.append(contentsOf: Array("%PDF-1.4\n".utf8))

    var offsets: [Int: Int] = [:]
    offsets[1] = bytes.count
    writeLine("1 0 obj")
    writeLine("<< /Type /Catalog /Pages 2 0 R >>")
    writeLine("endobj")
    offsets[2] = bytes.count
    writeLine("2 0 obj")
    writeLine("<< /Type /Pages /Kids [] /Count 0 >>")
    writeLine("endobj")
    offsets[5] = bytes.count
    writeLine("5 0 obj")
    writeLine("<< /Filter /Standard /V 2 >>")
    writeLine("endobj")

    let xrefOffset = bytes.count
    writeLine("xref")
    writeLine("0 6")
    for number in 0...5 {
      if number == 0 {
        writeLine("0000000000 65535 f")
      } else if let offset = offsets[number] {
        bytes.append(contentsOf: Array(String(format: "%010d 00000 n\n", offset).utf8))
      } else {
        writeLine("0000000000 00000 f")
      }
    }
    writeLine("trailer")
    writeLine("<< /Size 6 /Root 1 0 R /Encrypt 5 0 R >>")
    writeLine("startxref")
    writeLine("\(xrefOffset)")
    bytes.append(contentsOf: Array("%%EOF".utf8))
    return Data(bytes)
  }
}
