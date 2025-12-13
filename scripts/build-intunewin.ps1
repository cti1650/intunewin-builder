param (
  [Parameter(Mandatory)]
  [string]$App
)

$ErrorActionPreference = "Stop"

Write-Host "Building intunewin for app: $App"

# ==========
# Load app definition
# ==========
$appDefPath = "apps/$App.yml"
if (-not (Test-Path $appDefPath)) {
  throw "App definition not found: $appDefPath"
}

$appDef = Get-Content $appDefPath | ConvertFrom-Yaml

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

# Verify file header based on extension
$bytes = [System.IO.File]::ReadAllBytes("app/$setup")[0..3]
$header = [BitConverter]::ToString($bytes) -replace '-',''
Write-Host "File header: $header"

$extension = [System.IO.Path]::GetExtension($setup).ToLower()
if ($extension -eq ".msi" -and $header -ne "D0CF11E0") {
  Write-Host "WARNING: File does not appear to be a valid MSI"
  Write-Host "First 10 lines:"
  Get-Content "app/$setup" -TotalCount 10
} elseif ($extension -eq ".exe" -and $header -notlike "4D5A*") {
  Write-Host "WARNING: File does not appear to be a valid EXE"
  Write-Host "First 10 lines:"
  Get-Content "app/$setup" -TotalCount 10
} elseif ($extension -eq ".msix" -and $header -ne "504B0304") {
  Write-Host "WARNING: File does not appear to be a valid MSIX (ZIP-based package)"
  Write-Host "First 10 lines:"
  Get-Content "app/$setup" -TotalCount 10
}

# ==========
# Collect installer metadata
# ==========
$file        = Get-Item "app/$setup"
$hash        = Get-FileHash "app/$setup" -Algorithm SHA256
$version     = $file.VersionInfo.FileVersion
if (-not $version) {
  $version = "unknown"
}
$downloadUtc = (Get-Date).ToUniversalTime().ToString("o")

# ==========
# Download IntuneWinAppUtil
# ==========
Write-Host "Downloading IntuneWinAppUtil..."

$zipPath  = "IntuneWinAppUtil.zip"
$toolDir  = "IntuneWinAppUtil"
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
"@ | Out-File "output/metadata.txt" -Encoding utf8

Write-Host "Build completed successfully"
