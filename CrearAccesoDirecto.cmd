@echo off
rem Crea en el escritorio un acceso directo a WakeOnLan.ps1
rem que lo abre sin ninguna ventana de consola.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CrearAccesoDirecto.ps1"
pause
