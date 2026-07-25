import PapyrusCore
import PapyrusRendering
import SwiftUI

/// PDF 뷰어 뷰입니다 (SwiftUI 퍼사드 — 내부는 네이티브 스크롤 호스트).
///
/// 적재는 비동기입니다: 첫 표시 시 페이지 트리를 읽어 레이아웃·렌더링 파이프라인을
/// 조립하고, 완료 전에는 `ProgressView`, 실패 시 안내 뷰를 표시합니다. 진행 상황은
/// `model.loadState`(``ReaderLoadState``)로도 관찰할 수 있습니다. `document` 인스턴스가
/// 바뀌면 세션을 재조립합니다.
public struct PapyrusReader: View {
  /// 표시할 문서 (열린 상태).
  private let document: PapyrusDocument

  /// 관찰·제어 모델.
  private let model: PapyrusReaderModel

  /// 내부 세션 (뷰 수명에 부착).
  @State private var session = ReaderSession()

  /// 뷰어 부착 시점의 화면 배율 (가정 6 — SwiftUI 환경값이 플랫폼을 가린다).
  @Environment(\.displayScale) private var displayScale

  /// `View.papyrusSelectionMenu(_:)`로 지정된 선택 메뉴 빌더 (미지정이면 `nil`).
  @Environment(\.papyrusSelectionMenu) private var selectionMenuBuilder

  /// 뷰어를 만듭니다.
  /// - Parameters:
  ///   - document: 표시할 문서입니다 (열린 상태).
  ///   - model: 관찰·제어 모델입니다. 같은 모델을 목차 사이드바 등과 공유합니다.
  public init(document: PapyrusDocument, model: PapyrusReaderModel) {
    self.document = document
    self.model = model
  }

  /// 뷰 본문입니다.
  public var body: some View {
    Group {
      switch self.model.loadState {
      case .loading:
        ProgressView()
      case let .failed(error):
        ContentUnavailableView(
          "Unable to Display Document",
          systemImage: "doc.questionmark",
          description: Text(error.errorDescription ?? "The document could not be opened.")
        )
      case .ready:
        if let core = self.session.core {
          ReaderScrollViewRepresentable(core: core, menuBuilder: self.selectionMenuBuilder)
        }
      }
    }
    .task(id: ObjectIdentifier(self.document)) {
      self.session.assemble(
        document: self.document, model: self.model, pixelScale: self.displayScale
      )
    }
    .onDisappear {
      self.session.tearDown()
    }
  }
}

/// 내부 세션: `ReaderCore` + 조립 태스크 보유 (`@State`로 뷰 수명에 부착).
@MainActor
@Observable
final class ReaderSession {
  /// 조립 완료된 코어 (조립 전·실패면 `nil`).
  var core: ReaderCore?

  /// 진행 중 조립 태스크.
  var assembleTask: Task<Void, Never>?

  /// 문서에서 세션을 조립한다: 페이지 트리 → 레이아웃 → 렌더 서비스 → 코어 → 모델 연결.
  /// - Parameters:
  ///   - document: 조립 대상 문서.
  ///   - model: 연결할 모델.
  ///   - pixelScale: 렌더 서비스에 고정할 화면 배율.
  func assemble(document: PapyrusDocument, model: PapyrusReaderModel, pixelScale: CGFloat) {
    self.tearDown()
    model.beginLoading()
    self.assembleTask = Task { [weak self] in
      do {
        let snapshot = try await document.core.pageTree()
        guard !Task.isCancelled else {
          return
        }
        let pageSizes = snapshot.records.map(\.displaySize)
        let layout = ReaderLayoutEngine(pageSizes: pageSizes)
        let renderQueue = TileRenderQueue(
          documentData: document.core.sourceBytes, pageSizes: pageSizes,
          configuration: RenderConfiguration(pixelScale: pixelScale)
        )
        let coordinator = ReaderSearchCoordinator(document: document)
        let selectablePageStore = ReaderSelectablePageStore(
          provider: DocumentTextProvider(document: document),
          displayTransform: { [document] pageIndex in
            guard let info = try? await document.page(at: pageIndex) else {
              return .identity
            }
            return info.displayTransform
          }
        )
        let selectionController = ReaderSelectionController(store: selectablePageStore)
        let core = ReaderCore(
          layout: layout, renderQueue: renderQueue, pixelScale: pixelScale,
          searchCoordinator: coordinator, selectionController: selectionController
        )
        guard let self, !Task.isCancelled else {
          return
        }
        self.core = core
        model.attach(core: core)
      } catch {
        guard !Task.isCancelled else {
          return
        }
        model.applyFailure((error as? PapyrusError) ?? .damagedDocument)
      }
    }
  }

  /// 진행 중 조립을 취소하고 코어를 분리한다.
  func tearDown() {
    self.assembleTask?.cancel()
    self.assembleTask = nil
    self.core?.detach()
    self.core = nil
  }
}
