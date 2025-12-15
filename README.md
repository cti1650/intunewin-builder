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

| アプリ | インストーラ | 検出方法 |
|--------|-------------|----------|
| Google Chrome | EXE | ファイル存在確認 |
| Slack | MSIX | Appxパッケージ |
| Cloudflare WARP | MSI | レジストリ |
| Zoom Workplace | MSI | レジストリ |

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
2. **インストール前スナップショット**: レジストリ・Appx一覧を取得
3. **インストール**: サイレントインストール実行
4. **インストール後スナップショット**: 差分を表示
5. **検出確認**: 定義した検出条件でインストール成功を確認
6. **アンインストール**: サイレントアンインストール実行
7. **アンインストール後スナップショット**: 削除された項目を表示
8. **削除確認**: アプリが検出されないことを確認

## 使い方

1. `build-intunewin` を実行して intunewin を作成
2. `verify-installer` を実行して事前検証
3. 問題なければ Intune に登録

## 補足

このリポジトリは
「Intune に入れてから失敗する」ケースを減らすための仕組み。

本番展開前の最小限の実機確認は前提とする。
