import Foundation
import Papyrus
import SwiftUI

/// 뷰어 상단 툴바: 페이지 표시("n / N")·페이지 이동 입력·줌 ±·위치 저장/복원.
///
/// `PapyrusReaderModel`은 직접적인 `setZoom` API를 노출하지 않는다(줌은 스크롤 호스트의
/// 핀치/매그니피케이션이 원천 — ARCHITECTURE 확정). 줌 ± 버튼은 `capturePosition()` →
/// 배율만 바꾼 `ReaderPosition` → `restore(_:)` 경로로 동일 효과를 낸다(공개 API만 사용).
struct ReaderToolbar: View {
  /// 대상 뷰어 모델.
  let model: PapyrusReaderModel

  /// 페이지 이동 입력 필드 텍스트.
  @State private var pageFieldText = ""

  /// 위치 저장에 쓰는 `UserDefaults` 키.
  private static let savedPositionKey = "PapyrusDemo.savedReaderPosition"

  /// 줌 버튼 한 번의 배율 변화 (√2 — M5 스케일 버킷 간격과 정합).
  private static let zoomStep: CGFloat = 1.414_213_56

  var body: some View {
    HStack(spacing: 12) {
      Text("\(self.model.currentPageIndex + 1) / \(max(self.model.pageCount, 1))")
        .monospacedDigit()
        .accessibilityLabel("Current page")

      TextField("Page", text: self.$pageFieldText, prompt: Text("Go to…"))
        .frame(width: 70)
        .onSubmit(self.goToTypedPage)

      Button {
        self.adjustZoom(by: 1 / Self.zoomStep)
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .accessibilityLabel("Zoom out")

      Button {
        self.adjustZoom(by: Self.zoomStep)
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .accessibilityLabel("Zoom in")

      Button("Save Position", action: self.savePosition)
      Button("Restore Position", action: self.restorePosition)
    }
  }

  /// 입력 필드의 1 기반 페이지 번호로 이동한다.
  private func goToTypedPage() {
    guard let typedPage = Int(self.pageFieldText) else {
      return
    }
    self.model.goToPage(typedPage - 1)
  }

  /// 현재 위치를 포착해 배율만 바꾼 뒤 복원한다 (goToPage/restore만으로 줌 구현).
  /// - Parameter factor: 곱할 배율.
  private func adjustZoom(by factor: CGFloat) {
    guard let current = self.model.capturePosition() else {
      return
    }
    let adjusted = ReaderPosition(
      pageIndex: current.pageIndex, normalizedOffset: current.normalizedOffset,
      zoomScale: current.zoomScale * factor
    )
    self.model.restore(adjusted)
  }

  /// 현재 위치를 `UserDefaults`에 JSON으로 저장한다.
  private func savePosition() {
    guard let position = self.model.capturePosition(),
      let data = try? JSONEncoder().encode(position)
    else {
      return
    }
    UserDefaults.standard.set(data, forKey: Self.savedPositionKey)
  }

  /// `UserDefaults`에 저장된 위치를 복원한다 (없으면 무시).
  private func restorePosition() {
    guard let data = UserDefaults.standard.data(forKey: Self.savedPositionKey),
      let position = try? JSONDecoder().decode(ReaderPosition.self, from: data)
    else {
      return
    }
    self.model.restore(position)
  }
}
