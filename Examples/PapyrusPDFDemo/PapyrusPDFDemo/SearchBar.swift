import PapyrusPDF
import SwiftUI

/// 검색 필드 + 매치 카운트 + next/prev/clear (§3.7).
///
/// 상태는 전부 `model.searchState` 관찰 — 데모 쪽 별도 상태 없음(입력 필드 텍스트만 로컬).
/// 공개 API만 사용한다는 기존 데모 원칙을 유지한다 (`import PapyrusPDF`).
struct SearchBar: View {
  /// 대상 뷰어 모델.
  let model: PapyrusPDFReaderModel

  /// 검색 입력 필드 텍스트.
  @State private var queryText = ""

  var body: some View {
    HStack(spacing: 8) {
      TextField("Search", text: self.$queryText, prompt: Text("Search document…"))
        .frame(minWidth: 160)
        .onSubmit {
          self.model.search(self.queryText)
        }

      Text(self.matchCountText)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityLabel("Match count")

      Button {
        self.model.previousMatch()
      } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(self.model.searchState.matchCount == 0)
      .accessibilityLabel("Previous match")

      Button {
        self.model.nextMatch()
      } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(self.model.searchState.matchCount == 0)
      .accessibilityLabel("Next match")

      Button {
        self.queryText = ""
        self.model.clearSearch()
      } label: {
        Image(systemName: "xmark.circle")
      }
      .disabled(self.model.searchState.phase == .idle)
      .accessibilityLabel("Clear search")
    }
  }

  /// 매치 카운트 표시 텍스트 — 검색 중엔 `"n…"`, 그 외엔 `"current+1 / matchCount"`.
  private var matchCountText: String {
    let state = self.model.searchState
    guard state.phase != .idle else {
      return ""
    }
    if case .searching = state.phase {
      return "\(state.matchCount)…"
    }
    guard let currentMatchIndex = state.currentMatchIndex else {
      return "0 / \(state.matchCount)"
    }
    return "\(currentMatchIndex + 1) / \(state.matchCount)"
  }
}
