# Windows でゼロから .intunewin を生成する最小手順

> [← README に戻る](../README.md)

新規セットアップの Windows 10 / 11 で `.intunewin` を 1 個作るための最小経路。`IntuneWinAppUtil.exe` (Microsoft 公式) 単体で完結し、PowerShell モジュール / .NET / Visual Studio 等の追加導入は不要。

このリポジトリの自動化 (lint / build-and-verify) を使わず **ローカル端末で 1 回だけ手作業で .intunewin を作る** ケース向け (例: 公開リポジトリに載せられない社内アプリ・テナント固有アプリの一発変換)。

## 1. IntuneWinAppUtil.exe を取得

[microsoft/Microsoft-Win32-Content-Prep-Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) から `.exe` を直接落とす。Microsoft 公式の安定 URL は [`go.microsoft.com/fwlink/?linkid=2065730`](https://go.microsoft.com/fwlink/?linkid=2065730) で、リポジトリへリダイレクトされる。バイナリ単発で取りたい場合:

```powershell
# master ブランチ (最新)
Invoke-WebRequest `
  -Uri "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe" `
  -OutFile "$env:USERPROFILE\Downloads\IntuneWinAppUtil.exe"
```

> バージョンを固定したい場合は [GitHub Releases](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases) からタグ付き .zip を落とす方が安定する (例: v1.8.7 / 2025-08-13、FIPS 対応版)。

## 2. パック対象を 1 ディレクトリにまとめる

```
C:\work\app\
  setup.exe        ← メインインストーラ (.msi / .exe / .msix のいずれか)
  config.xml       ← (任意) 同梱したい追加ファイル
  ...
```

`-s` に指定するファイル (= 後で Intune が install command で起動するエントリポイント) が **このフォルダ直下** にある必要がある。

> **重要**: `IntuneWinAppUtil.exe` 自体を `-c` で指定するフォルダに置かないこと。置くと .intunewin の中身に同梱されてしまう ([Microsoft Learn の注意書き](https://learn.microsoft.com/en-us/intune/app-management/deployment/create-win32-package#convert-the-win32-app-content) に明記)。

## 3. パック実行

```powershell
& "$env:USERPROFILE\Downloads\IntuneWinAppUtil.exe" `
    -c C:\work\app `
    -s setup.exe `
    -o C:\work\out `
    -q
```

| フラグ | 意味 |
|---|---|
| `-c` | コンテンツソースフォルダ (= 上記 `C:\work\app`) |
| `-s` | エントリポイントになるファイル名 (フォルダ直下からの相対) |
| `-o` | `.intunewin` の出力先ディレクトリ。存在しない場合は自動作成される |
| `-q` | quiet mode (確認プロンプト省略・既存ファイル上書き)。指定しないと対話モードで起動する |
| `-h` | ヘルプ表示 |
| `-a <catalog_folder>` | Win10 S mode のカタログフォルダ (通常は不要) |

出力: `C:\work\out\setup.intunewin`

このファイルをそのまま [Intune admin center](https://intune.microsoft.com/) の **Apps → Windows → Add → Windows app (Win32)** からアップロードする。

## 4. Intune admin center 側で設定する 3 点 (`.intunewin` の中身ではない)

`.intunewin` は「コンテンツ + 暗号化メタデータ」だけで、以下の 3 点は Intune Portal で operator が個別に貼り付ける:

### Install command の例

| インストーラ種別 | サンプル |
|---|---|
| MSI | `msiexec /i Firefox-Setup-x64.msi /qn /norestart` |
| EXE (InnoSetup) | `Gyazo-5.9.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-` |
| EXE (NSIS) | `ovice-x64-latest-Setup.exe /S` |

### Uninstall command の例

| インストーラ種別 | サンプル |
|---|---|
| MSI (ProductCode 指定) | `msiexec /x {12345678-1234-1234-1234-123456789012} /qn /norestart` |
| EXE (InnoSetup) | `"C:\Program Files (x86)\Gyazo\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART` |
| EXE (NSIS, system) | `"%ProgramFiles%\AppName\Uninstall.exe" /S` |
| EXE (NSIS, user) | `"%LocalAppData%\Programs\ovice\Uninstall ovice.exe" /S` |

> いずれも実例ベース ([apps/firefox.yml](../apps/firefox.yml) / [apps/gyazo.yml](../apps/gyazo.yml) / [apps/ovice.yml](../apps/ovice.yml) 参照)。サイレント引数は **インストーラのビルダごとに異なる** ので必ずベンダー or [Silent Install HQ](https://silentinstallhq.com/) 等で確認すること。
>
> ProductCode はインストール後にレジストリ `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*` から取得できる。MSI なら `Get-WmiObject Win32_Product | Where-Object Name -like 'AppName*' | Select IdentifyingNumber` でも可。

### Detection rule (検出ルール)

Intune がインストール成功を判定するための条件。3 種類のいずれかを設定する:

| 種類 | 設定例 |
|---|---|
| **File** | パス `C:\Program Files\AppName\app.exe` 存在 (バージョン比較も可) |
| **Registry** | キー `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\<DisplayName>` の `DisplayName` が値あり |
| **MSI** | ProductCode 一致 (MSI のみ。Intune が自動補完することが多い) |

## 制約

| 項目 | 上限 / 制約 |
|---|---|
| パッケージサイズ | [30 GB 上限](https://learn.microsoft.com/en-us/intune/app-management/deployment/create-win32-package#prerequisites) (Intune service / 元のソース合計サイズに対して) |
| エントリポイント | 1 ファイル (`-s` で 1 つだけ指定可) |
| インストーラ要件 | サイレントインストール対応必須 (ユーザー操作不要で完走できること) |
| 暗号化 | コンテンツは自動的に暗号化される (鍵情報は `.intunewin` 内の Detection.xml に格納される) |

## 参照

- 公式ツール: [microsoft/Microsoft-Win32-Content-Prep-Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) ([Releases](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases))
- Microsoft Learn: [Prepare a Win32 app to be uploaded to Microsoft Intune](https://learn.microsoft.com/en-us/intune/app-management/deployment/create-win32-package)
- Microsoft Learn: [Add a Win32 app to Microsoft Intune](https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-win32-add) — install command / uninstall command / detection rule の Portal 入力欄に関する詳細
