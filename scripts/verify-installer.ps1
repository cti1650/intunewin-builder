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
$installerPath = (Resolve-Path "output/installer/$installerFile").Path
$type          = $appDef.installer.type
$installArgs   = $appDef.installer.install_args `
  -replace "{installer}", "`"$installerPath`""

if (-not (Test-Path $installerPath)) {
  throw "Installer not found: $installerPath"
}

# ==========
# Verify installer file
# ==========
Write-Host "Verifying installer file..."
Write-Host "Installer path: $installerPath"
$installerFileInfo = Get-Item $installerPath
Write-Host "File size: $([math]::Round($installerFileInfo.Length / 1MB, 2)) MB"

$bytes = [System.IO.File]::ReadAllBytes($installerPath)[0..3]
$header = [BitConverter]::ToString($bytes) -replace '-',''
Write-Host "File header: $header"

# Validate file header based on installer type
if ($type -eq "msi" -and $header -ne "D0CF11E0") {
  Write-Host "WARNING: File does not appear to be a valid MSI"
  Write-Host "First 10 lines:"
  Get-Content $installerPath -TotalCount 10
} elseif ($type -eq "exe" -and $header -notlike "4D5A*") {
  Write-Host "WARNING: File does not appear to be a valid EXE"
  Write-Host "First 10 lines:"
  Get-Content $installerPath -TotalCount 10
}

# ==========
# Install
# ==========
Write-Host "Installing..."
Write-Host "Installer type: $type"
Write-Host "Install args: $installArgs"

if ($type -eq "msi") {
  $process = Start-Process msiexec `
    -ArgumentList $installArgs `
    -Wait `
    -PassThru
  Write-Host "msiexec exit code: $($process.ExitCode)"
} else {
  $process = Start-Process `
    -FilePath $installerPath `
    -ArgumentList $installArgs `
    -Wait `
    -PassThru
  Write-Host "Installer exit code: $($process.ExitCode)"
}

Write-Host "Waiting for installation to complete..."
Start-Sleep -Seconds 10

# ==========
# Detect
# ==========
Write-Host "Detecting installation..."
$detected = $false

if ($appDef.detect.file) {
  $detected = Test-Path $appDef.detect.file
}

if ($appDef.detect.registry_display_name) {
  $searchName = $appDef.detect.registry_display_name
  $paths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
  )
  $allApps = $paths | ForEach-Object {
    Get-ItemProperty $_ -ErrorAction SilentlyContinue
  } | Where-Object { $_.DisplayName }

  Write-Host "Searching registry for: $searchName"
  Write-Host "Total registered apps: $($allApps.Count)"

  # Search for partial matches to help debug
  $searchWords = $searchName -split '\s+' | Where-Object { $_.Length -ge 3 }
  $partialMatches = $allApps | Where-Object {
    $displayName = $_.DisplayName
    $searchWords | Where-Object { $displayName -like "*$_*" }
  }
  if ($partialMatches) {
    Write-Host "Partial matches found:"
    $partialMatches | ForEach-Object { Write-Host "  - $($_.DisplayName)" }
  } else {
    Write-Host "No partial matches found for keywords: $($searchWords -join ', ')"
  }

  $detected = $allApps | Where-Object {
    $_.DisplayName -like "*$searchName*"
  }
}

if (-not $detected) {
  throw "Detection failed for $App"
}

Write-Host "Detection succeeded"

Write-Host "Verify completed successfully"
