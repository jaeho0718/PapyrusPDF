---
name: swift-style
description: >
  Papyrus의 Swift 코드 스타일 규칙(StyleShare swift-style-guide 기반)과 SwiftLint 운용법.
  Swift 코드를 작성·수정하기 전, SwiftLint 위반을 해결할 때, "스타일 맞춰줘"/"린트 에러
  고쳐줘" 요청 시 반드시 사용할 것.
---

# swift-style — StyleShare 스타일 + SwiftLint 운용

Papyrus의 모든 Swift 코드는 [StyleShare swift-style-guide]
(https://github.com/StyleShare/swift-style-guide)를 따르며, `.swiftlint.yml`이 이를
매 커밋 시 강제한다 (pre-commit 훅, `--strict`).

## 코드 작성 전 핵심 규칙 (요약)

- **들여쓰기 2칸 스페이스, 한 줄 최대 99자**
- import는 알파벳 순, 내장 프레임워크 먼저 → 빈 줄 → 서드파티
- 콜론은 오른쪽만 공백: `let names: [String: String]`
- 네이밍: 타입 UpperCamelCase / 함수·변수·상수·enum case lowerCamelCase (상수도
  SCREAMING_CASE 금지). 약어는 위치 따라 `userID`, `websiteURL`, `htmlString`
- 함수명에 `get` 접두사 금지. 액션 메서드는 주어+동사+목적어: `backButtonDidTap()`
- 클래스·구조체 내부에서는 `self` 명시
- 상속하지 않는 클래스는 `final`
- `[T]`, `[T: U]`, `() -> Void` 표기 (제네릭 원형·`() -> ()` 금지)
- 프로토콜 구현은 extension으로 분리 + `// MARK: - ProtocolName` (MARK 위아래 빈 줄)
- 파일은 빈 줄로 끝나고, 빈 줄에 공백 없음

전체 규칙과 예시는 `references/styleshare-rules.md`를 읽어라 (경계 케이스 판단 시).

## SwiftLint 운용

```bash
swiftlint lint --strict          # 검사 (커밋 전 필수, CI와 동일)
swiftlint --fix                  # 자동 수정 가능한 위반 일괄 수정
swiftlint analyze --compiler-log-path <log>  # explicit_self 등 analyzer 규칙 (선택)
```

- 프로젝트 규칙은 `.swiftlint.yml` — StyleShare 규칙 매핑에 주석으로 근거가 달려 있다.
- **`missing_docs`는 오류다**: public/open API에 `///` 문서 주석이 없으면 커밋이 차단된다.
  문서 작성법은 `docc-docs` 스킬 참조.
- 위반 해결 원칙: 규칙을 끄거나 `// swiftlint:disable`로 덮지 말고 코드를 고친다.
  disable 주석이 정말 필요한 예외(예: 생성 코드 테이블의 줄 길이)는 최소 범위
  (`:next`)로 한정하고 사유 주석을 붙인다.
- `.swiftlint.yml` 수정은 스타일 정책 변경이므로 단독 커밋(`chore:`)으로 분리하고 PR에서
  사유를 설명한다.
