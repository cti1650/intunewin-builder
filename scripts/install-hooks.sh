#!/usr/bin/env bash
# .githooks/ をリポジトリの hook ディレクトリとして登録する。
# 安全にオプトインで有効化できる (バイパス: git commit --no-verify)。
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

git config core.hooksPath .githooks
chmod +x .githooks/* scripts/dev-check.sh scripts/install-hooks.sh 2>/dev/null || true

echo "OK: git hooks installed (core.hooksPath=.githooks)"
echo ""
echo "  bypass once    : git commit --no-verify"
echo "  uninstall      : git config --unset core.hooksPath"
