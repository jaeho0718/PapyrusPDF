import Foundation
import Observation
import Papyrus

/// 파일 열기·합성 문서 생성을 담당하는 데모 앱 전용 관찰 모델.
///
/// `PapyrusReaderModel`은 문서 하나의 수명에 묶이므로, 문서를 교체할 때마다
/// 새 인스턴스로 갈아 끼운다 (`ContentView`가 새 모델을 `PapyrusReader`에 전달).
@MainActor
@Observable
final class DocumentLoader {
  /// 현재 열린 문서 (미열림이면 `nil`).
  private(set) var document: PapyrusDocument?

  /// 현재 문서에 대응하는 뷰어 모델 (문서 교체 시 새로 만들어진다).
  private(set) var readerModel = PapyrusReaderModel()

  /// 문서의 목차 (부재·미열림이면 빈 배열).
  private(set) var outline: [OutlineItem] = []

  /// 열기 중 축적된 경고 (관용 복구가 개입했음을 사용자에게 보여주는 용도).
  private(set) var openWarnings: [OpenWarning] = []

  /// 열기 진행 중 여부 (진행 표시기용).
  private(set) var isLoading = false

  /// 사용자에게 보여줄 에러 메시지 (nil이면 알림 미표시).
  var errorMessage: String?

  /// 표시용 문서 이름 (열기 전에는 빈 문자열).
  private(set) var displayName = ""

  /// 파일 URL에서 문서를 연다 (보안 스코프 접근 처리 포함).
  /// - Parameter url: `fileImporter`가 반환한 파일 URL.
  func open(url: URL) async {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }
    await self.load(displayName: url.lastPathComponent) {
      try await PapyrusDocument.open(url: url)
    }
  }

  /// 인메모리 바이트(합성 문서)에서 문서를 연다.
  /// - Parameters:
  ///   - data: 열려는 PDF 바이트.
  ///   - displayName: 사용자에게 보여줄 이름.
  func open(data: Data, displayName: String) async {
    await self.load(displayName: displayName) {
      try await PapyrusDocument.open(data: data)
    }
  }

  /// 공통 적재 절차: 문서 열기 → 목차 조회 → 상태 반영. 실패는 `errorMessage`로 통지한다.
  /// - Parameters:
  ///   - displayName: 성공 시 표시할 이름.
  ///   - open: 문서를 여는 클로저.
  private func load(
    displayName: String, open: () async throws -> PapyrusDocument
  ) async {
    self.isLoading = true
    defer {
      self.isLoading = false
    }
    do {
      let document = try await open()
      self.document = document
      self.openWarnings = document.openWarnings
      self.outline = try await document.outline
      self.readerModel = PapyrusReaderModel()
      self.displayName = displayName
    } catch let error as PapyrusError {
      self.errorMessage = error.errorDescription ?? "The document could not be opened."
    } catch {
      self.errorMessage = "The document could not be opened: \(error)"
    }
  }
}
