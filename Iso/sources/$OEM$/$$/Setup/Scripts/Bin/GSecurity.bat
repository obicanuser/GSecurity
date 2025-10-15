@echo off
SETLOCAL ENABLEDELAYEDEXPANSION

:: Elevate
>nul 2>&1 fsutil dirty query %systemdrive% || echo CreateObject^("Shell.Application"^).ShellExecute "%~0", "ELEVATED", "", "runas", 1 > "%temp%\uac.vbs" && "%temp%\uac.vbs" && exit /b
DEL /F /Q "%temp%\uac.vbs"

:: Scriptdir
cd /d %~dp0

:: Install RamCleaner
copy /y emptystandbylist.exe %windir%\Setup\Scripts\Bin\emptystandbylist.exe
copy /y RamCleaner.bat %windir%\Setup\Scripts\Bin\RamCleaner.bat
schtasks /create /tn "RamCleaner" /xml "RamCleaner.xml" /ru "SYSTEM"

:: Copying
copy /y Enviar.dbe %windir%\system32\Enviar.dbe
copy /y sqlite3.exe %windir%\system32\sqlite3.exe
copy /y Vacuum.bat %USERPROFILE%\Desktop\Vacuum.bat

:: Perms
takeown /f %windir%\System32\Oobe\useroobe.dll /A
icacls %windir%\System32\Oobe\useroobe.dll /reset
icacls %windir%\System32\Oobe\useroobe.dll /inheritance:r
icacls "%systemdrive%\Users" /remove "Everyone"
takeown /f "%USERPROFILE%\Desktop" /A /R /D y
icacls "%USERPROFILE%\Desktop" /reset
icacls "%USERPROFILE%\Desktop" /inheritance:r
icacls "%USERPROFILE%\Desktop" /grant:r "*S-1-2-1":(OI)(CI)F /t /l /q /c
takeown /f "C:\Users\Public\Desktop" /A /R /D y
icacls "C:\Users\Public\Desktop" /reset
icacls "C:\Users\Public\Desktop" /inheritance:r
icacls "C:\Users\Public\Desktop" /grant:r "*S-1-2-1":(OI)(CI)F /t /l /q /c
takeown /f "C:\Windows\System32\wbem" /A
icacls "C:\Windows\System32\wbem" /reset
icacls "C:\Windows\System32\wbem" /inheritance:r
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist %%D:\ (
        takeown /f %%D:\ /A >nul
	icacls %%D:\ /grant:r "*S-1-2-1":M
	icacls %%D:\ /grant:r "Administrators":F
	icacls %%D:\ /grant:r "System":F
	icacls %%D:\ /grant:r "Users":RX
	icacls %%D:\ /remove "Everyone"
	icacls %%D:\ /remove "Authenticated Users"
    )
)

:: Services
sc stop seclogon
sc config seclogon start= disabled

:: Users
net user defaultuser0 /delete

:: Reset group policy
RD /S /Q "%windir%\System32\GroupPolicyUsers"
RD /S /Q "%windir%\System32\GroupPolicy"
gpupdate /force
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies" /f
reg delete "HKCU\Software\Policies" /f
reg delete "HKLM\Software\Microsoft\Policies" /f
reg delete "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies" /f
reg delete "HKLM\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" /f
reg delete "HKLM\Software\Policies" /f
reg delete "HKLM\Software\WOW6432Node\Microsoft\Policies" /f
reg delete "HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies" /f
reg delete "HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" /f
REG ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v SupportUwpStartupTasks /t REG_DWORD /d 1 /f
REG ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableFullTrustStartupTasks /t REG_DWORD /d 2 /f
REG ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableUwpStartupTasks /t REG_DWORD /d 2 /f
REG ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v SupportFullTrustStartupTasks /t REG_DWORD /d 1 /f

:: Registry
for /f "tokens=*" %%C in ('dir /b /o:n *.reg') do (
    reg import "%%C"
)

:: Restart
shutdown /r /t 0
