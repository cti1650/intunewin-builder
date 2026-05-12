# CI 構成 (Lint / build-verify chain / Defender 例外)

> [← README に戻る](../README.md)

## Lint CI (push / PR トリガー)

`apps/` / `scripts/` / `.github/` / `.githooks/` 配下が変更されると [.github/workflows/lint.yml](../.github/workflows/lint.yml) が起動し、以下を ubuntu-latest で並列実行する (各 1 分以内):

| ジョブ | チェック内容 |
|---|---|
| **ps-syntax** | [scripts/check-syntax.ps1](../scripts/check-syntax.ps1) で全 `*.ps1` を AST パース |
| **apps-schema** | [scripts/check-apps-schema.ps1](../scripts/check-apps-schema.ps1) で `apps/*.yml` の必須フィールド・許可された type 値・name 一致を検証 |
| **choice-list** | [scripts/check-choice-list.ps1](../scripts/check-choice-list.ps1) で `build-and-verify.yml` の choice options と `apps/*.yml` の集合一致を検証 |
| **actionlint** | workflow YAML の構文 / shell コマンドを [actionlint](https://github.com/rhysd/actionlint) で検査 |

ローカルで個別に実行する場合:

```bash
pwsh -File scripts/check-syntax.ps1
pwsh -File scripts/check-apps-schema.ps1
pwsh -File scripts/check-choice-list.ps1
```

**lint を通せない PR はマージしない**。

## 自動 build-verify chain (master push / PR push 共通)

lint 完走後、`detect-affected-apps` ジョブが直前 commit / PR base との `git diff` から「変更された app」だけを matrix に絞って [build-and-verify-apps.yml](../.github/workflows/build-and-verify-apps.yml) / [script-based-verify-apps.yml](../.github/workflows/script-based-verify-apps.yml) を chain 実行する:

| イベント | diff の基準 |
|---|---|
| master push | `HEAD~1...HEAD` |
| pull_request | `origin/<base>...HEAD` (PR 全体の差分) |

トリガー対象になる変更:

- `apps/<name>.yml` → `<name>` のみ matrix
- `apps/<name>_script_based.yml` / `_shortcut.yml` → 同上 (script_based 側 matrix)
- `scripts/apps/<name>/**` → 対応 yml に応じて振り分け
- それ以外 (`scripts/*.ps1` / `.github/**` 等) → matrix は空、chain は skip

連続 push は `cancel-in-progress: true` で古い run を cancel し最新 commit だけ最後まで走る (あと優先)。

## CI 限定 Defender 例外

[scripts/generic-install.ps1](../scripts/generic-install.ps1) と [scripts/verify-installer.ps1](../scripts/verify-installer.ps1) の EXE インストーラ起動箇所には、`$env:GITHUB_ACTIONS -eq 'true'` 限定で `Add-MpPreference -ExclusionPath` を仕込んである。

Azure 特定 region (northcentralus 等) で NSIS 系 Setup.exe の子プロセス起動が Windows Defender real-time scanning と衝突して `0xC0000005` (`-1073741819` = ACCESS_VIOLATION) で死ぬ flaky を回避するため。エンドユーザー端末 (Intune 配信先) では発火しない。

新規アプリで EXE 系 Setup を扱う scripts を追加するとき:

- `$env:GITHUB_ACTIONS` で必ずガードする (エンドユーザー端末で発火させない)
- `try/catch` + `-ErrorAction SilentlyContinue` で Defender 不在環境でも黙ってスキップ
- 例外パスは installer ファイルが置かれているディレクトリ単位 (`Split-Path -Parent`)
