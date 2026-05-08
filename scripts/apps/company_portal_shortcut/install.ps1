$ErrorActionPreference = "Stop"

$ShortcutPath = "$env:PUBLIC\Desktop\ポータルサイト.lnk"
$AppId        = "Microsoft.CompanyPortal_8wekyb3d8bbwe!App"

# WshShortcut.Save() は TargetPath を検証するため、
# UWPアプリ (shell:AppsFolder\...) を直接指定すると未インストール環境では失敗する。
# explorer.exe をターゲットにして AppsFolder URI を引数で渡す方式にする
# （Windows標準の "Send to Desktop" がUWPアプリで生成するのと同じ形式）。
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath  = "$env:WINDIR\explorer.exe"
$Shortcut.Arguments   = "shell:AppsFolder\$AppId"
$Shortcut.Description = "社内アプリのインストールはこちらから"
$Shortcut.Save()

if (Test-Path $ShortcutPath) {
    Write-Output "Shortcut created successfully."
    exit 0
} else {
    Write-Error "Shortcut creation failed."
    exit 1
}
