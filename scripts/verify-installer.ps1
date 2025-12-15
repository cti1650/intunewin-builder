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

    # Snapshot before
    $snapshotBefore = Get-InstalledAppsSnapshot

    # Check file header magic
    $bytes = [System.IO.File]::ReadAllBytes($installerPath)[0..3]
    $header = [BitConverter]::ToString($bytes) -replace '-',''
    if ($type -eq "msi" -and $header -ne "D0CF11E0") { Write-Warning "Invalid MSI Header"; $summary.InstallerType = "Invalid MSI" }
    elseif ($type -eq "exe" -and $header -notlike "4D5A*") { Write-Warning "Invalid EXE Header"; $summary.InstallerType = "Invalid EXE" }
    # ★ MSIXのZipヘッダーチェックを復活
    elseif ($type -eq "msix" -and $header -ne "504B0304") { Write-Warning "Invalid MSIX Header"; $summary.InstallerType = "Invalid MSIX" }

    # ==========
    # Install
    # ==========
    Write-Host "Installing..."
    $timeoutSeconds = $appDef.installer.timeout
    if (-not $timeoutSeconds) { $timeoutSeconds = 600 }

    if ($type -eq "msi") {
        $process = Start-Process msiexec -ArgumentList $installArgs -PassThru
        if (-not $process.WaitForExit($timeoutSeconds * 1000)) { $process | Stop-Process -Force; throw "MSI Installation Timed Out" }
        $exitCode = $process.ExitCode
    } elseif ($type -eq "msix") {
        # ★ MSIXインストール処理を復活
        try {
            Add-AppxPackage -Path $installerPath -ErrorAction Stop
            $exitCode = 0
            Write-Host "MSIX installation completed"
        } catch {
            $exitCode = 1
            Write-Host "MSIX installation failed: $_"
            throw
        }
    } else {
        $process = Start-Process -FilePath $installerPath -ArgumentList $installArgs -PassThru
        if (-not $process.WaitForExit($timeoutSeconds * 1000)) { $process | Stop-Process -Force; throw "EXE Installation Timed Out" }
        $exitCode = $process.ExitCode
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
        
        if ($unType -eq "msi") {
            $searchName = $appDef.detect.registry_display_name
            $paths = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*")
            $match = $paths | ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } | Where-Object { $_.DisplayName -like "*$searchName*" } | Select-Object -First 1
            if ($match -and $match.PSChildName -match "^\{.*\}$") {
                $pCode = $match.PSChildName
                $uArgs = $appDef.uninstall.args -replace "\{product_code\}", $pCode
                Start-Process msiexec -ArgumentList $uArgs -Wait
                $summary.UninstallStatus = "Success"
            } else { $summary.UninstallStatus = "Failed (No ProductCode)" }
        } elseif ($unType -eq "msix") {
            # ★ MSIXアンインストール処理を復活
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
             # EXE用の簡易ロジック（実際はYAMLのpath等を使う）
             $summary.UninstallStatus = "Skipped (EXE logic)"
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