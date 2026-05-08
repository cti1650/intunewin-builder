$ErrorActionPreference = "Stop"

# Microsoft Store版 Slack
# - Package Name: 91750D7E.Slack
# - PackageFamilyName: 91750D7E.Slack_8she8kybcnzg4
# - 91750D7E は Microsoft Store が Slack 社に割り当てた publisher hash
$AppxName     = "91750D7E.Slack"
$AppId        = "91750D7E.Slack_8she8kybcnzg4!Slack"
$ShortcutPath = "$env:PUBLIC\Desktop\Slack.lnk"

# Public Desktop が無い環境(GitHub Actionsランナー等)に備えて親ディレクトリを保証
$ShortcutDir = Split-Path -Parent $ShortcutPath
if (-not (Test-Path $ShortcutDir)) {
    New-Item -Path $ShortcutDir -ItemType Directory -Force | Out-Null
}

try {
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.Description = "Slack for Desktop"

    # UWP本体がインストール済みなら直接 shell:AppsFolder\<AppId> をターゲットにする。
    # → アイコンがSlack本体のものになり、クリックで確実にSlackが起動する。
    # 未インストール環境(CIランナー等)は Save() の検証に失敗するため
    # explorer.exe 経由のフォールバックでひとまず .lnk を生成する。
    $appx = Get-AppxPackage -AllUsers -Name $AppxName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($appx) {
        Write-Host "Found UWP app: $($appx.PackageFullName)"
        $Shortcut.TargetPath = "shell:AppsFolder\$AppId"
    } else {
        Write-Warning "$AppxName not installed; using explorer.exe fallback"
        $Shortcut.TargetPath = "$env:WINDIR\explorer.exe"
        $Shortcut.Arguments  = "shell:AppsFolder\$AppId"
    }
    $Shortcut.Save()

    if (-not (Test-Path $ShortcutPath)) {
        throw "Shortcut not found at expected path: $ShortcutPath"
    }
    Write-Output "Slack shortcut created successfully."
    exit 0
}
catch {
    Write-Error "Failed to create shortcut: $_"
    exit 1618  # MSI retry code: Intuneに再試行させる
}
