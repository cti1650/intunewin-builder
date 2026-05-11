param (
    [Parameter(Mandatory)]
    [string]$App
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/lib.ps1"

Write-Host "Building script-based intunewin for app: $App"

# ==========
# Load app definition
# ==========
$appDef = Get-AppDefinition -App $App

if (-not $appDef.script_based) {
    throw "This app is not configured for script-based deployment. Use build-intunewin.ps1 instead."
}

# ==========
# Prepare directories
# ==========
New-Item app, output/intunewin, output/installer -ItemType Directory -Force | Out-Null

# ==========
# Copy install scripts to app folder, build context object
# ==========
$isCustomScript = $appDef.custom_script -eq $true
$installBehavior = $appDef.intune.install_behavior
$installBehaviorLabel = if ($installBehavior -eq 'user') { 'User' } else { 'System' }

if ($isCustomScript) {
    $customDir = "scripts/apps/$App"
    if (-not (Test-Path $customDir)) {
        throw "Custom script directory not found: $customDir"
    }

    $installScript = $appDef.installer.script
    if (-not $installScript) { $installScript = "install.ps1" }
    $installSrc = Join-Path $customDir $installScript
    if (-not (Test-Path $installSrc)) {
        throw "Custom install script not found: $installSrc"
    }
    Write-Host "Copying custom install script: $installSrc"
    Copy-Item $installSrc "app/$installScript" -Force

    if ($appDef.uninstall.script) {
        $uninstallSrc = Join-Path $customDir $appDef.uninstall.script
        if (-not (Test-Path $uninstallSrc)) {
            throw "Custom uninstall script not found: $uninstallSrc"
        }
        Write-Host "Copying custom uninstall script: $uninstallSrc"
        Copy-Item $uninstallSrc "app/$($appDef.uninstall.script)" -Force
    }

    $ctx = [ordered]@{
        Mode             = 'custom_script'
        MainScriptName   = $installScript
        InstallCommand   = "powershell.exe -ExecutionPolicy Bypass -File $installScript"
        UninstallCommand = if ($appDef.uninstall.script) {
            "powershell.exe -ExecutionPolicy Bypass -File $($appDef.uninstall.script)"
        } else { '(none)' }
        UninstallScript  = $appDef.uninstall.script
        DetectFile       = $appDef.detect.file
        DetectRegistry   = $appDef.detect.registry_display_name
    }
} else {
    Write-Host "Copying generic-install.ps1..."
    Copy-Item "scripts/generic-install.ps1" "app/generic-install.ps1" -Force

    $ctx = [ordered]@{
        Mode             = 'script_based'
        MainScriptName   = 'generic-install.ps1'
        InstallCommand   = "powershell.exe -ExecutionPolicy Bypass -File generic-install.ps1 -Url `"$($appDef.download.url)`" -Args `"$($appDef.installer.install_args)`""
        UninstallCommand = "powershell.exe -ExecutionPolicy Bypass -File generic-install.ps1 -Uninstall -RegistryName `"$($appDef.uninstall.registry_name)`""
        DownloadUrl      = $appDef.download.url
        InstallArgs      = $appDef.installer.install_args
        DetectFile       = $appDef.detect.file
        DetectRegistry   = $appDef.detect.registry_display_name
    }
}

# ==========
# Generate intune-config.txt (operator が Intune UI に貼る参照テキスト)
# ==========
$detectLines = @("File: $($ctx.DetectFile)")
if ($ctx.DetectRegistry) { $detectLines += "Registry: $($ctx.DetectRegistry)" }

$header = if ($ctx.Mode -eq 'custom_script') {
    'Script-Based Deployment Configuration (Custom Script)'
} else {
    'Script-Based Deployment Configuration'
}

$intuneConfig = @"
# $header
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

App: $($appDef.name)
Mode: $($ctx.Mode)
Install Behavior: $installBehaviorLabel

# Intune Install Command:
$($ctx.InstallCommand)

# Intune Uninstall Command:
$($ctx.UninstallCommand)

# Detection Rule:
$($detectLines -join "`n")
"@
$intuneConfig | Out-File "app/intune-config.txt" -Encoding utf8

# ==========
# Resolve IntuneWinAppUtil (cached if already extracted)
# ==========
$toolPath = Get-IntuneWinAppUtilPath

# ==========
# Build intunewin
# ==========
Write-Host "Building intunewin (main script: $($ctx.MainScriptName))..."
& $toolPath -c app -s $ctx.MainScriptName -o output/intunewin -q

# ==========
# Rename intunewin
# ==========
$intunewin = Get-ChildItem output/intunewin/*.intunewin | Select-Object -First 1
if ($intunewin) {
    $timestamp = Get-Date -Format "yyyyMMdd"
    Rename-Item -Path $intunewin.FullName -NewName "$($appDef.name)-$timestamp.intunewin"
}

# ==========
# Copy intune-config.txt and write output metadata.txt
# ==========
Copy-Item "app/intune-config.txt" "output/intune-config.txt" -Force

$metaLines = @(
    "app: $($appDef.name)"
    "type: $(if ($ctx.Mode -eq 'custom_script') { 'script_based (custom_script)' } else { 'script_based' })"
    "install_behavior: $installBehavior"
    "install_command: $($ctx.InstallCommand)"
    "uninstall_command: $($ctx.UninstallCommand)"
    "detect_file: $($ctx.DetectFile)"
)
if ($ctx.Mode -eq 'custom_script') {
    $metaLines += "install_script: $($ctx.MainScriptName)"
    if ($ctx.UninstallScript) { $metaLines += "uninstall_script: $($ctx.UninstallScript)" }
} else {
    $metaLines += "download_url: $($ctx.DownloadUrl)"
    $metaLines += "install_args: $($ctx.InstallArgs)"
    $metaLines += "registry_name: $($ctx.DetectRegistry)"
}
$metaLines += "built_at_utc: $((Get-Date).ToUniversalTime().ToString('o'))"
$metaLines -join "`n" | Out-File "output/metadata.txt" -Encoding utf8

# ==========
# Console output (intune-config.txt と同内容を見やすく表示)
# ==========
Write-Host "Build completed successfully"
Write-Host ""
Write-Host "=== Intune Configuration ===" -ForegroundColor Cyan
Write-Host "Install Behavior:"
Write-Host "  $installBehaviorLabel"
Write-Host ""
Write-Host "Install Command:"
Write-Host "  $($ctx.InstallCommand)"
Write-Host ""
if ($ctx.UninstallCommand -ne '(none)') {
    Write-Host "Uninstall Command:"
    Write-Host "  $($ctx.UninstallCommand)"
    Write-Host ""
}
Write-Host "Detection Rule (File):"
Write-Host "  Path: $($ctx.DetectFile)"
