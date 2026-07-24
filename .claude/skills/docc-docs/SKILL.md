---
name: docc-docs
description: >
  Papyrus의 DocC 문서화 규칙. Swift 코드 작성·수정 시 문서 주석(///) 작성법, DocC 카탈로그
  구성, 문서 생성 절차에 사용한다. "문서화해줘", "DocC 만들어줘", 공개 API 추가/변경 작업
  시 반드시 참조할 것. 매 작업마다 문서화는 필수 규칙이다.
---

# docc-docs — DocC 문서화 규칙

**매 작업마다 문서화한다.** 공개 API의 문서 주석 누락은 SwiftLint `missing_docs` 규칙이
오류로 차단하므로, 문서 없는 코드는 커밋 자체가 불가능하다.

## 문서 주석 규칙

모든 `public`/`open` 선언(타입, 프로퍼티, 메서드, case)에 `///` 주석을 작성한다:

```swift
/// PDF 문서를 열고 메타데이터·텍스트·검색 기능을 제공하는 진입점.
///
/// 문서는 메모리 맵으로 열리며 전체 파일을 메모리에 올리지 않는다.
/// 수천 페이지 문서도 열기 비용은 xref 파싱에 비례한다.
///
/// - Parameters:
///   - url: 열려는 PDF 파일의 위치.
/// - Returns: 열린 문서 인스턴스.
/// - Throws: 파일이 PDF가 아니면 ``PapyrusError/notAPDF``,
///   복구 불가 손상이면 ``PapyrusError/damagedDocument(underlying:)``.
public static func open(url: URL) async throws -> PapyrusDocument
```

- 첫 줄: 한 문장 요약 (마침표로 끝냄). 빈 줄 후 상세 설명.
- 파라미터가 있으면 `- Parameters:`, 반환이 있으면 `- Returns:`, throws면 `- Throws:`
  (어떤 조건에서 어떤 에러인지까지).
- 타입 간 참조는 심벌 링크 ` ``TypeName`` ` 사용.
- `package`/`internal` 선언도 동작이 자명하지 않으면 `///` 권장 (강제는 아님).
- 주석은 "무엇·왜"를 담는다. 구현 절차 나열("이 함수는 먼저 X를 하고...")은 금지.

## DocC 카탈로그

타겟별 카탈로그는 공개 API가 생기는 시점(마일스톤 M3)부터 유지한다:

```
Sources/PapyrusCore/PapyrusCore.docc/
  PapyrusCore.md        ← 랜딩 페이지: 개요 + 주요 심벌 Topics 그룹핑
```

- 랜딩 페이지 첫 줄은 `# ``PapyrusCore`` ` 형식.
- 새 공개 타입 추가 시 랜딩 페이지의 Topics에 등록한다.
- **DocC는 사람이 읽는 독립 기술 문서다.** 저장소 내부 산출물 참조(`Docs/ARCHITECTURE.md`
  경로, `_workspace/` 문서, "N행" 같은 위치 지시, 마일스톤 번호 M1~M8, 스킬 이름)를 본문에
  쓰지 않는다. DocC 아카이브만 받아 읽는 사용자 관점에서 자족적이어야 한다.
- **카탈로그 문서(랜딩·아티클)의 본문 문장은 합니다체로 쓴다.** 페이지 첫 줄 요약(abstract)은
  명사형 종결("...하는 코어.")을 허용한다. 코드 내 `///` 문서 주석은 기존 관례(간결한
  평서형/명사형)를 유지한다.
- 아키텍처 설명은 엄브렐러 카탈로그의 `Architecture.md` 아티클이 담당한다 — 사용자 대상
  현재 시제 시스템 설명으로 쓴다("Mn에서 구현" 같은 개발 이력 서술 금지). 아키텍처가
  실질적으로 바뀌는 변경 시 이 아티클도 갱신한다. `Docs/ARCHITECTURE.md`는 개발 계획서
  (마일스톤·리스크·검증 계획)로서 별도 유지하며, 서로 역할이 다르므로 그대로 복사하지 않는다.
- 엄브렐러 카탈로그(`Papyrus.docc`)에서는 다른 타겟의 심벌 링크(` ``...`` `)가 해소되지
  않으므로 코드 폰트(백틱 1개)로 표기한다.

## 생성·검증 절차

```bash
# 문서 빌드 (경고 = 심벌 링크 오타 등 확인)
swift package generate-documentation --target PapyrusCore

# 로컬 미리보기
swift package --disable-sandbox preview-documentation --target PapyrusCore
```

`swift-docc-plugin` 의존성이 Package.swift에 필요하다 — 카탈로그 도입 시점에 추가한다.
문서 빌드 경고는 PR 전에 해소한다.

## 작업 완료 체크

- [ ] 새/변경 public API 전부에 `///` (Parameters/Returns/Throws 포함)
- [ ] 심벌 링크(` ``...`` `)가 실제 심벌과 일치
- [ ] (카탈로그 도입 후) 새 공개 타입이 Topics에 등록됨
