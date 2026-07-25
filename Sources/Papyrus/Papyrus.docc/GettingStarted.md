# 시작하기

설치부터 문서 열기, 메타데이터·텍스트·검색, 뷰어 표시까지 처음부터 끝까지 따라가는 흐름입니다.

## 개요

`Papyrus`는 문서를 여는 파싱 코어와 문서를 화면에 그리는 SwiftUI 뷰어로 나뉩니다.
둘 다 `import Papyrus` 하나로 함께 들어옵니다. 아래 예제는 설치 → 열기 → 메타데이터 →
텍스트 → 검색 → 뷰어 순서로, 각 단계가 실제로 어떤 타입을 주고받는지 보여줍니다. 뷰어를
더 깊이 제어하는 방법(적재 상태 관찰, 검색 하이라이트·매치 탐색, 목차 이동, 위치
저장·복원)은 <doc:ViewerGuide>에서 이어집니다.

## 설치

Swift Package Manager로 설치합니다.

```swift
dependencies: [
  .package(url: "https://github.com/jaeho0718/Papyrus.git", branch: "main")
]
```

타겟 의존성에는 `Papyrus`(엄브렐러) 하나만 추가하면 파싱 코어와 뷰어 API가 모두
노출됩니다.

```swift
.target(name: "YourTarget", dependencies: ["Papyrus"])
```

## 요구 사항

- iOS 18+ / iPadOS 18+ / macOS 15+
- Swift 6 (strict concurrency)

## 문서 열기

파일 URL 또는 인메모리 바이트로 문서를 엽니다. 열기는 메모리 맵 기반이라 수천
페이지 문서도 즉시 반환하며, 손상된 파일은 가능한 한 복구하고 `document.openWarnings`에
경고를 남깁니다.

```swift
import Papyrus

let document = try await PapyrusDocument.open(url: pdfURL)

if !document.openWarnings.isEmpty {
  print("복구 경고: \(document.openWarnings)")
}
```

파일 시스템 경로 없이 이미 메모리에 있는 바이트(예: 네트워크로 내려받은 PDF)로도 열 수
있습니다.

```swift
import Foundation
import Papyrus

let document = try await PapyrusDocument.open(data: pdfData)
```

열기는 `PapyrusError`만 던집니다. 실패를 사용자에게 안내하려면 각 케이스를
구분해 처리합니다.

```swift
do {
  let document = try await PapyrusDocument.open(url: pdfURL)
  // 문서 사용
} catch PapyrusError.notAPDF {
  print("PDF 파일이 아닙니다.")
} catch PapyrusError.encryptedDocument(let filterName) {
  print("암호화된 문서입니다 (필터: \(filterName ?? "unknown")). 아직 지원하지 않습니다.")
} catch PapyrusError.damagedDocument {
  print("복구할 수 없을 정도로 손상된 문서입니다.")
} catch {
  // ioError, cancelled 등 나머지 케이스
  print((error as? PapyrusError)?.errorDescription ?? "알 수 없는 오류")
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

검색은 페이지 오름차순, 페이지 안에서는 위치 오름차순으로 결과를 스트리밍합니다.
기본 옵션은 대소문자·발음 구별 부호를 무시합니다.

```swift
for try await result in document.search("papyrus") {
  print("p.\(result.pageIndex): \(result.snippet)")
}
```

대소문자나 발음 구별 부호를 엄격히 구분하려면 `SearchOptions`를 전달합니다.

```swift
let options = SearchOptions(caseSensitive: true, diacriticSensitive: true)
for try await result in document.search("Café", options: options) {
  print("p.\(result.pageIndex): \(result.snippet)")
}
```

`for try await` 루프를 `break`나 취소로 이탈하면 스트림 내부의 남은 페이지 스캔도
함께 취소됩니다 — 첫 매치만 필요하면 그대로 빠져나와도 됩니다.

## 뷰어에 표시하기

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

뷰어의 적재 상태를 지켜보거나, 검색 결과를 뷰어 안에서 하이라이트·이동하거나,
목차 항목을 선택해 이동하거나, 사용자가 보던 위치를 저장했다가 다음에 이어서 열고
싶다면 <doc:ViewerGuide>를 이어서 읽으세요. 텍스트 선택·선택 메뉴는
<doc:SelectingText>, 지속 하이라이트는 <doc:PersistentHighlights>, 스캔 문서의
OCR 연결은 <doc:ConnectingOCR>을 참고하세요.
