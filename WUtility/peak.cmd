@echo off
rem  WUtility launcher - double-click to run, works from any folder or USB drive.
rem  Each command runs independently, so "%~dp0" (this file's folder) is used every time.

rem  Lift the "downloaded from the internet" block so it runs on any PC
powershell.exe -NoProfile -Command "Unblock-File -LiteralPath '%~dp0peak.ps1' -ErrorAction SilentlyContinue" >nul 2>&1

rem  Run it (arguments pass straight through:  peak.cmd -List, peak.cmd -Install git, ...)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0peak.ps1" %*

rem  Keep the window open if something went wrong
if errorlevel 1 (
  echo.
  echo WUtility closed with an error. Press any key to close this window...
  pause >nul
)
