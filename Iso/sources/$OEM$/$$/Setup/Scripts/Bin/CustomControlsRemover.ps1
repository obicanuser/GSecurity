param (
    [int]$CheckIntervalSeconds = 60  # Interval to check for custom controls in seconds
)

# Import required module
Import-Module -Name Microsoft.PowerShell.Management

function Register-SystemLogonScript {
    param ([string]$TaskName = "RunCCRAtLogon")

    $scriptSource = $MyInvocation.MyCommand.Path
    if (-not $scriptSource) { $scriptSource = $PSCommandPath }
    if (-not $scriptSource) {
        Write-Log "Error: Could not determine script path."
        return
    }

    $targetFolder = "C:\Windows\Setup\Scripts\Bin"
    $targetPath = Join-Path $targetFolder (Split-Path $scriptSource -Leaf)

    if (-not (Test-Path $targetFolder)) {
        New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null
        Write-Log "Created folder: $targetFolder"
    }

    try {
        Copy-Item -Path $scriptSource -Destination $targetPath -Force -ErrorAction Stop
        Write-Log "Copied script to: $targetPath"
    } catch {
        Write-Log "Failed to copy script: $_"
        return
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$targetPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal
        Write-Log "Scheduled task '$TaskName' created to run at user logon under SYSTEM."
    } catch {
        Write-Log "Failed to register task: $_"
    }
}

# Run the function
Register-SystemLogonScript
Write-Log "Script setup complete. Starting WMI monitoring..."

# Define base registry path for WOW6432Node CLSIDs
$basePath = "HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID"
$hkcrBasePath = "HKCR:\WOW6432Node\CLSID"

# Function to detect InProcServer32 and InprocHandler32 custom controls
function Detect-InProcControls {
    $allPaths = @()
    $allPaths += Get-ChildItem -Path $basePath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}}" }
    $allPaths += Get-ChildItem -Path $hkcrBasePath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}}" }

    foreach ($path in $allPaths) {
        $inProcPath = Join-Path $path.PSPath "InProcServer32"
        $inProcHandlerPath = Join-Path $path.PSPath "InprocHandler32"
        $value = $null

        if (Test-Path $inProcPath) {
            $value = (Get-ItemProperty -Path $inProcPath -ErrorAction SilentlyContinue)."(default)"
        } elseif (Test-Path $inProcHandlerPath) {
            $value = (Get-ItemProperty -Path $inProcHandlerPath -ErrorAction SilentlyContinue)."(default)"
        }

        if ($value -and (Test-Path $value)) {
            Write-Host "Detected InProc control at $path.PSPath with value $value"
            return $true, $path.PSPath, $value
        }
    }
    return $false, $null, $null
}

# Function to remove InProc controls
function Remove-InProcControls {
    param ([string]$path, [string]$value)
    if ($path -and $value) {
        try {
            # Remove registry entry
            $parentPath = Split-Path $path -Parent
            $keyName = Split-Path $path -Leaf
            Remove-ItemProperty -Path $parentPath -Name $keyName -Force -ErrorAction Stop
            Write-Host "Removed InProc control registry entry at $path"
            # Remove associated file if it exists
            if (Test-Path $value) {
                Remove-Item -Path $value -Force -ErrorAction Stop
                Write-Host "Removed file: $value"
            }
        } catch {
            Write-Host "Error removing $path : $_"
        }
    }
}

# Main loop to run resident in memory
Start-Job -ScriptBlock {
while ($true) {
    $detected, $path, $value = Detect-InProcControls
    if ($detected) {
        Remove-InProcControls -path $path -value $value
    } else {
        Write-Host "No InProc controls detected. Checking again in $CheckIntervalSeconds seconds..."
    }
    Start-Sleep -Seconds $CheckIntervalSeconds
}
}