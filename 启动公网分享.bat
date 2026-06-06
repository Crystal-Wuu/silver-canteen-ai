@echo off
cd /d "%~dp0"
powershell.exe -NoLogo -NoExit -ExecutionPolicy Bypass -File "%~dp0public_share.ps1"
