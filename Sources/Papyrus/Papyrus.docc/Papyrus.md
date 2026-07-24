# ``Papyrus``

수천 페이지급 대용량 PDF를 효율적으로 다루기 위한 멀티플랫폼 Swift 패키지.

PDFKit에 의존하지 않는 하이브리드 구조입니다 — 파일 구조(xref, 객체, 페이지 트리,
메타데이터, 목차, 페이지별 텍스트)는 순수 Swift로 직접 파싱하고, 픽셀 래스터화만
Core Graphics에 위임합니다. `import Papyrus` 하나로 파싱 코어(`PapyrusCore`)와
SwiftUI 뷰어(`PapyrusUI`)의 공개 API 전체를 사용할 수 있습니다.

빠르게 시작하려면 <doc:GettingStarted>를 참고하세요. 각 모듈의 상세 API는
`PapyrusCore`·`PapyrusUI` 타겟 문서에 있고, 내부 구조와 설계 원칙은
<doc:Architecture>에 정리되어 있습니다.

## Topics

### 시작하기

- <doc:GettingStarted>
- <doc:Architecture>
