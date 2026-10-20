@echo off
rem ===================================================================
rem  Cage Setup - installer for NieR Re[in]carnation
rem  Launches the guided installation GUI.
rem  Administrator rights (UAC) are needed to install MuMu Player:
rem  they are requested automatically here.
rem ===================================================================
setlocal
set "PS1=%~dp0Cage Setup.ps1"

if not exist "%PS1%" (
  echo ERROR: cannot find "Cage Setup.ps1" next to this file.
  pause
  exit /b 1
)

rem The script path contains spaces: it must be quoted before being handed
rem to the elevated process, otherwise Start-Process splits it in two.
rem [char]34 builds the double quote without fighting cmd/PowerShell parsing.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$a = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + [char]34 + $env:PS1 + [char]34; Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $a -WindowStyle Hidden"

if errorlevel 1 (
  echo.
  echo The installer could not be started.
  echo If you cancelled the UAC prompt, run this file again and choose "Yes".
  echo.
  pause
  exit /b 1
)
exit /b 0
