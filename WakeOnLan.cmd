@echo off
rem Lanza WakeOnLan.ps1 sin ninguna ventana de consola.
rem conhost --headless evita que Windows 11 la abra en Windows Terminal,
rem donde -WindowStyle Hidden no oculta la ventana.
start "" "%windir%\System32\conhost.exe" --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0WakeOnLan.ps1"
