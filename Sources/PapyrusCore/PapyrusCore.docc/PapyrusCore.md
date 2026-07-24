# ``PapyrusCore``

PDF 파일 구조를 순수 Swift로 파싱하는 코어.

파일 전체를 메모리에 올리지 않고 메모리 맵 + 지연 객체 로딩으로 문서를 엽니다. xref의
모든 변형(클래식 테이블, xref 스트림, 객체 스트림, 하이브리드, 증분 업데이트)과 흔한
구조적 손상을 관용적으로 복구하며, 복구가 개입했을 때는 ``OpenWarning``으로 알립니다.

## Topics

### 문서 열기

- ``PapyrusDocument``
- ``OpenWarning``
- ``PapyrusError``
- ``PapyrusVersion``

### 페이지 기하

- ``PageInfo``
- ``PageRotation``
- ``Quad``

### 메타데이터와 목차

- ``DocumentMetadata``
- ``OutlineItem``
- ``OutlineDestination``

### 페이지 텍스트

- ``PageTextContent``
- ``TextRun``

### 검색

- ``SearchOptions``
- ``SearchResult``
