function Detect-RootkitByNetstat {
    # Run netstat -ano and store the output
    $netstatOutput = netstat -ano | Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+:\d+' }

    if (-not $netstatOutput) {
        Write-Warning "No network connections found via netstat -ano. Possible rootkit hiding activity."

        # Optionally: Log the suspicious event
        $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $logFile = "$env:TEMP\rootkit_suspected_$timestamp.log"
        "Netstat -ano returned no results. Possible rootkit activity." | Out-File -FilePath $logFile

        # Get all running processes (you could refine this)
        $processes = Get-Process | Where-Object { $_.Id -ne $PID }

        foreach ($proc in $processes) {
            try {
                # Comment this line if you want to observe first
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                Write-Output "Stopped process: $($proc.ProcessName) (PID: $($proc.Id))"
            } catch {
                Write-Warning "Could not stop process: $($proc.ProcessName) (PID: $($proc.Id))"
            }
        }
    } else {
        Write-Host "Netstat looks normal. Active connections detected."
    }
}