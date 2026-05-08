$ErrorActionPreference = "Stop"

$AppxName     = "Microsoft.CompanyPortal"
$AppId        = "Microsoft.CompanyPortal_8wekyb3d8bbwe!App"
$ShortcutPath = "$env:PUBLIC\Desktop\ポータルサイト.lnk"
$Description  = "社内アプリのインストールはこちらから"

# Public Desktop が無い環境(GitHub Actionsランナー等)に備えて親ディレクトリを保証
$ShortcutDir = Split-Path -Parent $ShortcutPath
if (-not (Test-Path $ShortcutDir)) {
    New-Item -Path $ShortcutDir -ItemType Directory -Force | Out-Null
}

try {
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)

    # Public Desktop に置く UWP ショートカットは TargetPath = shell:AppsFolder\... を
    # 直接指定するとクリックしても起動しない (システムコンテキストでの解決が機能しないため)。
    # explorer.exe + AppsFolder URI 引数で確実に起動させる形式にする。
    $Shortcut.TargetPath  = "$env:WINDIR\explorer.exe"
    $Shortcut.Arguments   = "shell:AppsFolder\$AppId"
    $Shortcut.Description = $Description

    # explorer.exe をターゲットにすると既定でフォルダ風アイコンになるため、
    # UWP本体の実行ファイルから IconLocation を引き当てる。
    # (App更新で InstallLocation のバージョン部分が変わると壊れる点は許容)
    $appx = Get-AppxPackage -AllUsers -Name $AppxName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($appx) {
        Write-Host "Found UWP app: $($appx.PackageFullName)"
        try {
            $manifestPath = Join-Path $appx.InstallLocation "AppxManifest.xml"
            [xml]$manifest = Get-Content -LiteralPath $manifestPath -ErrorAction Stop
            $mainApp = $manifest.Package.Applications.Application | Select-Object -First 1
            $exeName = $mainApp.Executable
            if ($exeName) {
                $iconPath = Join-Path $appx.InstallLocation $exeName
                if (Test-Path -LiteralPath $iconPath) {
                    $Shortcut.IconLocation = "$iconPath,0"
                    Write-Host "Icon set to: $iconPath"
                }
            }
        } catch {
            Write-Warning "Could not set custom icon: $_"
        }
    } else {
        Write-Warning "$AppxName not installed; icon will fall back to explorer.exe"
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
