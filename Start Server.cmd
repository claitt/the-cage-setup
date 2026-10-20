@echo off
rem ===================================================================
rem  Lunar Tear - NieR Re[in]carnation private server
rem  Starts the game server (gRPC 8003, CDN 8080, auth 3000).
rem  Close this window or press CTRL+C to stop the server.
rem ===================================================================
title Lunar Tear - NieR Re[in]carnation Private Server
cd /d "%~dp0server"
echo Starting the Lunar Tear server (gRPC 8003, CDN 8080, Auth 3000)...
echo Close this window or press CTRL+C to stop the server.
echo.
wizard.exe --prefer-saved
echo.
echo The server has been stopped.
pause
