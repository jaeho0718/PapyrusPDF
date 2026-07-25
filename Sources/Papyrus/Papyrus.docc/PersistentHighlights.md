# 지속 하이라이트

선택에서 하이라이트를 만들고, 앱 저장소에 보존했다가 복원하는 방법입니다.

## 개요

`Highlight`는 `Codable` 값 타입입니다. 화면에 그리는 일은 뷰어가 맡지만, 언제·
어디에 저장할지는 전적으로 앱의 책임입니다 — `PapyrusReaderModel`은 등록된
하이라이트를 표시할 뿐, 별도의 영속 저장소를 갖지 않습니다.

검색 결과 하이라이트와는 다른 개념입니다. 검색 하이라이트는 현재 검색어에 종속된
일시적 상태로 `model.search(_:)` 호출마다 새로 계산되지만, 지속 하이라이트는
검색과 무관하게 앱이 직접 생성·등록하고 문서를 다시 열 때도 그대로 복원할 수
있습니다.

## 선택에서 하이라이트 만들기

표준 레시피는 세 단계입니다: `makeHighlights(from:color:)`로 현재 선택에서
하이라이트를 만들고, `addHighlights(_:)`로 등록하고, `clearSelection()`으로
선택을 해제합니다. `makeHighlights(from:color:)`가 비동기인 이유는 선택이 걸친
페이지 중 아직 텍스트가 캐시되지 않은 페이지가 있을 수 있기 때문입니다.

```swift
.papyrusSelectionMenu { context in
  guard case let .text(textContext) = context else { return [] }
  return [
    SelectionMenuItem(title: "Highlight", systemImage: "highlighter") { context in
      guard case let .text(textContext) = context else { return }
      Task {
        let highlights = await model.makeHighlights(from: textContext.selection, color: .yellow)
        model.addHighlights(highlights)
        model.clearSelection()
      }
    },
    .copy,
  ]
}
```

`HighlightColor`는 노랑·초록·파랑·분홍·주황 다섯 프리셋을 제공합니다
(`.yellow`, `.green`, `.blue`, `.pink`, `.orange`). 프리셋 외의 색이 필요하면
sRGB 성분과 불투명도(`red`/`green`/`blue`/`alpha`, 모두 0...1)로 직접
생성합니다.

## 저장과 복원

`model.allHighlights`는 등록된 전체 하이라이트를 페이지 오름차순으로 반환하는
스냅숏입니다. JSON으로 인코딩해 원하는 저장소(`UserDefaults`, 파일 등)에
보관합니다.

```swift
let data = try JSONEncoder().encode(model.allHighlights)
```

복원은 반대 순서로 자연스럽게 동작합니다: 모델을 생성하고, 디코딩한
하이라이트를 `addHighlights(_:)`로 주입하면, 리더가 적재를 마치는 즉시 화면에
반영됩니다. 문서 적재 전에 호출해도 안전합니다 — 등록은 보류됐다가 적재 완료
시 재생됩니다.

```swift
let highlights = try JSONDecoder().decode([Highlight].self, from: data)
model.addHighlights(highlights)
```

문서를 교체하면(새 `PapyrusDocument`와 새 `PapyrusReaderModel`) 하이라이트
등록은 리셋됩니다 — 이전 문서의 하이라이트가 새 문서에 남아있지 않습니다.
따라서 여러 문서를 다루는 앱이라면 문서마다 하이라이트 묶음을 별도로
저장하세요. 문서 식별자(파일 URL 등 앱이 정한 키)를 저장 키로 쓰는 방식을
권장합니다.

`Highlight.range`는 선택에서 만들어진 하이라이트에 한해 대응하는 페이지 문자열의
UTF-16 구간이 채워집니다(렌더링에는 쓰이지 않습니다). 앱이 하이라이트를 원본
텍스트와 다시 연결해야 할 때 이 값을 역참조 키로 사용할 수 있습니다.

## 탭으로 하이라이트 편집하기

하이라이트를 탭해서 색을 바꾸거나 삭제하는 UI는, 하이라이트의 quad를
`SelectableRegion`으로 다시 등록해 구현합니다. metadata에 하이라이트의 `id`를
담아 두면 탭 시 어떤 하이라이트인지 역참조할 수 있습니다.

```swift
struct HighlightRef: Sendable {
  let highlightID: String
}

func registerEditableRegions(for pageIndex: Int) {
  let regions = model.highlights(forPage: pageIndex).map { highlight in
    SelectableRegion(
      id: "highlight-\(highlight.id)", pageIndex: pageIndex,
      quad: highlight.quads.first ?? Quad(rect: .zero),
      metadata: HighlightRef(highlightID: highlight.id)
    )
  }
  model.setSelectableRegions(regions, forPage: pageIndex)
}
```

```swift
.papyrusSelectionMenu { context in
  guard case let .region(region) = context,
    let ref = region.metadata as? HighlightRef
  else { return [] }
  return [
    SelectionMenuItem(title: "Remove Highlight", systemImage: "trash") { _ in
      model.removeHighlight(id: ref.highlightID)
    }
  ]
}
```

영역·메뉴 API의 자세한 설명은 <doc:SelectingText>의 "선택 가능 영역"을
참고하세요.

## 성능 특성

하이라이트 등록·제거는 페이지 단위 변경 통지로 처리되므로, 실체화된(화면에
표시 중인) 페이지만 실제로 갱신됩니다 — 수만 건을 한 번에 등록해도 화면 밖
페이지에는 즉시 비용이 들지 않습니다.

`allHighlights`는 전체 등록을 순회하는 스냅숏입니다. 매 프레임 호출하지 말고
저장이 필요한 시점에만 호출하세요.
