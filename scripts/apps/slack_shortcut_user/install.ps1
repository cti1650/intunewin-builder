$ErrorActionPreference = "Stop"

# Microsoft Store版 Slack
# - Package Name: 91750D7E.Slack
# - PackageFamilyName: 91750D7E.Slack_8she8kybcnzg4
# - 91750D7E は Microsoft Store が Slack 社に割り当てた publisher hash
$AppxName     = "91750D7E.Slack"
# Slack は OS に独自 URI プロトコル "slack:" を登録している (deep-linking 用)。
# shell:AppsFolder\<PFN>!<AppId> 経由は AUMID 解決が壊れるリスクがある一方、
# URI スキームは HKCR\slack に登録されているため Explorer がシェル経由で確実に
# 解決する。公式書式は "slack://open"。
# Ref: https://docs.slack.dev/interactivity/deep-linking/
$LaunchUri    = "slack://open"
# user コンテキスト版: 実行ユーザの Desktop に作成する (リダイレクトされた
# Desktop フォルダにも追従するため [Environment]::GetFolderPath を使う)。
$DesktopDir   = [Environment]::GetFolderPath('Desktop')
$ShortcutPath = Join-Path $DesktopDir "Slack.lnk"
$Description  = "Slack for Desktop"

if (-not (Test-Path $DesktopDir)) {
    New-Item -Path $DesktopDir -ItemType Directory -Force | Out-Null
}

try {
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)

    # explorer.exe + "slack://open" URI で起動。Slack の URI ハンドラ
    # (HKCR\slack) 経由で UWP がシェルから呼び出される。
    $Shortcut.TargetPath  = "$env:WINDIR\explorer.exe"
    $Shortcut.Arguments   = $LaunchUri
    $Shortcut.Description = $Description

    # explorer.exe をターゲットにすると既定でフォルダ風アイコンになるため、
    # UWP本体の実行ファイル (Slack.exe) から IconLocation を引き当てる。
    # (App更新で InstallLocation のバージョン部分が変わると壊れる点は許容)
    $iconPath = $null
    $appx = Get-AppxPackage -Name $AppxName -ErrorAction SilentlyContinue | Select-Object -First 1
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
            $candidate = Join-Path $appx.InstallLocation "Slack.exe"
            if (Test-Path -LiteralPath $candidate) {
                $iconPath = $candidate
            }
        }
        # 第3候補: Slack*.exe を glob で拾う
        if (-not $iconPath) {
            $candidate = Get-ChildItem -LiteralPath $appx.InstallLocation -Filter "Slack*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($candidate) {
                $iconPath = $candidate.FullName
            }
        }
    }
    if ($iconPath) {
        $Shortcut.IconLocation = "$iconPath,0"
        Write-Host "Icon set to: $iconPath"
    } else {
        Write-Warning "$AppxName icon could not be resolved; shortcut will use default icon"
    }

    $Shortcut.Save()

    if (-not (Test-Path $ShortcutPath)) {
        throw "Shortcut not found at expected path: $ShortcutPath"
    }
    Write-Output "Slack shortcut created successfully at: $ShortcutPath"
    exit 0
}
catch {
    Write-Error "Failed to create shortcut: $_"
    exit 1618  # MSI retry code: Intuneに再試行させる
}
