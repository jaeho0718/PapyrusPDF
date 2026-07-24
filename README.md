# Papyrus

[![CI](https://github.com/jaeho0718/Papyrus/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/jaeho0718/Papyrus/actions/workflows/ci.yml)

수천 페이지급 대용량 PDF를 효율적으로 다루기 위한 macOS / iPadOS / iOS 멀티플랫폼 Swift 패키지.

## 왜 Papyrus인가

PDFKit에 의존하지 않습니다. PDF 파일 구조(xref, 객체, 페이지 트리, 메타데이터, 목차, 페이지별 텍스트)는 순수 Swift로 직접 파싱하고, 픽셀 래스터화만 Core Graphics에 위임하는 하이브리드 구조로 — 대용량 파일의 로딩 방식과 메모리 사용을 완전히 제어합니다.

v1 표면은 안정 상태입니다. 설계 전문은 [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md)를 참고하세요.

## 특징

- **파싱 코어**: 메모리 맵 + 지연 객체 로딩. 파일 전체를 메모리에 올리지 않고 제목·저자·생성일·목차·페이지별 텍스트를 추출
- **뷰어**: SwiftUI 뷰 하나로 사용하는 가상화 스크롤 뷰어. 페이지 뷰 재활용 + 커스텀 타일 렌더링으로 수천 페이지에서도 일정한 메모리·스크롤 성능
- **검색**: 추출된 텍스트 기반 문서 내 검색과 뷰어 하이라이트
- **손상 내성**: 어떤 입력에도 크래시·행 없음 — 퍼즈 코퍼스로 상시 검증. 복구 가능한 손상은 `openWarnings`로 보고

## 요구 사항

- iOS 18+ / iPadOS 18+ / macOS 15+
- Swift 6 (strict concurrency)

## 설치

Swift Package Manager로 설치합니다.

```swift
dependencies: [
  .package(url: "https://github.com/jaeho0718/Papyrus.git", branch: "main")
]
```

타겟 의존성에는 `Papyrus`(umbrella) 하나만 추가하면 파싱 코어와 뷰어 API가 모두 노출됩니다.

```swift
.target(name: "YourTarget", dependencies: ["Papyrus"])
```

## 빠른 시작

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

## v1 지원 범위

| 지원 | 미지원 (v1) |
|---|---|
| xref 전 변형·증분 업데이트·손상 복구 | 암호화 문서 (감지 후 명시적 에러) |
| 메타데이터(Info+XMP)·목차·페이지 텍스트 | 사전정의 CJK CMap (위치 유지, U+FFFD 표시) |
| 검색+하이라이트, 세로 스크롤+줌 뷰어 | 텍스트 선택·복사, 주석, 썸네일 |

## 손상 문서 다루기

`open`은 손상된 파일도 가능한 한 복구해 성공을 반환하며, 복구가 개입했다면 `openWarnings`로 알립니다.

```swift
let document = try await PapyrusDocument.open(url: pdfURL)
for warning in document.openWarnings {
  print(warning) // 예: "XRef offsets were biased by 12 bytes and corrected."
}
```

"경고하되 실패하지 않는" 것이 기본 복구 정책입니다 — 구조가 스펙을 어겨도 /Root를 확정할 수 있는 한 문서를 열고, 확정이 불가능한 경우에만 `PapyrusError.damagedDocument`를 던집니다. 어떤 입력을 넣어도 크래시나 행(hang)이 발생하지 않음은 퍼즈 하네스로 상시 검증됩니다(`Tests/PapyrusTests/Fuzz`).

## 성능

합성 픽스처, Apple Silicon 로컬 측정(release 빌드) 기준 설계 목표치입니다.

- 5,000페이지 문서 열기(`open` + `pageCount`) < 250ms
- warm `page(at:)` 호출 < 1ms
- 전체 문서 검색 스캔(매치 없음) < 200ms

메모리 정책: 타일 캐시 예산은 `min(256MB, 물리 메모리/8)`이며 LRU로 축출됩니다. 메모리 압박 시 예산이 반감(warning)되거나 타일이 전량 퍼지(critical)됩니다.

## 문서

DocC 문서를 생성합니다.

```bash
swift package generate-documentation --target Papyrus
```

아키텍처·동시성 모델·설계 근거 전문은 [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md)를 참고하세요.

## 데모 앱

`Examples/PapyrusDemo`는 별도 Xcode 프로젝트로, 실제 뷰어 동작과 Instruments 프로파일링(스크롤·메모리)을 확인할 수 있습니다.

## 기여 방법

### 개발 환경 셋업

클론 후 1회 실행하세요:

```bash
./Scripts/setup.sh
```

git 훅이 활성화되어 커밋 시 SwiftLint(strict)가 자동 실행되고, main/develop 직접 push가 차단됩니다. SwiftLint가 없다면 `brew install swiftlint`.

### 개발 규칙

- **gitflow**: 새 작업은 `develop`에서 `feature/{작업명}` 브랜치로 분기합니다. `develop`/`main` 병합은 **반드시 Pull Request**를 경유하며, CI(`lint-build-test`: SwiftLint + build + test + DocC) 통과가 필수입니다. 병합은 merge commit(`--merge`) 방식을 사용합니다.
- **코드 스타일**: [StyleShare swift-style-guide](https://github.com/StyleShare/swift-style-guide)를 따릅니다 (2칸 들여쓰기, 99자 줄 제한 등). `.swiftlint.yml`이 매 커밋 시 강제합니다.
- **문서화**: 모든 공개 API에 DocC 문서 주석(`///`)이 필수입니다 (SwiftLint `missing_docs` 규칙으로 강제). 매 작업마다 문서화를 완결합니다.
- **테스트**: 구현과 테스트(Swift Testing)는 같은 PR에서 완결합니다.

### PR 절차

1. `feature/...` 브랜치에서 작업 후 push
2. `develop` 대상 PR 생성 — 템플릿 체크리스트를 채워주세요
3. CI 통과 확인 후 병합

## 라이선스

미정.
