<#
.SYNOPSIS
    Crea en el escritorio un acceso directo "Wake-on-LAN" que abre
    WakeOnLan.ps1 sin ninguna ventana de consola.

.DESCRIPTION
    El acceso directo ejecuta "conhost.exe --headless powershell.exe ...".
    Con conhost en modo headless no se crea ventana, ni siquiera en Windows 11
    con Windows Terminal como terminal predeterminado (donde -WindowStyle
    Hidden no oculta la ventana).
#>

$script = Join-Path $PSScriptRoot 'WakeOnLan.ps1'
if (-not (Test-Path $script)) {
    Write-Host "No se encuentra $script." -ForegroundColor Red
    exit 1
}

$shell = New-Object -ComObject WScript.Shell
foreach ($carpeta in @([Environment]::GetFolderPath('Desktop'))) {
    $ruta = Join-Path $carpeta 'Wake-on-LAN.lnk'
    $lnk = $shell.CreateShortcut($ruta)
    $lnk.TargetPath = "$env:windir\System32\conhost.exe"
    $lnk.Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation = "$env:windir\System32\mstsc.exe,0"
    $lnk.Description = 'Encender por Wake-on-LAN y conectar por Escritorio remoto'
    $lnk.Save()
    Write-Host "Creado: $ruta"
}
