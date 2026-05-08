$ErrorActionPreference = "Stop"

# Microsoft Store版 Slack の AppsFolder ID
$AppId        = "SlackTechnologiesInc.Slack_zvaqb2p7yp98r!Slack"
$ShortcutPath = "$env:PUBLIC\Desktop\Slack.lnk"

# Public Desktop が無い環境(GitHub Actionsランナー等)に備えて親ディレクトリを保証
$ShortcutDir = Split-Path -Parent $ShortcutPath
if (-not (Test-Path $ShortcutDir)) {
    New-Item -Path $ShortcutDir -ItemType Directory -Force | Out-Null
}

try {
    # UWPアプリへの直接リンクは Save() のターゲット検証で失敗するため、
    # explorer.exe + AppsFolder URI 引数で間接起動する形式にする
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath  = "$env:WINDIR\explorer.exe"
    $Shortcut.Arguments   = "shell:AppsFolder\$AppId"
    $Shortcut.Description = "Slack for Desktop"
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
