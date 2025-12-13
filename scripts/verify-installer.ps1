param (
  [Parameter(Mandatory)]
  [string]$App
)

$ErrorActionPreference = "Stop"

# ==========
# Helper functions
# ==========
function Get-InstalledAppsSnapshot {
  $registryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
  )
  $registryApps = $registryPaths | ForEach-Object {
    Get-ItemProperty $_ -ErrorAction SilentlyContinue
  } | Where-Object { $_.DisplayName } |
    Select-Object -ExpandProperty DisplayName

  $appxApps = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Name

  return @{
    Registry = @($registryApps)
    Appx     = @($appxApps)
  }
}

function Compare-Snapshots {
  param($Before, $After)

  $addedRegistry = $After.Registry | Where-Object { $_ -notin $Before.Registry }
  $addedAppx = $After.Appx | Where-Object { $_ -notin $Before.Appx }

  return @{
    AddedRegistry = @($addedRegistry)
    AddedAppx     = @($addedAppx)
  }
}

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
# Snapshot before install
# ==========
Write-Host "Taking snapshot before install..."
$snapshotBefore = Get-InstalledAppsSnapshot
Write-Host "Registry apps: $($snapshotBefore.Registry.Count), Appx apps: $($snapshotBefore.Appx.Count)"

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
} elseif ($type -eq "msix" -and $header -ne "504B0304") {
  Write-Host "WARNING: File does not appear to be a valid MSIX (ZIP-based package)"
  Write-Host "First 10 lines:"
  Get-Content $installerPath -TotalCount 10
}

# ==========
# Install
# ==========
Write-Host "Installing..."
Write-Host "Installer type: $type"
Write-Host "Install args: $installArgs"

$timeoutSeconds = $appDef.installer.timeout
if ($timeoutSeconds) {
  Write-Host "Timeout: $timeoutSeconds seconds"
}

if ($type -eq "msi") {
  $process = Start-Process msiexec `
    -ArgumentList $installArgs `
    -Wait `
    -PassThru
  Write-Host "msiexec exit code: $($process.ExitCode)"
} elseif ($type -eq "msix") {
  try {
    Add-AppxPackage -Path $installerPath
    Write-Host "MSIX installation completed"
  } catch {
    Write-Host "MSIX installation failed: $_"
    throw
  }
} elseif ($timeoutSeconds) {
  $process = Start-Process `
    -FilePath $installerPath `
    -ArgumentList $installArgs `
    -PassThru

  $completed = $process.WaitForExit($timeoutSeconds * 1000)
  if ($completed) {
    Write-Host "Installer exit code: $($process.ExitCode)"
  } else {
    Write-Host "WARNING: Installer timed out after $timeoutSeconds seconds, killing process..."
    $process | Stop-Process -Force
    Write-Host "Process killed, continuing with detection..."
  }
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
# Snapshot after install
# ==========
Write-Host "Taking snapshot after install..."
$snapshotAfter = Get-InstalledAppsSnapshot
Write-Host "Registry apps: $($snapshotAfter.Registry.Count), Appx apps: $($snapshotAfter.Appx.Count)"

$diff = Compare-Snapshots -Before $snapshotBefore -After $snapshotAfter

Write-Host ""
Write-Host "=== Installation diff ==="
if ($diff.AddedRegistry.Count -gt 0) {
  Write-Host "New registry apps:"
  $diff.AddedRegistry | ForEach-Object { Write-Host "  + $_" }
} else {
  Write-Host "No new registry apps detected"
}

if ($diff.AddedAppx.Count -gt 0) {
  Write-Host "New Appx packages:"
  $diff.AddedAppx | ForEach-Object { Write-Host "  + $_" }
} else {
  Write-Host "No new Appx packages detected"
}
Write-Host "========================="
Write-Host ""

# ==========
# Detect
# ==========
Write-Host "Detecting installation..."
$detected = $false

if ($appDef.detect.file) {
  Write-Host "Checking file: $($appDef.detect.file)"
  $detected = Test-Path $appDef.detect.file
  Write-Host "File exists: $detected"
}

if ($appDef.detect.registry_display_name) {
  $searchName = $appDef.detect.registry_display_name
  Write-Host "Searching for registry app: $searchName"

  # Check in diff first
  $foundInDiff = $diff.AddedRegistry | Where-Object { $_ -like "*$searchName*" }
  if ($foundInDiff) {
    Write-Host "Found in diff: $foundInDiff"
    $detected = $true
  } else {
    # Fallback to full search
    $paths = @(
      "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
      "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
      "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $allApps = $paths | ForEach-Object {
      Get-ItemProperty $_ -ErrorAction SilentlyContinue
    } | Where-Object { $_.DisplayName }

    $match = $allApps | Where-Object { $_.DisplayName -like "*$searchName*" }
    if ($match) {
      Write-Host "Found in registry: $($match.DisplayName)"
      $detected = $true
    }
  }
}

if ($appDef.detect.appx_name) {
  $searchName = $appDef.detect.appx_name
  Write-Host "Searching for Appx package: $searchName"

  # Check in diff first
  $foundInDiff = $diff.AddedAppx | Where-Object { $_ -like "*$searchName*" }
  if ($foundInDiff) {
    Write-Host "Found in diff: $foundInDiff"
    $detected = $true
  } else {
    # Fallback to full search
    $appxPackages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "*$searchName*" }
    if ($appxPackages) {
      Write-Host "Found Appx: $($appxPackages.Name)"
      $detected = $true
    }
  }
}

if (-not $detected) {
  throw "Detection failed for $App"
}

Write-Host "Detection succeeded"

# ==========
# Uninstall
# ==========
if ($appDef.uninstall) {
  Write-Host ""
  Write-Host "=== Uninstall verification ==="
  Write-Host "Uninstalling..."

  $uninstallType = $appDef.uninstall.type

  if ($uninstallType -eq "msi") {
    # Find product code from registry
    $productCode = $null
    $searchName = $appDef.detect.registry_display_name
    $paths = @(
      "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
      "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
      "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $match = $paths | ForEach-Object {
      Get-ItemProperty $_ -ErrorAction SilentlyContinue
    } | Where-Object { $_.DisplayName -like "*$searchName*" } | Select-Object -First 1

    if ($match -and $match.PSChildName -match "^\{.*\}$") {
      $productCode = $match.PSChildName
      Write-Host "Found product code: $productCode"
    }

    if ($productCode) {
      $uninstallArgs = $appDef.uninstall.args -replace "\{product_code\}", $productCode
      Write-Host "Uninstall args: $uninstallArgs"
      $process = Start-Process msiexec -ArgumentList $uninstallArgs -Wait -PassThru
      Write-Host "msiexec uninstall exit code: $($process.ExitCode)"
    } else {
      Write-Host "WARNING: Could not find product code for MSI uninstall"
    }
  } elseif ($uninstallType -eq "msix") {
    $packageName = $appDef.uninstall.package_name
    Write-Host "Removing Appx package: $packageName"
    try {
      Get-AppxPackage -AllUsers -Name "*$packageName*" | Remove-AppxPackage -AllUsers
      Write-Host "MSIX uninstall completed"
    } catch {
      Write-Host "MSIX uninstall failed: $_"
    }
  } elseif ($uninstallType -eq "exe") {
    $uninstallPath = $appDef.uninstall.path
    $uninstallArgs = $appDef.uninstall.args

    # Handle {version} placeholder - find Chrome version from installed path
    if ($uninstallPath -like "*{version}*") {
      $basePath = $uninstallPath -replace "\{version\}.*", ""
      if (Test-Path $basePath) {
        $versionDir = Get-ChildItem $basePath -Directory |
          Where-Object { $_.Name -match "^\d+\." } |
          Sort-Object Name -Descending |
          Select-Object -First 1
        if ($versionDir) {
          $uninstallPath = $uninstallPath -replace "\{version\}", $versionDir.Name
          Write-Host "Resolved uninstall path: $uninstallPath"
        }
      }
    }

    if (Test-Path $uninstallPath) {
      Write-Host "Uninstall path: $uninstallPath"
      Write-Host "Uninstall args: $uninstallArgs"
      $process = Start-Process -FilePath $uninstallPath -ArgumentList $uninstallArgs -Wait -PassThru
      Write-Host "Uninstaller exit code: $($process.ExitCode)"
    } else {
      Write-Host "WARNING: Uninstall path not found: $uninstallPath"
    }
  }

  Write-Host "Waiting for uninstall to complete..."
  Start-Sleep -Seconds 10

  # ==========
  # Snapshot after uninstall
  # ==========
  Write-Host "Taking snapshot after uninstall..."
  $snapshotAfterUninstall = Get-InstalledAppsSnapshot
  Write-Host "Registry apps: $($snapshotAfterUninstall.Registry.Count), Appx apps: $($snapshotAfterUninstall.Appx.Count)"

  # Compare with post-install snapshot
  $removedRegistry = $snapshotAfter.Registry | Where-Object { $_ -notin $snapshotAfterUninstall.Registry }
  $removedAppx = $snapshotAfter.Appx | Where-Object { $_ -notin $snapshotAfterUninstall.Appx }

  Write-Host ""
  Write-Host "=== Uninstall diff ==="
  if ($removedRegistry.Count -gt 0) {
    Write-Host "Removed registry apps:"
    $removedRegistry | ForEach-Object { Write-Host "  - $_" }
  } else {
    Write-Host "No registry apps removed"
  }

  if ($removedAppx.Count -gt 0) {
    Write-Host "Removed Appx packages:"
    $removedAppx | ForEach-Object { Write-Host "  - $_" }
  } else {
    Write-Host "No Appx packages removed"
  }
  Write-Host "======================"

  # ==========
  # Verify uninstall
  # ==========
  Write-Host ""
  Write-Host "Verifying uninstall..."
  $stillDetected = $false

  if ($appDef.detect.file) {
    Write-Host "Checking file: $($appDef.detect.file)"
    $stillDetected = Test-Path $appDef.detect.file
    Write-Host "File exists: $stillDetected"
  }

  if ($appDef.detect.registry_display_name) {
    $searchName = $appDef.detect.registry_display_name
    Write-Host "Searching for registry app: $searchName"
    $paths = @(
      "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
      "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
      "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $match = $paths | ForEach-Object {
      Get-ItemProperty $_ -ErrorAction SilentlyContinue
    } | Where-Object { $_.DisplayName -like "*$searchName*" }
    if ($match) {
      Write-Host "Still found in registry: $($match.DisplayName)"
      $stillDetected = $true
    } else {
      Write-Host "Not found in registry"
    }
  }

  if ($appDef.detect.appx_name) {
    $searchName = $appDef.detect.appx_name
    Write-Host "Searching for Appx package: $searchName"
    $appxPackages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "*$searchName*" }
    if ($appxPackages) {
      Write-Host "Still found Appx: $($appxPackages.Name)"
      $stillDetected = $true
    } else {
      Write-Host "Not found in Appx packages"
    }
  }

  if ($stillDetected) {
    Write-Host "WARNING: App still detected after uninstall"
  } else {
    Write-Host "Uninstall verification succeeded"
  }
  Write-Host "==============================="
}

Write-Host ""
Write-Host "Verify completed successfully"
