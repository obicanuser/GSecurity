# GFocus.ps1 - Real-Time Network Lockdown with Connection Termination
# Runs as SYSTEM, logs to C:\GFocus.log, persists whitelist (process paths) to C:\GFocus_Whitelist.txt
# Whitelists focused apps (by path) and their children (by path), never removes from whitelist
# Blocks ALL non-whitelisted connections. No manual whitelisting; auto based on focus.
# Firewall rules by program path (no ID) for persistence across restarts.
# Deploy via Task Scheduler as SYSTEM (highest privs, hidden).

# Fixed paths for reliability under SYSTEM
$LogPath = "C:\GFocus.log"
$WhitelistPath = "C:\GFocus_Whitelist.txt"
if (!(Test-Path $LogPath)) { New-Item -ItemType File -Path $LogPath -Force | Out-Null }
if (!(Test-Path $WhitelistPath)) { New-Item -ItemType File -Path $WhitelistPath -Force | Out-Null }

function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$Timestamp - $Message" | Out-File -FilePath $LogPath -Append
    Write-Host $Message -ForegroundColor Yellow
}

function Register-GFocusTask {
    $taskName = "GFocus"
    $taskPath = "\"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"C:\Windows\Setup\Scripts\Bin\GFocus.ps1`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Write-Log "INFO: Registered scheduled task '$taskName' to run as SYSTEM on startup."
}

# Run setup if task doesn't exist
$task = Get-ScheduledTask -TaskName "GFocus" -ErrorAction SilentlyContinue
if (!$task) {
    Register-GFocusTask
}

# Config
$ScanIntervalMs = 1000  # Check every 1 second

# Load or initialize whitelist (array of process paths)
if (Test-Path $WhitelistPath) {
    $DynamicFocusWhitelist = Get-Content $WhitelistPath | Where-Object { $_ -ne "" } | ForEach-Object { $_.Trim() }
} else {
    $DynamicFocusWhitelist = @()
}
$LastForegroundProcess = $null

# Win32 API for foreground window
Add-Type @"
    using System;
    using System.Runtime.InteropServices;
    public class Win32 {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    }
"@

function Get-ForegroundProcess {
    $procId = 0
    $hWnd = [Win32]::GetForegroundWindow()
    [Win32]::GetWindowThreadProcessId($hWnd, [ref]$procId) | Out-Null
    if ($procId -ne 0) {
        try {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            return $proc
        } catch {
            Write-Log "ERROR: Failed to get process for ID $procId"
            return $null
        }
    }
    return $null
}

function Get-ChildProcesses {
    param($ParentId)
    $ChildProcs = Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $ParentId }
    $ChildPaths = @()
    foreach ($Child in $ChildProcs) {
        $ChildPath = $Child.ExecutablePath
        if ($ChildPath -and $ChildPaths -notcontains $ChildPath) {
            $ChildPaths += $ChildPath
        }
    }
    return $ChildPaths
}

function Save-Whitelist {
    $DynamicFocusWhitelist | Sort-Object -Unique | Out-File -FilePath $WhitelistPath -Force
    Write-Log "DEBUG: Saved whitelist to $WhitelistPath ($($DynamicFocusWhitelist.Count) entries)"
}

function Add-FirewallAllowRule {
    param($Path)
    if (!$Path) { return }
    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $RuleNameOut = "GFocus_Allow_Out_$BaseName"
    $RuleNameIn = "GFocus_Allow_In_$BaseName"
    try {
        $ExistingOut = netsh advfirewall firewall show rule name="$RuleNameOut" 2>$null
        if (!$ExistingOut) {
            netsh advfirewall firewall add rule name="$RuleNameOut" dir=out program="$Path" action=allow enable=yes | Out-Null
            Write-Log "DEBUG: Added outbound allow rule for $BaseName (Path: $Path)"
        }
        $ExistingIn = netsh advfirewall firewall show rule name="$RuleNameIn" 2>$null
        if (!$ExistingIn) {
            netsh advfirewall firewall add rule name="$RuleNameIn" dir=in program="$Path" action=allow enable=yes | Out-Null
            Write-Log "DEBUG: Added inbound allow rule for $BaseName (Path: $Path)"
        }
    } catch {
        Write-Log "ERROR: Failed to add firewall rules for $BaseName: $($_.Exception.Message)"
    }
}

function Terminate-NonWhitelistedConnections {
    param($Whitelist)
    $NetConns = Get-NetTCPConnection | Where-Object { 
        $_.State -eq "Established" -and 
        $_.RemoteAddress -notmatch "^(127\.|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)"
    } | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, OwningProcess

    foreach ($Conn in $NetConns) {
        $Proc = Get-Process -Id $Conn.OwningProcess -ErrorAction SilentlyContinue
        $ProcPath = $Proc.Path
        if ($ProcPath -and $Whitelist -notcontains $ProcPath) {
            $TempRuleName = "GFocus_TempBlock_$($Conn.OwningProcess)_$(Get-Random)"
            try {
                netsh advfirewall firewall add rule name="$TempRuleName" dir=out program="$ProcPath" action=block enable=yes | Out-Null
                Write-Log "INFO: Terminated connection to $($Conn.RemoteAddress):$($Conn.RemotePort) by $($Proc.Name) (Path: $ProcPath, Proc: $($Conn.OwningProcess))"
                Start-Sleep -Milliseconds 100
                netsh advfirewall firewall delete rule name="$TempRuleName" | Out-Null
            } catch {
                Write-Log "ERROR: Failed to terminate connection for $($Proc.Name): $($_.Exception.Message)"
            }
        }
    }
}

Write-Log "=== GFocus Started ==="
Write-Log "DEBUG: Loaded whitelist with $($DynamicFocusWhitelist.Count) entries"

# Add firewall allow rules for all existing whitelisted paths at startup
foreach ($Path in $DynamicFocusWhitelist) {
    Add-FirewallAllowRule -Path $Path
}

# Add block-all rules if not exist
try {
    if (!(netsh advfirewall firewall show rule name="GFocus_Block_All_Out" 2>$null)) {
        netsh advfirewall firewall add rule name="GFocus_Block_All_Out" dir=out action=block enable=yes | Out-Null
        Write-Log "DEBUG: Added block-all outbound rule"
    }
    if (!(netsh advfirewall firewall show rule name="GFocus_Block_All_In" 2>$null)) {
        netsh advfirewall firewall add rule name="GFocus_Block_All_In" dir=in action=block enable=yes | Out-Null
        Write-Log "DEBUG: Added block-all inbound rule"
    }
} catch {
    Write-Log "ERROR: Failed to add block-all rules: $($_.Exception.Message)"
}

# Main loop
while ($true) {
    $ActiveProcess = Get-ForegroundProcess
    if ($ActiveProcess) {
        $ProcId = $ActiveProcess.Id
        $ProcPath = $ActiveProcess.Path

        if ($ProcPath -and ($LastForegroundProcess -eq $null -or $LastForegroundProcess.Id -ne $ProcId -or $LastForegroundProcess.Path -ne $ProcPath)) {
            Write-Log "DEBUG: New active process: $($ActiveProcess.Name) (ID: $ProcId, Path: $ProcPath)"
            $LastForegroundProcess = $ActiveProcess

            if ($ProcPath -and $DynamicFocusWhitelist -notcontains $ProcPath) {
                $DynamicFocusWhitelist += $ProcPath
                Write-Log "INFO: Added parent to whitelist: $($ActiveProcess.Name) (Path: $ProcPath)"
                $LogEntry = "Foreground App: $($ActiveProcess.Name) (Path: $ProcPath, Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"
                $LogEntry | Out-File -FilePath $LogPath -Append
                Save-Whitelist
                Add-FirewallAllowRule -Path $ProcPath

                # Whitelist child processes (paths)
                $ChildProcesses = Get-ChildProcesses -ParentId $ProcId
                foreach ($ChildPath in $ChildProcesses) {
                    if ($ChildPath -and $DynamicFocusWhitelist -notcontains $ChildPath) {
                        $DynamicFocusWhitelist += $ChildPath
                        Write-Log "INFO: Added child to whitelist: $ChildPath (Parent: $($ActiveProcess.Name))"
                        Save-Whitelist
                        Add-FirewallAllowRule -Path $ChildPath
                    }
                }
            }
        }
    } else {
        Write-Log "DEBUG: No active process detected"
    }

    Terminate-NonWhitelistedConnections -Whitelist $DynamicFocusWhitelist

    $NetConns = Get-NetTCPConnection | Where-Object { 
        $_.State -eq "Established" -and 
        $_.RemoteAddress -notmatch "^(127\.|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)"
    } | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, OwningProcess

    if ($NetConns.Count -gt 0) {
        Write-Log "INFO: Checking $($NetConns.Count) connections:"
        foreach ($Conn in $NetConns) {
            $Proc = Get-Process -Id $Conn.OwningProcess -ErrorAction SilentlyContinue
            $ProcPath = $Proc.Path
            $ProcName = $Proc.Name
            if ($ProcPath -and $DynamicFocusWhitelist -contains $ProcPath) {
                Write-Log "  - ALLOWED: Connection to $($Conn.RemoteAddress):$($Conn.RemotePort) by $ProcName (Path: $ProcPath, Proc: $($Conn.OwningProcess))"
            } else {
                Write-Log "  - BLOCKED: Connection to $($Conn.RemoteAddress):$($Conn.RemotePort) by $ProcName (Path: $ProcPath, Proc: $($Conn.OwningProcess))"
            }
        }
    } else {
        Write-Log "INFO: No non-local network connections detected"
    }

    Start-Sleep -Milliseconds $ScanIntervalMs
}