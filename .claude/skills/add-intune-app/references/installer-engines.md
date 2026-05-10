# Installer Engines Reference

apps/*.yml の `installer.install_args` と `uninstall` を組み立てるための、エンジンごとのサイレント引数定型。**必ず公式ドキュメントで該当アプリの仕様を再確認すること**。アプリ固有のフラグ (例: `ALLUSERS=1`、`/MERGETASKS=`) はベンダー指定に従う。

## MSI (msiexec)

```yaml
installer:
  type: msi
  install_args: "/i {installer} /qn /norestart"

uninstall:
  type: msi
  args: "/x {product_code} /qn"
```

- `/qn`: 完全サイレント (UI 一切なし)
- `/norestart`: 再起動を抑止
- ProductCode は `build-and-verify` 時にレジストリから自動抽出される
- アプリ固有プロパティの例: `ALLUSERS=1` (machine-wide)、`AUTOUPDATE=true` 等。slack.yml / zoom.yml が参考

## EXE — Inno Setup

```yaml
installer:
  type: exe
  install_args: "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-"

uninstall:
  type: exe
  path: "C:\\Program Files\\<vendor>\\unins000.exe"
  args: "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
```

- `/VERYSILENT`: 進捗ダイアログも出さない
- `/SUPPRESSMSGBOXES`: 確認ダイアログ抑止
- `/SP-`: 「セットアップを実行しますか?」プロンプト抑止
- マシン全体インストールには `/ALLUSERS` が要るアプリもある (WinSCP 等)
- アンインストーラは固定で `unins000.exe` (まれに `unins001.exe`)

実例: [apps/gyazo.yml](../../../apps/gyazo.yml)

## EXE — NSIS

```yaml
installer:
  type: exe
  install_args: "/S"
```

- `/S` は大文字。小文字 `/s` は通らないことが多い
- アンインストーラは通常 `<install dir>\Uninstall.exe /S`
- per-user installer (Squirrel ベースの NSIS) は `--allusers` の有無で挙動が変わるアプリあり (Bitwarden 等)

実例: [apps/ovice.yml](../../../apps/ovice.yml)

## EXE — Bootstrapper (WiX Burn / 独自)

代表例: WebView2 Runtime、新版 Teams、Visual Studio Build Tools。

```yaml
installer:
  type: exe
  install_args: "/silent /install"   # アプリにより異なる
```

**完結しない (本体を別途 DL する)** ため build-and-verify が不安定になりがち。基本は採用回避するか、script_based 経由で扱う。

## EXE — Squirrel (per-user)

代表例: Discord、GitHub Desktop、Postman Agent。

```yaml
# 採用非推奨。SYSTEM context で詰む
```

`%LocalAppData%` 配下にインストールされる per-user installer。Intune の SYSTEM コンテキストで配信すると Win32 検出ルールも壊れる。Active Setup 等のラップ処理が要るため通常は採用しない。

## MSIX / MSIXBUNDLE

```yaml
script_based: true

installer:
  type: script
  install_args: ""

uninstall:
  type: script
  registry_name: "<package family name>"
```

`generic-install.ps1` が PowerShell の `Add-AppxProvisionedPackage` で system 配信する想定。Win32App として MSIX を扱う場合は **必ず script_based 経由**。直接 `installer.type: msix` で渡す経路は build-intunewin.ps1 にまだ実装されていない (実装する場合は別 PR)。

## カスタムスクリプト (custom_script: true)

ショートカット作成等の DL 不要ケース。

```yaml
script_based: true
custom_script: true

installer:
  type: script
  script: install.ps1

uninstall:
  type: script
  script: uninstall.ps1
```

PS1 は `scripts/apps/<name>/` 配下に置く。実例: [apps/company_portal_shortcut.yml](../../../apps/company_portal_shortcut.yml) と [scripts/apps/company_portal_shortcut/](../../../scripts/apps/company_portal_shortcut/)

## アンインストール特殊型

### registry_string

WiX Bootstrapper のように `UninstallString` がレジストリに動的に格納されるケース。

```yaml
uninstall:
  type: registry_string
  process_name: "<実行ファイル名 without .exe>"
```

レジストリの `Uninstall\*` から `DisplayName -like "*<name>*"` で検索して `QuietUninstallString` (なければ `UninstallString`) を実行する。実例: [apps/okta_verify.yml](../../../apps/okta_verify.yml)

## 検出条件 (detect ブロック)

エンジンに依らず最低限以下:

```yaml
detect:
  file: "C:\\Program Files\\<vendor>\\<app>.exe"      # 必須
  version: "<最低バージョン>"                          # 任意
  registry_display_name: "<部分一致でいい表示名>"     # MSI は必須に近い
```

- `version` を空にするとバージョン検査をスキップ
- `registry_display_name` は `-like "*<name>*"` で部分一致するため、「Mozilla Firefox」等のベース名で OK (バージョン込みの DisplayName を書かない)
- MSIX は `appx_name` (パッケージ名) を使う

### `detect.version` の値選びの注意

VersionCheck は `[version]'<installed>' -ge [version]'<pinned>'` で評価される。pin が **実機 install 結果より高い**と Failed になる。

**信頼できる情報源 (優先順)**:

1. **CI で `build-and-verify-intunewin -App <name>` を実走した結果の `InstalledVersion`** — これが正解。yml に書いてある download URL から落ちる実バイナリの版数なので、必ずパスする
2. **MSI の `ProductVersion`** (`scripts/build-intunewin.ps1` が `Get-InstallerVersion` で読み出す値) — レジストリ DisplayVersion と一致するのが普通
3. ベンダーの release notes / changelog — 参考程度

**信頼してはいけない情報源**:

- マーケティング / consumer / blog / release feed の版数。Enterprise / per-machine 配布版は別チャネルで遅延するケースがある
- 例: **Chrome は consumer stable channel と Enterprise MSI で別系統**。`versionhistory.googleapis.com` (consumer) は 148.0.7778.97 を返したが、`dl.google.com/chrome/install/googlechromestandaloneenterprise64.msi` は 147.0.7727.138 を配布していた (1〜2 マイナー遅延)
- 実バイナリを落として `Get-InstallerVersion` で確認するか、CI の verify サマリで `InstalledVersion` を見る方が安全

**運用フロー**:

新規アプリで version pin を決めるとき、または既存 yml の version を更新するときは:

1. `version` を空にした状態で PR を出して CI を回す
2. verify サマリの `InstalledVersion` 行を見る (例: `InstalledVersion: 147.0.7727.138`)
3. その値をそのまま `detect.version` に書き、別 commit で push して PR 更新

## 引数組み立てチェックリスト

PR を出す前に以下を全部確認:

- [ ] サイレント引数は **公式ドキュメントから引用** したか (推測ではない)
- [ ] `/norestart` 系の再起動抑止があるか
- [ ] machine-wide オプション (`ALLUSERS=1` 等) が必要か
- [ ] アンインストールが ProductCode 経由 / 固定パス / レジストリ動的取得のどれか確定したか
- [ ] アプリ固有のサイレント阻害要因 (例: 初回起動 wizard) が無いか
