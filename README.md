# Diagnostico de conexion SAP

Script de PowerShell que evalua el enlace desde el PC del trabajador hacia el servicio SAP y deja un informe en el Escritorio.

## Como ejecutarlo

1. Abrir **PowerShell** (Inicio > escribir "PowerShell" > Enter).
2. Pegar el comando entregado por TI y presionar Enter:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/rodrigoperez-bot/Diagnostico-conexionSAP/main/DiagnosticoSAP.ps1))) -ServerIp <IP> -Port <PUERTO>
```

> La IP y el puerto del servicio no se publican en este repositorio. TI los entrega por un canal interno.
> Si se ejecuta sin `-ServerIp` / `-Port`, el script los pide por pantalla.

3. Esperar entre 30 y 60 segundos. Al terminar se muestra un resumen y se guarda **`Informe SAP.txt` en el Escritorio**.

## Que informa

- Nombre del host, direccion MAC e IP local
- IP publica, pais, ciudad y proveedor (ISP)
- Gateway local: latencia, jitter y perdida
- Servicio SAP: latencia, jitter, perdida y estado del puerto SAP y del 443
- Diagnostico general (OPTIMO / ELEVADO / ALERTA CRITICA)
- IP de la ruta transatlantica detectada
- Resumen de la ruta salto a salto y registro crudo del `tracert`

## Requisitos

- Windows con PowerShell 5.1 o superior
- Acceso a `raw.githubusercontent.com`
