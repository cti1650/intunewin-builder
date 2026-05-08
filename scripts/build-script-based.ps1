param (
    [Parameter(Mandatory)]
    [string]$App
)

$ErrorActionPreference = "Stop"

Write-Host "Building script-based intunewin for app: $App"

# ==========
# Load app definition
# ==========
$appDefPath = "apps/$App.yml"
if (-not (Test-Path $appDefPath)) {
    throw "App definition not found: $appDefPath"
}

$appDef = Get-Content $appDefPath | ConvertFrom-Yaml

if (-not $appDef.script_based) {
    throw "This app is not configured for script-based deployment. Use build-intunewin.ps1 instead."
}

# ==========
# Prepare directories
# ==========
New-Item `
    app, `
    output/intunewin, `
    output/installer `
    -ItemType Directory -Force | Out-Null

# ==========
# Copy install scripts to app folder
# ==========
$isCustomScript = $appDef.custom_script -eq $true
$mainScriptName = "generic-install.ps1"

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
    $mainScriptName = $installScript

    if ($appDef.uninstall.script) {
        $uninstallSrc = Join-Path $customDir $appDef.uninstall.script
        if (-not (Test-Path $uninstallSrc)) {
            throw "Custom uninstall script not found: $uninstallSrc"
        }
        Write-Host "Copying custom uninstall script: $uninstallSrc"
        Copy-Item $uninstallSrc "app/$($appDef.uninstall.script)" -Force
    }
} else {
    Write-Host "Copying generic-install.ps1..."
    Copy-Item "scripts/generic-install.ps1" "app/generic-install.ps1" -Force
}

# ==========
# Generate metadata file for reference
# ==========
if ($isCustomScript) {
    $installCmd = "powershell.exe -ExecutionPolicy Bypass -File $mainScriptName"
    $uninstallCmd = if ($appDef.uninstall.script) {
        "powershell.exe -ExecutionPolicy Bypass -File $($appDef.uninstall.script)"
    } else { "(none)" }
    $metadataContent = @"
# Script-Based Deployment Configuration (Custom Script)
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

App: $($appDef.name)
Mode: custom_script

# Intune Install Command:
$installCmd

# Intune Uninstall Command:
$uninstallCmd

# Detection Rule:
File: $($appDef.detect.file)
"@
} else {
    $metadataContent = @"
# Script-Based Deployment Configuration
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

App: $($appDef.name)
Download URL: $($appDef.download.url)
Install Args: $($appDef.installer.install_args)
Registry Name: $($appDef.detect.registry_display_name)

# Intune Install Command:
powershell.exe -ExecutionPolicy Bypass -File generic-install.ps1 -Url "$($appDef.download.url)" -Args "$($appDef.installer.install_args)"

# Intune Uninstall Command:
powershell.exe -ExecutionPolicy Bypass -File generic-install.ps1 -Uninstall -RegistryName "$($appDef.uninstall.registry_name)"

# Detection Rule:
File: $($appDef.detect.file)
Registry: $($appDef.detect.registry_display_name)
"@
}
$metadataContent | Out-File "app/intune-config.txt" -Encoding utf8

# ==========
# Download IntuneWinAppUtil
# ==========
Write-Host "Downloading IntuneWinAppUtil..."

$zipPath = "IntuneWinAppUtil.zip"
$toolDir = "IntuneWinAppUtil"
$toolName = "IntuneWinAppUtil.exe"

Invoke-WebRequest `
    -Uri "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/archive/refs/heads/master.zip" `
    -OutFile $zipPath

Expand-Archive -Path $zipPath -DestinationPath $toolDir -Force

$toolPath = Get-ChildItem `
    -Path $toolDir `
    -Recurse `
    -Filter $toolName `
    | Select-Object -First 1 `
    | Select-Object -ExpandProperty FullName

if (-not $toolPath) {
    throw "IntuneWinAppUtil.exe not found."
}

# ==========
# Build intunewin
# ==========
Write-Host "Building intunewin (main script: $mainScriptName)..."
& $toolPath `
    -c app `
    -s $mainScriptName `
    -o output/intunewin `
    -q

# ==========
# Rename intunewin
# ==========
$intunewin = Get-ChildItem output/intunewin/*.intunewin | Select-Object -First 1
if ($intunewin) {
    $timestamp = Get-Date -Format "yyyyMMdd"
    $newName = "$($appDef.name)-$timestamp.intunewin"
    Rename-Item -Path $intunewin.FullName -NewName $newName
}

# ==========
# Copy metadata to output
# ==========
Copy-Item "app/intune-config.txt" "output/intune-config.txt" -Force

# ==========
# Write output metadata
# ==========
if ($isCustomScript) {
    @"
app: $($appDef.name)
type: script_based (custom_script)
install_script: $mainScriptName
uninstall_script: $($appDef.uninstall.script)
detect_file: $($appDef.detect.file)
built_at_utc: $((Get-Date).ToUniversalTime().ToString("o"))
"@ | Out-File "output/metadata.txt" -Encoding utf8
} else {
    @"
app: $($appDef.name)
type: script_based
download_url: $($appDef.download.url)
install_args: $($appDef.installer.install_args)
registry_name: $($appDef.detect.registry_display_name)
built_at_utc: $((Get-Date).ToUniversalTime().ToString("o"))
"@ | Out-File "output/metadata.txt" -Encoding utf8
}

Write-Host "Build completed successfully"
Write-Host ""
Write-Host "=== Intune Configuration ===" -ForegroundColor Cyan
if ($isCustomScript) {
    Write-Host "Install Command:"
    Write-Host "  powershell.exe -ExecutionPolicy Bypass -File $mainScriptName"
    Write-Host ""
    if ($appDef.uninstall.script) {
        Write-Host "Uninstall Command:"
        Write-Host "  powershell.exe -ExecutionPolicy Bypass -File $($appDef.uninstall.script)"
        Write-Host ""
    }
    Write-Host "Detection Rule (File):"
    Write-Host "  Path: $($appDef.detect.file)"
} else {
    Write-Host "Install Command:"
    Write-Host "  powershell.exe -ExecutionPolicy Bypass -File generic-install.ps1 -Url `"$($appDef.download.url)`" -Args `"$($appDef.installer.install_args)`""
    Write-Host ""
    Write-Host "Uninstall Command:"
    Write-Host "  powershell.exe -ExecutionPolicy Bypass -File generic-install.ps1 -Uninstall -RegistryName `"$($appDef.uninstall.registry_name)`""
    Write-Host ""
    Write-Host "Detection Rule (File):"
    Write-Host "  Path: $($appDef.detect.file)"
}
