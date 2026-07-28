import PapyrusPDF
import SwiftUI

/// 목차(북마크) 트리를 표시하고, 탭 시 뷰어를 해당 페이지로 이동시키는 사이드바.
struct OutlineSidebar: View {
  /// 표시할 목차 트리 (최상위 항목들).
  let items: [OutlineItem]

  /// 탐색 대상 뷰어 모델.
  let model: PapyrusPDFReaderModel

  var body: some View {
    if self.items.isEmpty {
      ContentUnavailableView(
        "No Outline", systemImage: "list.bullet.indent",
        description: Text("This document has no table of contents.")
      )
    } else {
      List {
        OutlineChildren(items: self.items, model: self.model)
      }
    }
  }
}

/// 목차 항목 하나의 재귀적 하위 트리 (자식이 있으면 `DisclosureGroup`으로 접고 편다).
private struct OutlineChildren: View {
  /// 이 레벨에서 표시할 항목들.
  let items: [OutlineItem]

  /// 탐색 대상 뷰어 모델.
  let model: PapyrusPDFReaderModel

  var body: some View {
    ForEach(Array(self.items.enumerated()), id: \.offset) { _, item in
      if item.children.isEmpty {
        self.row(for: item)
      } else {
        DisclosureGroup {
          OutlineChildren(items: item.children, model: self.model)
        } label: {
          self.row(for: item)
        }
      }
    }
  }

  /// 목차 항목 한 줄 — 목적지가 있으면 탭해 이동한다.
  /// - Parameter item: 표시할 목차 항목.
  private func row(for item: OutlineItem) -> some View {
    Button {
      if let destination = item.destination {
        self.model.go(to: destination)
      }
    } label: {
      Text(item.title.isEmpty ? "Untitled" : item.title)
    }
    .disabled(item.destination == nil)
  }
}
