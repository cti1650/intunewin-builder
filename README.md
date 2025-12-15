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
| **Slack** | MSI (64-bit) | ファイルパス | Machine-Wide Installer |
| **Cloudflare WARP** | MSI (64-bit) | レジストリ | 表示名検出 |
| **Zoom Workplace** | MSI (64-bit) | レジストリ | 表示名検出 / 自動更新ON |

## アプリ定義ファイル (YAML)

`apps/` ディレクトリに各アプリの定義ファイルを配置。

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
5. **インストール後スナップショット**: 差分を表示
6. **検出確認**: 定義した検出条件でインストール成功を確認
7. **アンインストール**: サイレントアンインストール実行
   * MSIの場合は ProductCode を自動抽出して実行
8. **アンインストール後スナップショット**: 削除された項目を表示
9. **削除確認**: アプリが検出されないことを確認
10. **結果サマリー**: 全ステップの成否を一覧表示

## 使い方

### 単体テスト
1. `build-and-verify-intunewin` を実行
2. アプリ名を選択して実行
3. Artifact (intunewin, ログ) を確認

### 一括テスト
1. `build-and-verify-intunewin-apps` を実行
2. `apps/` 以下の全アプリが並列で検証される

## 補足

このリポジトリは
「Intune に入れてから失敗する」ケースを減らすための仕組み。

本番展開前の最小限の実機確認は前提とする。
