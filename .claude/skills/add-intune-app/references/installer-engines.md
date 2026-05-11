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

### UWP / Store 版アプリへのショートカット作成パターン

Microsoft Store 配信の UWP アプリへのデスクトップショートカットを作る場合、起動方式は以下の優先順で選ぶ:

| 優先 | 起動方式 | 採用条件 | 例 |
|---|---|---|---|
| 1 | **専用 URI プロトコル** | アプリが `HKCR\<scheme>` を登録している (deep-linking 公式サポートあり) | `slack://open` / `companyportal:` / `msword:` / `onedrive:` |
| 2 | `shell:AppsFolder\<PFN>!<AppId>` フォールバック | URI ハンドラが無い UWP のみ | (該当なし。まずは URI を探すこと) |

**理由**: `shell:AppsFolder\...!<AppId>` の AUMID 解決は SYSTEM コンテキスト・パッケージ更新後の `InstallLocation` 変動・OS バージョンで壊れる。AUMID の末尾 (`!App` `!Slack` 等) は AppxManifest の `Application.Id` 由来でアプリごとに異なり、推測で書くと**クリックしても起動しない**。一方 URI スキームは Explorer がシェル経由で解決するので AUMID 変動の影響を受けない。

**確認済み URI スキーム**:

| アプリ | URI | 出典 |
|---|---|---|
| Slack (Store 版 / Desktop 版共通) | `slack://open` | [Slack Deep Linking Docs](https://docs.slack.dev/interactivity/deep-linking/) |
| Microsoft Company Portal | `companyportal:` | [Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/544416/company-portal-link-to-app) |

**実装テンプレ** (install.ps1 骨格):

```powershell
$ErrorActionPreference = "Stop"

$AppxName  = "<Package Name>"   # e.g. 91750D7E.Slack, Microsoft.CompanyPortal
$LaunchUri = "<scheme>://open"  # e.g. slack://open, companyportal:
$MainExe   = "<MainExe>"        # e.g. Slack, CompanyPortal (アイコン引き当て用)
# system 版: $ShortcutPath = "$env:PUBLIC\Desktop\<name>.lnk"
# user 版:   $ShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "<name>.lnk"

$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath  = "$env:WINDIR\explorer.exe"
$Shortcut.Arguments   = $LaunchUri
$Shortcut.Description = "<description>"

# アイコン解決: 3 段フォールバック
# explorer.exe を TargetPath にすると既定がフォルダ風アイコンになるため、
# UWP 本体 EXE のリソースから引き当てる必要がある。
$iconPath = $null
# system 版: Get-AppxPackage -AllUsers / user 版: Get-AppxPackage (引数なし)
$appx = Get-AppxPackage -AllUsers -Name $AppxName -ErrorAction SilentlyContinue | Select-Object -First 1
if ($appx) {
    # 第1: AppxManifest.xml の Application.Executable (理想形)
    try {
        [xml]$m = Get-Content -LiteralPath (Join-Path $appx.InstallLocation "AppxManifest.xml") -ErrorAction Stop
        $exe = ($m.Package.Applications.Application | Select-Object -First 1).Executable
        if ($exe) {
            $c = Join-Path $appx.InstallLocation $exe
            if (Test-Path -LiteralPath $c) { $iconPath = $c }
        }
    } catch {}
    # 第2: InstallLocation\<MainExe>.exe を直接 (AppxManifest が空・読めない時)
    if (-not $iconPath) {
        $c = Join-Path $appx.InstallLocation "$MainExe.exe"
        if (Test-Path -LiteralPath $c) { $iconPath = $c }
    }
    # 第3: <MainExe>*.exe を glob (バージョン入り EXE 名のとき)
    if (-not $iconPath) {
        $c = Get-ChildItem -LiteralPath $appx.InstallLocation -Filter "$MainExe*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { $iconPath = $c.FullName }
    }
}
if ($iconPath) { $Shortcut.IconLocation = "$iconPath,0" }

$Shortcut.Save()
```

**注意点**:

- **日本語ファイル名 (例: `ポータルサイト.lnk`)** は en-US Windows などシステムロケールに含まれない文字を含むパスで `WScript.Shell.Save()` が不安定。ASCII 一時パスに保存してから `Move-Item` で本来のパスに移す ([scripts/apps/company_portal_shortcut/install.ps1](../../../scripts/apps/company_portal_shortcut/install.ps1) 参照)
- **system 版 / user 版の両方を作るのが基本** (`<name>_shortcut.yml` と `<name>_shortcut_user.yml`)。system 版は `$env:PUBLIC\Desktop\`、user 版は `[Environment]::GetFolderPath('Desktop')` (リダイレクト追従)
- **`Get-AppxPackage` の引数**: system 版は `-AllUsers` を付ける (SYSTEM 自体は AppX を持たないため)、user 版は引数なしで現在ユーザのプロビジョン状態を見る
- **エラー時の exit code は `1618`** (MSI retry code: Intune に再試行させる)。`exit 1` は永久失敗扱いされる

**実例**: [scripts/apps/slack_shortcut/install.ps1](../../../scripts/apps/slack_shortcut/install.ps1)、[scripts/apps/company_portal_shortcut/install.ps1](../../../scripts/apps/company_portal_shortcut/install.ps1)

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

### `detect.file` の値も実機 install path を信頼する (version と同じ原則)

ベンダーのドキュメントから推定した install path が**実機と乖離する**ケースが本リポジトリでは複数発生している:

- **Gyazo Teams** ([apps/gyazo_teams.yml](../../../apps/gyazo_teams.yml)): "Gyazo Teams" 専用 dir を予想したが、実際は **regular Gyazo と install dir を共有** (`C:\Program Files (x86)\Gyazo\GyazoTeams.exe`)。Inno Setup の `DefaultDirName` が公開ドキュメントから読み取れず、innoextract でも内部 script を抽出できないため最終確定は CI 必須だった
- **Gyazo Teams (per-user 誤判定)**: 1 巡目の CI で「Not in Program Files」と出たため per-user (`%LocalAppData%`) と誤判定したが、実は **per-machine** (上記の通り)。CI の `Hint: registry InstallLocation = ...` 行が次の修正の決め手になった

運用フロー:

1. ベンダー想定の path で yml を作って CI を回す
2. 失敗したら verify サマリの `InstallPath` と Write-Host の `Hint: registry InstallLocation = ...` を読む
3. registry `InstallLocation` を信頼ソースにして `detect.file` を上書き
4. **path から `install_behavior` を機械的に決めない** (Program Files 配下でも per-user 設計の installer はあり得る)。`requestedExecutionLevel` や `PrivilegesRequired` を確認、UAC 昇格を要求しない (`asInvoker`) なら per-user 確定

### per-user installer (install_behavior: user) の追加要件

ovice ([apps/ovice.yml](../../../apps/ovice.yml)) のように `install_behavior: user` で配信する app は:

- **`detect.file` / `uninstall.path` には `%LocalAppData%` プレースホルダを必ず使う** (verify-installer は `Expand-EnvPath` で実パスに解決)
- **Intune の File-based detection rule は `%LocalAppData%` を解釈しない**ため、yml の `intune.detection` には Custom Detection Script を同梱する。テンプレ:

```yaml
intune:
  install_behavior: user
  install_command: "<setup>.exe /S"
  uninstall_command: "\"%LocalAppData%\\Programs\\<vendor>\\Uninstall.exe\" /S"
  detection:
    type: custom_script
    script: |
      if (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\<vendor>\<app>.exe')) {
          Write-Output 'Detected'
          exit 0
      }
      exit 1
```

operator は Intune UI の "Detection rules > Use a custom detection script" にこの script をそのまま貼り付ける。File-based detection rule で代替する道は無い (Microsoft 公式が user-context app に Custom Script を推奨)。

## 引数組み立てチェックリスト

PR を出す前に以下を全部確認:

- [ ] サイレント引数は **公式ドキュメントから引用** したか (推測ではない)
- [ ] `/norestart` 系の再起動抑止があるか
- [ ] machine-wide オプション (`ALLUSERS=1` 等) が必要か
- [ ] アンインストールが ProductCode 経由 / 固定パス / レジストリ動的取得のどれか確定したか
- [ ] アプリ固有のサイレント阻害要因 (例: 初回起動 wizard) が無いか
