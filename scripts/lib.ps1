<#
.SYNOPSIS
  CI 側 (build / verify) で共有する PowerShell ヘルパー群。

.DESCRIPTION
  - YAML からアプリ定義を読む
  - IntuneWinAppUtil.exe を取得する (キャッシュ対応、再 DL 抑止)
  - Uninstall レジストリエントリを検索する

  generic-install.ps1 はエンドユーザー端末で .intunewin から実行されるため
  本ファイルへの依存は持たない (self-contained を維持)。

.NOTES
  使い方: 呼び出し側スクリプトの先頭で
    . "$PSScriptRoot/lib.ps1"
  と dot-source してから関数を呼ぶ。
#>

$script:UninstallRegistryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Get-AppDefinition {
    <#
    .SYNOPSIS
      apps/<App>.yml を読み、Organization プレースホルダを置換した定義を返す。
    #>
    param(
        [Parameter(Mandatory)][string]$App,
        [string]$Organization = '',
        [string]$AppsPath = 'apps'
    )

    $appDefPath = Join-Path $AppsPath "$App.yml"
    if (-not (Test-Path $appDefPath)) {
        throw "App definition not found: $appDefPath"
    }

    $appDef = Get-Content $appDefPath | ConvertFrom-Yaml

    if ($appDef.download.url) {
        $url = $appDef.download.url
        if ($Organization) {
            $url = $url -replace 'YOUR_ORGANIZATION', $Organization
        }
        if ($url -match 'YOUR_ORGANIZATION') {
            throw "URL contains 'YOUR_ORGANIZATION' placeholder. Please provide -Organization (GitHub Actions input: 'organization')."
        }
        $appDef.download.url = $url
    }

    return $appDef
}

function Get-IntuneWinAppUtilPath {
    <#
    .SYNOPSIS
      IntuneWinAppUtil.exe のフルパスを返す。未取得なら GitHub から取得・展開する。

    .DESCRIPTION
      $CacheDir 配下に IntuneWinAppUtil.exe が既に存在すれば再 DL せずパスを返す。
      これにより同一 CI run 内の重複呼び出しと、actions/cache 経由の cross-run キャッシュの
      両方を素直に成立させる。
    #>
    param(
        [string]$CacheDir = 'IntuneWinAppUtil',
        [string]$ZipUrl  = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/archive/refs/heads/master.zip'
    )

    $existing = Get-ChildItem -Path $CacheDir -Filter 'IntuneWinAppUtil.exe' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($existing) {
        Write-Host "Using cached IntuneWinAppUtil: $($existing.FullName)"
        return $existing.FullName
    }

    Write-Host "Downloading IntuneWinAppUtil..."
    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) 'IntuneWinAppUtil.zip'
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $CacheDir -Force
    Remove-Item -Path $zipPath -ErrorAction SilentlyContinue

    $tool = Get-ChildItem -Path $CacheDir -Filter 'IntuneWinAppUtil.exe' -Recurse |
        Select-Object -First 1
    if (-not $tool) {
        throw "IntuneWinAppUtil.exe not found after extraction in: $CacheDir"
    }
    return $tool.FullName
}

function Find-RegistryUninstallEntry {
    <#
    .SYNOPSIS
      DisplayName 部分一致で HKLM/HKCU の Uninstall レジストリを走査する。

    .OUTPUTS
      最初にマッチした PSObject (DisplayName, PSChildName, UninstallString,
      QuietUninstallString 等を含む)、無ければ $null。
    #>
    param(
        [Parameter(Mandatory)][string]$DisplayName
    )

    foreach ($path in $script:UninstallRegistryPaths) {
        $match = Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$DisplayName*" } |
            Select-Object -First 1
        if ($match) { return $match }
    }
    return $null
}
