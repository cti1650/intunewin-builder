$ErrorActionPreference = "Stop"

$ShortcutPath = "$env:PUBLIC\Desktop\Slack.lnk"

if (Test-Path -LiteralPath $ShortcutPath) {
    Remove-Item -LiteralPath $ShortcutPath -Force
    Write-Output "Shortcut removed: $ShortcutPath"
} else {
    Write-Output "Shortcut not found, nothing to remove: $ShortcutPath"
}

exit 0
