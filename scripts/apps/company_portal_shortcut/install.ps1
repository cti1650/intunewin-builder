$ErrorActionPreference = "Stop"

$AppxName     = "Microsoft.CompanyPortal"
$MainExe      = "CompanyPortal"
# Company Portal は HKCR\companyportal に URI ハンドラを登録しているので、
# PowerShell の Start-Process 経由で起動する。
$LaunchUri    = "companyportal:"
$Description  = "社内アプリのインストールはこちらから"
$ShortcutPath = "$env:PUBLIC\Desktop\ポータルサイト.lnk"

# Public Desktop が無い環境(GitHub Actionsランナー等)に備えて親ディレクトリを保証
$ShortcutDir = Split-Path -Parent $ShortcutPath
if (-not (Test-Path $ShortcutDir)) {
    New-Item -Path $ShortcutDir -ItemType Directory -Force | Out-Null
}

try {
    # アイコン解決: 3 段フォールバック
    # UWP 本体 EXE (CompanyPortal.exe) のリソースから引き当てる。
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
        # 第2候補: InstallLocation\CompanyPortal.exe を直接
        if (-not $iconPath) {
            $candidate = Join-Path $appx.InstallLocation "$MainExe.exe"
            if (Test-Path -LiteralPath $candidate) {
                $iconPath = $candidate
            }
        }
        # 第3候補: CompanyPortal*.exe を glob で拾う
        if (-not $iconPath) {
            $candidate = Get-ChildItem -LiteralPath $appx.InstallLocation -Filter "$MainExe*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($candidate) {
                $iconPath = $candidate.FullName
            }
        }
    }

    # .lnk 作成。
    # TargetPath = powershell.exe (固定パス)、 Arguments = -Command "Start-Process '<uri>'"。
    # Arguments に URI を直接書く (例: "companyportal:") と WScript.Shell.Save() が URL
    # Shortcut と誤判定して TargetPath を破棄する罠があるため、 PowerShell オプション
    # 形式 (-Command "...") で URI を包んで前置きすることで URL Shortcut 判定を回避する。
    # WindowStyle = 7 (Minimized) で PowerShell ウィンドウは表示されない。
    #
    # WScript.Shell の Save() は en-US Windows などシステムロケールに含まれない
    # 文字を含むパスでは安定しないので (例: ja の "ポータルサイト.lnk")、
    # ASCII 一時パスに保存してから Move-Item で本来のパスへ移す。
    $TempShortcut = Join-Path $env:TEMP "_companyportal_shortcut.lnk"
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($TempShortcut)
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

    Move-Item -LiteralPath $TempShortcut -Destination $ShortcutPath -Force

    if (-not (Test-Path -LiteralPath $ShortcutPath)) {
        throw "Shortcut not found at expected path: $ShortcutPath"
    }
    Write-Output "Shortcut created successfully."
    exit 0
}
catch {
    Write-Error "Failed to create shortcut: $_"
    exit 1618
}
