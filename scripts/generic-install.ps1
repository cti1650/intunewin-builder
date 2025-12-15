param (
    [Parameter(Mandatory = $false)]
    [string]$Url,

    [Parameter(Mandatory = $false)]
    [string]$Args,

    [Parameter(Mandatory = $false)]
    [switch]$Uninstall,

    [Parameter(Mandatory = $false)]
    [string]$RegistryName
)

$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

# ==========
# Helper Functions
# ==========
function Get-InstallerType {
    param([string]$FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    switch ($ext) {
        ".msi" { return "msi" }
        ".exe" { return "exe" }
        ".msix" { return "msix" }
        default { return "unknown" }
    }
}

function Find-ProductCode {
    param([string]$DisplayName)
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($path in $paths) {
        $match = Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$DisplayName*" } |
            Select-Object -First 1
        if ($match -and $match.PSChildName -match "^\{.*\}$") {
            return $match.PSChildName
        }
    }
    return $null
}

# ==========
# Uninstall Mode
# ==========
if ($Uninstall) {
    if (-not $RegistryName) {
        Write-Error "Uninstall requires -RegistryName parameter"
        exit 1
    }

    Write-Host "Searching for product code: $RegistryName"
    $productCode = Find-ProductCode -DisplayName $RegistryName

    if ($productCode) {
        Write-Host "Found product code: $productCode"
        Write-Host "Uninstalling..."
        $process = Start-Process msiexec -ArgumentList "/x $productCode /qn /norestart" -PassThru -Wait
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
            Write-Host "Uninstall completed successfully (exit code: $($process.ExitCode))"
            exit 0
        } else {
            Write-Error "Uninstall failed with exit code: $($process.ExitCode)"
            exit $process.ExitCode
        }
    } else {
        Write-Warning "Product not found in registry: $RegistryName"
        exit 0
    }
}

# ==========
# Install Mode
# ==========
if (-not $Url) {
    Write-Error "Install requires -Url parameter"
    exit 1
}

# Determine filename from URL
$uri = [System.Uri]$Url
$fileName = $uri.Segments[-1]
if ($fileName -match "\?") {
    $fileName = $fileName.Split("?")[0]
}
# Fallback if no extension
if (-not [System.IO.Path]::GetExtension($fileName)) {
    $fileName = "installer.msi"
}

$tempDir = Join-Path $env:TEMP "generic-install"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$installerPath = Join-Path $tempDir $fileName

Write-Host "Downloading installer from: $Url"
Write-Host "Saving to: $installerPath"

try {
    Invoke-WebRequest -Uri $Url -OutFile $installerPath -UseBasicParsing
} catch {
    Write-Error "Download failed: $_"
    exit 1
}

$fileSize = (Get-Item $installerPath).Length / 1MB
Write-Host "Downloaded: $([math]::Round($fileSize, 2)) MB"

# Verify file header
$bytes = [System.IO.File]::ReadAllBytes($installerPath)[0..3]
$header = [BitConverter]::ToString($bytes) -replace '-', ''
Write-Host "File header: $header"

$installerType = Get-InstallerType -FilePath $installerPath

Write-Host "Installer type: $installerType"
Write-Host "Installing..."

$exitCode = 0
switch ($installerType) {
    "msi" {
        $msiArgs = "/i `"$installerPath`" /qn /norestart"
        if ($Args) { $msiArgs += " $Args" }
        Write-Host "Running: msiexec $msiArgs"
        $process = Start-Process msiexec -ArgumentList $msiArgs -PassThru -Wait
        $exitCode = $process.ExitCode
    }
    "exe" {
        $exeArgs = if ($Args) { $Args } else { "/S" }
        Write-Host "Running: $installerPath $exeArgs"
        $process = Start-Process -FilePath $installerPath -ArgumentList $exeArgs -PassThru -Wait
        $exitCode = $process.ExitCode
    }
    "msix" {
        Write-Host "Running: Add-AppxPackage"
        try {
            Add-AppxPackage -Path $installerPath -ErrorAction Stop
            $exitCode = 0
        } catch {
            Write-Error "MSIX installation failed: $_"
            $exitCode = 1
        }
    }
    default {
        Write-Error "Unknown installer type: $installerType"
        exit 1
    }
}

# Cleanup
Write-Host "Cleaning up temporary files..."
Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

if ($exitCode -eq 0 -or $exitCode -eq 3010) {
    Write-Host "Installation completed successfully (exit code: $exitCode)"
    exit 0
} else {
    Write-Error "Installation failed with exit code: $exitCode"
    exit $exitCode
}
