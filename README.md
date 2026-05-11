# intunewin-builder

GitHub Actions 上で Windows アプリを取得し、
.intunewin を生成・事前確認するための個人用リポジトリ。

ローカル端末を使わず、
Intune に登録する「前」までの確認を CI で完結させることを目的としている。

## できること

* GitHub Actions からアプリを選択して実行
* 公式配布元からインストーラをダウンロード
* intunewin を生成して artifact として取得
* サイレントインストールと検出条件を確認
* アンインストールと削除確認

## やらないこと

* Intune への自動登録・自動配布
* IME や割り当て挙動の検証
* アプリのバージョン管理

Intune 自体はブラックボックスとして扱い、
「Intune に渡す材料の品質」だけを責任範囲とする。

## 対応アプリ

現在は Windows11が32bit CPUのサポートをしていないため **全て 64-bit 版** での統一する。

| アプリ | インストーラ | Install Behavior | 検出方法 | 備考 |
|--------|-------------|---|----------|------|
| **Google Chrome** | MSI (64-bit) | system | ファイルパス | Enterprise版 |
| **Mozilla Firefox** | MSI (64-bit) | system | ファイルパス | 日本語版 (`lang=ja`) |
| **Cloudflare WARP** | MSI (64-bit) | system | レジストリ | 表示名検出 |
| **Zoom Workplace** | MSI (64-bit) | system | レジストリ | 表示名検出 / 自動更新ON |
| **AWS CLI v2** | MSI (64-bit) | system | ファイルパス | クラウドエンジニア向け CLI |
| **Gyazo** | EXE (InnoSetup) | system | ファイルパス | スクリーンショット共有ツール |
| **Gyazo Teams** | EXE (InnoSetup) | system | ファイルパス | Gyazo の Teams プラン向けクライアント (`GyazoTeams.exe`) |
| **ovice** | EXE (NSIS) | **user** | レジストリ | per-user installer (`%LocalAppData%\Programs\ovice`) |
| **Okta Verify** | EXE (Bootstrapper) | system | ファイルパス | URL に `YOUR_ORGANIZATION` placeholder。手動 dispatch 専用 |
| **Company Portal Shortcut** | カスタム PowerShell | system | ファイルパス (.lnk) | Public Desktop にポータルサイトのショートカットを作成 |
| **Company Portal Shortcut (user)** | カスタム PowerShell | **user** | ファイルパス (.lnk) | 実行ユーザの Desktop に作成。SYSTEM 権限不要・ローカル動作確認向け |
| **Slack Shortcut** | カスタム PowerShell | system | ファイルパス (.lnk) | Public Desktop に Microsoft Store 版 Slack へのショートカットを作成 |
| **Slack Shortcut (user)** | カスタム PowerShell | **user** | ファイルパス (.lnk) | 実行ユーザの Desktop に作成。SYSTEM 権限不要・ローカル動作確認向け |

`Install Behavior` は Intune の Win32 App 設定 "Install behavior" にそのまま入れる値 (`system` または `user`)。[apps/*.yml](apps/) の `intune.install_behavior` フィールドが情報源。

> **Slack 本体は Win32App 化しない方針**
> Slack 公式が [2025-09-15 に MSI インストーラを廃止](https://slack.com/help/articles/4426294050451-Slack-feature-and-plan-retirements) し、後継として MSIX (および Microsoft Store 配信) のみを案内しているため、Slack 本体は **Intune の "Microsoft Store app (new)" 機能** で配信することを推奨する。本リポジトリはショートカット (`slack_shortcut`) のみ提供する。

## アプリ定義ファイル (YAML)

`apps/` ディレクトリに各アプリの定義ファイルを配置。

デプロイ方式は3種類:

1. **通常 (MSI/EXE/MSIX)**: ビルド時にインストーラを同梱
2. **script_based**: 端末側で `generic-install.ps1` がURLから取得して実行
3. **script_based + custom_script**: `scripts/apps/<name>/` の任意のPS1を同梱（ダウンロード不要なケース）

```yaml
name: アプリ名

download:
  url: ダウンロードURL
  file: 保存ファイル名

installer:
  type: msi | exe | msix
  install_args: インストール引数（{installer}でパス置換）
  timeout: タイムアウト秒数（オプション）

detect:
  file: ファイルパス（EXE用）
  version: 必要最低バージョン（オプション、空欄でスキップ）
  registry_display_name: 表示名（MSI用）
  appx_name: パッケージ名（MSIX用）

uninstall:
  type: msi | exe | msix | registry_string | script
  args: アンインストール引数（{product_code}で自動置換）
  path: アンインストーラパス（EXE用、{version}で自動置換）
  package_name: パッケージ名（MSIX用）

intune:
  install_behavior: system | user   # 必須。Intune の "Install behavior" にそのまま入れる値
  install_command: ...               # 参照用 (operator が Intune UI に貼る)
  uninstall_command: ...             # 参照用
  detection: ...                     # 参照用
```

`detect.file` / `uninstall.path` には `%LocalAppData%` 等の環境変数を埋め込める (verify-installer は実行時に展開する)。`install_behavior: user` のアプリは原則 `%LocalAppData%` プレースホルダを使う ([apps/ovice.yml](apps/ovice.yml) 参照)。

## 検証フロー

1. **ビルド**: インストーラをダウンロードし intunewin を生成
2. **静的解析**:
   * ファイルヘッダーによる形式確認
   * **OS (64/32bit) とインストーラのアーキテクチャ不一致チェック**
3. **インストール前スナップショット**: レジストリ・Appx一覧を取得
4. **インストール**: サイレントインストール実行（タイムアウト監視付き）
   * 実行コマンドと終了コードをログ出力
5. **インストール後スナップショット**: 差分を表示
6. **検出確認**: 定義した検出条件でインストール成功を確認
7. **インストール場所チェック**: x64/x86両方のProgram Filesを確認し、どちらにインストールされたかをレポート
8. **アンインストール**: サイレントアンインストール実行
   * MSIの場合は ProductCode を自動抽出して実行
   * EXEの場合は定義されたアンインストーラを実行
   * 実行コマンドと終了コードをログ出力
9. **アンインストール後スナップショット**: 削除された項目を表示
10. **削除確認**: アプリが検出されないことを確認
11. **結果サマリー**: 全ステップの成否を一覧表示

## 使い方

### 単体テスト
1. `build-and-verify-intunewin` を実行
2. アプリ名を選択して実行
3. Artifact (intunewin, ログ) を確認

### 一括テスト
1. `build-and-verify-intunewin-apps` を実行
2. `apps/` 以下の全アプリが並列で検証される

## ローカル動作確認 (Intune を経由しない実機検証)

`.intunewin` パッケージングや Intune を経由せず、Windows 端末上で `apps/<App>.yml` の **Install / Uninstall を単発で実行**して挙動を確認したい場合は [scripts/local-run.ps1](scripts/local-run.ps1) を使う。`build-and-verify` のような検出/クリーンアップ検証は走らせず、純粋に install or uninstall だけを実行する。

```powershell
# 通常版 (msi/exe/msix)
powershell.exe -ExecutionPolicy Bypass -File scripts\local-run.ps1 -App firefox -Action Install
powershell.exe -ExecutionPolicy Bypass -File scripts\local-run.ps1 -App firefox -Action Uninstall

# script_based 版 (端末側で URL から DL)
powershell.exe -ExecutionPolicy Bypass -File scripts\local-run.ps1 -App firefox_script_based -Action Install

# custom_script 版 (同梱 PS1 を直接実行)
powershell.exe -ExecutionPolicy Bypass -File scripts\local-run.ps1 -App company_portal_shortcut -Action Install
```

特徴:

- **Windows PowerShell 5.1 で動く**ので、素の Windows 10/11 で `pwsh` (PowerShell 7) を入れずに実行できる。pwsh 7 でも同じく動く。
- 初回起動時に `powershell-yaml` モジュールが未導入なら CurrentUser スコープで自動取得する (`apps/*.yml` のパース用)。
- `installer.type` (msi/exe/msix) と `uninstall.type` (msi/exe/msix/script/registry_string) の dispatch は CI の verify-installer / build-script-based と同等。
- システムコンテキストインストーラの場合は管理者権限の PowerShell から実行する必要がある。

> **注意:** 本物のインストーラを実機に流すため、レジストリ・ファイルシステム・サービス等が変更される。**Windows Sandbox / 検証用 VM / 使い捨て端末で実行することを強く推奨**する。Sandbox を使う場合はリポジトリを zip で持ち込み、上記コマンドを管理者権限の PowerShell から実行すれば十分。

## 開発環境セットアップ (任意)

### 前提
- [PowerShell Core (pwsh)](https://learn.microsoft.com/powershell/scripting/install/) — macOS は `brew install --cask powershell`

### PowerShell 構文チェック (ローカル)

```bash
# 全 .ps1 を AST パーサで検査 (pwsh 未導入なら案内表示)
./scripts/dev-check.sh
```

`scripts/check-syntax.ps1` 単体で pwsh から呼び出すこともできる:

```bash
pwsh -File scripts/check-syntax.ps1
pwsh -File scripts/check-syntax.ps1 -Files scripts/build-intunewin.ps1
```

### git pre-commit hook (オプトイン)

stage された `*.ps1` のみを構文チェックする pre-commit hook を有効化できる:

```bash
./scripts/install-hooks.sh    # core.hooksPath を .githooks/ に設定
```

- バイパス: `git commit --no-verify`
- 解除: `git config --unset core.hooksPath`
- pwsh 未導入時は警告のみで通す (CI 側で最終ガード前提)

### Action バージョン更新

`.github/dependabot.yml` で github-actions を週次監視。新版が出ると自動で PR が立つ。

### Lint CI (push / PR トリガー)

`apps/`、`scripts/`、`.github/` 配下が変更されると `.github/workflows/lint.yml` が起動し、以下を ubuntu-latest で並列実行する (各 1 分以内):

| ジョブ | チェック内容 |
|---|---|
| **ps-syntax** | `scripts/check-syntax.ps1` で全 `*.ps1` を AST パース |
| **apps-schema** | `scripts/check-apps-schema.ps1` で `apps/*.yml` の必須フィールド・許可された type 値・name 一致を検証 |
| **choice-list** | `scripts/check-choice-list.ps1` で `build-and-verify.yml` の choice options と `apps/*.yml` の集合一致を検証 |
| **actionlint** | workflow YAML の構文・shell コマンドを [actionlint](https://github.com/rhysd/actionlint) で検査 |

ローカルで個別に実行する場合:

```bash
pwsh -File scripts/check-syntax.ps1
pwsh -File scripts/check-apps-schema.ps1
pwsh -File scripts/check-choice-list.ps1
```

### 自動 build-verify chain (master push / PR push 共通)

lint 完走後、`detect-affected-apps` ジョブが直前 commit / PR base との `git diff` から「変更された app」だけを matrix に絞って `build-and-verify-apps` / `script-based-verify-apps` を chain 実行する:

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

### CI 限定 Defender 例外

`scripts/generic-install.ps1` と `scripts/verify-installer.ps1` の EXE インストーラ起動箇所には、`$env:GITHUB_ACTIONS -eq 'true'` 限定で `Add-MpPreference -ExclusionPath` を仕込んである。Azure 特定 region (northcentralus 等) で NSIS 系 Setup.exe の子プロセス起動が Windows Defender real-time scanning と衝突して `0xC0000005` (`-1073741819`) で死ぬ flaky を回避するため。エンドユーザー端末 (Intune 配信先) では発火しない。

## 補足

このリポジトリは
「Intune に入れてから失敗する」ケースを減らすための仕組み。

本番展開前の最小限の実機確認は前提とする。
