# アプリ定義ファイル (apps/*.yml) スキーマ

> [← README に戻る](../README.md)

`apps/` ディレクトリ配下の YAML が CI のすべての入口。`scripts/check-apps-schema.ps1` が lint で機械的に検証する。

## デプロイ方式 (3 種)

| 方式 | ファイル名 | 内容 |
|---|---|---|
| 通常 (MSI/EXE/MSIX) | `<name>.yml` | ビルド時にインストーラを DL して同梱 |
| script_based | `<name>_script_based.yml` | 端末側で `generic-install.ps1` が URL から取得して実行 |
| custom_script | `<name>_shortcut.yml` 等 (`custom_script: true`) | `scripts/apps/<name>/` の任意の PS1 を同梱 (DL 不要) |

通常版と script_based 版の **両方を作るのが基本**。`build-and-verify.yml` の `workflow_dispatch.inputs.app.options` には通常版だけをアルファベット順に追加する (`choice-list` lint が整合性を保証)。

## 全フィールド

```yaml
name: アプリ名               # 必須。ファイル名 (拡張子除く) と一致させる

download:
  url: ダウンロード URL      # custom_script: true 以外は必須
  file: 保存ファイル名       # script_based: true 以外は必須

installer:
  type: msi | exe | msix | script
  install_args: インストール引数  # {installer} でパス置換
  timeout: タイムアウト秒数       # 任意 (既定 600)

detect:                            # 必須ブロック
  file: ファイルパス             # EXE 用。%LocalAppData% 等の環境変数可
  version: 必要最低バージョン    # 任意。空欄でスキップ
  registry_display_name: 表示名  # MSI 用
  appx_name: パッケージ名         # MSIX 用

uninstall:
  type: msi | exe | msix | script | registry_string
  args: アンインストール引数      # {product_code} で自動置換
  path: アンインストーラパス      # EXE 用。{version} / 環境変数で展開
  package_name: パッケージ名      # MSIX 用

intune:
  install_behavior: system | user  # 必須。Intune の "Install behavior" にそのまま入れる値
  install_command: ...             # 参照用 (operator が Intune UI に貼る)
  uninstall_command: ...           # 参照用
  detection: ...                   # 参照用
```

## 機械的に検証されるルール

| フィールド | 許可される値 |
|---|---|
| `installer.type` | `msi`, `exe`, `msix`, `script` |
| `uninstall.type` | `msi`, `exe`, `msix`, `script`, `registry_string` |
| `intune.install_behavior` | `system`, `user` (必須) |

加えて:

- `name` フィールドはファイル名 (拡張子除く) と一致させる
- `custom_script: true` でない場合は `download.url` 必須
- `script_based: true` でない場合は `download.file` 必須
- `detect` ブロックは必須

## 環境変数の展開

`detect.file` / `uninstall.path` には `%LocalAppData%`、`%ProgramFiles%`、`%ProgramFiles(x86)%` 等の Windows 環境変数を埋め込める。`scripts/verify-installer.ps1` が `Expand-EnvPath` で実行時に展開する。

`install_behavior: user` のアプリは原則 `%LocalAppData%` プレースホルダ表記を使う ([apps/ovice.yml](../apps/ovice.yml) 参照)。

## 関連ファイル

- スキーマ検証スクリプト: [scripts/check-apps-schema.ps1](../scripts/check-apps-schema.ps1)
- ビルドエントリ: [scripts/build-intunewin.ps1](../scripts/build-intunewin.ps1) / [scripts/build-script-based.ps1](../scripts/build-script-based.ps1)
- インストール / 検出 / アンインストール dispatch: [scripts/verify-installer.ps1](../scripts/verify-installer.ps1)
