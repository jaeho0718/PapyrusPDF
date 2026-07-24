# 시작하기

문서를 열고, 메타데이터·텍스트·검색을 읽고, 뷰어에 표시하기까지의 최소 흐름.

## 개요

`Papyrus`는 문서를 여는 파싱 코어와 문서를 화면에 그리는 SwiftUI 뷰어로 나뉩니다.
둘 다 `import Papyrus` 하나로 함께 들어옵니다. 아래 예제는 열기 → 메타데이터 →
텍스트 → 검색 → 뷰어 순서로, 각 단계가 실제로 어떤 타입을 주고받는지 보여줍니다.

## 문서 열기

파일 URL 또는 인메모리 바이트로 문서를 엽니다. 열기는 메모리 맵 기반이라 수천
페이지 문서도 즉시 반환하며, 손상된 파일은 가능한 한 복구하고 `openWarnings`에
경고를 남깁니다.

```swift
import Papyrus

let document = try await PapyrusDocument.open(url: pdfURL)

if !document.openWarnings.isEmpty {
  print("복구 경고: \(document.openWarnings)")
}
```

## 메타데이터와 목차

```swift
let metadata = try await document.metadata
print(metadata.title ?? "무제", metadata.author ?? "작자 미상")

let outline = try await document.outline
```

## 페이지별 텍스트

```swift
let pageCount = try await document.pageCount
let text = try await document.text(forPage: 0)
print(text.string)
```

## 검색

검색은 페이지 오름차순으로 결과를 스트리밍합니다.

```swift
for try await result in document.search("papyrus") {
  print("p.\(result.pageIndex): \(result.snippet)")
}
```

## 뷰어

`PapyrusReader`에 열린 문서와 `PapyrusReaderModel`을 전달하면 가상화 스크롤
뷰어가 표시됩니다. 같은 모델로 목차 이동·검색·줌을 제어합니다.

```swift
import Papyrus
import SwiftUI

struct ReaderScreen: View {
  let document: PapyrusDocument
  @State private var model = PapyrusReaderModel()

  var body: some View {
    PapyrusReader(document: document, model: model)
  }
}
```
