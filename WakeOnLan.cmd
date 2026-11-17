@echo off
rem Lanza WakeOnLan.ps1 sin dejar abierta la consola de PowerShell.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0WakeOnLan.ps1"
