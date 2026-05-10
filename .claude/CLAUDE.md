# CLAUDE.md

このファイルは Claude Code がこのリポジトリで作業するときに常時参照するプロジェクト固有のルール集。

## このリポジトリは何か

GitHub Actions 上で Windows アプリのインストーラを取得し、Microsoft Intune Win32App 配信用の `.intunewin` を生成・事前検証する仕組み。Intune そのものはブラックボックスとして扱い、「Intune に渡す材料の品質」だけを責任範囲とする。

主な構成:

- [apps/](../apps/) — アプリ定義 YAML (`<name>.yml` と `<name>_script_based.yml` のペアが基本)
- [scripts/](../scripts/) — ビルド/検証/lint 用 PowerShell + bash ヘルパ
- [.github/workflows/](../.github/workflows/) — Win 実機での build-and-verify 系 + ubuntu の lint
- [.githooks/](../.githooks/) — オプトイン pre-commit hook (PowerShell 構文チェック)

## 利用可能な Skill / Agent

このリポジトリでよく発生する作業は専用の Claude Code 設定で標準化されている。**該当する依頼が来たら必ずこれらを起動すること**:

| 種別 | 名前 | 起動条件 / 用途 |
|---|---|---|
| skill | [add-intune-app](skills/add-intune-app/SKILL.md) | 「アプリを追加して」「<name> を apps に入れて」等。URL検証 → YAML対生成 → choice options 更新 → README → PR まで一貫処理 |
| skill | [debug-build-failure](skills/debug-build-failure/SKILL.md) | 「ビルドが失敗した」「インストールが落ちる」「検出が効かない」等。失敗段階別の対処手順を提供 |
| skill | [check-url](skills/check-url/SKILL.md) | `/check-url <url>` または「URL を A/B/C で判定して」等。curl HEAD で URL を検証、A/B/C 級と推奨採用方式を返す |
| agent | [intune-app-researcher](agents/intune-app-researcher.md) | 候補アプリの URL/install_args/サイズ/ライセンスを一次情報で裏取り、A/B/C 級と採用判定を返す |
| agent | [intune-build-log-analyzer](agents/intune-build-log-analyzer.md) | workflow run URL を渡して artifact ログを取得、失敗根本原因を切り分け |

依頼内容に応じて適切な skill / agent を起動する。リサーチ深掘りは agent、手続き再現は skill。Skills は `/<skill-name>` で明示的に呼び出すことも description に基づいて自動起動することもできる。

## アプリ定義スキーマの主要ルール

詳細は [README.md](../README.md) の「アプリ定義ファイル (YAML)」セクション参照。lint で機械的に検証されるルールは以下:

| フィールド | 許可される値 |
|---|---|
| `installer.type` | `msi`, `exe`, `msix`, `script` |
| `uninstall.type` | `msi`, `exe`, `msix`, `script`, `registry_string` |
| `intune.install_behavior` | `system`, `user` (必須。Intune の "Install behavior" 設定と同義) |

加えて:

- `name` フィールドはファイル名 (拡張子除く) と一致させる
- `custom_script: true` でない場合は `download.url` 必須
- `script_based: true` でない場合は `download.file` 必須
- `detect` ブロックは必須
- `detect.file` / `uninstall.path` には `%LocalAppData%` 等の環境変数を埋め込める (verify-installer は `Expand-EnvPath` で実パスへ展開する)。`install_behavior: user` のアプリは原則 `%LocalAppData%` プレースホルダ表記を使う

## 命名規則

通常版とスクリプト版の **両方を作るのが基本**:

| 用途 | ファイル名 |
|---|---|
| 通常版 (ビルド時インストーラ同梱) | `apps/<name>.yml` |
| script_based 版 (端末側で URL から DL) | `apps/<name>_script_based.yml` |
| ショートカット系 (DL なし、PS1 同梱) | `apps/<name>_shortcut.yml` (`custom_script: true`) |

`build-and-verify.yml` の `workflow_dispatch.inputs.app.options` に **通常版だけ** をアルファベット順で追加する。lint の `choice-list` ジョブが整合性を保証する。

## URL 固定性の分類 (採用判断の基準)

| 等級 | 例 | 判断 |
|---|---|---|
| **A 級** (latest 固定 URL) | `aka.ms/...`、`download.mozilla.org/?product=...-latest-ssl`、`awscli.amazonaws.com/AWSCLIV2.msi` | 通常版で採用 |
| **B 級** (GitHub Releases latest API) | `github.com/owner/repo/releases/latest/download/<asset-with-version>` | script_based で採用 |
| **C 級** (バージョン入り URL のみ) | `https://example.com/foo-1.2.3.exe` | **基本不採用**。どうしても必要なら script_based + クローラ実装 |

URL HEAD で 200 が返るかは PR 前に手元で `curl -sIL <url>` で必ず確認する。SourceForge backed の URL (例: WinSCP) は HEAD が HTML mirror page を返すため A 級と誤認しやすい。実体バイナリかは `Content-Type` と `Content-Length` で判定する。

## やってはいけないこと

- **Microsoft Store で配布されているアプリを Win32App 化しない**。Intune の Microsoft Store アプリ配信機能を使う方が筋が良い (例: 1Password、LINE WORKS、Chatwork、Discord 等)
- **per-user installer (Squirrel 系) を通常版で採用しない**。SYSTEM コンテキストで詰む。Discord、GitHub Desktop、Postman Agent 等が該当
- **Bootstrapper 形式のインストーラ** (Teams new、gcloud SDK 等) は完結しないため、CI の build-and-verify で安定しないことがある。採用するなら script_based 経由を推奨
- **商用ライセンス必須のアプリ** (Docker Desktop の大企業利用、TeamViewer、AnyDesk の業務利用 等) を無断で追加しない

## Lint CI (push / PR で自動実行)

`.github/workflows/lint.yml` が ubuntu-latest で 4 ジョブ並列、合計 1 分以内:

| ジョブ | 内容 |
|---|---|
| ps-syntax | `scripts/check-syntax.ps1` で全 `*.ps1` を AST パース |
| apps-schema | `scripts/check-apps-schema.ps1` で apps/*.yml のスキーマ検証 |
| choice-list | `scripts/check-choice-list.ps1` で workflow choice の整合性検証 |
| actionlint | workflow YAML の lint |

`apps/`、`scripts/`、`.github/`、`.githooks/` 配下の変更でトリガーされる。**lint を通せない PR はマージしない**。

lint 完走後、`detect-affected-apps` ジョブが diff から「変更された app」だけを matrix に絞って `build-and-verify-apps` / `script-based-verify-apps` を chain 実行する。**master push と PR push の両方で発火**し、関係ない変更 (例: README のみ) では何も走らない。連続 push は cancel-in-progress であと優先。

## CI 限定の Defender 例外ルール

`scripts/generic-install.ps1` と `scripts/verify-installer.ps1` の **EXE インストーラ起動箇所**には、`$env:GITHUB_ACTIONS -eq 'true'` ガード付きで `Add-MpPreference -ExclusionPath` を仕込んである。Azure 特定 region (northcentralus 等) で NSIS 系 Setup.exe の子プロセス起動が Defender real-time scanning と衝突して `0xC0000005` (`-1073741819` ACCESS_VIOLATION) で死ぬ flaky を回避する目的。

新規アプリで EXE 系 Setup を扱う scripts を追加するとき:

- `$env:GITHUB_ACTIONS` で必ずガードする (エンドユーザー端末では発火させない)
- `try/catch` + `-ErrorAction SilentlyContinue` で Defender 不在環境でも黙ってスキップ
- 例外パスは installer ファイルが置かれているディレクトリ単位 (`Split-Path -Parent`)

## ローカルでの確認コマンド

PowerShell Core (`pwsh`) が必要。macOS は `brew install --cask powershell`。

```bash
./scripts/dev-check.sh                       # *.ps1 構文チェック
pwsh -File scripts/check-apps-schema.ps1     # apps/*.yml スキーマ検証
pwsh -File scripts/check-choice-list.ps1     # choice options 整合性
./scripts/install-hooks.sh                    # オプトイン pre-commit hook を有効化
```

## 依存追従

`actions/checkout` 等の GitHub Actions バージョン更新は Dependabot (`.github/dependabot.yml`) が週次で grouped PR を作る。これらは **lint が通れば原則そのまま merge** で良い。

## コミット規約

`feat:`, `fix:`, `chore:`, `ci:`, `docs:` の prefix を付ける。日本語本文 OK。`#PR番号` は GitHub が自動付与するので手動で入れない。
