# Simple Antivirus by Gorstak

# Define paths and parameters
$taskName = "SimpleAntivirusStartup"
$taskDescription = "Runs the Simple Antivirus script at user logon with admin privileges."
$scriptDir = "C:\Windows\Setup\Scripts\Bin"
$scriptPath = "$scriptDir\Antivirus.ps1"
$logFile = "$env:TEMP\antivirus_log.txt"
$localDatabase = "$env:TEMP\scanned_files.txt"
$scannedFiles = @{} # Initialize empty hash table
$virusTotalApiKey = "69943fa94565457f98509840a61638de2d509b39564f67ca443ef1ef1751fe10"
$maxRetries = 3
$retryDelaySeconds = 15
$maxFileSizeMB = 32

# Define allowed paths for EXE files
$allowedPaths = @(
    "C:\Users\",
    "C:\Program Files\",
    "C:\Program Files (x86)\"
)

# Define files to exclude from scanning
$excludedFiles = @(
    $logFile,
    $localDatabase
)

# Check if file path is in allowed paths for EXE monitoring
function Test-AllowedPath {
    param ([string]$filePath)
    foreach ($allowedPath in $allowedPaths) {
        if ($filePath -like "$allowedPath*") {
            return $true
        }
    }
    return $false
}

# Check if file should be excluded
function Test-ExcludedFile {
    param ([string]$filePath)
    foreach ($excludedFile in $excludedFiles) {
        if ($filePath -eq $excludedFile) {
            return $true
        }
    }
    return $false
}

# Check admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
Write-Host "Running as admin: $isAdmin"

# Logging Function with Rotation
function Write-Log {
    param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $message"
    Write-Host "Logging: $logEntry"
    if ((Test-Path $logFile) -and ((Get-Item $logFile -ErrorAction SilentlyContinue).Length -ge 10MB)) {
        $archiveName = "$env:TEMP\antivirus_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        Rename-Item -Path $logFile -NewName $archiveName -ErrorAction Stop
        Write-Host "Rotated log to: $archiveName"
    }
    $logEntry | Out-File -FilePath $logFile -Append -Encoding UTF8 -ErrorAction Stop
}

# Initial log with diagnostics
Write-Log "Script initialized. Admin: $isAdmin, User: $env:USERNAME, SID: $([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"

# Ensure execution policy allows script
if ((Get-ExecutionPolicy) -eq "Restricted") {
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
    Write-Log "Set execution policy to Bypass for current user."
}

# Setup script directory and copy script
if (-not (Test-Path $scriptDir)) {
    New-Item -Path $scriptDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    Write-Log "Created script directory: $scriptDir"
}
if (-not (Test-Path $scriptPath) -or (Get-Item $scriptPath).LastWriteTime -lt (Get-Item $MyInvocation.MyCommand.Path).LastWriteTime) {
    Copy-Item -Path $MyInvocation.MyCommand.Path -Destination $scriptPath -Force -ErrorAction Stop
    Write-Log "Copied/Updated script to: $scriptPath"
}

# Register scheduled task as SYSTEM
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $existingTask -and $isAdmin) {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Description $taskDescription
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -ErrorAction Stop
    Write-Log "Scheduled task '$taskName' registered to run as SYSTEM."
} elseif (-not $isAdmin) {
    Write-Log "Skipping task registration: Admin privileges required"
}

# Load or Reset Scanned Files Database
if (Test-Path $localDatabase) {
    try {
        $scannedFiles.Clear() # Reset hash table before loading
        $lines = Get-Content $localDatabase -ErrorAction Stop
        foreach ($line in $lines) {
            if ($line -match "^([0-9a-f]{64}),(true|false)$") {
                $scannedFiles[$matches[1]] = [bool]$matches[2]
            }
        }
        Write-Log "Loaded $($scannedFiles.Count) scanned file entries from database."
    } catch {
        Write-Log "Failed to load database: $($_.Exception.Message)"
        $scannedFiles.Clear() # Reset on failure
    }
} else {
    $scannedFiles.Clear() # Ensure reset if no database
    New-Item -Path $localDatabase -ItemType File -Force -ErrorAction Stop | Out-Null
    Write-Log "Created new database: $localDatabase"
}

# Take Ownership and Modify Permissions (Aggressive)
function Set-FileOwnershipAndPermissions {
    param ([string]$filePath)
    try {
        takeown /F $filePath /A | Out-Null
        icacls $filePath /reset | Out-Null
        icacls $filePath /grant "Administrators:F" /inheritance:d | Out-Null
        Write-Log "Forcibly set ownership and permissions for $filePath"
        return $true
    } catch {
        Write-Log "Failed to set ownership/permissions for ${filePath}: $($_.Exception.Message)"
        return $false
    }
}

# Calculate File Hash and Signature
function Calculate-FileHash {
    param ([string]$filePath)
    try {
        $signature = Get-AuthenticodeSignature -FilePath $filePath -ErrorAction Stop
        $hash = Get-FileHash -Path $filePath -Algorithm SHA256 -ErrorAction Stop
        Write-Log "Signature status for ${filePath}: $($signature.Status) - $($signature.StatusMessage)"
        return [PSCustomObject]@{
            Hash = $hash.Hash.ToLower()
            Status = $signature.Status
            StatusMessage = $signature.StatusMessage
        }
    } catch {
        Write-Log "Error processing ${filePath}: $($_.Exception.Message)"
        return $null
    }
}

# Quarantine File (Crash-Proof)
function Quarantine-File {
    param ([string]$filePath)
    try {
        icacls $filePath /inheritance:r | Out-Null
        icacls $filePath /grant:r "*S-1-2-1:F" | Out-Null
        Write-Log "Quarantined file by modifying permissions: $filePath"
        return $true
    } catch {
        Write-Log "Failed to quarantine ${filePath}: $($_.Exception.Message)"
        return $false
    }
}

# Stop Processes Using File (Aggressive)
function Stop-ProcessUsingFile {
    param ([string]$filePath)
    try {
        $processes = Get-Process | Where-Object { ($_.Modules | Where-Object { $_.FileName -eq $filePath }) -or ($_.Path -eq $filePath) }
        foreach ($process in $processes) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            Write-Log "Stopped process $($process.Name) (PID: $($process.Id)) using $filePath"
        }
    } catch {
        Write-Log "Error stopping processes for ${filePath}: $($_.Exception.Message)"
        try {
            $processes = Get-Process | Where-Object { ($_.Modules | Where-Object { $_.FileName -eq $filePath }) -or ($_.Path -eq $filePath) }
            foreach ($process in $processes) {
                taskkill /PID $process.Id /F | Out-Null
                Write-Log "Force-killed process $($process.Name) (PID: $($process.Id)) using taskkill"
            }
        } catch {
            Write-Log "Fallback process kill failed for ${filePath}: $($_.Exception.Message)"
        }
    }
}

# Upload File to VirusTotal
function Upload-FileToVirusTotal {
    param ([string]$filePath, [string]$fileHash)
    try {
        $fileInfo = Get-Item $filePath -ErrorAction Stop
        if ($fileInfo.Length -gt ($maxFileSizeMB * 1MB)) {
            Write-Log "Cannot upload ${filePath}: File size exceeds $maxFileSizeMB MB."
            return $false
        }
        $url = "https://www.virustotal.com/api/v3/files"
        $headers = @{ "x-apikey" = $virusTotalApiKey }
        $form = @{ file = $fileInfo }
        Write-Log "Uploading file ${filePath} to VirusTotal."
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Post -Form $form -ErrorAction Stop
        $analysisId = $response.data.id
        Write-Log "File ${filePath} uploaded. Analysis ID: $analysisId"
        
        # Poll for analysis results
        $analysisUrl = "https://www.virustotal.com/api/v3/analyses/$analysisId"
        for ($i = 0; $i -lt $maxRetries; $i++) {
            Start-Sleep -Seconds $retryDelaySeconds
            try {
                $analysisResponse = Invoke-RestMethod -Uri $analysisUrl -Headers $headers -Method Get -ErrorAction Stop
                if ($analysisResponse.data.attributes.status -eq "completed") {
                    $maliciousCount = $analysisResponse.data.attributes.stats.malicious
                    Write-Log "VirusTotal analysis for ${fileHash}: $maliciousCount malicious detections."
                    return $maliciousCount -gt 3
                }
            } catch {
                Write-Log "Error checking analysis status for ${fileHash}: $($_.Exception.Message)"
            }
        }
        Write-Log "Analysis for ${fileHash} did not complete in time."
        return $false
    } catch {
        Write-Log "Failed to upload ${filePath}: $($_.Exception.Message)"
        return $false
    }
}

# Scan File with VirusTotal
function Scan-FileWithVirusTotal {
    param ([string]$fileHash, [string]$filePath)
    for ($i = 0; $i -lt $maxRetries; $i++) {
        try {
            $url = "https://www.virustotal.com/api/v3/files/$fileHash"
            $headers = @{ "x-apikey" = $virusTotalApiKey }
            $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 30
            if ($response.data.attributes) {
                $maliciousCount = $response.data.attributes.last_analysis_stats.malicious
                Write-Log "VirusTotal result for ${fileHash}: $maliciousCount malicious detections."
                return $maliciousCount -gt 3
            }
        } catch {
            if ($_.Exception.Response.StatusCode -eq 404) {
                Write-Log "File hash ${fileHash} not found in VirusTotal database. Attempting to upload."
                return Upload-FileToVirusTotal -filePath $filePath -fileHash $fileHash
            }
            Write-Log "Error scanning ${fileHash}: $($_.Exception.Message)"
            if ($i -lt ($maxRetries - 1)) {
                Start-Sleep -Seconds $retryDelaySeconds
                continue
            }
        }
    }
    return $false
}

# Scan EXE Files (Limited to Allowed Paths)
function Scan-ExeFiles {
    Write-Log "Starting scan of EXE files in allowed paths."
    foreach ($path in $allowedPaths) {
        Write-Log "Scanning EXE files in: $path"
        try {
            $files = Get-ChildItem -Path $path -Filter *.exe -Recurse -File -ErrorAction Stop
            foreach ($file in $files) {
                $filePath = $file.FullName
                if (Test-ExcludedFile -filePath $filePath) {
                    Write-Log "Skipping excluded EXE file: $filePath"
                    continue
                }
                $fileInfo = $file
                try {
                    $fileHash = Calculate-FileHash -filePath $filePath
                    if ($fileHash) {
                        if ($scannedFiles.ContainsKey($fileHash.Hash)) {
                            Write-Log "Skipping already scanned EXE file: $filePath (Hash: $($fileHash.Hash))"
                            if (-not $scannedFiles[$fileHash.Hash]) {
                                if (Set-FileOwnershipAndPermissions -filePath $filePath) {
                                    Stop-ProcessUsingFile -filePath $filePath
                                    Quarantine-File -filePath $filePath
                                }
                            }
                        } else {
                            $isSignatureValid = $fileHash.Status -eq "Valid"
                            $isMalicious = $false
                            if ($isSignatureValid -and $fileInfo.Length -le ($maxFileSizeMB * 1MB)) {
                                $isMalicious = Scan-FileWithVirusTotal -fileHash $fileHash.Hash -filePath $filePath
                                Start-Sleep -Seconds $retryDelaySeconds  # Rate limit
                            } else {
                                Write-Log "Skipping VT scan for EXE file: $filePath (SignatureValid: $isSignatureValid, Size: $($fileInfo.Length))"
                            }
                            $isValid = $isSignatureValid -and -not $isMalicious
                            $scannedFiles[$fileHash.Hash] = $isValid
                            "$($fileHash.Hash),$isValid" | Out-File -FilePath $localDatabase -Append -Encoding UTF8 -ErrorAction Stop
                            Write-Log "Scanned new EXE file: $filePath (Valid: $isValid)"
                            if (-not $isValid) {
                                if (Set-FileOwnershipAndPermissions -filePath $filePath) {
                                    Stop-ProcessUsingFile -filePath $filePath
                                    Quarantine-File -filePath $filePath
                                }
                            }
                        }
                    }
                } catch {
                    Write-Log "Error processing EXE file ${filePath}: $($_.Exception.Message)"
                }
            }
        } catch {
            Write-Log "EXE scan failed for path ${path}: $($_.Exception.Message)"
        }
    }
}

# Scan DLL Files (All Drives)
function Scan-DllFiles {
    Write-Log "Starting scan of DLL files across all drives."
    $drives = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -in (2, 3, 4) }
    foreach ($drive in $drives) {
        $root = $drive.DeviceID + "\"
        Write-Log "Scanning DLL files on drive: $root"
        try {
            $files = Get-ChildItem -Path $root -Filter *.dll -Recurse -File -Exclude @("C:\Windows\System32\config") -ErrorAction Stop
            foreach ($file in $files) {
                $filePath = $file.FullName
                if (Test-ExcludedFile -filePath $filePath) {
                    Write-Log "Skipping excluded DLL file: $filePath"
                    continue
                }
                $fileInfo = $file
                try {
                    $fileHash = Calculate-FileHash -filePath $filePath
                    if ($fileHash) {
                        if ($scannedFiles.ContainsKey($fileHash.Hash)) {
                            Write-Log "Skipping already scanned DLL file: $filePath (Hash: $($fileHash.Hash))"
                            if (-not $scannedFiles[$fileHash.Hash]) {
                                if (Set-FileOwnershipAndPermissions -filePath $filePath) {
                                    Stop-ProcessUsingFile -filePath $filePath
                                    Quarantine-File -filePath $filePath
                                }
                            }
                        } else {
                            $isSignatureValid = $fileHash.Status -eq "Valid"
                            $isMalicious = $false
                            if ($isSignatureValid -and $fileInfo.Length -le ($maxFileSizeMB * 1MB)) {
                                $isMalicious = Scan-FileWithVirusTotal -fileHash $fileHash.Hash -filePath $filePath
                                Start-Sleep -Seconds $retryDelaySeconds  # Rate limit
                            } else {
                                Write-Log "Skipping VT scan for DLL file: $filePath (SignatureValid: $isSignatureValid, Size: $($fileInfo.Length))"
                            }
                            $isValid = $isSignatureValid -and -not $isMalicious
                            $scannedFiles[$fileHash.Hash] = $isValid
                            "$($fileHash.Hash),$isValid" | Out-File -FilePath $localDatabase -Append -Encoding UTF8 -ErrorAction Stop
                            Write-Log "Scanned new DLL file: $filePath (Valid: $isValid)"
                            if (-not $isValid) {
                                if (Set-FileOwnershipAndPermissions -filePath $filePath) {
                                    Stop-ProcessUsingFile -filePath $filePath
                                    Quarantine-File -filePath $filePath
                                }
                            }
                        }
                    }
                } catch {
                    Write-Log "Error processing DLL file ${filePath}: $($_.Exception.Message)"
                }
            }
        } catch {
            Write-Log "DLL scan failed for drive ${root}: $($_.Exception.Message)"
        }
    }
}

# Scan Other Files (All Drives)
function Scan-OtherFiles {
    Write-Log "Starting scan of other files across all drives."
    $drives = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -in (2, 3, 4) }
    foreach ($drive in $drives) {
        $root = $drive.DeviceID + "\"
        Write-Log "Scanning other files on drive: $root"
        try {
            $files = Get-ChildItem -Path $root -Recurse -File -ErrorAction Stop
            foreach ($file in $files) {
                $filePath = $file.FullName
                if (Test-ExcludedFile -filePath $filePath) {
                    Write-Log "Skipping excluded other file: $filePath"
                    continue
                }
                $fileInfo = $file
                try {
                    $fileHash = Calculate-FileHash -filePath $filePath
                    if ($fileHash) {
                        if ($scannedFiles.ContainsKey($fileHash.Hash)) {
                            Write-Log "Skipping already scanned other file: $filePath (Hash: $($fileHash.Hash))"
                            if (-not $scannedFiles[$fileHash.Hash]) {
                                if (Set-FileOwnershipAndPermissions -filePath $filePath) {
                                    Stop-ProcessUsingFile -filePath $filePath
                                    Quarantine-File -filePath $filePath
                                }
                            }
                        } else {
                            $isSignatureValid = $fileHash.Status -eq "Valid"
                            $isMalicious = $false
                            if ($isSignatureValid -and $fileInfo.Length -le ($maxFileSizeMB * 1MB)) {
                                $isMalicious = Scan-FileWithVirusTotal -fileHash $fileHash.Hash -filePath $filePath
                                Start-Sleep -Seconds $retryDelaySeconds  # Rate limit
                            } else {
                                Write-Log "Skipping VT scan for other file: $filePath (SignatureValid: $isSignatureValid, Size: $($fileInfo.Length))"
                            }
                            $isValid = $isSignatureValid -and -not $isMalicious
                            $scannedFiles[$fileHash.Hash] = $isValid
                            "$($fileHash.Hash),$isValid" | Out-File -FilePath $localDatabase -Append -Encoding UTF8 -ErrorAction Stop
                            Write-Log "Scanned new other file: $filePath (Valid: $isValid)"
                            if (-not $isValid) {
                                if (Set-FileOwnershipAndPermissions -filePath $filePath) {
                                    Stop-ProcessUsingFile -filePath $filePath
                                    Quarantine-File -filePath $filePath
                                }
                            }
                        }
                    }
                } catch {
                    Write-Log "Error processing other file ${filePath}: $($_.Exception.Message)"
                }
            }
        } catch {
            Write-Log "Other files scan failed for drive ${root}: $($_.Exception.Message)"
        }
    }
}

# File System Watcher (Unfiltered, Routes to Specific Functions)
$drives = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -in (2, 3, 4) }
foreach ($drive in $drives) {
    $monitorPath = $drive.DeviceID + "\"
    try {
        $fileWatcher = New-Object System.IO.FileSystemWatcher
        $fileWatcher.Path = $monitorPath
        $fileWatcher.Filter = "*.*"
        $fileWatcher.IncludeSubdirectories = $true
        $fileWatcher.EnableRaisingEvents = $true
        $fileWatcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite

        $action = {
            param($sender, $e)
            try {
                if ($e.ChangeType -in @("Created", "Changed")) {
                    $filePath = $e.FullPath
                    if (Test-ExcludedFile -filePath $filePath) {
                        Write-Log "Skipping excluded file in watcher: $filePath"
                        return
                    }
                    Write-Log "Detected file change: $filePath"
                    $fileInfo = Get-Item $filePath -ErrorAction SilentlyContinue
                    if ($fileInfo) {
                        if ($filePath.EndsWith(".exe") -and (Test-AllowedPath -filePath $filePath)) {
                            # Route EXE files in allowed paths to Scan-ExeFiles logic
                            $fileHash = Calculate-FileHash -filePath $filePath
                            if ($fileHash) {
                                if ($scannedFiles.ContainsKey($fileHash.Hash)) {
                                    Write-Log "Skipping already scanned EXE file: $filePath (Hash: $($fileHash.Hash))"
                                    if (-not $scannedFiles[$fileHash.Hash]) {
                                        if (Set-FileOwnershipAndPermissions -filePath $filePath) {
                                            Stop-ProcessUsingFile -filePath $filePath
                                            Quarantine-File -filePath $filePath
                                        }
                                    }
                                } else {
                                    $isSignatureValid = $fileHash.Status -eq "Valid"
                                    $isMalicious = $false
                                    if ($isSignatureValid -and $fileInfo.Length -le ($maxFileSizeMB * 1MB)) {
                                        $isMalicious = Scan-FileWithVirusTotal -fileHash $fileHash.Hash -filePath $filePath
                                        Start-Sleep -Seconds $retryDelaySeconds  # Rate limit
                                    } else {
                                        Write-Log "Skipping VT scan for EXE file: $filePath (SignatureValid: $isSignatureValid, Size: $($fileInfo.Length))"
                                    }
                                    $isValid = $isSignatureValid -and -not $isMalicious
                                    $scannedFiles[$fileHash.Hash] = $isValid
                                    "$($fileHash.Hash),$isValid" | Out-File -FilePath $localDatabase -Append -Encoding UTF8 -ErrorAction Stop
                                    Write-Log "Scanned new EXE file: $filePath (Valid: $isValid)"
                                    if (-not $isValid) {
                                        if (Set-FileOwnershipAndPermissions -filePath $filePath) {
                                            Stop-ProcessUsingFile -filePath $filePath
                                            Quarantine-File -filePath $filePath
                                        }
                                    }
                                }
                            }
                        } elseif ($filePath.EndsWith(".dll")) {
                            # Route DLL files to Scan-DllFiles logic
                            $fileHash = Calculate-FileHash -filePath $filePath
                            if ($fileHash) {
                                if ($scannedFiles.ContainsKey($fileHash.Hash)) {
                                    Write-Log "Skipping already scanned DLL file: $filePath (Hash: $($fileHash.Hash))"
                                    if (-not $scannedFiles[$fileHash.Hash]) {
                                        if (Set-FileOwnershipAndPermissions -filePath $filePath) {
                                            Stop-ProcessUsingFile -filePath $filePath
                                            Quarantine-File -filePath $filePath
                                        }
                                    }
                                } else {
                                    $isSignatureValid = $fileHash.Status -eq "Valid"
                                    $isMalicious = $false
                                    if ($isSignatureValid -and $fileInfo.Length -le ($maxFileSizeMB * 1MB)) {
                                        $isMalicious = Scan-FileWithVirusTotal -fileHash $fileHash.Hash -filePath $filePath
                                        Start-Sleep -Seconds $retryDelaySeconds  # Rate limit
                                    } else {
                                        Write-Log "Skipping VT scan for DLL file: $filePath (SignatureValid: $isSignatureValid, Size: $($fileInfo.Length))"
                                    }
                                    $isValid = $isSignatureValid -and -not $isMalicious
                                    $scannedFiles[$fileHash.Hash] = $isValid
                                    "$($fileHash.Hash),$isValid" | Out-File -FilePath $localDatabase -Append -Encoding UTF8 -ErrorAction Stop
                                    Write-Log "Scanned new DLL file: $filePath (Valid: $isValid)"
                                    if (-not $isValid) {
                                        if (Set-FileOwnershipAndPermissions -filePath $filePath) {
                                            Stop-ProcessUsingFile -filePath $filePath
                                            Quarantine-File -filePath $filePath
                                        }
                                    }
                                }
                            }
                        } else {
                            # Route other files to Scan-OtherFiles logic
                            $fileHash = Calculate-FileHash -filePath $filePath
                            if ($fileHash) {
                                if ($scannedFiles.ContainsKey($fileHash.Hash)) {
                                    Write-Log "Skipping already scanned other file: $filePath (Hash: $($fileHash.Hash))"
                                    if (-not $scannedFiles[$fileHash.Hash]) {
                                        if (Set-FileOwnershipAndPermissions -filePath $filePath) {
                                            Stop-ProcessUsingFile -filePath $filePath
                                            Quarantine-File -filePath $filePath
                                        }
                                    }
                                } else {
                                    $isSignatureValid = $fileHash.Status -eq "Valid"
                                    $isMalicious = $false
                                    if ($isSignatureValid -and $fileInfo.Length -le ($maxFileSizeMB * 1MB)) {
                                        $isMalicious = Scan-FileWithVirusTotal -fileHash $fileHash.Hash -filePath $filePath
                                        Start-Sleep -Seconds $retryDelaySeconds  # Rate limit
                                    } else {
                                        Write-Log "Skipping VT scan for other file: $filePath (SignatureValid: $isSignatureValid, Size: $($fileInfo.Length))"
                                    }
                                    $isValid = $isSignatureValid -and -not $isMalicious
                                    $scannedFiles[$fileHash.Hash] = $isValid
                                    "$($fileHash.Hash),$isValid" | Out-File -FilePath $localDatabase -Append -Encoding UTF8 -ErrorAction Stop
                                    Write-Log "Scanned new other file: $filePath (Valid: $isValid)"
                                    if (-not $isValid) {
                                        if (Set-FileOwnershipAndPermissions -filePath $filePath) {
                                            Stop-ProcessUsingFile -filePath $filePath
                                            Quarantine-File -filePath $filePath
                                        }
                                    }
                                }
                            }
                        }
                        # Throttle lightly without blocking the runspace
                        Start-Job -ScriptBlock { Start-Sleep -Milliseconds 500 } | Wait-Job -Timeout 1 | Remove-Job -Force -ErrorAction SilentlyContinue
                    }
                }
            } catch {
                Write-Log "Watcher error for ${filePath}: $($_.Exception.Message)"
            }
        }

        Register-ObjectEvent -InputObject $fileWatcher -EventName Created -Action $action -ErrorAction Stop
        Register-ObjectEvent -InputObject $fileWatcher -EventName Changed -Action $action -ErrorAction Stop
        Write-Log "FileSystemWatcher set up for $monitorPath"
    } catch {
        Write-Log "Failed to set up watcher for ${monitorPath}: $($_.Exception.Message)"
    }
}

# Initial scan
Scan-ExeFiles
Scan-DllFiles
Scan-OtherFiles
Write-Log "Initial scan completed. Monitoring started."

# Keep script running with crash protection
Write-Host "Antivirus running. Press [Ctrl] + [C] to stop."
try {
    while ($true) { Start-Sleep -Seconds 10 }
} catch {
    Write-Log "Main loop crashed: $($_.Exception.Message)"
    Write-Host "Script crashed. Check $logFile for details."
}