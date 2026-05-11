$ErrorActionPreference = "Stop"

# Microsoft Store版 Slack
# - Package Name: 91750D7E.Slack
# - PackageFamilyName: 91750D7E.Slack_8she8kybcnzg4
# - 91750D7E は Microsoft Store が Slack 社に割り当てた publisher hash
$AppxName     = "91750D7E.Slack"
$MainExe      = "Slack"
# Slack は HKCR\slack に URI ハンドラを登録している (deep-linking 用)。
# 公式書式は "slack://open"。Ref: https://docs.slack.dev/interactivity/deep-linking/
$LaunchUri    = "slack://open"
$Description  = "Slack for Desktop"
$ShortcutPath = "$env:PUBLIC\Desktop\Slack.lnk"

# Public Desktop が無い環境(GitHub Actionsランナー等)に備えて親ディレクトリを保証
$ShortcutDir = Split-Path -Parent $ShortcutPath
if (-not (Test-Path $ShortcutDir)) {
    New-Item -Path $ShortcutDir -ItemType Directory -Force | Out-Null
}

try {
    # アイコン解決: 3 段フォールバック
    # UWP 本体 EXE (Slack.exe) のリソースから引き当てる。
    # (App更新で InstallLocation のバージョン部分が変わると壊れる点は許容)
    $iconPath = $null
    $appx = Get-AppxPackage -AllUsers -Name $AppxName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($appx) {
        Write-Host "Found UWP app: $($appx.PackageFullName)"
        # 第1候補: AppxManifest.xml の Application.Executable
        try {
            $manifestPath = Join-Path $appx.InstallLocation "AppxManifest.xml"
            [xml]$manifest = Get-Content -LiteralPath $manifestPath -ErrorAction Stop
            $mainApp = $manifest.Package.Applications.Application | Select-Object -First 1
            $exeName = $mainApp.Executable
            if ($exeName) {
                $candidate = Join-Path $appx.InstallLocation $exeName
                if (Test-Path -LiteralPath $candidate) {
                    $iconPath = $candidate
                }
            }
        } catch {
            Write-Warning "Could not parse AppxManifest: $_"
        }
        # 第2候補: InstallLocation\Slack.exe を直接
        if (-not $iconPath) {
            $candidate = Join-Path $appx.InstallLocation "$MainExe.exe"
            if (Test-Path -LiteralPath $candidate) {
                $iconPath = $candidate
            }
        }
        # 第3候補: Slack*.exe を glob で拾う
        if (-not $iconPath) {
            $candidate = Get-ChildItem -LiteralPath $appx.InstallLocation -Filter "$MainExe*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($candidate) {
                $iconPath = $candidate.FullName
            }
        }
    }

    # .lnk 作成。
    # TargetPath = powershell.exe、 Arguments = -Command "Start-Process '<uri>'"。
    # Arguments に URI を直接書く (例: "slack://open") と WScript.Shell.Save() が URL
    # Shortcut と誤判定して TargetPath を破棄する罠があるため、 PowerShell オプション
    # 形式 (-Command "...") で URI を包んで前置きすることで URL Shortcut 判定を回避する。
    # WindowStyle = 7 (Minimized) で PowerShell ウィンドウは表示されない。
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath  = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $Shortcut.Arguments   = "-NoProfile -WindowStyle Hidden -Command `"Start-Process '$LaunchUri'`""
    $Shortcut.Description = $Description
    $Shortcut.WindowStyle = 7
    if ($iconPath) {
        $Shortcut.IconLocation = "$iconPath,0"
        Write-Host "Icon set to: $iconPath"
    } else {
        Write-Warning "$AppxName icon could not be resolved; shortcut will use default icon"
    }
    $Shortcut.Save()

    if (-not (Test-Path -LiteralPath $ShortcutPath)) {
        throw "Shortcut not found at expected path: $ShortcutPath"
    }
    Write-Output "Slack shortcut created successfully."
    exit 0
}
catch {
    Write-Error "Failed to create shortcut: $_"
    exit 1618  # MSI retry code: Intuneに再試行させる
}
