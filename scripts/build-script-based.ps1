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
# Copy generic-install.ps1 to app folder
# ==========
Write-Host "Copying generic-install.ps1..."
Copy-Item "scripts/generic-install.ps1" "app/generic-install.ps1" -Force

# ==========
# Generate metadata file for reference
# ==========
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
Write-Host "Building intunewin..."
& $toolPath `
    -c app `
    -s "generic-install.ps1" `
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
@"
app: $($appDef.name)
type: script_based
download_url: $($appDef.download.url)
install_args: $($appDef.installer.install_args)
registry_name: $($appDef.detect.registry_display_name)
built_at_utc: $((Get-Date).ToUniversalTime().ToString("o"))
"@ | Out-File "output/metadata.txt" -Encoding utf8

Write-Host "Build completed successfully"
Write-Host ""
Write-Host "=== Intune Configuration ===" -ForegroundColor Cyan
Write-Host "Install Command:"
Write-Host "  powershell.exe -ExecutionPolicy Bypass -File generic-install.ps1 -Url `"$($appDef.download.url)`" -Args `"$($appDef.installer.install_args)`""
Write-Host ""
Write-Host "Uninstall Command:"
Write-Host "  powershell.exe -ExecutionPolicy Bypass -File generic-install.ps1 -Uninstall -RegistryName `"$($appDef.uninstall.registry_name)`""
Write-Host ""
Write-Host "Detection Rule (File):"
Write-Host "  Path: $($appDef.detect.file)"
