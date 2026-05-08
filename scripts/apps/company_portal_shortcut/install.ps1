$ErrorActionPreference = "Stop"

$AppxName     = "Microsoft.CompanyPortal"
$AppId        = "Microsoft.CompanyPortal_8wekyb3d8bbwe!App"
$ShortcutPath = "$env:PUBLIC\Desktop\ポータルサイト.lnk"

# Public Desktop が無い環境(GitHub Actionsランナー等)に備えて親ディレクトリを保証
$ShortcutDir = Split-Path -Parent $ShortcutPath
if (-not (Test-Path $ShortcutDir)) {
    New-Item -Path $ShortcutDir -ItemType Directory -Force | Out-Null
}

try {
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.Description = "社内アプリのインストールはこちらから"

    # UWP本体がインストール済みなら直接 shell:AppsFolder\<AppId> をターゲットにする。
    # → アイコンがUWPアプリ本体のものになり、クリックで確実に起動する。
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
    Write-Output "Shortcut created successfully."
    exit 0
}
catch {
    Write-Error "Failed to create shortcut: $_"
    exit 1618
}
