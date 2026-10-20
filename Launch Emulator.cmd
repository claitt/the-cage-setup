@echo off
title NieR Re[in]carnation - MuMu Player
rem ------------------------------------------------------------------
rem  Starts the MuMu Player instance (Android 15).
rem  The game is already installed inside the emulator; open it from the
rem  home screen, or use "Launch game" in the installer GUI.
rem  The Lunar Tear server must be running (see "Start Server.cmd").
rem ------------------------------------------------------------------
set MGR="C:\Program Files\Netease\MuMuPlayer\nx_main\MuMuManager.exe"

echo Starting the MuMu Player instance (Android 15)...
%MGR% control -v 0 launch
if errorlevel 1 (
  echo.
  echo ERROR: MuMu Player not found or cannot be started.
  echo Check that it is installed in "C:\Program Files\Netease\MuMuPlayer".
)

echo.
echo Remember: the Lunar Tear server must be running ("Start Server.cmd").
echo.
pause
