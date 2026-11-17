#Requires -Version 5.1
<#
.SYNOPSIS
    Enciende otro PC por Wake-on-LAN y abre Escritorio remoto contra él.

.DESCRIPTION
    Ventana con dos botones:
      - Encender (WOL): envía el paquete mágico a la MAC configurada.
      - Conectar (RDP): si el equipo responde en el puerto RDP lanza mstsc.
        Si no responde, envía WOL, espera a que arranque y entonces lanza mstsc.

    La configuración (equipo, MAC, broadcast, espera máxima) se guarda en
    config.json, junto al script.

    Al arrancar comprueba si en GitHub hay una etiqueta vX.Y.Z mayor que
    $Version y, si la hay, ofrece descargarla e instalarla.
#>

# Versión del script. Al publicar una nueva, súbela aquí y crea la etiqueta
# git "v<versión>" (ver README).
$Version = '1.1.0'
$RepoGitHub = 'amiguelp/WakeOnLan'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ScriptPath = $PSCommandPath
$ConfigPath = Join-Path $PSScriptRoot 'config.json'

# Cada cuánto se comprueba si el equipo está encendido, en segundos.
$IntervaloComprobacion = 5
$IntervaloComprobacionEsperando = 3
# Tiempo máximo para que responda el puerto RDP, en milisegundos.
$TimeoutConexionMs = 2000
# Cada cuánto se repite el paquete WOL mientras se espera el arranque, en segundos.
$IntervaloReenvioWol = 30

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

function Read-Config {
    $cfg = [ordered]@{
        Equipo    = ''
        Mac       = ''
        Broadcast = ''      # vacío = automático (todas las redes locales)
        PuertoWol = 9
        PuertoRdp = 3389
        EsperaMax = 180     # segundos
    }
    if (Test-Path $ConfigPath) {
        try {
            $leido = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $leido.PSObject.Properties) {
                if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "No se ha podido leer config.json:`n$($_.Exception.Message)",
                'Wake-on-LAN', 'OK', 'Warning') | Out-Null
        }
    }
    return $cfg
}

function Save-Config($cfg) {
    try {
        $cfg | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch {
        Write-Log "No se ha podido guardar config.json: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Wake-on-LAN
# ---------------------------------------------------------------------------

function Test-Mac([string]$Mac) {
    return $Mac -match '^\s*([0-9A-Fa-f]{2}[-:. ]?){5}[0-9A-Fa-f]{2}\s*$'
}

function ConvertTo-MacBytes([string]$Mac) {
    $hex = $Mac -replace '[^0-9A-Fa-f]', ''
    $bytes = New-Object byte[] 6
    for ($i = 0; $i -lt 6; $i++) {
        $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
    }
    return , $bytes
}

# Direcciones de broadcast de todas las redes IPv4 activas, más 255.255.255.255.
# En equipos con varias tarjetas, 255.255.255.255 solo sale por una de ellas,
# así que se envía también al broadcast de cada subred.
function Get-BroadcastAddresses {
    $lista = New-Object System.Collections.Generic.List[string]
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($ua in $nic.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne 'InterNetwork' -or -not $ua.IPv4Mask) { continue }
            $ip = $ua.Address.GetAddressBytes()
            $mascara = $ua.IPv4Mask.GetAddressBytes()
            $bc = New-Object byte[] 4
            for ($i = 0; $i -lt 4; $i++) {
                $bc[$i] = [byte]($ip[$i] -bor ((-bnot $mascara[$i]) -band 0xFF))
            }
            $lista.Add((New-Object System.Net.IPAddress (, $bc)).ToString())
        }
    }
    $lista.Add('255.255.255.255')
    return $lista | Select-Object -Unique
}

# IPv4 del equipo remoto, o $null si no se puede resolver (con el PC apagado
# es normal que su nombre no resuelva; por eso es mejor usar la IP).
function Resolve-IPv4([string]$Equipo) {
    if ([string]::IsNullOrWhiteSpace($Equipo)) { return $null }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($Equipo.Trim(), [ref]$ip)) {
        if ($ip.AddressFamily -eq 'InterNetwork') { return $ip }
        return $null
    }
    try {
        return [System.Net.Dns]::GetHostAddresses($Equipo.Trim()) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            Select-Object -First 1
    } catch {
        return $null
    }
}

# Destinos del paquete mágico.
#  - Broadcast indicado a mano: solo ese.
#  - Automático: broadcast de cada red local y 255.255.255.255, y además la IP
#    del equipo y el broadcast de su red (suponiendo /24). Estos dos últimos
#    sirven cuando el equipo está en otra red, por ejemplo detrás de otro
#    router: el broadcast local no llega allí, pero un paquete dirigido sí puede
#    llegar si el router lo deja pasar o aún recuerda la MAC de esa IP.
function Get-WolDestinations([string]$Equipo, [string]$Broadcast) {
    if (-not [string]::IsNullOrWhiteSpace($Broadcast)) { return @($Broadcast.Trim()) }

    $destinos = New-Object System.Collections.Generic.List[string]
    foreach ($d in Get-BroadcastAddresses) { $destinos.Add($d) }

    $ip = Resolve-IPv4 $Equipo
    if ($ip) {
        $b = $ip.GetAddressBytes()
        $b[3] = 255
        $destinos.Add((New-Object System.Net.IPAddress (, $b)).ToString())
        $destinos.Add($ip.ToString())
    }
    return $destinos | Select-Object -Unique
}

function Send-WakeOnLan([string]$Mac, [string[]]$Destinos, [int]$Puerto) {
    # Ojo: no llamar a esta variable $mac, que es el mismo nombre que el parámetro
    # [string]$Mac y convertiría los bytes en texto.
    $macBytes = ConvertTo-MacBytes $Mac
    # Paquete mágico: 6 bytes 0xFF seguidos de la MAC repetida 16 veces.
    $paquete = New-Object byte[] 102
    for ($i = 0; $i -lt 6; $i++) { $paquete[$i] = 0xFF }
    for ($r = 0; $r -lt 16; $r++) { [Array]::Copy($macBytes, 0, $paquete, 6 + $r * 6, 6) }

    $destinos = @($Destinos)
    $fallos = New-Object System.Collections.Generic.List[string]

    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.EnableBroadcast = $true
        foreach ($d in $destinos) {
            # Un destino que falle (por ejemplo sin ruta) no impide enviar a los demás.
            try {
                $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($d)), $Puerto
                [void]$udp.Send($paquete, $paquete.Length, $ep)
            } catch {
                $fallos.Add("$d ($($_.Exception.GetBaseException().Message))")
            }
        }
    } finally {
        $udp.Close()
    }
    if ($fallos.Count -eq @($destinos).Count) { throw "No se ha podido enviar a ningún destino: $($fallos -join '; ')" }
    return $fallos
}

# ---------------------------------------------------------------------------
# Comprobación de estado (asíncrona, para no bloquear la ventana)
# ---------------------------------------------------------------------------

function Start-Probe([string]$Equipo, [int]$Puerto) {
    $sonda = [pscustomobject]@{
        Equipo  = $Equipo
        Cliente = New-Object System.Net.Sockets.TcpClient
        Tarea   = $null
        Inicio  = [DateTime]::Now
        Error   = $false
    }
    try {
        $sonda.Tarea = $sonda.Cliente.ConnectAsync($Equipo, $Puerto)
    } catch {
        $sonda.Error = $true
    }
    return $sonda
}

# ---------------------------------------------------------------------------
# Actualizaciones desde GitHub
# ---------------------------------------------------------------------------

function New-GitHubClient {
    # Windows PowerShell 5.1 no activa TLS 1.2 por defecto y GitHub lo exige.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers['User-Agent'] = 'WakeOnLan-ps1'
    $wc.Headers['Accept'] = 'application/vnd.github+json'
    return $wc
}

# Devuelve la etiqueta vX.Y.Z más alta de la respuesta de /tags, o $null.
function Get-LatestTag([string]$Json) {
    $mejor = $null
    foreach ($t in (ConvertFrom-Json $Json)) {
        if ($t.name -match '^v?(\d+\.\d+\.\d+)$') {
            $v = [version]$Matches[1]
            if (-not $mejor -or $v -gt $mejor.Version) {
                $mejor = [pscustomobject]@{ Tag = $t.name; Version = $v }
            }
        }
    }
    return $mejor
}

# Descarga el código de la etiqueta y sobrescribe los ficheros del script
# (config.json no está en el repositorio, así que se conserva).
function Install-Update([string]$Tag, [string]$Destino) {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('WakeOnLan-' + [guid]::NewGuid().ToString('N'))
    $zip = "$temp.zip"
    try {
        $wc = New-GitHubClient
        try {
            $wc.DownloadFile("https://api.github.com/repos/$RepoGitHub/zipball/$Tag", $zip)
        } finally {
            $wc.Dispose()
        }
        Expand-Archive -Path $zip -DestinationPath $temp -Force
        # El zip de GitHub contiene una única carpeta "<usuario>-<repo>-<commit>".
        $origen = Get-ChildItem $temp -Directory | Select-Object -First 1
        $nuevo = Join-Path $origen.FullName 'WakeOnLan.ps1'
        if (-not (Test-Path $nuevo)) { throw 'El paquete descargado no contiene WakeOnLan.ps1.' }
        $errores = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($nuevo, [ref]$null, [ref]$errores)
        if ($errores.Count) { throw "WakeOnLan.ps1 de $Tag tiene errores: $($errores[0].Message)" }
        Get-ChildItem $origen.FullName -Force |
            Where-Object { $_.Name -ne 'config.json' } |
            Copy-Item -Destination $Destino -Recurse -Force
    } finally {
        Remove-Item $zip, $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Interfaz
# ---------------------------------------------------------------------------

$State = @{
    Sonda          = $null
    UltimaSonda    = [DateTime]::MinValue
    Encendido      = $null      # $true, $false o $null (desconocido)
    Esperando      = $false
    InicioEspera   = [DateTime]::MinValue
    UltimoWol      = [DateTime]::MinValue
    Comprobacion   = $null      # consulta de actualizaciones en curso
}

$Config = Read-Config

$form = New-Object System.Windows.Forms.Form
$form.Text = "Wake-on-LAN + Escritorio remoto $Version"
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(460, 440)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
try {
    $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:windir\System32\mstsc.exe")
} catch { }

function Add-Label([string]$Texto, [int]$Y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Texto
    $l.Location = New-Object System.Drawing.Point(15, ($Y + 3))
    $l.Size = New-Object System.Drawing.Size(135, 20)
    $form.Controls.Add($l)
}

function Add-TextBox([string]$Valor, [int]$Y, [int]$Ancho = 200) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = $Valor
    $t.Location = New-Object System.Drawing.Point(150, $Y)
    $t.Size = New-Object System.Drawing.Size($Ancho, 23)
    $form.Controls.Add($t)
    return $t
}

Add-Label 'Equipo (nombre o IP):' 15
$txtEquipo = Add-TextBox $Config.Equipo 15 295

Add-Label 'Dirección MAC:' 47
$txtMac = Add-TextBox $Config.Mac 47 200
$btnDetectar = New-Object System.Windows.Forms.Button
$btnDetectar.Text = 'Detectar'
$btnDetectar.Location = New-Object System.Drawing.Point(358, 46)
$btnDetectar.Size = New-Object System.Drawing.Size(87, 25)
$form.Controls.Add($btnDetectar)

Add-Label 'Broadcast:' 79
$txtBroadcast = Add-TextBox $Config.Broadcast 79 200
$lblBcAyuda = New-Object System.Windows.Forms.Label
$lblBcAyuda.Text = 'vacío = automático'
$lblBcAyuda.ForeColor = [System.Drawing.Color]::Gray
$lblBcAyuda.Location = New-Object System.Drawing.Point(355, 82)
$lblBcAyuda.Size = New-Object System.Drawing.Size(100, 20)
$form.Controls.Add($lblBcAyuda)

Add-Label 'Espera máxima (s):' 111
$numEspera = New-Object System.Windows.Forms.NumericUpDown
$numEspera.Minimum = 30
$numEspera.Maximum = 900
$numEspera.Increment = 30
$numEspera.Value = [Math]::Min(900, [Math]::Max(30, [int]$Config.EsperaMax))
$numEspera.Location = New-Object System.Drawing.Point(150, 111)
$numEspera.Size = New-Object System.Drawing.Size(80, 23)
$form.Controls.Add($numEspera)

# Indicador de estado
$pnlLed = New-Object System.Windows.Forms.Panel
$pnlLed.Location = New-Object System.Drawing.Point(17, 152)
$pnlLed.Size = New-Object System.Drawing.Size(14, 14)
$pnlLed.BackColor = [System.Drawing.Color]::Gray
$form.Controls.Add($pnlLed)

$lblEstado = New-Object System.Windows.Forms.Label
$lblEstado.Location = New-Object System.Drawing.Point(38, 149)
$lblEstado.Size = New-Object System.Drawing.Size(410, 20)
$lblEstado.Text = 'Comprobando…'
$form.Controls.Add($lblEstado)

# Botones principales
$fuenteBoton = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

$btnWol = New-Object System.Windows.Forms.Button
$btnWol.Text = 'Encender (WOL)'
$btnWol.Font = $fuenteBoton
$btnWol.Location = New-Object System.Drawing.Point(15, 180)
$btnWol.Size = New-Object System.Drawing.Size(212, 45)
$form.Controls.Add($btnWol)

$btnRdp = New-Object System.Windows.Forms.Button
$btnRdp.Text = 'Conectar (RDP)'
$btnRdp.Font = $fuenteBoton
$btnRdp.Location = New-Object System.Drawing.Point(233, 180)
$btnRdp.Size = New-Object System.Drawing.Size(212, 45)
$form.Controls.Add($btnRdp)

$lblEspera = New-Object System.Windows.Forms.Label
$lblEspera.Location = New-Object System.Drawing.Point(15, 232)
$lblEspera.Size = New-Object System.Drawing.Size(430, 20)
$lblEspera.ForeColor = [System.Drawing.Color]::DarkOrange
$form.Controls.Add($lblEspera)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.BackColor = [System.Drawing.SystemColors]::Window
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Location = New-Object System.Drawing.Point(15, 257)
$txtLog.Size = New-Object System.Drawing.Size(430, 148)
$form.Controls.Add($txtLog)

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = "Versión $Version"
$lblVersion.ForeColor = [System.Drawing.Color]::Gray
$lblVersion.Location = New-Object System.Drawing.Point(15, 414)
$lblVersion.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($lblVersion)

$lnkActualizar = New-Object System.Windows.Forms.LinkLabel
$lnkActualizar.Text = 'Buscar actualizaciones'
$lnkActualizar.TextAlign = 'TopRight'
$lnkActualizar.Location = New-Object System.Drawing.Point(215, 414)
$lnkActualizar.Size = New-Object System.Drawing.Size(230, 20)
$form.Controls.Add($lnkActualizar)

$form.AcceptButton = $btnRdp

# ---------------------------------------------------------------------------
# Lógica de la interfaz
# ---------------------------------------------------------------------------

function Write-Log([string]$Mensaje) {
    $txtLog.AppendText(('[{0:HH:mm:ss}] {1}' -f [DateTime]::Now, $Mensaje) + "`r`n")
}

function Show-Aviso([string]$Mensaje) {
    [System.Windows.Forms.MessageBox]::Show($form, $Mensaje, 'Wake-on-LAN', 'OK', 'Warning') | Out-Null
}

function Get-FormConfig {
    $Config.Equipo = $txtEquipo.Text.Trim()
    $Config.Mac = $txtMac.Text.Trim()
    $Config.Broadcast = $txtBroadcast.Text.Trim()
    $Config.EsperaMax = [int]$numEspera.Value
    return $Config
}

function Set-Estado($Encendido) {
    $anterior = $State.Encendido
    $State.Encendido = $Encendido
    if ($null -eq $Encendido) {
        $pnlLed.BackColor = [System.Drawing.Color]::Gray
        $lblEstado.Text = 'Comprobando…'
    } elseif ($Encendido) {
        $pnlLed.BackColor = [System.Drawing.Color]::LimeGreen
        $lblEstado.Text = 'Encendido: Escritorio remoto disponible'
    } else {
        $pnlLed.BackColor = [System.Drawing.Color]::Firebrick
        $lblEstado.Text = 'Apagado o sin respuesta en el puerto RDP'
    }
    if ($null -ne $anterior -and $null -ne $Encendido -and $anterior -ne $Encendido) {
        if ($Encendido) { Write-Log 'El equipo responde.' } else { Write-Log 'El equipo ha dejado de responder.' }
    }
}

function Invoke-Wol($cfg) {
    if (-not (Test-Mac $cfg.Mac)) {
        Show-Aviso 'Indica una dirección MAC válida (por ejemplo 00-11-22-33-44-55).'
        return $false
    }
    if ($cfg.Broadcast -and -not [System.Net.IPAddress]::TryParse($cfg.Broadcast, [ref]$null)) {
        Show-Aviso "La dirección de broadcast '$($cfg.Broadcast)' no es una IP válida."
        return $false
    }
    try {
        $destinos = @(Get-WolDestinations $cfg.Equipo $cfg.Broadcast)
        $fallos = Send-WakeOnLan $cfg.Mac $destinos ([int]$cfg.PuertoWol)
        $State.UltimoWol = [DateTime]::Now
        Write-Log "WOL enviado a $($cfg.Mac) ($($destinos -join ', '))."
        foreach ($f in $fallos) { Write-Log "  No se ha podido enviar a $f." }
        return $true
    } catch {
        Write-Log "Error al enviar WOL: $($_.Exception.Message)"
        return $false
    }
}

function Start-Rdp($cfg) {
    $destino = $cfg.Equipo
    if ([int]$cfg.PuertoRdp -ne 3389) { $destino = '{0}:{1}' -f $cfg.Equipo, $cfg.PuertoRdp }
    Write-Log "Abriendo Escritorio remoto con $destino."
    Start-Process -FilePath "$env:windir\System32\mstsc.exe" -ArgumentList "/v:$destino"
}

function Start-Espera {
    $State.Esperando = $true
    $State.InicioEspera = [DateTime]::Now
    $State.UltimaSonda = [DateTime]::MinValue
    $btnRdp.Text = 'Cancelar espera'
    $btnWol.Enabled = $false
    $txtEquipo.Enabled = $false
    $lblEspera.Text = 'Esperando a que arranque…'
}

function Stop-Espera {
    $State.Esperando = $false
    $btnRdp.Text = 'Conectar (RDP)'
    $btnWol.Enabled = $true
    $txtEquipo.Enabled = $true
    $lblEspera.Text = ''
}

function Start-UpdateCheck([bool]$Manual) {
    if ($State.Comprobacion) { return }
    try {
        $wc = New-GitHubClient
        $State.Comprobacion = [pscustomobject]@{
            Cliente = $wc
            Tarea   = $wc.DownloadStringTaskAsync("https://api.github.com/repos/$RepoGitHub/tags?per_page=100")
            Manual  = $Manual
        }
        if ($Manual) { $lnkActualizar.Text = 'Buscando…' }
    } catch {
        Write-Log "No se han podido buscar actualizaciones: $($_.Exception.Message)"
    }
}

function Complete-UpdateCheck($Comprobacion) {
    $lnkActualizar.Text = 'Buscar actualizaciones'
    $tarea = $Comprobacion.Tarea
    if ($tarea.IsFaulted -or $tarea.IsCanceled) {
        $motivo = if ($tarea.Exception) { $tarea.Exception.GetBaseException().Message } else { 'cancelada' }
        Write-Log "No se han podido buscar actualizaciones: $motivo"
        if ($Comprobacion.Manual) { Show-Aviso "No se han podido buscar actualizaciones:`n$motivo" }
        return
    }

    $ultima = Get-LatestTag $tarea.Result
    if (-not $ultima -or $ultima.Version -le [version]$Version) {
        if ($Comprobacion.Manual) {
            Write-Log "Tienes la última versión ($Version)."
            [System.Windows.Forms.MessageBox]::Show($form, "Tienes la última versión ($Version).",
                'Wake-on-LAN', 'OK', 'Information') | Out-Null
        }
        return
    }

    Write-Log "Hay una versión nueva: $($ultima.Tag) (tienes la $Version)."
    $lblVersion.Text = "Versión $Version ($($ultima.Tag) disponible)"
    $lblVersion.ForeColor = [System.Drawing.Color]::DarkOrange

    if (Test-Path (Join-Path $PSScriptRoot '.git')) {
        Write-Log 'Esta copia es un repositorio git: actualízala con git pull.'
        return
    }
    if ($State.Esperando) {
        Write-Log 'Se puede actualizar desde "Buscar actualizaciones" cuando termine la espera.'
        return
    }

    $respuesta = [System.Windows.Forms.MessageBox]::Show($form,
        "Hay una versión nueva: $($ultima.Tag). Tienes la $Version.`n`n¿Quieres actualizar ahora? El programa se reiniciará.",
        'Actualización disponible', 'YesNo', 'Question')
    if ($respuesta -ne 'Yes') { return }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Write-Log "Descargando $($ultima.Tag)…"
        Install-Update $ultima.Tag $PSScriptRoot
    } catch {
        Write-Log "Error al actualizar: $($_.Exception.Message)"
        Show-Aviso "No se ha podido actualizar:`n$($_.Exception.Message)"
        return
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    Write-Log "Actualizado a $($ultima.Tag). Reiniciando…"
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$ScriptPath`"")
    $form.Close()
}

$lnkActualizar.Add_LinkClicked({ Start-UpdateCheck $true })

$btnWol.Add_Click({
    $cfg = Get-FormConfig
    Save-Config $cfg
    if (Invoke-Wol $cfg) {
        # Comprobar pronto para ver cuándo arranca.
        $State.UltimaSonda = [DateTime]::MinValue
    }
})

$btnRdp.Add_Click({
    if ($State.Esperando) {
        Stop-Espera
        Write-Log 'Espera cancelada.'
        return
    }
    $cfg = Get-FormConfig
    if (-not $cfg.Equipo) {
        Show-Aviso 'Indica el nombre o la IP del equipo.'
        return
    }
    Save-Config $cfg

    if ($State.Encendido -eq $true) {
        Start-Rdp $cfg
        return
    }

    Write-Log 'El equipo no responde: se envía WOL antes de conectar.'
    if (Invoke-Wol $cfg) {
        Start-Espera
    }
})

$btnDetectar.Add_Click({
    $equipo = $txtEquipo.Text.Trim()
    if (-not $equipo) {
        Show-Aviso 'Indica primero el nombre o la IP del equipo (tiene que estar encendido).'
        return
    }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $ip = [System.Net.Dns]::GetHostAddresses($equipo) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            Select-Object -First 1
        if (-not $ip) { throw "No se ha podido resolver '$equipo' a una IPv4." }
        $ip = $ip.ToString()
        # Un ping llena la tabla ARP con la MAC del equipo.
        [void](Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue)
        $vecino = Get-NetNeighbor -IPAddress $ip -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' } |
            Select-Object -First 1
        if (-not $vecino) {
            throw "No se ha encontrado la MAC de $ip. El equipo tiene que estar encendido y en la misma red local."
        }
        $txtMac.Text = $vecino.LinkLayerAddress
        Write-Log "MAC de $ip detectada: $($vecino.LinkLayerAddress)."
        Save-Config (Get-FormConfig)
    } catch {
        Show-Aviso $_.Exception.Message
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

$txtEquipo.Add_TextChanged({
    Set-Estado $null
    # Esperar un poco antes de comprobar, mientras se escribe.
    $State.UltimaSonda = [DateTime]::Now.AddSeconds(1 - $IntervaloComprobacion)
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    $equipo = $txtEquipo.Text.Trim()
    $ahora = [DateTime]::Now

    # Resultado de la búsqueda de actualizaciones. Se limpia antes de procesarlo
    # porque puede abrir un diálogo y el temporizador sigue disparándose debajo.
    $comp = $State.Comprobacion
    if ($comp -and $comp.Tarea.IsCompleted) {
        $State.Comprobacion = $null
        $comp.Cliente.Dispose()
        Complete-UpdateCheck $comp
        if ($form.IsDisposed -or -not $form.Visible) { return }
    }

    # Recoger el resultado de la comprobación en curso.
    $sonda = $State.Sonda
    if ($sonda) {
        $terminada = $sonda.Tarea -and $sonda.Tarea.IsCompleted
        $caducada = ($ahora - $sonda.Inicio).TotalMilliseconds -gt $TimeoutConexionMs
        if ($terminada -or $caducada -or $sonda.Error) {
            $ok = $terminada -and -not $sonda.Tarea.IsFaulted -and -not $sonda.Tarea.IsCanceled -and $sonda.Cliente.Connected
            try { $sonda.Cliente.Close() } catch { }
            $State.Sonda = $null
            $State.UltimaSonda = $ahora
            if ($sonda.Equipo -eq $equipo) { Set-Estado ([bool]$ok) }
        }
    }

    # Esperando a que arranque para lanzar RDP.
    if ($State.Esperando) {
        $transcurrido = ($ahora - $State.InicioEspera).TotalSeconds
        if ($State.Encendido -eq $true) {
            Stop-Espera
            Write-Log ('El equipo ha arrancado en {0:N0} s.' -f $transcurrido)
            Start-Rdp (Get-FormConfig)
        } elseif ($transcurrido -ge $numEspera.Value) {
            Stop-Espera
            Write-Log 'El equipo no ha arrancado a tiempo.'
            Show-Aviso ("El equipo no ha respondido en {0} s.`n`nComprueba que Wake-on-LAN está activado en la BIOS y en la tarjeta de red, y que Escritorio remoto está habilitado." -f $numEspera.Value)
        } else {
            if (($ahora - $State.UltimoWol).TotalSeconds -ge $IntervaloReenvioWol) {
                [void](Invoke-Wol (Get-FormConfig))
            }
            $lblEspera.Text = 'Esperando a que arranque… {0:N0} s de {1} s' -f $transcurrido, $numEspera.Value
        }
    }

    # Lanzar una nueva comprobación si toca.
    if (-not $State.Sonda -and $equipo) {
        $intervalo = if ($State.Esperando) { $IntervaloComprobacionEsperando } else { $IntervaloComprobacion }
        if (($ahora - $State.UltimaSonda).TotalSeconds -ge $intervalo) {
            $State.Sonda = Start-Probe $equipo ([int]$Config.PuertoRdp)
        }
    }
})

$form.Add_Shown({
    Write-Log 'Listo.'
    if (-not $txtEquipo.Text) { $txtEquipo.Focus() } else { $btnRdp.Focus() }
    $timer.Start()
    Start-UpdateCheck $false
})

$form.Add_FormClosing({
    $timer.Stop()
    Save-Config (Get-FormConfig)
})

[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
