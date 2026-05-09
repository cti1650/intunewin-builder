---
name: add-intune-app
description: intunewin-builder リポジトリに新規アプリ定義を追加するときに使う。apps/<name>.yml と apps/<name>_script_based.yml の対を生成し、build-and-verify.yml の choice options 更新、README 反映、lint 通過確認、PR 作成までを一貫して扱う。トリガー: 「アプリを追加して」「<アプリ名> を apps に入れて」「Firefox を intunewin 化したい」など、apps/*.yml 追加が必要な依頼。
---

# Add Intune App

新規アプリを `apps/*.yml` に追加し、関連ファイルを更新して PR を切るまでの一連の手順。

## 前提

ユーザーから具体的なアプリ名と URL が提示されているか、[intune-app-researcher](../../agents/intune-app-researcher.md) サブエージェントの調査結果がある状態を想定する。URL や install_args が未確定の場合は先にリサーチを依頼する。

## 採用判定の事前チェック

進める前に以下を必ず満たすか確認する。満たさないなら追加を中止して理由を伝える:

- [ ] **URL 固定性**: A 級 (latest 固定) または B 級 (GitHub Releases latest API)。C 級なら script_based 専用 + クローラ実装が必要
- [ ] **完結性**: Bootstrapper でない単一インストーラ (Bootstrapper は build-and-verify が安定しないことがある)
- [ ] **サイレントインストール可能**: `/qn`、`/S`、`/VERYSILENT` 等のフラグが公式ドキュメントで案内されている
- [ ] **system context で動く**: per-user installer (Squirrel 系) は基本不可
- [ ] **Microsoft Store 未配布**: Store 配布があるなら Intune の Store 配信機能を使うべきで、Win32 化非推奨
- [ ] **配布ライセンス**: 商用無償、または明示的な配布許諾あり

## 手順

### 1. URL 検証 (実行必須)

```bash
curl -sIL "<URL>" | head -30
```

- 最終レスポンスが `200 OK`、`Content-Type` が `application/x-msi`/`application/octet-stream`/`binary/octet-stream` 等のバイナリであること
- `text/html` を返す場合は SourceForge mirror page 等の罠。A 級ではない
- `Content-Length` でサイズを記録

### 2. インストーラ種別と install_args の決定

エンジンごとの定型は [references/installer-engines.md](references/installer-engines.md) を参照。判別方法:

- 拡張子 `.msi` → MSI (`/i {installer} /qn /norestart`)
- 拡張子 `.exe` → 起動時に `--help` で確認、または公式ドキュメント記載のサイレント引数
- 拡張子 `.msix`/`.msixbundle` → MSIX (script_based 経由で `Add-AppxProvisionedPackage`)

### 3. 既存パターンに合わせて YAML 2 本作成

通常版テンプレ (MSI):

```yaml
name: <name>

download:
  url: <verified URL>
  file: <download filename>

installer:
  type: msi
  install_args: "/i {installer} /qn /norestart"

detect:
  file: "C:\\Program Files\\<vendor>\\<app>.exe"
  registry_display_name: "<DisplayName>"

uninstall:
  type: msi
  args: "/x {product_code} /qn"

# ==========
# Intune Win32アプリ設定値（参照用）
# ==========
intune:
  # Intune の "Install behavior" 設定値: system (per-machine) / user (per-user)
  # MSI per-machine インストーラは原則 system。NSIS per-user 系 (例: ovice) は user
  install_behavior: system
  install_command: "msiexec /i <file> /qn /norestart"
  uninstall_command: 'msiexec /x "{ProductCode}" /qn'
  detection:
    type: file
    path: "C:\\Program Files\\<vendor>"
    file: "<app>.exe"
```

script_based 版テンプレ:

```yaml
name: <name>_script_based

script_based: true

download:
  url: <verified URL>

installer:
  type: script
  install_args: ""

detect:
  file: "C:\\Program Files\\<vendor>\\<app>.exe"
  registry_display_name: "<DisplayName>"

uninstall:
  type: script
  registry_name: "<DisplayName>"

intune:
  install_behavior: system
```

`intune.install_behavior` は必須フィールドで `system` または `user` のみ受け付ける ([scripts/check-apps-schema.ps1](../../scripts/check-apps-schema.ps1) で機械検証)。ユーザーコンテキストインストーラ (NSIS の per-user / Squirrel 等) のみ `user` を選び、検出パスは `%LocalAppData%` プレースホルダで書く ([apps/ovice.yml](../../apps/ovice.yml) 参照)。

EXE / MSIX / 特殊ケースの引数は [references/installer-engines.md](references/installer-engines.md) を参照。

### 4. build-and-verify.yml の choice options を更新

[.github/workflows/build-and-verify.yml](../../.github/workflows/build-and-verify.yml) の `inputs.app.options` に **通常版のみ** をアルファベット順で追加。

`_script_based` や `_shortcut` は追加しない (lint の choice-list ジョブで弾かれる)。

### 5. README の対応アプリ表を更新

[README.md](../../README.md) の「対応アプリ」テーブルに 1 行追加:

```markdown
| **<DisplayName>** | <種別> (64-bit) | <検出方法> | <備考> |
```

### 6. ローカルで lint 通過確認

`pwsh` が入っているなら必ず実行:

```bash
./scripts/dev-check.sh                       # *.ps1 構文 (今回は触らないが念のため)
pwsh -File scripts/check-apps-schema.ps1     # 必須フィールド確認
pwsh -File scripts/check-choice-list.ps1     # choice options 整合性
```

`pwsh` 未導入なら CI で確認する旨をコミットメッセージに残す。

### 7. ブランチ・コミット・PR

```bash
git checkout -b feat/add-<name>
git add apps/<name>.yml apps/<name>_script_based.yml \
        .github/workflows/build-and-verify.yml README.md
git commit -m "feat: <DisplayName> を対応アプリに追加"
git push -u origin feat/add-<name>
gh pr create --title "feat: <DisplayName> を対応アプリに追加" --body "<要約>"
```

PR description には以下を必ず含める:

- URL の検証結果 (`curl -sIL` の最終 `Content-Length` と `Content-Type`)
- URL 安定性 (A / B 級)
- サイズと ARM64 対応の有無
- 検出条件 (`detect.file` のパスとレジストリ表示名)
- Test plan: build-and-verify-intunewin の手動実行で動作確認

### 8. CI lint の通過確認

PR を作ったら自動で `lint.yml` の 4 ジョブが回る。全 green になったら build-and-verify を手動実行して実機検証する。

## 失敗パターンと対処

| 症状 | 原因 | 対処 |
|---|---|---|
| `apps-schema` が `name does not match filename` | `name:` フィールドとファイル名 (拡張子除く) がずれている | どちらかを揃える |
| `choice-list` で `missing` | 通常版 yml を追加したが build-and-verify.yml の options に入れ忘れ | options に追加 |
| `choice-list` で `extra` | `_script_based` や `_shortcut` を options に入れている | 通常版だけにする |
| MSI ダウンロード後 `WARNING: File does not appear to be a valid MSI` | URL が HTML mirror page を返している | A 級判定を見直す。SourceForge 系なら別 URL を探す |
| install で exit code 1603 | サイレント引数が誤り or 既存インストールと競合 | 公式ドキュメントを再確認、`MSIRESTARTMANAGERCONTROL=Disable` 等の追加引数を検討 |

## 参考リファレンス

- [references/installer-engines.md](references/installer-engines.md) — エンジンごとのサイレント引数定型
- [README.md](../../README.md) — スキーマ定義の正本
- [intune-app-researcher](../../agents/intune-app-researcher.md) — 候補調査用サブエージェント
