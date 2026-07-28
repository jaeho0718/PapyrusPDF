# ``PapyrusPDFRendering``

PDF 페이지를 Core Graphics로 래스터화하는 렌더링 파이프라인입니다.

내부적으로는 뷰어의 타일·프리뷰 캐시를 구동하는 워커 풀을 제공합니다. 공개 표면은
페이지 전체를 이미지 한 장으로 렌더하는 ``PageImageRenderer``입니다 — OCR처럼 뷰어
바깥에서 페이지 래스터가 필요한 작업을 위한 것입니다.

## Topics

### 페이지 이미지 렌더링

- ``PageImageRenderer``
- ``RenderError``
