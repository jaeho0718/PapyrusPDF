---
name: papyrus-dev
description: >
  PapyrusPDF 패키지의 모든 개발 작업 파이프라인 오케스트레이터. 기능 구현("M1 렉서 구현해줘",
  "타일 캐시 만들어줘"), 로직 개선("xref 파서 개선", "동시성 구조 리팩터링"), 버그 수정,
  테스트 추가, 그리고 후속 작업("다시 해줘", "리뷰 반영해서 수정", "이어서 진행", "이전 결과
  보완") 요청 시 반드시 이 스킬을 사용할 것. gitflow 브랜치 생성부터 설계(fable)→구현(sonnet)
  →리뷰→PR 생성까지 전 과정을 조율한다. 단순 지식 질문(예: "PDF xref가 뭐야?")이나 코드
  읽기만 하는 요청에는 사용하지 않는다.
---

# papyrus-dev — 개발 파이프라인 오케스트레이터

PapyrusPDF의 개발 작업을 gitflow + 설계/구현 분리 원칙에 따라 조율한다.

**실행 모드: 서브 에이전트 파이프라인.** 순차 의존(설계→구현→리뷰) + 파일 기반 산출물
전달(`_workspace/`)이므로 팀 통신은 불필요하다. 리뷰 피드백 루프는 오케스트레이터가
implementer를 재호출하는 방식으로 처리한다.

**모델 규칙 (필수 준수):** 로직 구성·개선 = `papyrus-architect`(fable),
하위 구현 = `papyrus-implementer`(sonnet). Agent 도구 호출 시 에이전트 정의의 model
frontmatter가 적용되므로 별도 model 파라미터를 넘기지 않는다.

## Phase 0: 컨텍스트 확인

1. `git status`와 현재 브랜치를 확인한다. 작업 중이던 feature 브랜치가 있으면 이어서
   작업할지 판단한다 (사용자가 "이어서"라고 하면 해당 브랜치에서 계속).
2. `_workspace/` 확인:
   - 관련 설계/리뷰 산출물 존재 + 부분 수정 요청 → **부분 재실행** (해당 에이전트만 재호출)
   - 산출물 존재 + 완전히 새 작업 → 기존 산출물은 그대로 두고 순번(NN)을 이어서 사용
   - 미존재 → **초기 실행** (`_workspace/` 생성, git 비추적 디렉터리)
3. `Docs/ARCHITECTURE.md`에서 작업 관련 섹션을 읽어 마일스톤·설계 맥락을 파악한다.

## Phase 1: 브랜치 준비 (gitflow)

`gitflow-workflow` 스킬의 규칙을 따른다. 요약:
- 새 작업은 develop에서 `feature/{kebab-case-작업명}` 분기 (예: `feature/m1-cos-lexer`)
- 버그 수정은 `feature/fix-{내용}`, 배포 브랜치 긴급 수정만 `hotfix/`
- develop이 최신인지 확인: `git fetch origin && git checkout develop && git pull` 후 분기

## Phase 2: 설계 — papyrus-architect (fable)

**로직 설계·개선이 필요한 작업만.** 다음이면 설계 단계를 건너뛴다: 오타/주석 수정, 기존
설계 문서가 이미 커버하는 단순 구현, 테스트만 추가, 리뷰 지적 반영.

Agent 도구로 `papyrus-architect`를 호출한다. 프롬프트에 포함할 것:
- 작업 목표와 범위, ARCHITECTURE.md의 관련 섹션명
- 기존 코드 경로 (개선 작업일 때)
- 산출물 경로 규칙: `_workspace/{NN}_architect_{topic}.md`

산출된 설계 문서를 읽고 요약을 사용자에게 보고한 뒤 진행한다. 설계가 ARCHITECTURE.md
수정을 권고하면 문서를 갱신하고 커밋에 포함한다.

## Phase 3: 구현 — papyrus-implementer (sonnet)

Agent 도구로 `papyrus-implementer`를 호출한다. 프롬프트에 포함할 것:
- 설계 문서 경로 (Phase 2 산출물) 또는 단순 작업 설명
- 완료 기준: `swift build` + `swift test` + `swiftlint lint --strict` 전부 통과,
  public API DocC 주석(`docc-docs` 스킬 규칙) 필수

보고에 "설계 이슈"가 있으면 → Phase 2로 회귀: architect에게 이슈를 전달해 설계를 수정하고,
수정된 설계로 implementer를 재호출한다.

## Phase 4: 리뷰 — papyrus-reviewer

Agent 도구로 `papyrus-reviewer`를 호출한다 (`subagent_type: general-purpose` 아닌
`papyrus-reviewer` 사용). 프롬프트에 설계 문서 경로 + 변경 파일 목록을 전달한다.

판정 처리:
- **승인** → Phase 5
- **수정 필요** (blocker/should) → implementer 재호출로 반영 후 재리뷰. 최대 2회 반복,
  그래도 미해결이면 사용자에게 상황을 보고하고 판단을 구한다
- **아키텍트 회부** → architect에게 결함을 전달해 수정 설계 → implementer → 재리뷰

## Phase 5: 커밋과 PR

1. 최종 확인: `swift build && swift test && swiftlint lint --strict`
2. 커밋: gitflow-workflow 스킬의 커밋 메시지 규칙. pre-commit 훅이 SwiftLint를 재검사한다.
   훅이 커밋을 차단하면 위반을 수정한다 — `--no-verify` 사용 금지.
3. push 후 `gh pr create --base develop`으로 PR 생성. PR 본문은 템플릿 체크리스트를
   실제 결과로 채운다.
4. **병합은 하지 않는다.** PR URL과 CI 상태를 사용자에게 보고하고, 병합은 사용자가
   결정한다.

## 데이터 전달 프로토콜

- 에이전트 간 전달은 `_workspace/` 파일 기반: `{NN}_{agent}_{artifact}.md` (NN은 2자리 순번,
  브랜치 내에서 증가)
- `_workspace/`는 git에 커밋하지 않는다 (.gitignore 등록됨). 감사 추적용으로 보존한다.
- 각 에이전트의 반환 메시지는 요약만 — 상세는 파일에서 읽는다.

## 에러 핸들링

| 상황 | 처리 |
|---|---|
| 에이전트 작업 실패 | 1회 재시도. 재실패 시 실패 내용과 함께 사용자에게 보고 (은폐 금지) |
| 빌드/테스트가 리뷰까지 통과했는데 CI 실패 | CI 로그를 확인해 환경 차이(Xcode 버전 등)를 진단하고 수정 커밋 |
| 리뷰 루프 2회 초과 | 미해결 항목을 정리해 사용자 판단 요청 |
| 설계↔ARCHITECTURE.md 충돌 | 아키텍트의 권고안을 사용자에게 보고 후 문서 갱신 여부 확인 |

## 테스트 시나리오

**정상 흐름**: "M1의 COSLexer 구현해줘" → Phase 0(초기 실행 판별) → `feature/m1-cos-lexer`
분기 → architect가 `_workspace/01_architect_cos-lexer.md` 산출 → implementer가
COSLexer.swift + 테스트 구현, 3종 검증 통과 → reviewer 승인 → 커밋·push·PR 생성 → PR URL 보고.

**에러 흐름**: 구현 중 implementer가 "설계의 토큰 enum이 스트림 키워드를 누락" 설계 이슈
보고 → 오케스트레이터가 architect 재호출로 설계 개정(개정 이력 추가) → implementer 재호출
→ 이후 정상 진행. 리뷰에서 blocker(경계값 테스트 누락) → implementer 재호출로 테스트 추가
→ 재리뷰 승인 → PR.
