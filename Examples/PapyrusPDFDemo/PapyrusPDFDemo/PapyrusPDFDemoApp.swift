import SwiftUI

/// PapyrusPDF 뷰어 데모 앱 진입점 (M6 설계 §7.2).
///
/// 파일 열기·목차 탐색·5,000페이지 합성 문서 생성 UI를 제공한다. 제품 코드는
/// `import PapyrusPDF` 하나만 쓴다 (umbrella 제품, ARCHITECTURE.md 확정).
@main
struct PapyrusPDFDemoApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
