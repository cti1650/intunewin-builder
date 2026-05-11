$ErrorActionPreference = "Stop"

$AppxName     = "Microsoft.CompanyPortal"
# Slack 等の一般 UWP と違い、Company Portal は独自 URI プロトコル "companyportal:" を
# OS に登録している。shell:AppsFolder\...!<AppId> 経由だと AUMID 解決が壊れて
# クリックしても起動しない事象が出るため、公式 URI スキームに統一する。
$LaunchUri    = "companyportal:"
# user コンテキスト版: 実行ユーザの Desktop に作成する (リダイレクトされた
# Desktop フォルダにも追従するため [Environment]::GetFolderPath を使う)。
$DesktopDir   = [Environment]::GetFolderPath('Desktop')
$ShortcutPath = Join-Path $DesktopDir "ポータルサイト.lnk"
$Description  = "社内アプリのインストールはこちらから"

if (-not (Test-Path $DesktopDir)) {
    New-Item -Path $DesktopDir -ItemType Directory -Force | Out-Null
}

try {
    # WScript.Shell の Save() は en-US Windows などシステムロケールに含まれない
    # 文字を含むパスでは安定しない (例: ja の "ポータルサイト.lnk")。
    # 一旦 ASCII パスに保存してから NTFS の Move-Item で本来のパスへ移す。
    $TempShortcut = Join-Path $env:TEMP "_companyportal_shortcut.lnk"
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($TempShortcut)

    # explorer.exe + "companyportal:" URI で起動。URI ハンドラは HKCR\companyportal
    # に登録されているので Explorer がシェル経由で UWP を呼び出してくれる。
    $Shortcut.TargetPath  = "$env:WINDIR\explorer.exe"
    $Shortcut.Arguments   = $LaunchUri
    $Shortcut.Description = $Description

    # explorer.exe をターゲットにすると既定でフォルダ風アイコンになるため、
    # UWP本体の実行ファイル (CompanyPortal.exe) から IconLocation を引き当てる。
    # (App更新で InstallLocation のバージョン部分が変わると壊れる点は許容)
    $iconPath = $null
    $appx = Get-AppxPackage -Name $AppxName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($appx) {
        Write-Host "Found UWP app: $($appx.PackageFullName)"
        # 第1候補: AppxManifest.xml の Application.Executable
        try {
            $manifestPath = Join-Path $appx.InstallLocation "AppxManifest.xml"
            [xml]$manifest = Get-Content -LiteralPath $manifestPath -ErrorAction Stop
            $mainApp = $manifest.Package.Applications.Application | Select-Object -First 1
            $exeName = $mainApp.Executable
            if ($exeName) {
                $candidate = Join-Path $appx.InstallLocation $exeName
                if (Test-Path -LiteralPath $candidate) {
                    $iconPath = $candidate
                }
            }
        } catch {
            Write-Warning "Could not parse AppxManifest: $_"
        }
        # 第2候補: InstallLocation\CompanyPortal.exe を直接
        if (-not $iconPath) {
            $candidate = Join-Path $appx.InstallLocation "CompanyPortal.exe"
            if (Test-Path -LiteralPath $candidate) {
                $iconPath = $candidate
            }
        }
        # 第3候補: CompanyPortal*.exe を glob で拾う
        if (-not $iconPath) {
            $candidate = Get-ChildItem -LiteralPath $appx.InstallLocation -Filter "CompanyPortal*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($candidate) {
                $iconPath = $candidate.FullName
            }
        }
    }
    if ($iconPath) {
        $Shortcut.IconLocation = "$iconPath,0"
        Write-Host "Icon set to: $iconPath"
    } else {
        Write-Warning "$AppxName icon could not be resolved; shortcut will use default icon"
    }

    $Shortcut.Save()

    Move-Item -LiteralPath $TempShortcut -Destination $ShortcutPath -Force

    if (-not (Test-Path -LiteralPath $ShortcutPath)) {
        throw "Shortcut not found at expected path: $ShortcutPath"
    }
    Write-Output "Shortcut created successfully at: $ShortcutPath"
    exit 0
}
catch {
    Write-Error "Failed to create shortcut: $_"
    exit 1618
}
