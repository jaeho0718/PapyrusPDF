# 뷰어 심화

`PapyrusReader`와 `PapyrusReaderModel`로 적재 상태를 관찰하고, 목차로 이동하고, 검색
결과를 하이라이트·탐색하고, 읽던 위치를 저장·복원하는 방법입니다. <doc:GettingStarted>의
"뷰어에 표시하기"에서 이어집니다.

## 개요

`PapyrusReaderModel`은 뷰어를 직접 소유하지 않는 관찰·제어용 모델입니다. `PapyrusReader`에
전달하면 뷰가 내부적으로 연결하며, 이후 같은 모델 인스턴스를 검색창·목차 사이드바 같은
다른 뷰와 공유해 뷰어를 원격 제어할 수 있습니다. `@Observable`이므로 SwiftUI 뷰 본문에서
모델의 프로퍼티를 읽기만 해도 자동으로 갱신됩니다.

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

모델의 탐색·검색 메서드(`goToPage`, `go(to:)`, `search`, `restore`)는 `PapyrusReader`가
아직 문서 적재를 마치기 전에 호출해도 안전합니다. 요청은 보류됐다가 적재가 끝나는 즉시
한 번 재생됩니다 — "화면을 열자마자 특정 페이지로 이동" 같은 패턴이 그대로 동작합니다.

## 적재 상태 관찰

`model.loadState`는 뷰어가 문서를 표시할 준비가 됐는지 알려줍니다. 페이지 수·검색창
활성화 여부 같은 주변 UI를 적재 완료 여부에 맞춰 제어할 때 사용합니다.

```swift
switch model.loadState {
case .loading:
  ProgressView()
case .ready:
  Text("\(model.pageCount)페이지")
case let .failed(error):
  Text(error.errorDescription ?? "문서를 열 수 없습니다.")
}
```

적재가 끝난 뒤에는 `model.pageCount`, `model.currentPageIndex`, `model.visiblePageRange`,
`model.zoomScale`이 스크롤·줌에 따라 계속 갱신됩니다.

## 목차로 이동하기

`document.outline`에서 얻은 항목의 `destination`을 그대로 넘기면 됩니다. 목적지가 없는
항목(구분선 등)은 `destination`이 `nil`이므로 건너뜁니다.

```swift
let outline = try await document.outline

// 사용자가 목차 사이드바에서 항목을 선택했다고 가정합니다.
if let destination = outline.first?.destination {
  model.go(to: destination)
}
```

페이지 번호를 직접 입력받는 UI라면 `goToPage(_:animated:)`를 씁니다.

```swift
model.goToPage(41, animated: true)
```

## 검색과 하이라이트

`model.search(_:options:)`를 호출하면 뷰어가 내부적으로 페이지를 스캔하며 매치를
자동으로 하이라이트하고, 첫 매치가 나오는 즉시 그 위치로 스크롤합니다 — 하이라이트를
직접 그리는 API는 따로 없습니다. 검색창 UI는 `model.searchState`를 관찰해 진행 상태와
매치 수를 보여주면 됩니다.

```swift
model.search("papyrus")
```

```swift
switch model.searchState.phase {
case .idle:
  EmptyView()
case .searching:
  ProgressView()
case .completed:
  Text("\(model.searchState.matchCount)건 검색됨")
case let .failed(error):
  Text(error.errorDescription ?? "검색에 실패했습니다.")
}
```

다음/이전 버튼은 현재 매치를 화면 중앙으로 스크롤하며 이동합니다(양끝에서 랩어라운드).

```swift
model.nextMatch()
model.previousMatch()
```

검색을 끝내려면 하이라이트와 매치 상태를 함께 지웁니다.

```swift
model.clearSearch()
```

`search(_:options:)`는 호출 즉시 이전 검색을 취소하고 새 검색을 시작하며 자체
디바운스는 하지 않습니다 — 검색창에 타이핑할 때마다 매 키 입력을 그대로 전달하면
매번 처음부터 다시 스캔하므로, 디바운스가 필요하면 호출하는 쪽에서 적용합니다.

## 읽던 위치 저장·복원

`ReaderPosition`은 `Codable`이라 `UserDefaults`나 파일에 그대로 인코딩해 보관할 수
있습니다. 화면이 사라지거나 앱이 백그라운드로 전환되는 시점에 저장해 둡니다.

```swift
if let position = model.capturePosition() {
  let data = try? JSONEncoder().encode(position)
  // data를 원하는 저장소에 보관합니다.
}
```

다음에 같은 문서를 열 때 저장해 둔 위치를 복원합니다. 모델을 만든 직후, 뷰어가
적재를 마치기 전에 호출해도 적재 완료 시점에 자동으로 적용됩니다.

```swift
if let data = savedPositionData,
  let position = try? JSONDecoder().decode(ReaderPosition.self, from: data) {
  model.restore(position)
}
```
