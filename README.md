# wakeonlan

Script de PowerShell con ventana para encender otro PC por Wake-on-LAN y conectarse a él por Escritorio remoto.

- **Encender (WOL)**: envía el paquete mágico a la MAC configurada.
- **Conectar (RDP)**: si el equipo responde en el puerto RDP, abre `mstsc`. Si no responde, envía WOL, espera a que arranque (reenviando WOL cada 30 s) y entonces abre `mstsc`. Mientras espera, el botón pasa a **Cancelar espera**.

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
| Broadcast | Vacío = se envía al broadcast de todas las redes locales y a `255.255.255.255`. Pon una dirección concreta (por ejemplo `192.168.1.255`) si hace falta. |
| Espera máxima | Segundos que se espera a que arranque antes de dar el aviso. |

La configuración se guarda en `config.json`, junto al script (no se sube al repositorio). En ese fichero también se pueden cambiar `PuertoWol` (9) y `PuertoRdp` (3389).

## Requisitos en el PC remoto

- Wake-on-LAN activado en la BIOS/UEFI y en las propiedades de la tarjeta de red (*Activar con Magic Packet*). Conviene desactivar el *Inicio rápido* de Windows, que en algunos equipos impide el WOL desde el apagado.
- Escritorio remoto habilitado (Windows Pro o superior) y el puerto 3389 permitido en el firewall.
- WOL funciona dentro de la misma red local: el paquete de broadcast no atraviesa routers.
