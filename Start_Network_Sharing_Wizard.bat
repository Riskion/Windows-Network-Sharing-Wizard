@echo off
setlocal

title Windows 11 Network Sharing Wizard

set "SCRIPT=%~dp0Network_Sharing_Wizard.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: Network_Sharing_Wizard.ps1 was not found.
    echo Keep this batch file in the same folder as the PowerShell script.
    echo.
    pause
    exit /b 1
)

rem Check whether this batch file is already running as Administrator.
powershell.exe -NoProfile -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>&1

if errorlevel 1 (
    echo Requesting Administrator permission...
    powershell.exe -NoProfile -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%SCRIPT%""'"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

if errorlevel 1 (
    echo.
    echo The wizard closed with an error. Check the messages above.
    pause
)

endlocal
