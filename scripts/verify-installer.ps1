param (
  [Parameter(Mandatory)]
  [string]$App
)

$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

# ==========
# Result Summary Object
# ==========
$summary = [ordered]@{
    AppName           = $App
    DisplayName       = ""
    InstallPath       = ""
    InstalledVersion  = ""
    OSArchitecture    = if ([Environment]::Is64BitOperatingSystem) { "64-bit" } else { "32-bit" }
    AppArchitecture   = "Unknown"
    ArchCheck         = "Not Checked"
    InstallerType     = "Unknown"
    InstallStatus     = "Skipped"
    DetectionStatus   = "Skipped"
    VersionCheck      = "Skipped"
    InstallLocation   = "Skipped"
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

function Get-BinaryArchitecture {
    param($Path)
    if (-not (Test-Path $Path)) { return "NotFound" }
    $ext = [System.IO.Path]::GetExtension($Path).ToLower()

    try {
        if ($ext -eq ".msi") {
            $wi = New-Object -ComObject WindowsInstaller.Installer
            $db = $wi.SummaryInformation($Path, 0) 
            $template = $db.Property(7)
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($db) | Out-Null
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($wi) | Out-Null
            if ($template -match "x64|AMD64|Intel64") { return "64-bit" }
            if ($template -match "Intel|i386") { return "32-bit" }
            return "Unknown (MSI Template: $template)"
        }
        if ($ext -eq ".exe") {
            $fs = [System.IO.File]::OpenRead($Path)
            try {
                $buffer = New-Object byte[] 1024
                $fs.Read($buffer, 0, 1024) | Out-Null
                $peOffset = [BitConverter]::ToInt32($buffer, 60)
                $magicOffset = $peOffset + 24
                if ($magicOffset + 2 -gt 1024) { return "Unknown (Header too large)" }
                $magic = [BitConverter]::ToUInt16($buffer, $magicOffset)
                if ($magic -eq 0x20b) { return "64-bit" }
                if ($magic -eq 0x10b) { return "32-bit" }
                return "Unknown (Magic: 0x$($magic.ToString('X')))"
            } finally { $fs.Close() }
        }
        if ($ext -eq ".msix" -or $ext -eq ".appx") {
            # MSIXはコンテナなので、中身（AppxManifest.xml）を見ないとアーキテクチャは不明
            # 簡易的にチェック対象外とする
            return "MSIX (Container)"
        }
    } catch { Write-Warning "Failed to analyze binary architecture: $_" }
    return "Unknown"
}

# ==========
# Main Logic
# ==========
try {
    Write-Host "Verifying installer for app: $App"

    # Load definition
    $appDefPath = "apps/$App.yml"
    if (-not (Test-Path $appDefPath)) { throw "App definition not found: $appDefPath" }
    $appDef = Get-Content $appDefPath | ConvertFrom-Yaml

    $isScriptBased = $appDef.script_based -eq $true
    $type = $appDef.installer.type
    $summary.InstallerType = if ($isScriptBased) { "script" } else { $type }

    # Snapshot before
    $snapshotBefore = Get-InstalledAppsSnapshot

    if ($isScriptBased) {
        # ==========
        # Script-based Install
        # ==========
        Write-Host "Mode: Script-based deployment"
        $summary.AppArchitecture = "N/A (Script)"
        $summary.ArchCheck = "Skipped (Script)"

        $url = $appDef.download.url
        $installArgs = $appDef.installer.install_args

        Write-Host "Installing via generic-install.ps1..."
        Write-Host "  URL: $url"
        Write-Host "  Args: $installArgs"

        if ($installArgs) {
            & scripts/generic-install.ps1 -Url $url -Args $installArgs
        } else {
            & scripts/generic-install.ps1 -Url $url
        }
        $exitCode = $LASTEXITCODE

    } else {
        # ==========
        # Traditional Install (MSI/EXE/MSIX)
        # ==========
        $installerFile = $appDef.download.file
        $installerPath = (Resolve-Path "output/installer/$installerFile").Path
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

        # MSIXの場合はアーキテクチャ不一致チェックをスキップ（コンテナのため）
        if ($binArch -ne "MSIX (Container)") {
            if ($summary.OSArchitecture -eq "64-bit" -and $binArch -eq "32-bit") {
                Write-Warning "Running 32-bit installer on 64-bit OS."
                $summary.ArchCheck = "Warning (32-on-64)"
            } elseif ($summary.OSArchitecture -eq "32-bit" -and $binArch -eq "64-bit") {
                throw "Incompatible Architecture: Trying to install 64-bit app on 32-bit OS."
            } else {
                $summary.ArchCheck = "Pass"
            }
        } else {
            $summary.ArchCheck = "Skipped (MSIX)"
        }

        # Check file header magic
        $bytes = [System.IO.File]::ReadAllBytes($installerPath)[0..3]
        $header = [BitConverter]::ToString($bytes) -replace '-',''
        if ($type -eq "msi" -and $header -ne "D0CF11E0") { Write-Warning "Invalid MSI Header"; $summary.InstallerType = "Invalid MSI" }
        elseif ($type -eq "exe" -and $header -notlike "4D5A*") { Write-Warning "Invalid EXE Header"; $summary.InstallerType = "Invalid EXE" }
        elseif ($type -eq "msix" -and $header -ne "504B0304") { Write-Warning "Invalid MSIX Header"; $summary.InstallerType = "Invalid MSIX" }

        # ==========
        # Install
        # ==========
        Write-Host "Installing..."
        $timeoutSeconds = $appDef.installer.timeout
        if (-not $timeoutSeconds) { $timeoutSeconds = 600 }

        if ($type -eq "msi") {
            Write-Host "Running MSI installer: msiexec $installArgs"
            $process = Start-Process msiexec -ArgumentList $installArgs -PassThru
            if (-not $process.WaitForExit($timeoutSeconds * 1000)) { $process | Stop-Process -Force; throw "MSI Installation Timed Out" }
            $exitCode = $process.ExitCode
            Write-Host "MSI installation completed (exit code: $exitCode)"
        } elseif ($type -eq "msix") {
            Write-Host "Running MSIX installer: Add-AppxPackage -Path $installerPath"
            try {
                Add-AppxPackage -Path $installerPath -ErrorAction Stop
                $exitCode = 0
                Write-Host "MSIX installation completed (exit code: 0)"
            } catch {
                $exitCode = 1
                Write-Warning "MSIX installation failed: $_"
                throw
            }
        } else {
            Write-Host "Running EXE installer: $installerPath $installArgs"
            $process = Start-Process -FilePath $installerPath -ArgumentList $installArgs -PassThru
            if (-not $process.WaitForExit($timeoutSeconds * 1000)) { $process | Stop-Process -Force; throw "EXE Installation Timed Out" }
            $exitCode = $process.ExitCode
            Write-Host "EXE installation completed (exit code: $exitCode)"
        }
    }

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
        try { Invoke-Expression $appDef.verify.command | Out-Null; Write-Host "Verify command passed." } catch { Write-Warning "Verify command failed." }
    }

    # ==========
    # Detect (AND条件: 指定された全ての条件がマッチする必要がある)
    # ==========
    Write-Host "Detecting..."
    $detectionResults = @{}

    # レジストリ検出
    if ($appDef.detect.registry_display_name) {
        $searchName = $appDef.detect.registry_display_name
        $summary.DisplayName = $searchName
        $registryMatch = $false
        if ($diff.AddedRegistry | Where-Object { $_ -like "*$searchName*" }) { $registryMatch = $true }
        elseif ((Get-InstalledAppsSnapshot).Registry | Where-Object { $_ -like "*$searchName*" }) { $registryMatch = $true }
        $detectionResults["Registry"] = $registryMatch
        if ($registryMatch) { Write-Host "Registry detection: Pass" }
        else { Write-Warning "Registry detection: Failed (not found: $searchName)" }
    }

    # Appx検出
    if ($appDef.detect.appx_name) {
        $searchName = $appDef.detect.appx_name
        $appxMatch = $false
        if ($diff.AddedAppx | Where-Object { $_ -like "*$searchName*" }) { $appxMatch = $true }
        elseif ((Get-InstalledAppsSnapshot).Appx | Where-Object { $_ -like "*$searchName*" }) { $appxMatch = $true }
        $detectionResults["Appx"] = $appxMatch
        if ($appxMatch) { Write-Host "Appx detection: Pass" }
        else { Write-Warning "Appx detection: Failed (not found: $searchName)" }
    }

    # ファイル検出
    if ($appDef.detect.file) {
        $summary.InstallPath = $appDef.detect.file
        if (Test-Path $appDef.detect.file) {
            $detectionResults["File"] = $true
            Write-Host "File detection: Pass"

            # バージョン取得
            $fileInfo = Get-Item $appDef.detect.file
            $installedVersion = $fileInfo.VersionInfo.FileVersion
            if ($installedVersion) {
                $summary.InstalledVersion = $installedVersion
            }

            # バージョンチェック（指定されている場合のみ）
            if ($appDef.detect.version) {
                $requiredVersion = $appDef.detect.version
                Write-Host "Installed Version: $installedVersion"
                Write-Host "Required Version : $requiredVersion"
                try {
                    if ([version]$installedVersion -ge [version]$requiredVersion) {
                        Write-Host "Version check: Pass"
                        $summary.VersionCheck = "Pass ($installedVersion >= $requiredVersion)"
                        $detectionResults["Version"] = $true
                    } else {
                        Write-Warning "Version check: Failed ($installedVersion < $requiredVersion)"
                        $summary.VersionCheck = "Failed ($installedVersion < $requiredVersion)"
                        $detectionResults["Version"] = $false
                    }
                } catch {
                    Write-Warning "Version check: Error (Parse failed)"
                    $summary.VersionCheck = "Error (Parse failed)"
                    $detectionResults["Version"] = $false
                }
            } else {
                $summary.VersionCheck = "Not Required"
            }
        } else {
            Write-Warning "File detection: Failed (not found: $($appDef.detect.file))"
            $detectionResults["File"] = $false
            $summary.VersionCheck = "Skipped (File not found)"
        }

        # インストール場所チェック（x64/x86両方を確認）
        $detectFilePath = $appDef.detect.file
        $x64Path = $null
        $x86Path = $null
        $x64Exists = $false
        $x86Exists = $false

        if ($detectFilePath -match "^C:\\Program Files\\(.+)$") {
            $relativePath = $Matches[1]
            $x64Path = "C:\Program Files\$relativePath"
            $x86Path = "C:\Program Files (x86)\$relativePath"
        } elseif ($detectFilePath -match "^C:\\Program Files \(x86\)\\(.+)$") {
            $relativePath = $Matches[1]
            $x64Path = "C:\Program Files\$relativePath"
            $x86Path = "C:\Program Files (x86)\$relativePath"
        }

        if ($x64Path -and $x86Path) {
            $x64Exists = Test-Path $x64Path
            $x86Exists = Test-Path $x86Path

            Write-Host "Install location check:"
            Write-Host "  x64 path ($x64Path): $(if ($x64Exists) { 'Found' } else { 'Not found' })"
            Write-Host "  x86 path ($x86Path): $(if ($x86Exists) { 'Found' } else { 'Not found' })"

            if ($x64Exists -and $x86Exists) {
                $summary.InstallLocation = "Both (x64 + x86)"
                Write-Host "  -> Installed as: Both (x64 + x86)"
            } elseif ($x64Exists) {
                $summary.InstallLocation = "x64 only"
                Write-Host "  -> Installed as: x64 only"
            } elseif ($x86Exists) {
                $summary.InstallLocation = "x86 only"
                Write-Host "  -> Installed as: x86 only"
            } else {
                $summary.InstallLocation = "Not in Program Files"
                Write-Host "  -> Installed as: Not in Program Files"
            }
        } else {
            $summary.InstallLocation = "N/A (Non-standard path)"
        }
    }

    # 全ての条件がマッチしたか確認
    $allPassed = ($detectionResults.Count -gt 0) -and ($detectionResults.Values | Where-Object { $_ -eq $false }).Count -eq 0

    if ($allPassed) {
        $summary.DetectionStatus = "Success"
        Write-Host "Detection Success (all $($detectionResults.Count) checks passed)"
    } else {
        $failedChecks = ($detectionResults.GetEnumerator() | Where-Object { $_.Value -eq $false } | ForEach-Object { $_.Key }) -join ", "
        $summary.DetectionStatus = "Failed ($failedChecks)"
        throw "Detection failed: $failedChecks"
    }

    # ==========
    # Uninstall
    # ==========
    if ($appDef.uninstall) {
        Write-Host "Uninstalling..."
        $unType = $appDef.uninstall.type

        # Stop processes/services before uninstalling (if specified)
        if ($appDef.uninstall.process_name) {
            Write-Host "Stopping process: $($appDef.uninstall.process_name)"
            Stop-Process -Name $appDef.uninstall.process_name -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        if ($appDef.uninstall.service_name) {
            Write-Host "Stopping service: $($appDef.uninstall.service_name)"
            Stop-Service -Name $appDef.uninstall.service_name -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }

        if ($unType -eq "script") {
            # Script-based uninstall
            $registryName = $appDef.uninstall.registry_name
            if (-not $registryName) { $registryName = $appDef.detect.registry_display_name }
            Write-Host "Uninstalling via generic-install.ps1..."
            Write-Host "  RegistryName: $registryName"
            & scripts/generic-install.ps1 -Uninstall -RegistryName $registryName
            if ($LASTEXITCODE -eq 0) {
                $summary.UninstallStatus = "Success"
            } else {
                $summary.UninstallStatus = "Failed ($LASTEXITCODE)"
            }
        } elseif ($unType -eq "msi") {
            $searchName = $appDef.detect.registry_display_name
            $paths = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*")
            $match = $paths | ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } | Where-Object { $_.DisplayName -like "*$searchName*" } | Select-Object -First 1
            if ($match -and $match.PSChildName -match "^\{.*\}$") {
                $pCode = $match.PSChildName
                $uArgs = $appDef.uninstall.args -replace "\{product_code\}", $pCode
                $proc = Start-Process msiexec -ArgumentList $uArgs -PassThru -Wait
                $exitCode = $proc.ExitCode
                Write-Host "MSI uninstall exit code: $exitCode"
                if ($exitCode -eq 0 -or $exitCode -eq 3010) {
                    $summary.UninstallStatus = "Success ($exitCode)"
                } else {
                    $summary.UninstallStatus = "Failed ($exitCode)"
                }
            } else { $summary.UninstallStatus = "Failed (No ProductCode)" }
        } elseif ($unType -eq "msix") {
            $pkgName = $appDef.uninstall.package_name
            try {
                Get-AppxPackage -AllUsers -Name "*$pkgName*" | Remove-AppxPackage -AllUsers -ErrorAction Stop
                $summary.UninstallStatus = "Success"
                Write-Host "MSIX uninstall completed"
            } catch {
                $summary.UninstallStatus = "Failed"
                Write-Warning "MSIX uninstall failed: $_"
            }
        } elseif ($unType -eq "exe") {
            $uninstallPath = $appDef.uninstall.path
            $uninstallArgs = $appDef.uninstall.args

            if (Test-Path $uninstallPath) {
                Write-Host "Running EXE uninstaller: $uninstallPath $uninstallArgs"
                $process = Start-Process -FilePath $uninstallPath -ArgumentList $uninstallArgs -PassThru -Wait
                if ($process.ExitCode -eq 0) {
                    $summary.UninstallStatus = "Success"
                    Write-Host "EXE uninstall completed (exit code: 0)"
                } else {
                    $summary.UninstallStatus = "Failed ($($process.ExitCode))"
                    Write-Warning "EXE uninstall failed (exit code: $($process.ExitCode))"
                }
            } else {
                $summary.UninstallStatus = "Failed (Uninstaller not found)"
                Write-Warning "EXE uninstaller not found: $uninstallPath"
            }
        }
        
        Start-Sleep -Seconds 5
        
        # Verify Cleanup
        $clean = $true
        
        # 1. レジストリの残骸チェック
        if ($appDef.detect.registry_display_name) {
             if ((Get-InstalledAppsSnapshot).Registry -like "*$($appDef.detect.registry_display_name)*") { 
                 Write-Host "Cleanup Check Failed: Registry entry still exists"
                 $clean = $false 
             }
        }
        
        # 2. Appxの残骸チェック
        if ($appDef.detect.appx_name) {
             if ((Get-InstalledAppsSnapshot).Appx -like "*$($appDef.detect.appx_name)*") { 
                 Write-Host "Cleanup Check Failed: Appx package still exists"
                 $clean = $false 
             }
        }
        
        # 3. ファイルの残骸チェック
        if ($appDef.detect.file) {
             if (Test-Path $appDef.detect.file) {
                 Write-Host "Cleanup Check Failed: File still exists at $($appDef.detect.file)"
                 $clean = $false
             }
        }
        
        if ($clean) { $summary.CleanUpStatus = "Success" } else { $summary.CleanUpStatus = "Failed (Residue)" }
    }

    $summary.OverallResult = "PASS"

} catch {
    Write-Error $_
    $summary.OverallResult = "FAIL"
    exit 1
} finally {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   VERIFICATION SUMMARY: $App" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    $summary.Keys | ForEach-Object {
        $val = $summary[$_]
        $color = "White"
        if ($val -match "Success|Pass|64-bit") { $color = "Green" }
        if ($val -match "Warning|32-bit") { $color = "Yellow" }
        if ($val -match "Failed|FAIL|Unknown") { $color = "Red" }
        Write-Host "$($_.PadRight(18)) : " -NoNewline; Write-Host $val -ForegroundColor $color
    }
    Write-Host "==========================================" -ForegroundColor Cyan
}