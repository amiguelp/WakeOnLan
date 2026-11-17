# wakeonlan

Script de PowerShell con ventana para encender otro PC por Wake-on-LAN y conectarse a él por Escritorio remoto.

- **Encender (WOL)**: envía el paquete mágico a la MAC configurada.
- **Conectar (RDP)**: si el equipo responde en el puerto RDP, abre `mstsc`. Si no responde, envía WOL, espera a que arranque (reenviando WOL cada 30 s) y entonces abre `mstsc`. Mientras espera, el botón pasa a **Cancelar espera**.
- **Apagar**: pide confirmación y apaga el equipo con `shutdown /s /f /t 0 /m \\<equipo>`. Los programas abiertos se cierran sin guardar. Ver [Apagado remoto](#apagado-remoto).

El indicador de estado comprueba cada 5 s si el puerto RDP (3389) del equipo responde.

## Uso

Haz doble clic en `WakeOnLan.cmd`, o ejecuta:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WakeOnLan.ps1
```

Rellena:

| Campo | Qué es |
|---|---|
| Equipo | Nombre o IP del PC remoto. Una IP fija es más fiable: con el PC apagado el nombre puede no resolverse. |
| Dirección MAC | MAC de la tarjeta de red del PC remoto. Con el PC encendido, el botón **Detectar** la obtiene de la tabla ARP. |
| Usar broadcast | Marcado (por defecto): el WOL se envía al broadcast de todas las redes locales, a `255.255.255.255`, al broadcast de la red del equipo (suponiendo máscara /24) y a su IP. Desmarcado: solo a la IP del equipo, sin ningún broadcast. |
| Espera máxima | Segundos que se espera a que arranque antes de dar el aviso. |

La configuración se guarda en `config.json`, junto al script (no se sube al repositorio). En ese fichero también se pueden cambiar `PuertoWol` (9) y `PuertoRdp` (3389).

## Actualizaciones

Al arrancar, el script consulta las etiquetas `vX.Y.Z` de este repositorio en GitHub. Si hay una mayor que su `$Version`, pregunta si se quiere actualizar: descarga el código de esa etiqueta, sobrescribe los ficheros (conserva `config.json`) y se reinicia. También se puede buscar a mano con el enlace **Buscar actualizaciones**.

Si la carpeta del script es un clon de git (tiene `.git`), en lugar de sobrescribir los ficheros actualiza con `git pull --ff-only`. Necesita `git.exe` en el PATH y no actualiza si hay cambios sin confirmar en ficheros del repositorio, para no pisarlos.

### Publicar una versión

1. Sube `$Version` al principio de `WakeOnLan.ps1` (por ejemplo `'1.1.0'`).
2. Haz commit y crea la etiqueta con la misma versión y el prefijo `v`:

   ```bash
   git tag v1.1.0
   git push origin main v1.1.0
   ```

La etiqueta tiene que coincidir con `$Version`: si la etiqueta es mayor que la versión del código que contiene, el script ofrecerá actualizar cada vez que arranque.

## Requisitos en el PC remoto

- Wake-on-LAN activado en la BIOS/UEFI y en las propiedades de la tarjeta de red (*Activar con Magic Packet*). Conviene desactivar el *Inicio rápido* de Windows, que en algunos equipos impide el WOL desde el apagado.
- Escritorio remoto habilitado (Windows Pro o superior) y el puerto 3389 permitido en el firewall.
- WOL está pensado para la misma red local: el paquete de broadcast no atraviesa routers.

### Apagado remoto

`shutdown /m` necesita que el equipo remoto acepte la orden:

- Tu usuario tiene que ser **administrador** en el equipo remoto. Lo más sencillo es usar en los dos PC la misma cuenta (o una cuenta local con el mismo nombre y contraseña). Si son distintas, conéctate una vez con `net use \\192.168.1.102\IPC$ /user:EQUIPO\usuario` antes de pulsar **Apagar**.
- Con **cuentas locales** (no de Microsoft ni de dominio), Windows quita los permisos de administrador a las conexiones remotas. En el equipo remoto, en PowerShell como administrador:

  ```powershell
  New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System `
      -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force
  ```

- El firewall del equipo remoto tiene que permitir **Compartir archivos e impresoras** en la red privada, y la red tiene que estar marcada como privada.

Si falla, el registro muestra el mensaje de `shutdown` (código 5: acceso denegado; 53: no se encuentra la ruta de red).

### Si el equipo está en otra red

Pasa, por ejemplo, si tu PC está detrás de un mesh en modo router (192.168.68.x) y el equipo a encender está en el router principal (192.168.1.x). El broadcast local no llega a la otra red, así que el script envía además el paquete a la IP del equipo y al broadcast de su red. Que lleguen depende del router que tiene una pata en la red del equipo (en el ejemplo, el mesh, cuyo lado WAN está en 192.168.1.x):

- Al broadcast de su red (`192.168.1.255`), solo si el router deja pasar *broadcasts dirigidos*. La mayoría de routers domésticos no lo hacen.
- A la IP del equipo, solo mientras el router recuerde su MAC (unos minutos después de apagarlo), o siempre si el router permite fijar la pareja IP–MAC (*ARP estático*).

Para saber cuál de los dos funciona en tu red, prueba con el equipo apagado desde hace al menos media hora: con **Usar broadcast** marcado (incluye el broadcast dirigido) y con **Usar broadcast** desmarcado (solo la IP).

Si nada de eso funciona, las alternativas son poner el mesh en modo punto de acceso, para que todo quede en la misma red, o tener en la red del equipo un aparato siempre encendido (un ESP32, una Raspberry Pi) que reenvíe el paquete como broadcast. Para todo esto conviene indicar el equipo por **IP**: apagado, su nombre puede no resolverse.
