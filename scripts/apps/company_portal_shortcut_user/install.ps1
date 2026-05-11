$ErrorActionPreference = "Stop"

$AppxName     = "Microsoft.CompanyPortal"
$MainExe      = "CompanyPortal"
# Company Portal は HKCR\companyportal に URI ハンドラを登録しているので、
# PowerShell の Start-Process 経由で起動する。
$LaunchUri    = "companyportal:"
$Description  = "社内アプリのインストールはこちらから"
# user コンテキスト版: 実行ユーザの Desktop に作成 (リダイレクト対応)
$DesktopDir   = [Environment]::GetFolderPath('Desktop')
$ShortcutPath = Join-Path $DesktopDir "ポータルサイト.lnk"

if (-not (Test-Path $DesktopDir)) {
    New-Item -Path $DesktopDir -ItemType Directory -Force | Out-Null
}

try {
    # アイコン解決: 3 段フォールバック
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
            $candidate = Join-Path $appx.InstallLocation "$MainExe.exe"
            if (Test-Path -LiteralPath $candidate) {
                $iconPath = $candidate
            }
        }
        # 第3候補: CompanyPortal*.exe を glob で拾う
        if (-not $iconPath) {
            $candidate = Get-ChildItem -LiteralPath $appx.InstallLocation -Filter "$MainExe*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($candidate) {
                $iconPath = $candidate.FullName
            }
        }
    }

    # .lnk 作成 (詳細は system 版コメント参照)。日本語パス対策で一時パス退避 + Move-Item。
    $TempShortcut = Join-Path $env:TEMP "_companyportal_shortcut.lnk"
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($TempShortcut)
    $Shortcut.TargetPath  = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $Shortcut.Arguments   = "-NoProfile -WindowStyle Hidden -Command `"Start-Process '$LaunchUri'`""
    $Shortcut.Description = $Description
    $Shortcut.WindowStyle = 7
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
