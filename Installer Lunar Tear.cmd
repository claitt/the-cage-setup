@echo off
rem ===================================================================
rem  Lunar Tear - installer for NieR Re[in]carnation
rem  Launches the guided installation GUI.
rem  Administrator rights (UAC) are needed to install MuMu Player:
rem  they are requested automatically here.
rem ===================================================================
setlocal
set "PS1=%~dp0Installer Lunar Tear.ps1"

if not exist "%PS1%" (
  echo ERROR: cannot find "Installer Lunar Tear.ps1" next to this file.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $env:PS1) -WindowStyle Hidden"
exit
