$ErrorActionPreference = "Stop"

$DesktopDir   = [Environment]::GetFolderPath('Desktop')
$ShortcutPath = Join-Path $DesktopDir "Slack.lnk"

if (Test-Path -LiteralPath $ShortcutPath) {
    Remove-Item -LiteralPath $ShortcutPath -Force
    Write-Output "Shortcut removed: $ShortcutPath"
} else {
    Write-Output "Shortcut not found, nothing to remove: $ShortcutPath"
}

exit 0
