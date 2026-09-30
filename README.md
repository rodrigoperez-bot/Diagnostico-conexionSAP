# Diagnostico de conexion - Servicios Google y SAP

Script de PowerShell que evalua el enlace desde el PC del trabajador hacia Google Meet, Google Drive, Google Mail, Google Chat y el servicio SAP, y deja un informe en el Escritorio.

## Como ejecutarlo

1. Abrir PowerShell (Inicio > escribir "PowerShell" > Enter).
2. Pegar este comando y presionar Enter:

```powershell
irm https://raw.githubusercontent.com/rodrigoperez-bot/Diagnostico-conexionSAP/main/DiagnosticoSAP.ps1 | iex
```

3. Esperar entre 3 y 4 minutos. Si no hay red local ni internet, el script lo indica y termina antes. Al terminar se muestra un resumen y se guarda **Informe Servicios.txt** en el Escritorio.
4. Enviar ese archivo a TI.

## Que informa

- Nombre del host, direccion MAC e IP local
- IP publica, pais, ciudad y proveedor (ISP)
- Red local (se revisa primero): tipo de conexion (cable o Wi-Fi), senal Wi-Fi, velocidad del enlace, latencia, jitter, perdida y ruta hacia la puerta de enlace, con deteccion de cuellos de botella
- DNS: servidores configurados, si responden, tiempo de resolucion y diagnostico de problemas de DNS
- Salida a internet
- Google Meet, Drive, Mail y Chat: latencia, jitter, perdida y ruta salto a salto
- Servicio SAP: latencia, jitter, perdida y ruta salto a salto
- Diagnostico SAP (OPTIMO / ELEVADO / ALERTA CRITICA)
- Registro crudo del tracert de cada servicio

## Requisitos

- Windows con PowerShell 5.1 o superior
- Acceso a raw.githubusercontent.com
