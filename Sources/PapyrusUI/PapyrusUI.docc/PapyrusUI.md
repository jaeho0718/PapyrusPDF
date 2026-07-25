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

### 선택 메뉴

- ``SelectionContext``
- ``TextSelectionContext``
- ``SelectionMenuItem``
- ``SelectionMenuItemsBuilder``
- ``SwiftUICore/View/papyrusSelectionMenu(_:)``
