$ErrorActionPreference = "Stop"

$ShortcutPath = "$env:PUBLIC\Desktop\ポータルサイト.lnk"
$AppId        = "Microsoft.CompanyPortal_8wekyb3d8bbwe!App"

# Public Desktop が無い環境(GitHub Actionsランナー等)に備えて親ディレクトリを保証
$ShortcutDir = Split-Path -Parent $ShortcutPath
if (-not (Test-Path $ShortcutDir)) {
    New-Item -Path $ShortcutDir -ItemType Directory -Force | Out-Null
}

# UWPアプリへの直接リンクは Save() のターゲット検証で失敗するため、
# explorer.exe + AppsFolder URI 引数で間接起動する形式にする
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
