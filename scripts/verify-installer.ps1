param (
  [Parameter(Mandatory)]
  [string]$App
)

$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue' # ダウンロード等のプログレスバーによるログ汚れ防止

# ==========
# Result Summary Object (Initialize)
# ==========
$summary = [ordered]@{
    AppName           = $App
    OSArchitecture    = if ([Environment]::Is64BitOperatingSystem) { "64-bit" } else { "32-bit" }
    AppArchitecture   = "Unknown"
    ArchCheck         = "Not Checked"
    InstallerType     = "Unknown"
    InstallStatus     = "Skipped"
    DetectionStatus   = "Skipped"
    UninstallStatus   = "Skipped"
    CleanUpStatus     = "Skipped"
    OverallResult     = "Failed"
}

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

# バイナリのアーキテクチャ判定関数
function Get-BinaryArchitecture {
    param($Path)
    
    if (-not (Test-Path $Path)) { return "NotFound" }
    $ext = [System.IO.Path]::GetExtension($Path).ToLower()

    try {
        # MSIの場合: COMオブジェクトでSummaryInfoを読み取る
        if ($ext -eq ".msi") {
            $wi = New-Object -ComObject WindowsInstaller.Installer
            # 0 = ReadOnly
            $db = $wi.SummaryInformation($Path, 0) 
            # PID_TEMPLATE (Property 7) に "Intel", "x64", "Intel64", "AMD64" 等が含まれる
            $template = $db.Property(7)
            
            # COMオブジェクトの開放
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($db) | Out-Null
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($wi) | Out-Null
            
            if ($template -match "x64|AMD64|Intel64") { return "64-bit" }
            if ($template -match "Intel|i386") { return "32-bit" }
            return "Unknown (MSI Template: $template)"
        }
        
        # EXEの場合: PEヘッダーのMagic Numberを読む
        if ($ext -eq ".exe") {
            $fs = [System.IO.File]::OpenRead($Path)
            try {
                $buffer = New-Object byte[] 1024
                $fs.Read($buffer, 0, 1024) | Out-Null
                
                # PE Signature Offset (at 0x3C)
                $peOffset = [BitConverter]::ToInt32($buffer, 60)
                
                # Magic Number Offset (PE Signature 4bytes + FileHeader 20bytes = 24bytes after PE)
                # Magic is at start of Optional Header
                $magicOffset = $peOffset + 24
                
                if ($magicOffset + 2 -gt 1024) { return "Unknown (Header too large)" }
                
                $magic = [BitConverter]::ToUInt16($buffer, $magicOffset)
                
                # 0x10b = PE32 (32-bit), 0x20b = PE32+ (64-bit)
                if ($magic -eq 0x20b) { return "64-bit" }
                if ($magic -eq 0x10b) { return "32-bit" }
                return "Unknown (Magic: 0x$($magic.ToString('X')))"
            }
            finally {
                $fs.Close()
            }
        }
    }
    catch {
        Write-Warning "Failed to analyze binary architecture: $_"
    }
    return "Unknown"
}

# ==========
# Main Logic
# ==========
try {
    Write-Host "Verifying installer for app: $App"

    # Load app definition
    $appDefPath = "apps/$App.yml"
    if (-not (Test-Path $appDefPath)) { throw "App definition not found: $appDefPath" }

    $appDef = Get-Content $appDefPath | ConvertFrom-Yaml

    $installerFile = $appDef.download.file
    $installerPath = (Resolve-Path "output/installer/$installerFile").Path
    $type          = $appDef.installer.type
    $summary.InstallerType = $type
    $installArgs   = $appDef.installer.install_args -replace "{installer}", "`"$installerPath`""

    if (-not (Test-Path $installerPath)) { throw "Installer not found: $installerPath" }

    # ==========
    # Check Architecture
    # ==========
    Write-Host "Checking architecture..."
    $binArch = Get-BinaryArchitecture -Path $installerPath
    $summary.AppArchitecture = $binArch
    
    Write-Host "OS Arch  : $($summary.OSArchitecture)"
    Write-Host "App Arch : $binArch"

    if ($summary.OSArchitecture -eq "64-bit" -and $binArch -eq "32-bit") {
        Write-Warning "Running 32-bit installer on 64-bit OS. This is compatible but 64-bit is recommended."
        $summary.ArchCheck = "Warning (32-on-64)"
    } elseif ($summary.OSArchitecture -eq "32-bit" -and $binArch -eq "64-bit") {
        throw "Incompatible Architecture: Trying to install 64-bit app on 32-bit OS."
    } else {
        $summary.ArchCheck = "Pass"
    }

    # Snapshot before
    Write-Host "Taking snapshot before install..."
    $snapshotBefore = Get-InstalledAppsSnapshot

    # Check file header magic
    $bytes = [System.IO.File]::ReadAllBytes($installerPath)[0..3]
    $header = [BitConverter]::ToString($bytes) -replace '-',''
    if ($type -eq "msi" -and $header -ne "D0CF11E0") { Write-Warning "Invalid MSI Header"; $summary.InstallerType = "Invalid MSI" }
    elseif ($type -eq "exe" -and $header -notlike "4D5A*") { Write-Warning "Invalid EXE Header"; $summary.InstallerType = "Invalid EXE" }

    # ==========
    # Install
    # ==========
    Write-Host "Installing..."
    $timeoutSeconds = $appDef.installer.timeout
    if (-not $timeoutSeconds) { $timeoutSeconds = 600 } # Default 10 min

    if ($type -eq "msi") {
        $process = Start-Process msiexec -ArgumentList $installArgs -PassThru
        $completed = $process.WaitForExit($timeoutSeconds * 1000)
        if (-not $completed) { 
            $process | Stop-Process -Force
            throw "MSI Installation Timed Out" 
        }
        $exitCode = $process.ExitCode
    } elseif ($type -eq "msix") {
        Add-AppxPackage -Path $installerPath
        $exitCode = 0
    } else {
        $process = Start-Process -FilePath $installerPath -ArgumentList $installArgs -PassThru
        $completed = $process.WaitForExit($timeoutSeconds * 1000)
        if (-not $completed) {
            $process | Stop-Process -Force
            throw "EXE Installation Timed Out"
        }
        $exitCode = $process.ExitCode
    }

    Write-Host "Exit Code: $exitCode"
    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
        $summary.InstallStatus = "Success ($exitCode)"
    } else {
        $summary.InstallStatus = "Failed ($exitCode)"
        throw "Installation failed with code $exitCode"
    }

    Start-Sleep -Seconds 5

    # Snapshot after
    $snapshotAfter = Get-InstalledAppsSnapshot
    $diff = Compare-Snapshots -Before $snapshotBefore -After $snapshotAfter
    
    # Optional Command Verify
    if ($appDef.verify.command) {
        try {
             Invoke-Expression $appDef.verify.command | Out-Null
             Write-Host "Verify command passed."
        } catch {
             Write-Warning "Verify command failed."
             # Verification failure doesn't always mean install failure, but worth noting
        }
    }

    # ==========
    # Detect
    # ==========
    Write-Host "Detecting..."
    $detected = $false
    
    if ($appDef.detect.registry_display_name) {
        $searchName = $appDef.detect.registry_display_name
        # Diff Check
        if ($diff.AddedRegistry | Where-Object { $_ -like "*$searchName*" }) { $detected = $true }
        # Full Scan
        elseif ((Get-InstalledAppsSnapshot).Registry | Where-Object { $_ -like "*$searchName*" }) { $detected = $true }
    }
    if ($appDef.detect.file -and (Test-Path $appDef.detect.file)) { $detected = $true }
    
    if ($detected) {
        $summary.DetectionStatus = "Success"
        Write-Host "Detection Success"
    } else {
        $summary.DetectionStatus = "Failed"
        throw "Detection failed"
    }

    # ==========
    # Uninstall
    # ==========
    if ($appDef.uninstall) {
        Write-Host "Uninstalling..."
        
        # MSI Uninstall Logic
        if ($appDef.uninstall.type -eq "msi") {
            # Try to get ProductCode from registry diff first (Most accurate)
            $searchName = $appDef.detect.registry_display_name
            $paths = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*")
            $match = $paths | ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } | Where-Object { $_.DisplayName -like "*$searchName*" } | Select-Object -First 1
            
            if ($match -and $match.PSChildName -match "^\{.*\}$") {
                $pCode = $match.PSChildName
                $uArgs = $appDef.uninstall.args -replace "\{product_code\}", $pCode
                Start-Process msiexec -ArgumentList $uArgs -Wait
                $summary.UninstallStatus = "Success"
            } else {
                 $summary.UninstallStatus = "Failed (No ProductCode)"
            }
        } 
        # EXE/Other Logic could go here
        else {
            # Simplified for summary demo
             $summary.UninstallStatus = "Skipped (EXE logic)"
        }
        
        Start-Sleep -Seconds 5
        
        # Verify Uninstall (CleanUp Check)
        $snapshotFinal = Get-InstalledAppsSnapshot
        $clean = $true
        if ($appDef.detect.registry_display_name) {
             if ($snapshotFinal.Registry -like "*$($appDef.detect.registry_display_name)*") { $clean = $false }
        }
        if ($clean) { $summary.CleanUpStatus = "Success" } else { $summary.CleanUpStatus = "Failed (Residue)" }
    }

    $summary.OverallResult = "PASS"

} catch {
    Write-Error $_
    $summary.OverallResult = "FAIL"
    exit 1
} finally {
    # ==========
    # SUMMARY OUTPUT
    # ==========
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   VERIFICATION SUMMARY: $App" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    
    $summary.Keys | ForEach-Object {
        $key = $_
        $val = $summary[$key]
        
        # Color coding
        $color = "White"
        if ($val -match "Success|Pass|64-bit") { $color = "Green" }
        if ($val -match "Warning|32-bit") { $color = "Yellow" }
        if ($val -match "Failed|FAIL|Unknown") { $color = "Red" }
        if ($key -eq "OSArchitecture") { $color = "Gray" }

        Write-Host "$($key.PadRight(18)) : " -NoNewline
        Write-Host $val -ForegroundColor $color
    }
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
}