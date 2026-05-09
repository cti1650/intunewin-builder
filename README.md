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

| アプリ | インストーラ | 検出方法 | 備考 |
|--------|-------------|----------|------|
| **Google Chrome** | MSI (64-bit) | ファイルパス | Enterprise版 |
| **Mozilla Firefox** | MSI (64-bit) | ファイルパス | 日本語版 (`lang=ja`) |
| **Slack** | MSI (64-bit) | ファイルパス | Machine-Wide Installer |
| **Cloudflare WARP** | MSI (64-bit) | レジストリ | 表示名検出 |
| **Zoom Workplace** | MSI (64-bit) | レジストリ | 表示名検出 / 自動更新ON |
| **AWS CLI v2** | MSI (64-bit) | ファイルパス | クラウドエンジニア向け CLI |
| **Gyazo** | EXE (InnoSetup) | ファイルパス | スクリーンショット共有ツール |
| **ovice** | EXE (NSIS) | レジストリ | ユーザー固有パス ※script_based推奨 |
| **Company Portal Shortcut** | カスタム PowerShell | ファイルパス (.lnk) | Public Desktop にポータルサイトのショートカットを作成 |
| **Slack Shortcut** | カスタム PowerShell | ファイルパス (.lnk) | Public Desktop に Microsoft Store 版 Slack へのショートカットを作成 |

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
  type: msi | exe | msix
  args: アンインストール引数（{product_code}で自動置換）
  path: アンインストーラパス（EXE用、{version}で自動置換）
  package_name: パッケージ名（MSIX用）
```

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

## 補足

このリポジトリは
「Intune に入れてから失敗する」ケースを減らすための仕組み。

本番展開前の最小限の実機確認は前提とする。
