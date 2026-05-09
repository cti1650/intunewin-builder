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

function Get-AppFiles {
    <#
    .SYNOPSIS
      apps/*.yml を全件返す (FileInfo[])。
    #>
    param([string]$AppsPath = 'apps')
    return Get-ChildItem -Path $AppsPath -Filter *.yml -File | Sort-Object Name
}

function Get-ChoiceListAppNames {
    <#
    .SYNOPSIS
      build-and-verify.yml の choice options 用に、通常版だけを抽出した
      アプリ名 (BaseName) のソート済み配列を返す。

    .DESCRIPTION
      script_based: true / custom_script: true / ファイル名末尾 _script_based の
      いずれかに該当するものは除外する。
    #>
    param([string]$AppsPath = 'apps')
    return Get-AppFiles -AppsPath $AppsPath | ForEach-Object {
        if ($_.BaseName -match '_script_based$') { return }
        $def = Get-Content $_.FullName -Raw | ConvertFrom-Yaml
        if ($def.script_based -eq $true) { return }
        if ($def.custom_script -eq $true) { return }
        $_.BaseName
    } | Where-Object { $_ } | Sort-Object
}

function Get-NestedValue {
    <#
    .SYNOPSIS
      ドット区切りキーパス (例: 'installer.type') で hashtable / PSObject から値を取り出す。
    #>
    param($Object, [string]$KeyPath)
    $current = $Object
    foreach ($key in $KeyPath -split '\.') {
        if ($null -eq $current) { return $null }
        if ($current -is [hashtable]) {
            if (-not $current.ContainsKey($key)) { return $null }
            $current = $current[$key]
        } else {
            $prop = $current.PSObject.Properties[$key]
            if (-not $prop) { return $null }
            $current = $prop.Value
        }
    }
    return $current
}

function Expand-EnvPath {
    <#
    .SYNOPSIS
      detect.file / detect.path / detect.appx_name 等に含まれる
      %LocalAppData% / %ProgramFiles% 等の環境変数を現在のプロセスで展開して返す。

    .DESCRIPTION
      install_behavior: user のアプリでは detect.file が %LocalAppData% プレフィックス
      で書かれることが多い。verify-installer の Test-Path 等で実パスへ展開するための薄い wrapper。
    #>
    param([string]$Path)
    if (-not $Path) { return $Path }
    return [System.Environment]::ExpandEnvironmentVariables($Path)
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
