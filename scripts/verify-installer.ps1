param (
  [Parameter(Mandatory)]
  [string]$App
)

$ErrorActionPreference = "Stop"

Write-Host "Verifying installer for app: $App"

# ==========
# Load app definition
# ==========
$appDefPath = "apps/$App.yml"
if (-not (Test-Path $appDefPath)) {
  throw "App definition not found: $appDefPath"
}

$appDef = Get-Content $appDefPath | ConvertFrom-Yaml

$installerFile = $appDef.download.file
$installerPath = "output/installer/$installerFile"
$type          = $appDef.installer.type
$installArgs   = $appDef.installer.install_args `
  -replace "{installer}", "`"$installerPath`""

if (-not (Test-Path $installerPath)) {
  throw "Installer not found: $installerPath"
}

# ==========
# Install
# ==========
Write-Host "Installing..."
if ($type -eq "msi") {
  Start-Process msiexec `
    -ArgumentList $installArgs `
    -Wait
} else {
  Start-Process `
    -FilePath $installerPath `
    -ArgumentList $installArgs `
    -Wait
}

Start-Sleep -Seconds 5

# ==========
# Detect
# ==========
Write-Host "Detecting installation..."
$detected = $false

if ($appDef.detect.file) {
  $detected = Test-Path $appDef.detect.file
}

if ($appDef.detect.registry_display_name) {
  $paths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
  )
  $detected = $paths | ForEach-Object {
    Get-ItemProperty $_ -ErrorAction SilentlyContinue
  } | Where-Object {
    $_.DisplayName -like "*$($appDef.detect.registry_display_name)*"
  }
}

if (-not $detected) {
  throw "Detection failed for $App"
}

Write-Host "Detection succeeded"

Write-Host "Verify completed successfully"
