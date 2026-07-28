---
name: gitflow-workflow
description: >
  PapyrusPDF 저장소의 gitflow 규칙. 브랜치 생성/네이밍, 커밋 메시지, PR 생성·병합 절차가
  필요한 모든 git 작업 전에 이 스킬을 참조할 것. "브랜치 만들어줘", "커밋해줘", "PR 올려줘",
  "릴리스 준비" 요청 시 반드시 사용한다.
---

# gitflow-workflow — PapyrusPDF 브랜치·PR 규칙

## 브랜치 구조

| 브랜치 | 역할 | 분기 원점 | 병합 대상 |
|---|---|---|---|
| `main` | 릴리스된 안정 버전만 | — | — |
| `develop` | 통합 개발 브랜치 (기본 브랜치) | main | — |
| `feature/{작업명}` | 기능 개발·개선·버그 수정 | develop | develop |
| `release/{버전}` | 릴리스 준비 (버전 표기, 최종 QA) | develop | main + develop |
| `hotfix/{내용}` | 릴리스 긴급 수정 | main | main + develop |

네이밍은 kebab-case: `feature/m1-cos-lexer`, `feature/fix-xref-offset`, `release/1.0.0`,
`hotfix/tile-cache-crash`.

## 철칙

1. **develop과 main에는 직접 push하지 않는다.** 반드시 PR을 경유한다. 로컬 `pre-push` 훅과
   GitHub 브랜치 보호(required check: `lint-build-test`)가 이를 강제한다.
2. 훅 우회(`--no-verify`, `PAPYRUSPDF_ALLOW_PROTECTED_PUSH=1`)는 사용하지 않는다. 훅이
   차단하면 원인을 고치는 것이 규칙이다.
3. 새 feature는 항상 최신 develop에서 분기한다:
   `git fetch origin && git checkout develop && git pull && git checkout -b feature/...`

## 커밋 메시지

```
{type}: {한 줄 요약 (72자 이내, 한국어 가능)}

{필요 시 본문: 무엇을·왜. 어떻게는 코드가 말한다.}
```

type: `feat`(기능) / `fix`(버그) / `refactor`(동작 불변 구조 변경) / `test`(테스트만) /
`docs`(문서·DocC) / `chore`(빌드·설정·하네스). 하나의 커밋은 하나의 논리 단위 — 설계 문서
갱신과 해당 구현은 같은 커밋에 묶어도 된다.

## PR 절차

1. `git push -u origin feature/...`
2. `gh pr create --base develop --title "{type}: {요약}"` — 본문은
   `.github/PULL_REQUEST_TEMPLATE.md` 체크리스트를 실제 수행 결과로 채운다
3. CI(`lint-build-test`) 통과 확인: `gh pr checks`
4. **병합은 merge commit 방식** (gitflow 표준, 이력 보존): `gh pr merge --merge`.
   squash/rebase 병합 금지. 병합 실행은 사용자 확인 후에만.
5. 병합 후 로컬 정리: `git checkout develop && git pull && git branch -d feature/...`

## release / hotfix

- `release/{버전}`: develop에서 분기 → 버전 표기·최종 점검 커밋 → main으로 PR → 병합 후
  `git tag {버전}` → develop으로도 back-merge PR.
- `hotfix/{내용}`: main에서 분기 → 수정 → main PR + develop back-merge PR.

## 이 규칙의 이유

PR 강제는 CI(린트+빌드+테스트)가 develop을 항상 그린 상태로 유지하게 하는 유일한 관문이다.
merge commit 유지는 feature 단위 이력을 보존해 회귀 추적(`git log --first-parent develop`)을
가능하게 한다.
