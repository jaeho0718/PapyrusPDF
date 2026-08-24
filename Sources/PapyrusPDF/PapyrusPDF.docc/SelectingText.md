# 텍스트 선택과 메뉴

드래그로 텍스트를 선택·복사하고, 선택 메뉴를 커스터마이징하고, 개발자 정의 영역을
선택 가능하게 만드는 방법입니다.

## 개요

`PapyrusPDFReader`는 별도 설정 없이도 네이티브에 가까운 텍스트 선택을 제공합니다.
iOS에서는 롱프레스로 단어를 선택한 뒤 핸들을 드래그해 범위를 조정하고, macOS에서는
마우스 드래그(더블클릭은 단어, 트리플클릭은 줄 단위)로 선택한 뒤 `Cmd+C`로
복사합니다. 선택은 페이지 경계를 넘나들 수 있습니다.

기본 선택 메뉴는 복사 항목 하나입니다 — 커스터마이징 방법은 아래 "선택 메뉴
커스터마이징"에서 다룹니다.

내장 텍스트가 없는 스캔 문서에서도 선택이 동작하게 하려면 <doc:ConnectingOCR>을
참고하세요.

## 선택 관찰과 제어

`PapyrusPDFReaderModel.selection`은 현재 선택을 담은 `@Observable` 프로퍼티입니다.
선택이 바뀔 때마다 갱신되므로, SwiftUI 뷰 본문에서 읽기만 해도 선택에 반응하는
UI를 만들 수 있습니다.

```swift
if let selection = model.selection {
  Text("페이지 \(selection.pageRange.lowerBound + 1)부터 선택됨")
}
```

`clearSelection()`으로 선택을 해제하고(메뉴도 함께 닫힙니다), `select(_:)`로
프로그램적으로 선택을 지정할 수 있습니다. 문서 적재가 끝나기 전에 호출해도
안전합니다 — 요청은 보류됐다가 적재 완료 직후 재생됩니다. 선택된 문자열이
필요하면 `selectedString()`을 호출합니다. 이 메서드는 페이지 경계를 넘는 선택의
텍스트를 개행으로 이어붙여야 할 수 있으므로 비동기입니다.

```swift
let text = await model.selectedString()
```

선택 좌표는 `TextSelection`(시작·끝 `TextPosition`)으로 표현됩니다. 각 위치는
페이지 인덱스와 그 페이지 문자열의 UTF-16 오프셋으로 이루어지며, 검색 결과인
`SearchResult.range`와 동일한 좌표계를 씁니다. `TextSelection`은 `Codable`이므로
선택 상태를 그대로 저장했다가 나중에 복원할 수도 있습니다.

검색 결과를 그대로 선택하고 싶다면 결과의 위치로 `TextSelection`을 만들어
`select(_:)`에 넘깁니다.

```swift
for try await result in document.search("papyrus") {
  let selection = TextSelection(
    start: TextPosition(pageIndex: result.pageIndex, utf16Offset: result.range.lowerBound),
    end: TextPosition(pageIndex: result.pageIndex, utf16Offset: result.range.upperBound)
  )
  model.select(selection)
  break
}
```

## 선택 메뉴 커스터마이징

`.papyrusPDFSelectionMenu` modifier로 `PapyrusPDFReader`가 표시할 메뉴 항목을 지정합니다.
빌더 클로저는 선택이 확정될 때마다 `SelectionContext`를 받아 `[SelectionMenuItem]`을
반환합니다. 컨텍스트는 텍스트 선택(`.text`)과 선택 가능 영역(`.region`) 두 케이스로
나뉘므로, 상황에 맞는 항목을 분기해 구성할 수 있습니다.

```swift
PapyrusPDFReader(document: document, model: model)
  .papyrusPDFSelectionMenu { context in
    switch context {
    case let .text(textContext):
      return [
        SelectionMenuItem(title: "Search", systemImage: "magnifyingglass") { context in
          guard case let .text(textContext) = context else { return }
          model.search(textContext.selectedText)
        },
        .copy,
      ]
    case .region:
      return []
    }
  }
```

`.copy`는 텍스트 선택 문자열을 시스템 페이스트보드에 복사하는 기본 항목입니다 —
커스텀 메뉴에서도 복사를 유지하려면 배열에 포함하세요. modifier를 지정하지 않으면
텍스트 선택은 복사 항목만, 영역 선택은 메뉴 없음이 기본값입니다. 빌더가 빈 배열을
반환하면 그 선택에는 메뉴가 표시되지 않습니다.

메뉴 항목의 액션은 메인 액터에서 실행되며, 실행 시점에 다시 평가된 선택
컨텍스트를 받습니다 — 메뉴가 표시된 뒤 선택이 바뀌었더라도 액션은 항상 최신
컨텍스트를 봅니다.

## 선택 가능 영역

`SelectableRegion`은 텍스트와 무관하게 개발자가 정의한 탭(클릭) 가능 영역입니다.
도표·이미지·주석 아이콘처럼 텍스트가 아닌 콘텐츠에 선택·메뉴 파이프라인을 그대로
연결할 때 사용합니다. `setSelectableRegions(_:forPage:)`로 페이지 단위로
등록합니다 — 같은 페이지를 다시 등록하면 이전 등록을 완전히 대체합니다. 문서
적재 전에 호출해도 안전합니다.

```swift
struct FigureInfo: Sendable {
  let caption: String
}

model.setSelectableRegions(
  [SelectableRegion(
    id: "figure-1", pageIndex: 3, quad: Quad(rect: figureRect),
    metadata: FigureInfo(caption: "그림 1")
  )],
  forPage: 3
)
```

영역을 탭하면 선택 강조가 표시되고 메뉴가 열립니다 — 텍스트 선택과 동일한
오버레이·메뉴 파이프라인을 공유하며, 텍스트 선택과는 상호 배타입니다(하나를
선택하면 다른 하나는 자동으로 해제됩니다).

영역이 선택되면 `selectedRegion`과 같은 통지에서 `selectedRegionAnchor`에 그
영역의 앵커 사각형이 함께 실립니다. 좌표계는 `PapyrusPDFReader`가 차지한 뷰의
좌표계라, SwiftUI `popover(attachmentAnchor:)` 같은 API에 변환 없이 그대로 쓸 수
있습니다. 값은 **선택 순간의 스냅숏**이며 이후 스크롤·줌을 따라 갱신되지
않습니다 — 선택이 해제되거나 텍스트 선택으로 전환되면 `selectedRegion`과 함께
`nil`이 됩니다.

quad는 PDF 페이지 공간 좌표입니다. 축 정렬 사각형이면 `Quad(rect:)` 편의
이니셜라이저로 간단히 만들 수 있습니다. 겹치는 영역이 있으면 나중에 등록된(배열
뒤쪽) 영역이 우선합니다 — 등록 순서가 곧 z-순서입니다.

`metadata`는 임의의 `Sendable` 값입니다. 메뉴 액션에서 등록 시 넣은 타입으로
캐스팅해 사용합니다.

```swift
.papyrusPDFSelectionMenu { context in
  guard case let .region(region) = context else { return [] }
  return [
    SelectionMenuItem(title: "Show Info", systemImage: "info.circle") { context in
      guard case let .region(region) = context,
        let info = region.metadata as? FigureInfo
      else { return }
      print(info.caption)
    }
  ]
}
```

수천 페이지 문서에서 영역이 많다면, 모든 페이지에 미리 등록하는 대신
`model.visiblePageRange`를 관찰해 화면에 보이는 페이지에만 지연 등록하는 편이
메모리 친화적입니다.

```swift
for pageIndex in model.visiblePageRange where model.selectableRegions(forPage: pageIndex).isEmpty {
  model.setSelectableRegions(regions(forPage: pageIndex), forPage: pageIndex)
}
```
