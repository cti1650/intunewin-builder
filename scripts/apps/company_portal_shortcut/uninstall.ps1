$ErrorActionPreference = "Stop"

$ShortcutPath = "$env:PUBLIC\Desktop\ポータルサイト.lnk"

if (Test-Path $ShortcutPath) {
    Remove-Item -Path $ShortcutPath -Force
    Write-Output "Shortcut removed successfully."
} else {
    Write-Output "Shortcut not found, nothing to remove."
}

exit 0
