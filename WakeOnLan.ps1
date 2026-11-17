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
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

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

function Send-WakeOnLan([string]$Mac, [string]$Broadcast, [int]$Puerto) {
    $mac = ConvertTo-MacBytes $Mac
    # Paquete mágico: 6 bytes 0xFF seguidos de la MAC repetida 16 veces.
    $paquete = New-Object byte[] 102
    for ($i = 0; $i -lt 6; $i++) { $paquete[$i] = 0xFF }
    for ($r = 0; $r -lt 16; $r++) { [Array]::Copy($mac, 0, $paquete, 6 + $r * 6, 6) }

    if ([string]::IsNullOrWhiteSpace($Broadcast)) {
        $destinos = @(Get-BroadcastAddresses)
    } else {
        $destinos = @($Broadcast.Trim())
    }

    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.EnableBroadcast = $true
        foreach ($d in $destinos) {
            $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($d)), $Puerto
            [void]$udp.Send($paquete, $paquete.Length, $ep)
        }
    } finally {
        $udp.Close()
    }
    return $destinos
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
# Interfaz
# ---------------------------------------------------------------------------

$State = @{
    Sonda          = $null
    UltimaSonda    = [DateTime]::MinValue
    Encendido      = $null      # $true, $false o $null (desconocido)
    Esperando      = $false
    InicioEspera   = [DateTime]::MinValue
    UltimoWol      = [DateTime]::MinValue
}

$Config = Read-Config

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Wake-on-LAN + Escritorio remoto'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(460, 420)
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
        $destinos = Send-WakeOnLan $cfg.Mac $cfg.Broadcast ([int]$cfg.PuertoWol)
        $State.UltimoWol = [DateTime]::Now
        Write-Log "WOL enviado a $($cfg.Mac) ($($destinos -join ', '))."
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
})

$form.Add_FormClosing({
    $timer.Stop()
    Save-Config (Get-FormConfig)
})

[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
