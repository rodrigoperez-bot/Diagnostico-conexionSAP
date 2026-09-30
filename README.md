# Diagnostico de conexion - Servicios Google y SAP

Script de PowerShell que evalua el enlace desde el PC del trabajador hacia Google Meet, Google Drive, Google Mail, Google Chat y el servicio SAP, y deja un informe en el Escritorio.

## Como ejecutarlo

1. Abrir PowerShell (Inicio > escribir "PowerShell" > Enter).
2. Pegar este comando y presionar Enter:

```powershell
irm https://raw.githubusercontent.com/rodrigoperez-bot/Diagnostico-conexionSAP/main/DiagnosticoSAP.ps1 | iex
```

3. Esperar entre 3 y 4 minutos. Al terminar se muestra un resumen y se guarda **Informe Servicios.txt** en el Escritorio.
4. Enviar ese archivo a TI.

## Que informa

- Nombre del host, direccion MAC e IP local
- IP publica, pais, ciudad y proveedor (ISP)
- Gateway local: latencia, jitter y perdida
- Salida a internet por el puerto 443 (HTTPS)
- Google Meet, Drive, Mail y Chat: latencia TCP, jitter, perdida, puerto 443 y ruta salto a salto
- Servicio SAP: latencia, jitter, perdida, estado del puerto SAP y ruta salto a salto
- Diagnostico SAP (OPTIMO / ELEVADO / ALERTA CRITICA)
- Registro crudo del tracert de cada servicio

## Requisitos

- Windows con PowerShell 5.1 o superior
- Acceso a raw.githubusercontent.com
