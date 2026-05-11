<#
.SYNOPSIS
  apps/<App>.yml を読み、Install または Uninstall を端末上で実行する。
  Intune も .intunewin パッケージングも経由しないローカル動作確認用エントリポイント。

.DESCRIPTION
  Windows PowerShell 5.1 / pwsh 7+ どちらでも動く (powershell-yaml が未インストール
  なら CurrentUser スコープで自動取得する)。

  対応するアプリ種別:
    - 通常版 (apps/<name>.yml)         : DL → installer.type に従って msiexec / exe / Add-AppxPackage
    - script_based (apps/<name>_script_based.yml) : scripts/generic-install.ps1 を直接呼ぶ
    - custom_script (apps/<name>_shortcut.yml 等) : scripts/apps/<name>/*.ps1 を直接実行

  破壊的操作なので Windows Sandbox / 検証 VM / 使い捨て端末で実行するのを推奨する。

.PARAMETER App
  apps/<App>.yml の <App> 部分 (拡張子なし)。例: firefox / firefox_script_based / company_portal_shortcut

.PARAMETER Action
  Install または Uninstall。

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File scripts\local-run.ps1 -App firefox -Action Install

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File scripts\local-run.ps1 -App firefox_script_based -Action Uninstall

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File scripts\local-run.ps1 -App company_portal_shortcut -Action Install
#>
param(
    [Parameter(Mandatory)][string]$App,
    [Parameter(Mandatory)][ValidateSet('Install', 'Uninstall')][string]$Action
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ==========
# powershell-yaml bootstrap (Get-AppDefinition の前提)
# ==========
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host 'powershell-yaml が未導入のため CurrentUser スコープでインストールします...'
    Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    Install-Module powershell-yaml -Scope CurrentUser -Force
}
Import-Module powershell-yaml

. "$PSScriptRoot/lib.ps1"

# apps/ をリポジトリルート相対で解決するため、リポジトリルートで実行する
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    $appDef         = Get-AppDefinition -App $App
    $isScriptBased  = $appDef.script_based -eq $true
    $isCustomScript = $appDef.custom_script -eq $true

    Write-Host ""
    Write-Host "App   : $App"
    Write-Host "Mode  : $(if ($isCustomScript) { 'custom_script' } elseif ($isScriptBased) { 'script_based' } else { 'traditional' })"
    Write-Host "Action: $Action"
    Write-Host ""

    if ($Action -eq 'Install') {
        if ($isCustomScript) {
            $scriptName = $appDef.installer.script
            if (-not $scriptName) { $scriptName = 'install.ps1' }
            $scriptPath = "scripts/apps/$App/$scriptName"
            if (-not (Test-Path $scriptPath)) { throw "Custom install script not found: $scriptPath" }
            Write-Host "Running custom install script: $scriptPath"
            & powershell.exe -ExecutionPolicy Bypass -File $scriptPath
            $exitCode = $LASTEXITCODE
        }
        elseif ($isScriptBased) {
            $url   = $appDef.download.url
            $iArgs = $appDef.installer.install_args
            Write-Host "Calling generic-install.ps1"
            Write-Host "  URL : $url"
            Write-Host "  Args: $iArgs"
            if ($iArgs) {
                & "$PSScriptRoot/generic-install.ps1" -Url $url -Args $iArgs
            } else {
                & "$PSScriptRoot/generic-install.ps1" -Url $url
            }
            $exitCode = $LASTEXITCODE
        }
        else {
            $url      = $appDef.download.url
            $fileName = $appDef.download.file
            $type     = $appDef.installer.type
            $tmpDir   = Join-Path $env:TEMP 'intunewin-builder-local'
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $installerPath = Join-Path $tmpDir $fileName

            Write-Host "Downloading: $url"
            Write-Host "  -> $installerPath"
            Invoke-WebRequest -Uri $url -OutFile $installerPath -UseBasicParsing
            $sizeMB = [math]::Round((Get-Item $installerPath).Length / 1MB, 2)
            Write-Host "Downloaded: $sizeMB MB"

            $iArgs = $appDef.installer.install_args -replace '\{installer\}', "`"$installerPath`""
            $timeoutSec = if ($appDef.installer.timeout) { [int]$appDef.installer.timeout } else { 600 }

            switch ($type) {
                'msi' {
                    Write-Host "Running: msiexec $iArgs"
                    $proc = Start-Process msiexec -ArgumentList $iArgs -PassThru
                    if (-not $proc.WaitForExit($timeoutSec * 1000)) {
                        $proc | Stop-Process -Force
                        throw "MSI install timed out after $timeoutSec sec"
                    }
                    $exitCode = $proc.ExitCode
                }
                'exe' {
                    Write-Host "Running: `"$installerPath`" $iArgs"
                    $proc = Start-Process -FilePath $installerPath -ArgumentList $iArgs -PassThru
                    if (-not $proc.WaitForExit($timeoutSec * 1000)) {
                        $proc | Stop-Process -Force
                        throw "EXE install timed out after $timeoutSec sec"
                    }
                    $exitCode = $proc.ExitCode
                }
                'msix' {
                    Write-Host "Running: Add-AppxPackage -Path $installerPath"
                    Add-AppxPackage -Path $installerPath -ErrorAction Stop
                    $exitCode = 0
                }
                default { throw "Unsupported installer.type for traditional install: $type" }
            }
        }

        if ($exitCode -eq 0 -or $exitCode -eq 3010) {
            Write-Host ""
            Write-Host "Install completed (exit code: $exitCode)" -ForegroundColor Green
            exit 0
        }
        Write-Error "Install failed (exit code: $exitCode)"
        exit $exitCode
    }

    # ==========
    # Uninstall
    # ==========
    if ($isCustomScript) {
        $scriptName = $appDef.uninstall.script
        if (-not $scriptName) {
            Write-Warning 'custom_script app に uninstall.script が定義されていないので何もしない'
            exit 0
        }
        $scriptPath = "scripts/apps/$App/$scriptName"
        if (-not (Test-Path $scriptPath)) { throw "Custom uninstall script not found: $scriptPath" }
        Write-Host "Running custom uninstall script: $scriptPath"
        & powershell.exe -ExecutionPolicy Bypass -File $scriptPath
        $exitCode = $LASTEXITCODE
    }
    else {
        $uType = $appDef.uninstall.type
        switch ($uType) {
            'msi' {
                $entry = Find-RegistryUninstallEntry -DisplayName $appDef.detect.registry_display_name
                if (-not ($entry -and $entry.PSChildName -match '^\{.*\}$')) {
                    throw "ProductCode not found in registry for: $($appDef.detect.registry_display_name)"
                }
                $uArgs = $appDef.uninstall.args -replace '\{product_code\}', $entry.PSChildName
                Write-Host "Running: msiexec $uArgs"
                $proc = Start-Process msiexec -ArgumentList $uArgs -PassThru -Wait
                $exitCode = $proc.ExitCode
            }
            'exe' {
                $exe = Expand-EnvPath $appDef.uninstall.path
                if (-not (Test-Path $exe)) { throw "Uninstaller not found: $exe" }
                $uArgs = $appDef.uninstall.args
                Write-Host "Running: `"$exe`" $uArgs"
                $proc = Start-Process -FilePath $exe -ArgumentList $uArgs -PassThru -Wait
                $exitCode = $proc.ExitCode
            }
            'msix' {
                $pkg = $appDef.uninstall.package_name
                Write-Host "Running: Get-AppxPackage -AllUsers -Name *$pkg* | Remove-AppxPackage -AllUsers"
                Get-AppxPackage -AllUsers -Name "*$pkg*" | Remove-AppxPackage -AllUsers -ErrorAction Stop
                $exitCode = 0
            }
            'registry_string' {
                $entry = Find-RegistryUninstallEntry -DisplayName $appDef.detect.registry_display_name
                if (-not $entry) { throw "Registry entry not found: $($appDef.detect.registry_display_name)" }
                $cmd = if ($entry.QuietUninstallString) { $entry.QuietUninstallString } else { $entry.UninstallString }
                if ($cmd -match '^"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $uArgs = $Matches[2].Trim() }
                else { $exe = $cmd; $uArgs = '' }
                if (-not $uArgs) { $uArgs = '/S' }
                Write-Host "Running: `"$exe`" $uArgs"
                $proc = Start-Process -FilePath $exe -ArgumentList $uArgs -PassThru -Wait
                $exitCode = $proc.ExitCode
            }
            'script' {
                $regName = $appDef.uninstall.registry_name
                if (-not $regName) { $regName = $appDef.detect.registry_display_name }
                Write-Host "Calling generic-install.ps1 -Uninstall -RegistryName `"$regName`""
                & "$PSScriptRoot/generic-install.ps1" -Uninstall -RegistryName $regName
                $exitCode = $LASTEXITCODE
            }
            default { throw "Unsupported uninstall.type: $uType" }
        }
    }

    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
        Write-Host ""
        Write-Host "Uninstall completed (exit code: $exitCode)" -ForegroundColor Green
        exit 0
    }
    Write-Error "Uninstall failed (exit code: $exitCode)"
    exit $exitCode
}
finally {
    Pop-Location
}
