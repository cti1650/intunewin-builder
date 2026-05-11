param (
  [Parameter(Mandatory)]
  [string]$App,
  [string]$Organization = ""
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/lib.ps1"

Write-Host "Building intunewin for app: $App"

# ==========
# Load app definition
# ==========
$appDef = Get-AppDefinition -App $App -Organization $Organization

$url   = $appDef.download.url
$setup = $appDef.download.file

# ==========
# Prepare directories
# ==========
New-Item `
  app, `
  output/intunewin, `
  output/installer `
  -ItemType Directory -Force | Out-Null

# ==========
# Download installer
# ==========
Write-Host "Downloading installer..."
Write-Host "URL: $url"

$response = Invoke-WebRequest -Uri $url -OutFile "app/$setup" -PassThru
Write-Host "Content-Type: $($response.Headers['Content-Type'])"
if ($response.Headers['Content-Disposition']) {
  Write-Host "Content-Disposition: $($response.Headers['Content-Disposition'])"
}

$downloadedFile = Get-Item "app/$setup"
Write-Host "Downloaded file size: $([math]::Round($downloadedFile.Length / 1MB, 2)) MB"

# Verify file header
$extension = [System.IO.Path]::GetExtension($setup).ToLower().TrimStart('.')
if (-not (Test-InstallerHeader -FilePath "app/$setup" -Type $extension)) {
  Write-Host "WARNING: File header does not match expected $extension format"
  Write-Host "First 10 lines:"
  Get-Content "app/$setup" -TotalCount 10
}

# ==========
# Collect installer metadata
# ==========
$hash        = Get-FileHash "app/$setup" -Algorithm SHA256
$downloadUtc = (Get-Date).ToUniversalTime().ToString("o")

$version = Get-InstallerVersion -FilePath "app/$setup"
if (-not $version) { $version = "unknown" }
Write-Host "Detected version: $version"

# ==========
# Resolve IntuneWinAppUtil (cached if already extracted)
# ==========
$toolPath = Get-IntuneWinAppUtilPath

# ==========
# Build intunewin
# ==========
Write-Host "Building intunewin..."
& $toolPath `
  -c app `
  -s $setup `
  -o output/intunewin `
  -q

# ==========
# Rename intunewin
# ==========
$intunewin = Get-ChildItem output/intunewin/*.intunewin | Select-Object -First 1
if ($intunewin) {
  $newName = "$($appDef.name)-$version.intunewin"
  Rename-Item -Path $intunewin.FullName -NewName $newName
}

# ==========
# Save original installer
# ==========
Copy-Item "app/$setup" "output/installer/$setup" -Force

# ==========
# Write metadata
# ==========
@"
app: $($appDef.name)
download_url: $url
installer_name: $setup
file_version: $version
sha256: $($hash.Hash)
downloaded_at_utc: $downloadUtc
install_behavior: $($appDef.intune.install_behavior)
"@ | Out-File "output/metadata.txt" -Encoding utf8

Write-Host "Build completed successfully"
