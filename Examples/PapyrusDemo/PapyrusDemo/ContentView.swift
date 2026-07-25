import Papyrus
import SwiftUI
import UniformTypeIdentifiers

/// 데모 앱 최상위 화면: 사이드바(목차) + 디테일(리더), 파일 열기·합성 문서 생성 툴바.
struct ContentView: View {
  /// 문서 열기·목차·뷰어 모델을 소유하는 로더.
  @State private var loader = DocumentLoader()

  /// 파일 선택기 표시 여부.
  @State private var isFileImporterPresented = false

  /// 합성 문서 생성 진행 중 여부 (버튼 중복 탭 방지).
  @State private var isGeneratingSyntheticDocument = false

  /// 선택 메뉴 커스텀 항목이 남긴 알림 메시지 (M11 `.papyrusSelectionMenu` 데모용).
  ///
  /// `nil`이 아니면 알림을 띄운다 — 액션 클로저가 실제로 `selectedText`를 수신·사용하는지
  /// 눈으로 확인하는 용도다.
  @State private var selectionNotice: String?

  var body: some View {
    NavigationSplitView {
      OutlineSidebar(items: self.loader.outline, model: self.loader.readerModel)
        .navigationTitle("Outline")
    } detail: {
      let title = self.loader.displayName.isEmpty ? "Papyrus Demo" : self.loader.displayName
      self.detailContent
        .navigationTitle(title)
        .toolbar {
          ToolbarItemGroup(placement: .primaryAction) {
            if self.loader.document != nil {
              SearchBar(model: self.loader.readerModel)
              ReaderToolbar(model: self.loader.readerModel)
            }
          }
          ToolbarItem(placement: .navigation) {
            Button("Open…") {
              self.isFileImporterPresented = true
            }
          }
          ToolbarItem {
            Button("Generate 5,000-Page Document") {
              Task {
                await self.generateSyntheticDocument()
              }
            }
            .disabled(self.isGeneratingSyntheticDocument)
          }
        }
    }
    .fileImporter(
      isPresented: self.$isFileImporterPresented, allowedContentTypes: [.pdf]
    ) { result in
      switch result {
      case let .success(url):
        Task {
          await self.loader.open(url: url)
        }
      case let .failure(error):
        self.loader.errorMessage = error.localizedDescription
      }
    }
    .alert(
      "Unable to Open Document",
      isPresented: Binding(
        get: { self.loader.errorMessage != nil },
        set: { isPresented in
          if !isPresented {
            self.loader.errorMessage = nil
          }
        }
      ),
      presenting: self.loader.errorMessage
    ) { _ in
      Button("OK") {
        self.loader.errorMessage = nil
      }
    } message: { message in
      Text(message)
    }
    .alert(
      "Selection Menu Action",
      isPresented: Binding(
        get: { self.selectionNotice != nil },
        set: { isPresented in
          if !isPresented {
            self.selectionNotice = nil
          }
        }
      ),
      presenting: self.selectionNotice
    ) { _ in
      Button("OK") {
        self.selectionNotice = nil
      }
    } message: { message in
      Text(message)
    }
  }

  /// 디테일 영역: 미열림 안내 / 로딩 중 / 뷰어.
  @ViewBuilder
  private var detailContent: some View {
    if self.isGeneratingSyntheticDocument || self.loader.isLoading {
      ProgressView("Preparing document…")
    } else if let document = self.loader.document {
      PapyrusReader(document: document, model: self.loader.readerModel)
        .papyrusSelectionMenu(self.selectionMenuItems)
    } else {
      ContentUnavailableView(
        "No Document Open", systemImage: "doc",
        description: Text("Open a PDF, or generate a 5,000-page synthetic document to profile.")
      )
    }
  }

  /// M11/M12 선택 메뉴 데모: 텍스트 선택엔 커스텀 항목 2개 + 기본 복사, 영역
  /// 선택(``SelectableRegion``, 페이지 0에 등록됨)엔 metadata를 표시하는 커스텀 항목
  /// 1개를 반환한다. 액션은 모두 액션 실행 시점의 선택 컨텍스트를 실제로 수신·사용해,
  /// `.papyrusSelectionMenu`가 항목마다 정확한 컨텍스트를 전달하는지 눈으로 확인할 수
  /// 있다.
  /// - Parameter context: 선택 컨텍스트 (`.text` 또는 `.region`).
  /// - Returns: 표시할 메뉴 항목.
  private func selectionMenuItems(for context: SelectionContext) -> [SelectionMenuItem] {
    switch context {
    case .text:
      return [
        SelectionMenuItem(title: "Search Selection", systemImage: "magnifyingglass") { context in
          guard case let .text(textContext) = context else {
            return
          }
          // 기존 검색 바 배선(`PapyrusReaderModel.search(_:)`)을 그대로 재사용한다 — 매치
          // 하이라이트·카운트가 갱신되면 selectedText가 그대로 검색에 쓰였다는 뜻이다.
          self.loader.readerModel.search(textContext.selectedText)
        },
        SelectionMenuItem(title: "Show Length", systemImage: "textformat.size") { context in
          guard case let .text(textContext) = context else {
            return
          }
          let text = textContext.selectedText
          let preview = text.count > 40 ? "\(text.prefix(40))…" : text
          self.selectionNotice = "\(text.count) characters selected: “\(preview)”"
        },
        .copy
      ]
    case .region:
      return [
        SelectionMenuItem(title: "Show Region Info", systemImage: "info.circle") { context in
          guard case let .region(region) = context else {
            return
          }
          // 등록 시 넣은 `FigureInfo`로 캐스팅한다 — M12 metadata 왕복 데모.
          let caption = (region.metadata as? FigureInfo)?.caption ?? "(no metadata)"
          self.selectionNotice = "Region “\(region.id)” on page \(region.pageIndex + 1): \(caption)"
        }
      ]
    }
  }

  /// "5,000페이지 생성" 메뉴 동작 — `SyntheticPDF`로 즉석 생성 후 연다.
  private func generateSyntheticDocument() async {
    self.isGeneratingSyntheticDocument = true
    defer {
      self.isGeneratingSyntheticDocument = false
    }
    let data = SyntheticPDF.make(pageCount: 5_000)
    await self.loader.open(data: data, displayName: "Synthetic (5,000 pages)")
  }
}
