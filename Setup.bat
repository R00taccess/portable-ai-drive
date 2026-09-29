@echo off
setlocal
rem Portable AI Drive - Windows setup launcher
rem https://github.com/R00taccess/portable-ai-drive
cd /d "%~dp0"
title Portable AI Drive - Setup
if exist "installer\setup.ps1" goto run
echo Downloading the installer from GitHub...
if not exist installer mkdir installer
curl -fsSL -o "installer\setup.ps1" "https://raw.githubusercontent.com/R00taccess/portable-ai-drive/main/installer/setup.ps1" || goto dlfail
curl -fsSL -o "installer\catalog.json" "https://raw.githubusercontent.com/R00taccess/portable-ai-drive/main/installer/catalog.json" || goto dlfail
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "installer\setup.ps1" %*
set "RC=%ERRORLEVEL%"
if not defined PAD_NOPAUSE pause
exit /b %RC%
:dlfail
echo.
echo Could not download the installer. Check the internet connection, or download
echo the whole project from https://github.com/R00taccess/portable-ai-drive
pause
exit /b 1
