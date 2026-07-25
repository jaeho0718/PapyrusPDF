# ``PapyrusUI``

SwiftUI 퍼사드와 가상화 스크롤 뷰어.

``PapyrusReader``는 열린 `PapyrusDocument`(`PapyrusCore`)를 받아 페이지 뷰 재활용 +
커스텀 타일 렌더링으로 수천 페이지 문서도 일정한 메모리·스크롤 성능으로 표시합니다.
``PapyrusReaderModel``로 탐색·검색을 제어하고 적재·검색 상태를 관찰합니다.

## Topics

### 뷰어

- ``PapyrusReader``
- ``PapyrusReaderModel``

### 상태와 위치

- ``ReaderLoadState``
- ``ReaderSearchState``
- ``ReaderPosition``

### 텍스트 선택

- ``PapyrusReaderModel/selection``
- ``PapyrusReaderModel/select(_:)``
- ``PapyrusReaderModel/clearSelection()``
- ``PapyrusReaderModel/selectedString()``

### 선택 메뉴

- ``SelectionContext``
- ``TextSelectionContext``
- ``SelectionMenuItem``
- ``SelectionMenuItemsBuilder``
- ``SwiftUICore/View/papyrusSelectionMenu(_:)``

### 선택 가능 영역

- ``SelectableRegion``
- ``PapyrusReaderModel/setSelectableRegions(_:forPage:)``
- ``PapyrusReaderModel/selectableRegions(forPage:)``
- ``PapyrusReaderModel/clearSelectableRegions()``
- ``PapyrusReaderModel/selectedRegion``

### 지속 하이라이트

- ``Highlight``
- ``HighlightColor``
- ``PapyrusReaderModel/addHighlights(_:)``
- ``PapyrusReaderModel/addHighlight(_:)``
- ``PapyrusReaderModel/removeHighlight(id:)``
- ``PapyrusReaderModel/removeAllHighlights()``
- ``PapyrusReaderModel/highlights(forPage:)``
- ``PapyrusReaderModel/allHighlights``
- ``PapyrusReaderModel/makeHighlights(from:color:)``
