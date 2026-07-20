# Papyrus

수천 페이지급 대용량 PDF를 효율적으로 다루기 위한 macOS / iPadOS / iOS 멀티플랫폼 Swift 패키지.

PDFKit에 의존하지 않습니다. PDF 파일 구조(xref, 객체, 페이지 트리, 메타데이터, 목차, 페이지별 텍스트)는 순수 Swift로 직접 파싱하고, 픽셀 래스터화만 Core Graphics에 위임하는 하이브리드 구조로 — 대용량 파일의 로딩 방식과 메모리 사용을 완전히 제어합니다.

- **파싱 코어**: 메모리 맵 + 지연 객체 로딩. 파일 전체를 메모리에 올리지 않고 제목·저자·생성일·목차·페이지별 텍스트를 추출
- **뷰어**: SwiftUI 뷰 하나로 사용하는 가상화 스크롤 뷰어. 페이지 뷰 재활용 + 커스텀 타일 렌더링으로 수천 페이지에서도 일정한 메모리·스크롤 성능
- **검색**: 추출된 텍스트 기반 문서 내 검색과 뷰어 하이라이트

> 현재 개발 초기 단계입니다. 설계 전문은 [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md)를 참고하세요.

## 요구 사항

- iOS 18+ / iPadOS 18+ / macOS 15+
- Swift 6 (strict concurrency)

## 사용 방법

> 아래 API는 v1 목표 인터페이스이며 구현 진행에 따라 달라질 수 있습니다.

```swift
import Papyrus

// 문서 열기 — 메모리 맵 기반, 수천 페이지도 즉시
let document = try await PapyrusDocument.open(url: pdfURL)

// 메타데이터
let metadata = try await document.metadata
print(metadata.title ?? "무제", metadata.author ?? "작자 미상")

// 목차
let outline = try await document.outline

// 페이지별 텍스트
let text = try await document.text(forPage: 0)

// 검색 (스트리밍 결과)
for try await result in document.search("papyrus") {
  print("p.\(result.pageIndex): \(result.snippet)")
}
```

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

## 기여 방법

### 개발 환경 셋업

클론 후 1회 실행하세요:

```bash
./Scripts/setup.sh
```

git 훅이 활성화되어 커밋 시 SwiftLint(strict)가 자동 실행되고, main/develop 직접 push가 차단됩니다. SwiftLint가 없다면 `brew install swiftlint`.

### 개발 규칙

- **gitflow**: 새 작업은 `develop`에서 `feature/{작업명}` 브랜치로 분기합니다. `develop`/`main` 병합은 **반드시 Pull Request**를 경유하며, CI(`lint-build-test`: SwiftLint + build + test) 통과가 필수입니다. 병합은 merge commit(`--merge`) 방식을 사용합니다.
- **코드 스타일**: [StyleShare swift-style-guide](https://github.com/StyleShare/swift-style-guide)를 따릅니다 (2칸 들여쓰기, 99자 줄 제한 등). `.swiftlint.yml`이 매 커밋 시 강제합니다.
- **문서화**: 모든 공개 API에 DocC 문서 주석(`///`)이 필수입니다 (SwiftLint `missing_docs` 규칙으로 강제). 매 작업마다 문서화를 완결합니다.
- **테스트**: 구현과 테스트(Swift Testing)는 같은 PR에서 완결합니다.

### PR 절차

1. `feature/...` 브랜치에서 작업 후 push
2. `develop` 대상 PR 생성 — 템플릿 체크리스트를 채워주세요
3. CI 통과 확인 후 병합
