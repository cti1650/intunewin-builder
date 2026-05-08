$ErrorActionPreference = "Stop"

$ShortcutPath = "$env:PUBLIC\Desktop\Slack.lnk"
$TargetPath   = "C:\Program Files\Slack\slack.exe"

# Public Desktop が無い環境(GitHub Actionsランナー等)に備えて親ディレクトリを保証
$ShortcutDir = Split-Path -Parent $ShortcutPath
if (-not (Test-Path $ShortcutDir)) {
    New-Item -Path $ShortcutDir -ItemType Directory -Force | Out-Null
}

$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath        = $TargetPath
$Shortcut.WorkingDirectory  = "C:\Program Files\Slack"
$Shortcut.Description       = "Slack"
$Shortcut.Save()

if (Test-Path $ShortcutPath) {
    Write-Output "Shortcut created successfully."
    exit 0
} else {
    Write-Error "Shortcut creation failed."
    exit 1
}
