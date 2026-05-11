$ErrorActionPreference = "Stop"

# Microsoft Store版 Slack
# - Package Name: 91750D7E.Slack
# - PackageFamilyName: 91750D7E.Slack_8she8kybcnzg4
# - 91750D7E は Microsoft Store が Slack 社に割り当てた publisher hash
$AppxName     = "91750D7E.Slack"
$AppId        = "91750D7E.Slack_8she8kybcnzg4!Slack"
# user コンテキスト版: 実行ユーザの Desktop に作成する (リダイレクトされた
# Desktop フォルダにも追従するため [Environment]::GetFolderPath を使う)。
$DesktopDir   = [Environment]::GetFolderPath('Desktop')
$ShortcutPath = Join-Path $DesktopDir "Slack.lnk"
$Description  = "Slack for Desktop"

if (-not (Test-Path $DesktopDir)) {
    New-Item -Path $DesktopDir -ItemType Directory -Force | Out-Null
}

try {
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)

    # user 起動なら shell:AppsFolder\... を TargetPath に直接指定しても解決するが、
    # system 版と挙動を揃え、explorer.exe 経由で確実に起動させる形に統一する。
    $Shortcut.TargetPath  = "$env:WINDIR\explorer.exe"
    $Shortcut.Arguments   = "shell:AppsFolder\$AppId"
    $Shortcut.Description = $Description

    # explorer.exe をターゲットにすると既定でフォルダ風アイコンになるため、
    # UWP本体の実行ファイルから IconLocation を引き当てる。
    # (App更新で InstallLocation のバージョン部分が変わると壊れる点は許容)
    $appx = Get-AppxPackage -Name $AppxName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($appx) {
        Write-Host "Found UWP app: $($appx.PackageFullName)"
        try {
            $manifestPath = Join-Path $appx.InstallLocation "AppxManifest.xml"
            [xml]$manifest = Get-Content -LiteralPath $manifestPath -ErrorAction Stop
            $mainApp = $manifest.Package.Applications.Application | Select-Object -First 1
            $exeName = $mainApp.Executable
            if ($exeName) {
                $iconPath = Join-Path $appx.InstallLocation $exeName
                if (Test-Path -LiteralPath $iconPath) {
                    $Shortcut.IconLocation = "$iconPath,0"
                    Write-Host "Icon set to: $iconPath"
                }
            }
        } catch {
            Write-Warning "Could not set custom icon: $_"
        }
    } else {
        Write-Warning "$AppxName not installed for current user; icon will fall back to explorer.exe"
    }

    $Shortcut.Save()

    if (-not (Test-Path $ShortcutPath)) {
        throw "Shortcut not found at expected path: $ShortcutPath"
    }
    Write-Output "Slack shortcut created successfully at: $ShortcutPath"
    exit 0
}
catch {
    Write-Error "Failed to create shortcut: $_"
    exit 1618  # MSI retry code: Intuneに再試行させる
}
