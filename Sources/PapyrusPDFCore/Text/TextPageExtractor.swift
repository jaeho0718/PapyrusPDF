/// 추출 CPU 단계의 합성점 — 액터 밖(`@concurrent`) 실행.
package enum TextPageExtractor {
  /// 해석 → 조립. 취소 협조: 실행 전후로 `Task.isCancelled`를 확인하고 취소 시 부분
  /// 결과 대신 빈 결과를 반환한다 (공유 태스크라 실제 취소는 드물다).
  /// - Parameter input: 사전 해소된 페이지 추출 입력.
  /// - Returns: 조립된 페이지 텍스트 스냅숏 (취소 시 빈 스냅숏).
  @concurrent
  package static func extract(_ input: PageExtractionInput) async -> PageTextContent {
    guard !Task.isCancelled else {
      return PageTextContent(pageIndex: input.pageIndex, string: "", runs: [])
    }
    let runs = ContentStreamInterpreter.run(input)
    guard !Task.isCancelled else {
      return PageTextContent(pageIndex: input.pageIndex, string: "", runs: [])
    }
    return TextAssembler.assemble(runs, pageIndex: input.pageIndex)
  }
}
