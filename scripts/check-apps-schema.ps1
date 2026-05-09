<#
.SYNOPSIS
  apps/*.yml の最低限スキーマを検証する。

.DESCRIPTION
  - name フィールドの存在とファイル名一致
  - installer.type が allowlist (msi/exe/msix/script) に含まれる
  - uninstall.type が allowlist (msi/exe/msix/script/registry_string) に含まれる
  - detect ブロックの存在
  - custom_script でない場合 download.url の存在
  - script_based でない場合 download.file の存在

  必須項目漏れ・タイポ・不正な type 値を Push 時に検出するための軽量チェック。
  build-and-verify を回さないと気づけないクラスのバグをここで潰す。

.EXAMPLE
  pwsh -File scripts/check-apps-schema.ps1
  pwsh -File scripts/check-apps-schema.ps1 -Path apps
#>
[CmdletBinding()]
param(
    [string]$Path = 'apps'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host "Installing powershell-yaml..."
    Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    Install-Module powershell-yaml -Scope CurrentUser -Force
}
Import-Module powershell-yaml

. "$PSScriptRoot/lib.ps1"

$validInstallerTypes = @('msi', 'exe', 'msix', 'script')
$validUninstallTypes = @('msi', 'exe', 'msix', 'script', 'registry_string')
$validInstallBehaviors = @('system', 'user')

$files = Get-AppFiles -AppsPath $Path
if (-not $files) {
    Write-Host "No yml files found in $Path"
    exit 0
}

$totalErrors = 0
foreach ($file in $files) {
    $content = Get-Content $file.FullName -Raw
    try {
        $def = ConvertFrom-Yaml $content
    } catch {
        Write-Host "$($file.Name): YAML parse error: $($_.Exception.Message)" -ForegroundColor Red
        $totalErrors++
        continue
    }

    $errors = @()

    # name
    if (-not $def.name) {
        $errors += "missing 'name'"
    } elseif ($def.name -ne $file.BaseName) {
        $errors += "name '$($def.name)' does not match filename '$($file.BaseName)'"
    }

    # installer.type
    $installerType = Get-NestedValue $def 'installer.type'
    if (-not $installerType) {
        $errors += "missing 'installer.type'"
    } elseif ($installerType -notin $validInstallerTypes) {
        $errors += "invalid installer.type '$installerType' (must be: $($validInstallerTypes -join ', '))"
    }

    # uninstall.type (任意だが指定があれば allowlist チェック)
    $uninstallType = Get-NestedValue $def 'uninstall.type'
    if ($uninstallType -and $uninstallType -notin $validUninstallTypes) {
        $errors += "invalid uninstall.type '$uninstallType' (must be: $($validUninstallTypes -join ', '))"
    }

    # detect
    if (-not (Get-NestedValue $def 'detect')) {
        $errors += "missing 'detect' block"
    }

    # intune.install_behavior (Intune の Install behavior と同名・同義: system / user)
    $installBehavior = Get-NestedValue $def 'intune.install_behavior'
    if (-not $installBehavior) {
        $errors += "missing 'intune.install_behavior'"
    } elseif ($installBehavior -notin $validInstallBehaviors) {
        $errors += "invalid intune.install_behavior '$installBehavior' (must be: $($validInstallBehaviors -join ', '))"
    }

    # download.url / download.file (custom_script でなければ必須)
    $isCustom = $def.custom_script -eq $true
    $isScriptBased = $def.script_based -eq $true
    if (-not $isCustom) {
        if (-not (Get-NestedValue $def 'download.url')) {
            $errors += "missing 'download.url'"
        }
        if (-not $isScriptBased -and -not (Get-NestedValue $def 'download.file')) {
            $errors += "missing 'download.file' (required for non-script_based)"
        }
    }

    foreach ($msg in $errors) {
        Write-Host "$($file.Name): $msg" -ForegroundColor Red
        $totalErrors++
    }
}

Write-Host ""
if ($totalErrors -gt 0) {
    Write-Host "FAILED: $totalErrors schema error(s) across $($files.Count) file(s)" -ForegroundColor Red
    exit 1
}
Write-Host "OK: $($files.Count) file(s) passed schema check" -ForegroundColor Green
exit 0
