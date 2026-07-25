# Papyrus

[![CI](https://github.com/jaeho0718/Papyrus/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/jaeho0718/Papyrus/actions/workflows/ci.yml)

----

Papyrus는 수천 페이지급 대용량 PDF를 macOS·iPadOS·iOS에서 다루기 위한 순수 Swift
패키지입니다. PDFKit에 의존하지 않고, PDF 파일 구조(xref, 객체, 페이지 트리,
메타데이터, 목차, 페이지별 텍스트)는 직접 파싱하고 픽셀 래스터화만 Core Graphics에
위임하는 하이브리드 구조를 취합니다 — 이 분리 덕분에 대용량 파일을 여는 방식과
메모리 사용량을 패키지가 전적으로 제어합니다.

파싱 코어는 메모리 맵과 지연 객체 로딩으로 파일 전체를 메모리에 올리지 않고,
뷰어는 페이지 뷰를 재활용하는 가상화 스크롤과 커스텀 타일 렌더링으로 수천
페이지에서도 일정한 메모리와 스크롤 성능을 유지합니다. 검색은 추출된 텍스트를
기반으로 결과를 스트리밍하며 뷰어 안에서 바로 하이라이트됩니다. 어떤 입력에도
크래시나 행 없이 열리도록 손상 문서를 상시 퍼즈 테스트로 검증하며, 복구가
개입한 경우에는 실패 대신 경고로 알립니다.

뷰어는 네이티브와 같은 텍스트 드래그 선택·복사를 제공하고, 선택 메뉴는 항목
배열로 커스터마이징합니다. 개발자가 정의한 영역을 탭 선택 대상으로 등록할 수
있고, 스캔 PDF에는 OCR 결과를 텍스트 공급원으로 주입해 선택·검색이 그 위에서
동작하며, `Codable` 하이라이트로 형광펜 상태를 앱 저장소에 보존할 수 있습니다.

0.2.0 표면은 안정 상태입니다. 릴리스 이력은 GitHub Releases를 참고하세요.

## Papyrus 사용 시작하기

Swift Package Manager로 설치합니다.

```swift
dependencies: [
  .package(url: "https://github.com/jaeho0718/Papyrus.git", branch: "main")
]
```

타겟 의존성에는 `Papyrus`(엄브렐러) 하나만 추가하면 파싱 코어와 뷰어 API가 모두
노출됩니다.

```swift
.target(name: "YourTarget", dependencies: ["Papyrus"])
```

iOS 18+ / iPadOS 18+ / macOS 15+, Swift 6(strict concurrency)을 요구합니다.

설치부터 문서 열기, 메타데이터·텍스트·검색, 뷰어 표시까지 이어지는 전체 흐름은
[GettingStarted]를, 뷰어를 더 깊이 제어하는 방법(적재 상태 관찰, 검색
하이라이트·매치 탐색, 목차 이동, 위치 저장·복원)은 [ViewerGuide]를, 내부 모듈
구성과 동시성·손상 내성 설계는 [Architecture]를 참고하세요. 텍스트 선택·선택
메뉴·영역은 [SelectingText]를, 하이라이트 보존은 [PersistentHighlights]를, 스캔
PDF의 OCR 연결은 [ConnectingOCR]를 참고하세요. 현재 지원 범위와 성능 특성은
[SupportedFeatures]에 정리되어 있습니다. 이 문서들은 DocC 카탈로그로
작성되어 있으며, 저장소를 체크아웃한 뒤 아래 커맨드로 로컬에서 생성해 읽을 수
있습니다.

```bash
swift package generate-documentation --target Papyrus
```

## Papyrus 개발 참여하기

저장소를 클론한 뒤 빌드와 테스트, 린트를 실행합니다.

```bash
swift build
swift test
swiftlint lint --strict
```

손상 문서에 대한 심층 퍼즈 실행은 별도 커맨드로 수행합니다: `PAPYRUS_FUZZ=1 swift
test -c release --filter DeepFuzzTests`. 실제 뷰어 동작과 Instruments
프로파일링(스크롤·메모리)을 눈으로 확인하려면 `Examples/PapyrusDemo` 데모 앱을
여세요.

gitflow 브랜치 전략, 코드 스타일, 문서화·테스트 규칙, PR 절차를 포함한 개발 설계
전문은 [Docs/ARCHITECTURE.md]를 참고하세요.

## 지원

버그를 발견했거나 기능을 제안하고 싶다면 [이슈 트래커][Issues]에 등록해
주세요. 재현 가능한 최소 예제(가능하면 원인이 된 PDF 파일이나 생성 방법)를 함께
남겨 주시면 원인 파악이 빨라집니다.

동작이나 설계에 대한 질문도 이슈로 남겨 주시면 됩니다.

## 라이선스

Papyrus는 [MIT 라이선스][LICENSE]를 따릅니다.

[GettingStarted]: Sources/Papyrus/Papyrus.docc/GettingStarted.md
[ViewerGuide]: Sources/Papyrus/Papyrus.docc/ViewerGuide.md
[SelectingText]: Sources/Papyrus/Papyrus.docc/SelectingText.md
[PersistentHighlights]: Sources/Papyrus/Papyrus.docc/PersistentHighlights.md
[ConnectingOCR]: Sources/Papyrus/Papyrus.docc/ConnectingOCR.md
[Architecture]: Sources/Papyrus/Papyrus.docc/Architecture.md
[SupportedFeatures]: Sources/Papyrus/Papyrus.docc/SupportedFeatures.md
[Docs/ARCHITECTURE.md]: Docs/ARCHITECTURE.md
[Issues]: https://github.com/jaeho0718/Papyrus/issues
[LICENSE]: LICENSE
