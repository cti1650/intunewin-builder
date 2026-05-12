# build-and-verify の 11 ステップ

> [← README に戻る](../README.md)

`.github/workflows/build-and-verify.yml` (および同 `-apps.yml`) が Windows runner で実行する検証フロー。`.intunewin` 生成だけでなく **インストール → 検出 → アンインストール → 削除確認** までを 1 サイクルで回す。

| # | ステップ | 内容 |
|---|---|---|
| 1 | **ビルド** | インストーラを download.url から取得し `.intunewin` を生成 |
| 2 | **静的解析** | ファイルヘッダーによる形式確認 + OS (64/32bit) とインストーラのアーキテクチャ不一致チェック |
| 3 | **インストール前スナップショット** | レジストリ / Appx 一覧を取得 (差分比較用) |
| 4 | **インストール** | サイレントインストール実行 (タイムアウト監視付き)。実行コマンドと終了コードをログ出力 |
| 5 | **インストール後スナップショット** | 差分を表示 |
| 6 | **検出確認** | YAML の `detect` ブロックの条件でインストール成功を確認 |
| 7 | **インストール場所チェック** | x64 / x86 両方の Program Files を確認し、どちらにインストールされたかをレポート |
| 8 | **アンインストール** | サイレントアンインストール実行。MSI は ProductCode を自動抽出、EXE は定義された uninstaller を実行 |
| 9 | **アンインストール後スナップショット** | 削除された項目を表示 |
| 10 | **削除確認** | アプリが検出されないことを確認 |
| 11 | **結果サマリー** | 全ステップの成否を一覧表示 |

## 実装

- メインスクリプト: [scripts/verify-installer.ps1](../scripts/verify-installer.ps1)
- ビルド: [scripts/build-intunewin.ps1](../scripts/build-intunewin.ps1) / [scripts/build-script-based.ps1](../scripts/build-script-based.ps1)
- インストール dispatch: [scripts/generic-install.ps1](../scripts/generic-install.ps1)
- workflow: [.github/workflows/build-and-verify.yml](../.github/workflows/build-and-verify.yml) / [build-and-verify-apps.yml](../.github/workflows/build-and-verify-apps.yml)
