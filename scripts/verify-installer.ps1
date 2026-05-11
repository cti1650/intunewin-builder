param (
  [Parameter(Mandatory)]
  [string]$App
)

$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

. "$PSScriptRoot/lib.ps1"

# ==========
# Result Summary Object
# ==========
$summary = [ordered]@{
    AppName           = $App
    DisplayName       = ""
    InstallPath       = ""
    InstalledVersion  = ""
    InstallBehavior   = ""
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
  $registryApps = $script:UninstallRegistryPaths | ForEach-Object {
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

function Format-ExitCodeStatus {
    param([int]$ExitCode, [int[]]$SuccessCodes = @(0, 3010))
    if ($SuccessCodes -contains $ExitCode) { return "Success ($ExitCode)" }
    return "Failed ($ExitCode)"
}

function Stop-UninstallTargets {
    param($AppDef)
    if ($AppDef.uninstall.process_name) {
        Write-Host "Stopping process: $($AppDef.uninstall.process_name)"
        Stop-Process -Name $AppDef.uninstall.process_name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    if ($AppDef.uninstall.service_name) {
        Write-Host "Stopping service: $($AppDef.uninstall.service_name)"
        Stop-Service -Name $AppDef.uninstall.service_name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
}

function Invoke-MsiUninstall {
    param($AppDef)
    $match = Find-RegistryUninstallEntry -DisplayName $AppDef.detect.registry_display_name
    if (-not ($match -and $match.PSChildName -match "^\{.*\}$")) {
        return "Failed (No ProductCode)"
    }
    $uArgs = $AppDef.uninstall.args -replace "\{product_code\}", $match.PSChildName
    $proc = Start-Process msiexec -ArgumentList $uArgs -PassThru -Wait
    Write-Host "MSI uninstall exit code: $($proc.ExitCode)"
    return Format-ExitCodeStatus $proc.ExitCode
}

function Invoke-RegistryStringUninstall {
    param($AppDef)
    $entry = Find-RegistryUninstallEntry -DisplayName $AppDef.detect.registry_display_name
    if (-not $entry) {
        Write-Warning "Registry entry not found for: $($AppDef.detect.registry_display_name)"
        return "Failed (Registry entry not found)"
    }
    $uninstallCmd = if ($entry.QuietUninstallString) { $entry.QuietUninstallString } else { $entry.UninstallString }
    Write-Host "Uninstall command: $uninstallCmd"
    if ($uninstallCmd -match '^"([^"]+)"\s*(.*)$') {
        $exe = $Matches[1]; $uArgs = $Matches[2].Trim()
    } else {
        $exe = $uninstallCmd; $uArgs = ""
    }

    # UninstallString は /S 等のサイレントフラグを持たない場合がある (例: Firefox MSI は
    # QuietUninstallString を書き込まず、UninstallString が引数なしの helper.exe のみ →
    # UI 起動 → ハング → workflow timeout)。args が空のときに限り /S を補完する。
    # generic-install.ps1 のアンインストール経路と同じ補完ロジック。
    if (-not $uArgs) {
        Write-Host "Augmenting empty UninstallString args with /S (silent uninstall)"
        $uArgs = "/S"
    }

    $proc = Start-Process -FilePath $exe -ArgumentList $uArgs -PassThru -Wait
    Write-Host "Uninstall exit code: $($proc.ExitCode)"
    return Format-ExitCodeStatus $proc.ExitCode
}

function Invoke-MsixUninstall {
    param($AppDef)
    $pkgName = $AppDef.uninstall.package_name
    try {
        Get-AppxPackage -AllUsers -Name "*$pkgName*" | Remove-AppxPackage -AllUsers -ErrorAction Stop
        Write-Host "MSIX uninstall completed"
        return "Success"
    } catch {
        Write-Warning "MSIX uninstall failed: $_"
        return "Failed"
    }
}

function Invoke-ExeUninstall {
    param($AppDef)
    # uninstall.path に %LocalAppData% 等の環境変数が含まれる per-user app に対応
    $uninstallPath = Expand-EnvPath $AppDef.uninstall.path
    if (-not (Test-Path $uninstallPath)) {
        Write-Warning "EXE uninstaller not found: $uninstallPath"
        return "Failed (Uninstaller not found)"
    }
    $uninstallArgs = $AppDef.uninstall.args
    Write-Host "Running EXE uninstaller: $uninstallPath $uninstallArgs"
    $process = Start-Process -FilePath $uninstallPath -ArgumentList $uninstallArgs -PassThru -Wait
    if ($process.ExitCode -eq 0) {
        Write-Host "EXE uninstall completed (exit code: 0)"
        return "Success"
    }
    Write-Warning "EXE uninstall failed (exit code: $($process.ExitCode))"
    return "Failed ($($process.ExitCode))"
}

function Invoke-ScriptUninstall {
    param($AppDef, [string]$App, [bool]$IsCustomScript)

    if ($IsCustomScript) {
        $uninstallScriptName = $AppDef.uninstall.script
        if (-not $uninstallScriptName) {
            Write-Warning "custom_script app has no uninstall.script defined; skipping"
            return "Skipped (no script)"
        }
        $uninstallScriptPath = "scripts/apps/$App/$uninstallScriptName"
        if (-not (Test-Path $uninstallScriptPath)) {
            Write-Warning "Custom uninstall script not found: $uninstallScriptPath"
            return "Failed (script not found)"
        }
        Write-Host "Running custom uninstall script: $uninstallScriptPath"
        & powershell.exe -ExecutionPolicy Bypass -File $uninstallScriptPath
        if ($LASTEXITCODE -eq 0) { return "Success" }
        return "Failed ($LASTEXITCODE)"
    }

    $registryName = $AppDef.uninstall.registry_name
    if (-not $registryName) { $registryName = $AppDef.detect.registry_display_name }
    Write-Host "Uninstalling via generic-install.ps1..."
    Write-Host "  RegistryName: $registryName"
    & scripts/generic-install.ps1 -Uninstall -RegistryName $registryName
    if ($LASTEXITCODE -eq 0) { return "Success" }
    return "Failed ($LASTEXITCODE)"
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
    $appDef = Get-AppDefinition -App $App

    $isScriptBased = $appDef.script_based -eq $true
    $type = $appDef.installer.type
    $summary.InstallerType = if ($isScriptBased) { "script" } else { $type }
    $summary.InstallBehavior = $appDef.intune.install_behavior

    # Snapshot before
    $snapshotBefore = Get-InstalledAppsSnapshot

    $isCustomScript = $appDef.custom_script -eq $true

    if ($isScriptBased) {
        # ==========
        # Script-based Install
        # ==========
        $summary.AppArchitecture = "N/A (Script)"
        $summary.ArchCheck = "Skipped (Script)"

        if ($isCustomScript) {
            Write-Host "Mode: Script-based deployment (custom_script)"
            $installScriptName = $appDef.installer.script
            if (-not $installScriptName) { $installScriptName = "install.ps1" }
            $installScriptPath = "scripts/apps/$App/$installScriptName"
            if (-not (Test-Path $installScriptPath)) {
                throw "Custom install script not found: $installScriptPath"
            }
            Write-Host "Running custom install script: $installScriptPath"
            & powershell.exe -ExecutionPolicy Bypass -File $installScriptPath
            $exitCode = $LASTEXITCODE
        } else {
            Write-Host "Mode: Script-based deployment"
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
        }

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
            # CI 環境では Defender real-time scanning が NSIS 系インストーラの子プロセス起動と
            # 衝突して 0xC0000005 (-1073741819) で死ぬことがある (Azure 特定 region 多発)。
            # generic-install.ps1 (script_based 経路) では PR #22 で対処済み、こちらは traditional 経路。
            # エンドユーザー端末では発火させない。
            if ($env:GITHUB_ACTIONS -eq 'true') {
                try {
                    $exclDir = Split-Path -Parent $installerPath
                    Add-MpPreference -ExclusionPath $exclDir -ErrorAction SilentlyContinue
                    Write-Host "Added Defender exclusion for: $exclDir"
                } catch { }
            }
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

    # ファイル検出 (%LocalAppData% 等の環境変数を展開)
    if ($appDef.detect.file) {
        $detectFile = Expand-EnvPath $appDef.detect.file
        $summary.InstallPath = $detectFile
        if (Test-Path $detectFile) {
            $detectionResults["File"] = $true
            Write-Host "File detection: Pass"

            # バージョン取得 (FileVersion → 空ならレジストリ DisplayVersion フォールバック)
            $fileInfo = Get-Item $detectFile
            $installedVersion = $fileInfo.VersionInfo.FileVersion
            if (-not $installedVersion -and $appDef.detect.registry_display_name) {
                $entry = Find-RegistryUninstallEntry -DisplayName $appDef.detect.registry_display_name
                if ($entry -and $entry.DisplayVersion) {
                    $installedVersion = $entry.DisplayVersion
                    Write-Host "Version source: registry DisplayVersion ($installedVersion)"
                }
            }
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
            Write-Warning "File detection: Failed (not found: $detectFile)"
            $detectionResults["File"] = $false
            $summary.VersionCheck = "Skipped (File not found)"
            # 診断: registry の InstallLocation を表示し、yml の detect.file 修正先を分かりやすくする
            if ($appDef.detect.registry_display_name) {
                $entry = Find-RegistryUninstallEntry -DisplayName $appDef.detect.registry_display_name
                if ($entry -and $entry.InstallLocation) {
                    Write-Host "Hint: registry InstallLocation = $($entry.InstallLocation)"
                    Write-Host "      (yml の detect.file が実際の install 先と乖離している可能性)"
                }
            }
        }

        # インストール場所チェック（x64/x86両方を確認）
        $detectFilePath = $detectFile
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

    # detect.file を持たないアプリ (例: ovice_script_based) でも summary を埋めるため、
    # registry_display_name のエントリから DisplayVersion / InstallLocation を補完する。
    if ($appDef.detect.registry_display_name -and (-not $summary.InstalledVersion -or -not $summary.InstallPath)) {
        $entry = Find-RegistryUninstallEntry -DisplayName $appDef.detect.registry_display_name
        if ($entry) {
            if (-not $summary.InstalledVersion -and $entry.DisplayVersion) {
                $summary.InstalledVersion = $entry.DisplayVersion
                Write-Host "InstalledVersion source: registry DisplayVersion ($($entry.DisplayVersion))"
            }
            if (-not $summary.InstallPath -and $entry.InstallLocation) {
                $summary.InstallPath = $entry.InstallLocation
                Write-Host "InstallPath source: registry InstallLocation ($($entry.InstallLocation))"
            }
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
        Stop-UninstallTargets -AppDef $appDef

        $summary.UninstallStatus = switch ($appDef.uninstall.type) {
            'script'          { Invoke-ScriptUninstall          -AppDef $appDef -App $App -IsCustomScript $isCustomScript }
            'msi'             { Invoke-MsiUninstall             -AppDef $appDef }
            'registry_string' { Invoke-RegistryStringUninstall  -AppDef $appDef }
            'msix'            { Invoke-MsixUninstall            -AppDef $appDef }
            'exe'             { Invoke-ExeUninstall             -AppDef $appDef }
            default           { "Skipped (unknown type: $($appDef.uninstall.type))" }
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
        
        # 3. ファイルの残骸チェック (%LocalAppData% 等は展開して比較)
        if ($appDef.detect.file) {
             $detectFile = Expand-EnvPath $appDef.detect.file
             if (Test-Path $detectFile) {
                 Write-Host "Cleanup Check Failed: File still exists at $detectFile"
                 $clean = $false
             }
        }
        
        if ($clean) { $summary.CleanUpStatus = "Success" } else { $summary.CleanUpStatus = "Failed (Residue)" }
    }

    # 後段ステップ (Uninstall / CleanUp) は throw しないため、ここで再評価して
    # 1 つでも Failed なら throw して CI を fail させる。Detection / VersionCheck は
    # 既に途中で throw 済みなのでここに来た時点では Pass / Skipped のいずれか。
    $failedSteps = @()
    if ($summary.UninstallStatus -like 'Failed*') { $failedSteps += 'Uninstall' }
    if ($summary.CleanUpStatus   -like 'Failed*') { $failedSteps += 'CleanUp' }
    if ($failedSteps.Count -gt 0) {
        $summary.OverallResult = "FAIL ($($failedSteps -join ', '))"
        throw "Verify failed at: $($failedSteps -join ', ')"
    }
    $summary.OverallResult = "PASS"

} catch {
    Write-Error $_
    if ($summary.OverallResult -notlike 'FAIL*') {
        $summary.OverallResult = "FAIL"
    }
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