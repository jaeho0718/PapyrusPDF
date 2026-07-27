import PapyrusPDF
import PapyrusPDFRendering
import PapyrusPDFUI
import Testing

/// `PapyrusPDF` umbrella 타겟의 `@_exported` 재수출 배선과 타겟 그래프 연결을 검증한다.
struct UmbrellaSmokeTests {
  /// S1: `import PapyrusPDF`만으로 `PapyrusPDFCore`를 직접 import하지 않고도
  /// `PapyrusPDFVersion.current`에 접근할 수 있어야 한다 (`@_exported` 재수출 배선).
  @Test func papyrusPDFVersionIsExportedThroughUmbrella() {
    #expect(PapyrusPDFVersion.current == "0.1.0")
  }

  /// S2: `PapyrusPDFRendering`/`PapyrusPDFUI`가 실제로 빌드·링크되어 시드 마커에 접근할 수 있다.
  @Test func moduleGraphLinksRenderingAndUI() {
    #expect(PapyrusPDFRendering.ModuleInfo.name == "PapyrusPDFRendering")
    #expect(PapyrusPDFUI.ModuleInfo.name == "PapyrusPDFUI")
  }
}
