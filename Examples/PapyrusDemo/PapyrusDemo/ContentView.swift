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
  }

  /// 디테일 영역: 미열림 안내 / 로딩 중 / 뷰어.
  @ViewBuilder
  private var detailContent: some View {
    if self.isGeneratingSyntheticDocument || self.loader.isLoading {
      ProgressView("Preparing document…")
    } else if let document = self.loader.document {
      PapyrusReader(document: document, model: self.loader.readerModel)
    } else {
      ContentUnavailableView(
        "No Document Open", systemImage: "doc",
        description: Text("Open a PDF, or generate a 5,000-page synthetic document to profile.")
      )
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
