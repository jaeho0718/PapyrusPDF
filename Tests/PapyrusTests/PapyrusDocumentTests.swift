import Foundation
import Papyrus
import PapyrusTestSupport
import Testing

/// 공개 퍼사드 ``PapyrusDocument``를 `import Papyrus` 단일 임포트로 검증한다
/// (설계 §5.5 PA1-PA6).
struct PapyrusDocumentTests {
  // MARK: PA1 — 성공 경로 전 표면

  /// PA1: `open(data:)`·`open(url:)` 성공 경로 — pageCount/metadata/outline/page(at:)
  /// 전 표면 + `import Papyrus` 단일 임포트로 컴파일된다.
  @Test func openDataAndURLExposeFullSurface() async throws {
    let info = PDFFixtureBuilder.InfoSpec(entries: [("Title", "(Hello)")])
    let outline = PDFFixtureBuilder.OutlineSpec(items: [
      .titled("Chapter", destination: .direct(pageIndex: 0))
    ])
    let fixture = PDFFixtureBuilder(pageCount: 2, outline: outline, info: info).build()

    let dataDocument = try await PapyrusDocument.open(data: fixture.data)
    #expect(try await dataDocument.pageCount == 2)
    #expect(try await dataDocument.metadata.title == "Hello")
    #expect(try await dataDocument.outline.first?.title == "Chapter")
    let page = try await dataDocument.page(at: 0)
    #expect(page.index == 0)

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
    try fixture.data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let urlDocument = try await PapyrusDocument.open(url: url)
    #expect(try await urlDocument.pageCount == 2)
  }

  // MARK: PA2 — 에러 매핑

  /// PA2: 비PDF 바이트 → `.notAPDF`; /Encrypt 주입 → `.encryptedDocument`; 복구 불능 →
  /// `.damagedDocument`; 없는 파일 URL → `.ioError`.
  @Test func errorsMapToPublicDomain() async throws {
    await #expect(throws: PapyrusError.notAPDF) {
      _ = try await PapyrusDocument.open(data: Data("not a pdf".utf8))
    }

    let encrypted = PDFFixtureBuilder(
      pageCount: 1, extraTrailerEntries: ["Encrypt": "<< /Filter /Standard /V 2 >>"]
    ).build()
    do {
      _ = try await PapyrusDocument.open(data: encrypted.data)
      Issue.record("암호화 문서가 성공적으로 열림")
    } catch let error {
      guard case .encryptedDocument = error else {
        Issue.record("예상치 못한 에러: \(error)")
        return
      }
    }

    let damaged = Data("%PDF-1.4\nnot a valid pdf body at all".utf8)
    do {
      _ = try await PapyrusDocument.open(data: damaged)
      Issue.record("손상 문서가 성공적으로 열림")
    } catch let error {
      guard case .damagedDocument = error else {
        Issue.record("예상치 못한 에러: \(error)")
        return
      }
    }

    let missingURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
    do {
      _ = try await PapyrusDocument.open(url: missingURL)
      Issue.record("존재하지 않는 파일이 성공적으로 열림")
    } catch let error {
      guard case .ioError = error else {
        Issue.record("예상치 못한 에러: \(error)")
        return
      }
    }
  }

  // MARK: PA3 — 인덱스 이탈

  /// PA3: `page(at: -1)`·`page(at: pageCount)` → `.pageOutOfRange` 연관값 정합.
  @Test func pageOutOfRangeCarriesCorrectAssociatedValues() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 3).build()
    let document = try await PapyrusDocument.open(data: fixture.data)

    do {
      _ = try await document.page(at: -1)
      Issue.record("음수 인덱스가 성공적으로 반환됨")
    } catch let error {
      guard case let .pageOutOfRange(index, pageCount) = error else {
        Issue.record("예상치 못한 에러: \(error)")
        return
      }
      #expect(index == -1)
      #expect(pageCount == 3)
    }

    do {
      _ = try await document.page(at: 3)
      Issue.record("범위 밖 인덱스가 성공적으로 반환됨")
    } catch let error {
      guard case let .pageOutOfRange(index, pageCount) = error else {
        Issue.record("예상치 못한 에러: \(error)")
        return
      }
      #expect(index == 3)
      #expect(pageCount == 3)
    }
  }

  // MARK: PA4 — 경고 매핑

  /// PA4: `junkPrefix` 손상 픽스처 → `openWarnings`에 `.header`·`.crossReference` kind
  /// 존재, 동기 접근.
  @Test func warningsMapToPublicKindsAndAreSyncAccessible() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 2).build()
    let corrupted = PDFFixtureCorruptor.apply([.junkPrefix(byteCount: 200)], to: fixture)

    let document = try await PapyrusDocument.open(data: corrupted.data)
    let kinds = Set(document.openWarnings.map(\.kind))
    #expect(kinds.contains(.header) || kinds.contains(.crossReference))
  }

  // MARK: PA5 — 동시성 스모크

  /// PA5: TaskGroup으로 pageCount/metadata/outline/page 혼합 32요청 → 값 일관·크래시 없음.
  @Test func concurrentMixedAccessIsConsistentAndCrashFree() async throws {
    let fixture = PDFFixtureBuilder(pageCount: 5).build()
    let document = try await PapyrusDocument.open(data: fixture.data)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<32 {
        group.addTask {
          switch index % 4 {
          case 0:
            _ = try await document.pageCount
          case 1:
            _ = try await document.metadata
          case 2:
            _ = try await document.outline
          default:
            _ = try await document.page(at: index % 5)
          }
        }
      }
      try await group.waitForAll()
    }
    #expect(try await document.pageCount == 5)
  }

  // MARK: PA6 — typed throws 컴파일 계약

  /// PA6: `catch let e as PapyrusError` 없이 `catch e` 만으로 exhaustive (typed throws 확인).
  @Test func typedThrowsAllowsExhaustiveCatchWithoutCasting() async {
    do {
      _ = try await PapyrusDocument.open(data: Data("not a pdf".utf8))
    } catch {
      // `error`가 이미 `PapyrusError` 타입이다(캐스팅 없이) — 컴파일된다는 사실 자체가 검증.
      let mapped: PapyrusError = error
      #expect(mapped == .notAPDF)
    }
  }
}
