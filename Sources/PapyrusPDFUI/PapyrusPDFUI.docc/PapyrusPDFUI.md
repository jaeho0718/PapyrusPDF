# ``PapyrusPDFUI``

SwiftUI 퍼사드와 가상화 스크롤 뷰어.

``PapyrusPDFReader``는 열린 `PapyrusPDFDocument`(`PapyrusPDFCore`)를 받아 페이지 뷰 재활용 +
커스텀 타일 렌더링으로 수천 페이지 문서도 일정한 메모리·스크롤 성능으로 표시합니다.
``PapyrusPDFReaderModel``로 탐색·검색을 제어하고 적재·검색 상태를 관찰합니다.

## Topics

### 뷰어

- ``PapyrusPDFReader``
- ``PapyrusPDFReaderModel``

### 상태와 위치

- ``ReaderLoadState``
- ``ReaderSearchState``
- ``ReaderPosition``

### 줌 제어

- ``PapyrusPDFReaderModel/setZoom(_:animated:)``
- ``PapyrusPDFReaderModel/fitWidth(animated:)``
- ``PapyrusPDFReaderModel/zoomRange``
- ``PapyrusPDFReaderModel/zoomScale``

### 텍스트 선택

- ``PapyrusPDFReaderModel/selection``
- ``PapyrusPDFReaderModel/select(_:)``
- ``PapyrusPDFReaderModel/clearSelection()``
- ``PapyrusPDFReaderModel/selectedString()``

### 선택 메뉴

- ``SelectionContext``
- ``TextSelectionContext``
- ``SelectionMenuItem``
- ``SelectionMenuItemsBuilder``
- ``SwiftUICore/View/papyrusPDFSelectionMenu(_:)``

### 선택 가능 영역

- ``SelectableRegion``
- ``PapyrusPDFReaderModel/setSelectableRegions(_:forPage:)``
- ``PapyrusPDFReaderModel/selectableRegions(forPage:)``
- ``PapyrusPDFReaderModel/clearSelectableRegions()``
- ``PapyrusPDFReaderModel/selectedRegion``

### 지속 하이라이트

- ``Highlight``
- ``HighlightColor``
- ``PapyrusPDFReaderModel/addHighlights(_:)``
- ``PapyrusPDFReaderModel/addHighlight(_:)``
- ``PapyrusPDFReaderModel/removeHighlight(id:)``
- ``PapyrusPDFReaderModel/removeAllHighlights()``
- ``PapyrusPDFReaderModel/highlights(forPage:)``
- ``PapyrusPDFReaderModel/allHighlights``
- ``PapyrusPDFReaderModel/makeHighlights(from:color:)``
