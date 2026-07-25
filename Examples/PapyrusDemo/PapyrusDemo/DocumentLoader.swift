import CoreGraphics
import Foundation
import Observation
import Papyrus

/// M12 `SelectableRegion` 데모용 메타데이터 (설계 §1.1 DocC 레시피의 `FigureInfo` 예시를
/// 그대로 따른다). 페이지 0에 등록해 두고, 선택 메뉴 빌더가 `.region` 컨텍스트에서
/// `as?`로 캐스팅해 표시한다.
struct FigureInfo: Sendable {
  /// 영역 설명 문구 (선택 시 알림에 표시).
  let caption: String
}

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
      self.registerDemoSelectableRegion(on: self.readerModel)
      self.displayName = displayName
    } catch let error as PapyrusError {
      self.errorMessage = error.errorDescription ?? "The document could not be opened."
    } catch {
      self.errorMessage = "The document could not be opened: \(error)"
    }
  }

  /// M12 데모: 페이지 0에 `SelectableRegion` 1개를 등록한다.
  ///
  /// PDF 페이지 공간(y-위, 원점 좌하단) 기준 좌하단 근방의 작은 사각형이라 어떤 페이지
  /// 크기(합성 문서의 US Letter, 실제 파일의 임의 크기)에서도 안전하게 페이지 안에
  /// 들어간다. 리더가 아직 표시되기 전(`readerModel` 생성 직후)에 등록해도 안전하다 —
  /// `setSelectableRegions(_:forPage:)`는 적재 전 호출을 보류했다가 적재 완료 시
  /// 자동 반영한다.
  /// - Parameter model: 등록 대상 모델.
  private func registerDemoSelectableRegion(on model: PapyrusReaderModel) {
    let quad = Quad(rect: CGRect(x: 24, y: 24, width: 180, height: 56))
    let region = SelectableRegion(
      id: "demo-figure", pageIndex: 0, quad: quad,
      metadata: FigureInfo(caption: "Registered via setSelectableRegions(_:forPage:) — M12 demo")
    )
    model.setSelectableRegions([region], forPage: 0)
  }
}
