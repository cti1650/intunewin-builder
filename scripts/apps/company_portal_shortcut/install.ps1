$ErrorActionPreference = "Stop"

$ShortcutPath = "$env:PUBLIC\Desktop\ポータルサイト.lnk"
$TargetAppId  = "shell:AppsFolder\Microsoft.CompanyPortal_8wekyb3d8bbwe!App"

# ショートカット作成
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath  = $TargetAppId
$Shortcut.Description = "社内アプリのインストールはこちらから"
$Shortcut.Save()

# Intune検知用のファイルを作成（Win32アプリの検知ルール用）
if (Test-Path $ShortcutPath) {
    Write-Output "Shortcut created successfully."
    exit 0
} else {
    Write-Error "Shortcut creation failed."
    exit 1
}
