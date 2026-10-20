@echo off
title NieR Re[in]carnation - restart game (audio fix)
rem ------------------------------------------------------------------
rem  Force-stops and relaunches the game. Useful when the audio stops
rem  working after the emulator has been running for a long time.
rem ------------------------------------------------------------------
set ADB="C:\Program Files\Netease\MuMuPlayer\nx_device\15.0\shell\adb.exe"
set PKG=com.square_enix.android_googleplay.nierspww

if not exist %ADB% (
  echo ERROR: adb not found at %ADB%
  pause
  exit /b 1
)

%ADB% connect 127.0.0.1:7555 >nul 2>&1
echo Closing the game...
%ADB% -s 127.0.0.1:7555 shell am force-stop %PKG%
timeout /t 3 /nobreak >nul
echo Relaunching the game (audio should come back)...
%ADB% -s 127.0.0.1:7555 shell monkey -p %PKG% -c android.intent.category.LAUNCHER 1 >nul 2>&1
echo Done. Wait a few seconds on the device.
timeout /t 4 /nobreak >nul
