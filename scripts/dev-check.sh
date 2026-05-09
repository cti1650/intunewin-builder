#!/usr/bin/env bash
# PowerShell 構文チェックを pwsh 経由で実行する bash ラッパ。
# pwsh 未インストール時は導入手順を表示して非ゼロ終了する。
set -euo pipefail

if ! command -v pwsh >/dev/null 2>&1; then
    cat >&2 <<'EOF'
ERROR: pwsh (PowerShell Core) が見つかりません。

導入方法:
  macOS    : brew install --cask powershell
  Windows  : winget install Microsoft.PowerShell
  Linux    : https://learn.microsoft.com/powershell/scripting/install/

導入後、再度このスクリプトを実行してください。
EOF
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || cd "$(dirname "$0")/.." && pwd)"

exec pwsh -NoProfile -File "$REPO_ROOT/scripts/check-syntax.ps1" "$@"
