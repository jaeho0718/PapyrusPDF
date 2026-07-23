import Foundation
@testable import PapyrusCore
import Testing

/// ``NameTreeKeyOrder``와 ``PDFDocumentCore/nameTreeValue(root:key:)``를 검증한다
/// (설계 §5.4 NT1-NT3). 정렬 위반·순환·훼손 /Limits는 픽스처 빌더의 스펙 표면 밖(항상
/// 정렬해 기록)이므로 바이트 수준 raw 픽스처로 직접 구성한다.
struct NameTreeTests {
  // MARK: NT1 — 바이트 사전식 경계

  /// NT1: 빈 키, 접두 관계, 0xFF 등 바이트 사전식 경계를 검증한다.
  @Test func keyOrderHandlesByteLexicographicEdgeCases() {
    #expect(NameTreeKeyOrder.isOrderedBefore([], [0x00]))
    #expect(!NameTreeKeyOrder.isOrderedBefore([0x00], []))
    #expect(!NameTreeKeyOrder.isOrderedBefore([], []))

    // 접두 관계: "AB" < "ABC".
    #expect(NameTreeKeyOrder.isOrderedBefore([0x41, 0x42], [0x41, 0x42, 0x43]))
    #expect(!NameTreeKeyOrder.isOrderedBefore([0x41, 0x42, 0x43], [0x41, 0x42]))

    // 0xFF 경계.
    #expect(NameTreeKeyOrder.isOrderedBefore([0xFE], [0xFF]))
    #expect(!NameTreeKeyOrder.isOrderedBefore([0xFF], [0xFE]))

    #expect(NameTreeKeyOrder.contains(key: [0x41], min: [0x41], max: [0x5A]))
    #expect(NameTreeKeyOrder.contains(key: [0x5A], min: [0x41], max: [0x5A]))
    #expect(!NameTreeKeyOrder.contains(key: [0x60], min: [0x41], max: [0x5A]))
  }

  // MARK: NT2 — 정렬 위반 리프

  /// NT2: 정렬 위반 리프(raw 픽스처, "zzz" 앞·"aaa" 뒤) → 선형 스캔이 그래도 찾는다.
  @Test func linearScanFindsKeyInUnsortedLeaf() async throws {
    let data = Self.rawFixture(objects: [
      (1, "<< /Type /Catalog /Pages 2 0 R >>"),
      (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
      (3, "<< /Type /Page >>"),
      (5, "<< /Names [(zzz) [3 0 R /XYZ null null null] (aaa) [3 0 R /XYZ null null null]] >>")
    ])
    let document = try await PDFDocumentCore.open(data: data)
    let result = try await document.nameTreeValue(
      root: .reference(ObjectID(number: 5, generation: 0)), key: Array("aaa".utf8)
    )
    guard case let .array(elements) = result else {
      Issue.record("네임 트리 값이 배열이 아님: \(String(describing: result))")
      return
    }
    #expect(elements.first == .reference(ObjectID(number: 3, generation: 0)))
  }

  // MARK: NT3 — /Limits 훼손 · 순환

  /// NT3a: /Limits 훼손 kid → 관용 하강 폴백(한계 있는 kid가 전부 불일치일 때 채택).
  @Test func malformedLimitsKidIsUsedAsFallback() async throws {
    let data = Self.rawFixture(objects: [
      (1, "<< /Type /Catalog /Pages 2 0 R >>"),
      (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
      (3, "<< /Type /Page >>"),
      // 루트: kid6(한계 없음, 실제로 찾는 키를 보유) + kid7(유효 한계지만 키 밖).
      (5, "<< /Kids [6 0 R 7 0 R] >>"),
      (6, "<< /Names [(nnn) [3 0 R /XYZ null null null]] >>"),
      (7, "<< /Limits [(xxx) (yyy)] /Names [(xxx) [3 0 R /XYZ null null null]] >>")
    ])
    let document = try await PDFDocumentCore.open(data: data)
    let result = try await document.nameTreeValue(
      root: .reference(ObjectID(number: 5, generation: 0)), key: Array("nnn".utf8)
    )
    guard case let .array(elements) = result else {
      Issue.record("한계 없는 kid로의 관용 하강 실패: \(String(describing: result))")
      return
    }
    #expect(elements.first == .reference(ObjectID(number: 3, generation: 0)))
  }

  /// NT3b: 순환 kid(한계 없는 상호 참조) → 깊이 캡으로 절단, 크래시·행 없이 `nil`.
  @Test func cyclicKidsAreCappedToNilWithoutHanging() async throws {
    let data = Self.rawFixture(objects: [
      (1, "<< /Type /Catalog /Pages 2 0 R >>"),
      (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
      (3, "<< /Type /Page >>"),
      (5, "<< /Kids [6 0 R] >>"),
      (6, "<< /Kids [5 0 R] >>")
    ])
    let document = try await PDFDocumentCore.open(data: data)
    let result = try await document.nameTreeValue(
      root: .reference(ObjectID(number: 5, generation: 0)), key: Array("anything".utf8)
    )
    #expect(result == nil)
  }
}

// MARK: - 테스트 전용 헬퍼

extension NameTreeTests {
  /// 최소 클래식 xref PDF를 (객체 번호, 본문) 목록으로부터 직접 조립한다.
  private static func rawFixture(objects: [(number: Int, body: String)]) -> Data {
    var bytes: [UInt8] = []
    func writeLine(_ text: String) {
      bytes.append(contentsOf: Array(text.utf8))
      bytes.append(0x0A)
    }
    bytes.append(contentsOf: Array("%PDF-1.4\n".utf8))

    var offsets: [Int: Int] = [:]
    for object in objects.sorted(by: { $0.number < $1.number }) {
      offsets[object.number] = bytes.count
      writeLine("\(object.number) 0 obj")
      writeLine(object.body)
      writeLine("endobj")
    }

    let xrefOffset = bytes.count
    writeLine("xref")
    let highest = offsets.keys.max() ?? 0
    writeLine("0 \(highest + 1)")
    for number in 0...highest {
      if number == 0 {
        writeLine("0000000000 65535 f")
      } else if let offset = offsets[number] {
        bytes.append(contentsOf: Array(String(format: "%010d 00000 n\n", offset).utf8))
      } else {
        writeLine("0000000000 00000 f")
      }
    }
    writeLine("trailer")
    writeLine("<< /Size \(highest + 1) /Root 1 0 R >>")
    writeLine("startxref")
    writeLine("\(xrefOffset)")
    bytes.append(contentsOf: Array("%%EOF".utf8))
    return Data(bytes)
  }
}
