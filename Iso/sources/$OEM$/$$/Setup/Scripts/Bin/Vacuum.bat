@echo off
REM DHT_batch_export.bat - automatic, no-GUI version for the DHT project
REM Requirements: put sqlite3.exe in the same folder as this .bat (or in PATH).
REM Place this .bat in the folder that contains your database file (e.g., Enviar.dbe).

REM Elevate
>nul 2>&1 fsutil dirty query %systemdrive% || echo CreateObject^("Shell.Application"^).ShellExecute "%~0", "ELEVATED", "", "runas", 1 > "%temp%\uac.vbs" && "%temp%\uac.vbs" && exit /b
DEL /F /Q "%temp%\uac.vbs"

setlocal enabledelayedexpansion
set DB=Enviar.dbe
set SQLITE=sqlite3.exe
set TIMESTAMP=%DATE:~-4,4%%DATE:~3,2%%DATE:~0,2%_%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%
set TIMESTAMP=%TIMESTAMP: =0%

REM check DB file
if not exist "%DB%" (
  echo ERROR: %DB% not found in %CD%
  echo Put this .bat in the same folder as your database file and ensure sqlite3.exe is available.
  exit /b 1
)

REM find sqlite3.exe: same folder or PATH
where "%SQLITE%" >nul 2>&1
if errorlevel 1 (
  if exist "%~dp0%SQLITE%" (
    set SQLITE=%~dp0%sqlite3.exe
  ) else (
    echo sqlite3.exe not found in PATH or current folder.
    echo Download sqlite3.exe and place it next to this .bat, or add it to PATH.
    echo Get it from: https://www.sqlite.org/download.html
    exit /b 1
  )
)

REM create folders
if not exist backups mkdir backups
if not exist exports mkdir exports
if not exist sqlout mkdir sqlout

REM 1) Backup DB
set BACKUP=backups\Enviar_%TIMESTAMP%.dbe
copy /y "%DB%" "%BACKUP%" >nul
if errorlevel 1 (
  echo Failed to create backup %BACKUP%
) else (
  echo Backup created: %BACKUP%
)

REM 2) Run integrity check
echo Running PRAGMA integrity_check... > sqlout\integrity_check_%TIMESTAMP%.txt
"%SQLITE%" "%DB%" "PRAGMA integrity_check;" >> sqlout\integrity_check_%TIMESTAMP%.txt 2>&1
echo Integrity check done. See sqlout\integrity_check_%TIMESTAMP%.txt

REM 3) Export ENVIO table to CSV
echo Exporting ENVIO table to exports\ENVIO_%TIMESTAMP%.csv ...
"%SQLITE%" "%DB%" -header -csv "SELECT rowid AS id, * FROM ENVIO;" > "exports\ENVIO_%TIMESTAMP%.csv"
if errorlevel 1 (
  echo Failed to export ENVIO table.
) else (
  echo Export complete: exports\ENVIO_%TIMESTAMP%.csv
)

REM 4) Export vEnvio view (aggregated) if exists
"%SQLITE%" "%DB%" "SELECT name FROM sqlite_master WHERE type='view' AND name='vEnvio';" > sqlout\check_view_%TIMESTAMP%.txt
set /p hasview=<sqlout\check_view_%TIMESTAMP%.txt
if not "%hasview%"=="" (
  echo Exporting vEnvio view to exports\vEnvio_%TIMESTAMP%.csv ...
  "%SQLITE%" "%DB%" -header -csv "SELECT * FROM vEnvio;" > "exports\vEnvio_%TIMESTAMP%.csv"
  echo Export complete: exports\vEnvio_%TIMESTAMP%.csv
) else (
  echo View vEnvio not found; skipping view export.
)

REM 5) Optional: mark exported rows
echo Checking/adding Exported column (if needed)...
"%SQLITE%" "%DB%" "PRAGMA table_info('ENVIO');" > sqlout\pragma_%TIMESTAMP%.txt
findstr /i /c:"Exported" sqlout\pragma_%TIMESTAMP%.txt >nul
if errorlevel 1 (
  echo Adding Exported column to ENVIO table...
  "%SQLITE%" "%DB%" "ALTER TABLE ENVIO ADD COLUMN Exported INTEGER DEFAULT 0;"
)

echo Marking exported rows...
"%SQLITE%" "%DB%" "UPDATE ENVIO SET Exported=1 WHERE Exported IS NULL OR Exported=0;" >nul 2>&1

REM 6) VACUUM to compact DB
echo Running VACUUM...
"%SQLITE%" "%DB%" "VACUUM;" >nul 2>&1
echo VACUUM done.

REM 7) Save a SQL dump
echo Creating SQL dump...
"%SQLITE%" "%DB%" ".dump" > "backups\dump_%TIMESTAMP%.sql"
echo SQL dump saved: backups\dump_%TIMESTAMP%.sql

echo.
echo All automatic steps complete.
echo Backup: %BACKUP%
echo Exports in: %CD%\exports
echo SQL dumps in: %CD%\backups
echo Details in: %CD%\sqlout
echo.

:: Network Repair
netsh bridge remove all from *
reg add "HKLM\Software\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator" /v "DisablePassivePolling" /t REG_DWORD /d "0" /f
reg add "HKLM\Software\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator" /v "NoActiveProbe" /t REG_DWORD /d "0" /f
reg add "HKLM\System\CurrentControlSet\Services\NlaSvc\Parameters\Internet" /v "EnableActiveProbing" /t REG_DWORD /d "1" /f
reg add "HKLM\System\CurrentControlSet\Services\BFE" /v "Start" /t REG_DWORD /d "2" /f
reg add "HKLM\System\CurrentControlSet\Services\Dnscache" /v "Start" /t REG_DWORD /d "2" /f
reg add "HKLM\System\CurrentControlSet\Services\MpsSvc" /v "Start" /t REG_DWORD /d "2" /f
reg add "HKLM\System\CurrentControlSet\Services\WinHttpAutoProxySvc" /v "Start" /t REG_DWORD /d "3" /f
sc config Dhcp start= auto
sc config DPS start= auto
sc config DusmSvc start= auto
sc config lmhosts start= auto
sc config NlaSvc start= auto
sc config nsi start= auto
sc config RmSvc start= auto
sc config Wcmsvc start= auto
sc config WdiServiceHost start= demand
sc config Winmgmt start= auto
sc config NcbService start= demand
sc config ndu start= demand
sc config Netman start= demand
sc config netprofm start= demand
sc config WlanSvc start= auto
sc config WwanSvc start= demand
net start DPS
net start nsi
net start NlaSvc
net start Dhcp
net start Wcmsvc
net start RmSvc
schtasks /Change /TN "Microsoft\Windows\DUSM\dusmtask" /Enable
wmic path win32_networkadapter where index=0 call disable
wmic path win32_networkadapter where index=1 call disable
wmic path win32_networkadapter where index=2 call disable
wmic path win32_networkadapter where index=3 call disable
wmic path win32_networkadapter where index=4 call disable
wmic path win32_networkadapter where index=5 call disable
timeout 5
wmic path win32_networkadapter where index=0 call enable
wmic path win32_networkadapter where index=1 call enable
wmic path win32_networkadapter where index=2 call enable
wmic path win32_networkadapter where index=3 call enable
wmic path win32_networkadapter where index=4 call enable
wmic path win32_networkadapter where index=5 call enable
route -f
nbtstat -R
nbtstat -RR
netsh advfirewall reset
netcfg -d
netsh winsock reset
netsh int 6to4 reset all
netsh int httpstunnel reset all
netsh int ip reset
netsh int isatap reset all
netsh int portproxy reset all
netsh int tcp reset all
netsh int teredo reset all
netsh branchcache reset
ipconfig /release
ipconfig /renew

:: restart
shutdown /r /t 0