# intunewin-builder

GitHub Actions 上で Windows アプリを取得し、`.intunewin` を生成・事前確認するための個人用リポジトリ。

ローカル端末を使わず、Intune に登録する「前」までの確認を CI で完結させることを目的としている。

## できること

* GitHub Actions からアプリを選択して実行
* 公式配布元からインストーラをダウンロード
* `.intunewin` を生成して artifact として取得
* サイレントインストールと検出条件を確認
* アンインストールと削除確認

## やらないこと

* Intune への自動登録・自動配布
* IME や割り当て挙動の検証
* アプリのバージョン管理

Intune 自体はブラックボックスとして扱い、「Intune に渡す材料の品質」だけを責任範囲とする。

## 対応アプリ

現在は Windows 11 が 32-bit CPU のサポートをしていないため **全て 64-bit 版** で統一する。

| アプリ | インストーラ | Install Behavior | 検出方法 | 備考 |
|--------|-------------|---|----------|------|
| **Google Chrome** | MSI (64-bit) | system | ファイルパス | Enterprise 版 |
| **Mozilla Firefox** | MSI (64-bit) | system | ファイルパス | 日本語版 (`lang=ja`) |
| **Cloudflare WARP** | MSI (64-bit) | system | レジストリ | 表示名検出 |
| **Zoom Workplace** | MSI (64-bit) | system | レジストリ | 表示名検出 / 自動更新 ON |
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

## 使い方

### 単体テスト
1. `build-and-verify-intunewin` を実行
2. アプリ名を選択して実行
3. Artifact (`.intunewin` / ログ) を確認

### 一括テスト
1. `build-and-verify-intunewin-apps` を実行
2. `apps/` 以下の全アプリが並列で検証される

## ドキュメント

| ドキュメント | 内容 |
|---|---|
| [docs/windows-quickstart.md](docs/windows-quickstart.md) | このリポジトリを使わず Windows 単体で `.intunewin` を 1 個作る最小手順 |
| [docs/yaml-schema.md](docs/yaml-schema.md) | `apps/*.yml` のスキーマ (フィールド一覧 / 許可される値 / 環境変数展開ルール) |
| [docs/verify-flow.md](docs/verify-flow.md) | `build-and-verify` が実行する 11 ステップ (build → install → detect → uninstall) |
| [docs/local-verify.md](docs/local-verify.md) | `scripts/local-run.ps1` で Intune を経由せず実機 install / uninstall を確認 |
| [docs/dev-setup.md](docs/dev-setup.md) | ローカル lint・pre-commit hook・PowerShell エンコーディング規約 |
| [docs/ci.md](docs/ci.md) | Lint CI のジョブ構成・自動 build-verify chain・CI 限定 Defender 例外 |

## 補足

このリポジトリは「Intune に入れてから失敗する」ケースを減らすための仕組み。本番展開前の最小限の実機確認は前提とする。
