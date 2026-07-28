#!/bin/bash
# PapyrusPDF 개발 환경 셋업 — 클론 후 1회 실행.
#   ./Scripts/setup.sh
# 1) git 훅 활성화 (pre-commit: SwiftLint strict, pre-push: 보호 브랜치 차단)
# 2) SwiftLint 설치 확인
set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push
echo "✓ git 훅 활성화 (.githooks)"

if command -v swiftlint >/dev/null 2>&1; then
  echo "✓ SwiftLint $(swiftlint version)"
else
  echo "✗ SwiftLint가 없습니다. 설치: brew install swiftlint" >&2
  exit 1
fi

echo "셋업 완료. 커밋 시 SwiftLint가 자동 실행되며, main/develop 직접 push는 차단됩니다."
