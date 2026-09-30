<#
    Informe Tecnico de Conectividad - Servicios Google y SAP
    ---------------------------------------------------------
    Ejecuta el diagnostico de red hacia los servicios Google y SAP,
    y guarda el informe en el Escritorio como "Informe Servicios.txt".

    Uso:
        irm https://raw.githubusercontent.com/rodrigoperez-bot/Diagnostico-conexionSAP/main/DiagnosticoSAP.ps1 | iex
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# --- CONFIGURACION SAP (codificada en base64) ---
function Dec($b) { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) }
$SAP_HOST    = Dec 'c2FwLmFsby1ncm91cC5jb20='
$SERVER_PORT = [int](Dec 'NjEzNTE=')

# --- SERVICIOS GOOGLE ---
$SERVICIOS_GOOGLE = [ordered]@{
    'Google Meet'  = 'meet.google.com'
    'Google Drive' = 'drive.google.com'
    'Google Chat'  = 'chat.google.com'
    'Google Mail'  = 'mail.google.com'
}
$PUERTO_GOOGLE = 443

# Umbrales latencia TCP Google (ms)
$GOOGLE_UMBRAL_OK   = 150
$GOOGLE_UMBRAL_ROJO = 300

# Referencias WonderNetwork para SAP
$REFERENCIAS = @{
    'Chile'    = @{ ciudad = 'Santiago'; EU = 210; US = 160 }
    'Peru'     = @{ ciudad = 'Lima';     EU = 240; US = 180 }
    'Bolivia'  = @{ ciudad = 'La Paz';   EU = 255; US = 195 }
    'Ecuador'  = @{ ciudad = 'Quito';    EU = 235; US = 170 }
    'Colombia' = @{ ciudad = 'Bogota';   EU = 190; US = 140 }
    'Paraguay' = @{ ciudad = 'Asuncion'; EU = 220; US = 165 }
}

$NOMBRE_INFORME = 'Informe Servicios.txt'

$MAX_SALTOS        = 30
$MAX_SALTOS_GOOGLE = 20
$ESPERA_MS         = 800
$LIMITE_SEG        = 75
$LIMITE_SEG_GOOGLE = 35

$KW_HOSTING      = @('hetzner', 'your-server')
$KW_HOTEL_RED    = @('equinix', 'telehouse', 'interxion', 'digitalrealty', 'coresite', 'cyrusone', 'globalswitch', 'de-cix', 'decix', 'ams-ix', 'amsix', 'linx', 'ixp', 'datacenter')
$TOK_HOTEL_RED   = @('nap', 'ix', 'ixp')
$KW_SUBMARINO    = @('telxius', 'sparkle', 'seabone', 'globenet', 'ufinet', 'submarin', 'subsea', 'ellalink')
$KW_TRANSITO     = @('level3', 'lumen', 'centurylink', 'cogent', 'arelion', 'telia', 'twelve99', 'tata', 'zayo', 'sprint', 'verizon', 'retn', 'he.net', 'ntt', 'gtt')
$KW_ISP_NACIONAL = @('entel', 'claro', 'movistar', 'telefonica', 'vtr', 'wom', 'gtd', 'netline')
$KW_GOOGLE       = @('google', '1e100')

$RE_SALTO_WIN = '^(\d+)\s+((?:<?\d+\s*ms|\*)\s+(?:<?\d+\s*ms|\*)\s+(?:<?\d+\s*ms|\*))\s*(.*)$'
$RE_IP        = '\d{1,3}(?:\.\d{1,3}){3}'

# ------------------------------------------------------------------
# Funciones de apoyo
# ------------------------------------------------------------------

function Test-Contiene($texto, $palabras) {
    foreach ($p in $palabras) { if ($texto.Contains($p)) { return $true } }
    return $false
}

function Obtener-UbicacionPublica {
    $geo = @{ ip = 'No disponible'; pais = 'Desconocido'; ciudad = 'Desconocida'; isp = 'Desconocido'; ok = $false }
    try {
        $d = Invoke-RestMethod -Uri 'https://ipwho.is/' -TimeoutSec 6 -UseBasicParsing
        if ($d.success) {
            $geo.ip = $d.ip; $geo.pais = $d.country; $geo.ciudad = $d.city
            $geo.isp = "$($d.connection.isp) ($($d.connection.org))"
            $geo.ok = $true
            return $geo
        }
    } catch {}
    try {
        $d = Invoke-RestMethod -Uri 'http://ip-api.com/json/' -TimeoutSec 6 -UseBasicParsing
        if ($d.query) {
            $geo.ip = $d.query; $geo.pais = $d.country; $geo.ciudad = $d.city
            $geo.isp = $d.isp
            $geo.ok = $true
        }
    } catch {}
    return $geo
}

function Obtener-DatosHostLocal {
    $nombre = [System.Net.Dns]::GetHostName()
    $ipLocal = '127.0.0.1'
    try {
        $s = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
        $s.Connect('8.8.8.8', 80)
        $ipLocal = $s.LocalEndPoint.Address.ToString()
        $s.Close()
    } catch {}
    $mac = 'Desconocida'
    try {
        $nic = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
            $_.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.ToString() -eq $ipLocal }
        } | Select-Object -First 1
        if ($nic) {
            $mac = (($nic.GetPhysicalAddress().ToString()) -split '(..)' | Where-Object { $_ }) -join ':'
        }
    } catch {}
    return @{ nombre = $nombre; ip_local = $ipLocal; mac = $mac.ToUpper() }
}

function Obtener-Gateway {
    try {
        $gw = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.OperationalStatus -eq 'Up' } |
            ForEach-Object { $_.GetIPProperties().GatewayAddresses } |
            Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0' } |
            Select-Object -First 1
        if ($gw) { return $gw.Address.ToString() }
    } catch {}
    return $null
}

function Detectar-RegionServidor($ip) {
    try {
        $h = ([System.Net.Dns]::GetHostEntry($ip)).HostName.ToLower()
        if (Test-Contiene $h @('hetzner', 'ovh', 'scaleway', 'strato', 'ionos', 'server.de', 'contabo')) { return 'EU' }
        if (Test-Contiene $h @('amazonaws', 'azure', 'google', 'digitalocean', 'linode', 'cloudflare')) { return 'US' }
    } catch {}
    return 'DESCONOCIDA'
}

function Hacer-Pings($ip, $cantidad = 10) {
    $tiempos = @()
    $ping = New-Object System.Net.NetworkInformation.Ping
    for ($i = 0; $i -lt $cantidad; $i++) {
        try {
            $r = $ping.Send($ip, 2000)
            if ($r.Status -eq 'Success') { $tiempos += [int]$r.RoundtripTime }
        } catch {}
        Start-Sleep -Milliseconds 200
    }
    $ping.Dispose()
    return ,$tiempos
}

function Medir-LatenciaTCP($destino, $puerto, $intentos = 5) {
    $tiempos = @()
    for ($i = 0; $i -lt $intentos; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            $t = $c.ConnectAsync($destino, $puerto)
            if ($t.Wait(3000) -and $c.Connected) {
                $sw.Stop()
                $tiempos += [int]$sw.ElapsedMilliseconds
            }
        } catch {} finally { $c.Close(); if ($sw.IsRunning) { $sw.Stop() } }
        Start-Sleep -Milliseconds 300
    }
    return ,$tiempos
}

function Calcular-Jitter($tiempos) {
    if ($tiempos.Count -lt 2) { return 0 }
    $suma = 0
    for ($i = 0; $i -lt $tiempos.Count - 1; $i++) { $suma += [math]::Abs($tiempos[$i] - $tiempos[$i + 1]) }
    return [math]::Floor($suma / ($tiempos.Count - 1))
}

function Evaluar-MetricasPing($tiempos, $umbralRojo, $refMs) {
    if ($tiempos.Count -eq 0) {
        return @{ latencia = 9999; jitter = 0; perdida = 100; est_lat = 'SIN RESPUESTA'; est_jit = 'ALTO'; est_perd = 'ALTA' }
    }
    $avg     = [math]::Floor(($tiempos | Measure-Object -Sum).Sum / $tiempos.Count)
    $perdida = [math]::Round(((10 - $tiempos.Count) / 10) * 100, 1)
    $jitter  = Calcular-Jitter $tiempos
    $estLat  = if ($avg -ge $umbralRojo) { 'SOBRE UMBRAL' } elseif ($avg -ge ($refMs * 1.10)) { 'ELEVADO' } else { 'OK' }
    $estJit  = if ($jitter -ge 30) { 'ALTO' } elseif ($jitter -ge 15) { 'ELEVADO' } else { 'OK' }
    $estPerd = if ($perdida -ge 3) { 'ALTA' } elseif ($perdida -ge 1) { 'LEVE' } else { 'OK' }
    return @{ latencia = $avg; jitter = $jitter; perdida = $perdida; est_lat = $estLat; est_jit = $estJit; est_perd = $estPerd }
}

function Comprobar-Puerto($destino, $puerto) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $t = $c.ConnectAsync($destino, $puerto)
        if ($t.Wait(2000) -and $c.Connected) { return 'ABIERTO' }
    } catch {} finally { $c.Close() }
    return 'CERRADO/FILTRADO'
}

function Es-IpPrivada($ip) {
    $o = $ip.Split('.') | ForEach-Object { [int]$_ }
    if ($o.Count -ne 4) { return $false }
    if ($o[0] -eq 10) { return $true }
    if ($o[0] -eq 127) { return $true }
    if ($o[0] -eq 172 -and $o[1] -ge 16 -and $o[1] -le 31) { return $true }
    if ($o[0] -eq 192 -and $o[1] -eq 168) { return $true }
    if ($o[0] -eq 169 -and $o[1] -eq 254) { return $true }
    if ($o[0] -eq 100 -and $o[1] -ge 64 -and $o[1] -le 127) { return $true }
    return $false
}

function Resolver-Nombres($ips, $esperaSeg = 4) {
    $nombres = @{}
    $tareas = @{}
    foreach ($ip in $ips) {
        try { $tareas[$ip] = [System.Net.Dns]::GetHostEntryAsync($ip) } catch {}
    }
    if ($tareas.Count -eq 0) { return $nombres }
    try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($tareas.Values), $esperaSeg * 1000) } catch {}
    foreach ($ip in $tareas.Keys) {
        $t = $tareas[$ip]
        if ($t.Status -eq 'RanToCompletion') { $nombres[$ip] = $t.Result.HostName } else { $nombres[$ip] = '' }
    }
    return $nombres
}

function Resolver-IP($hostname) {
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($hostname) | Where-Object { $_.AddressFamily -eq 'InterNetwork' }
        if ($addrs) { return $addrs[0].ToString() }
    } catch {}
    return $null
}

function Ejecutar-Tracert($ipDestino, $maxSaltos = $MAX_SALTOS, $limiteSeg = $LIMITE_SEG) {
    $argumentos = "-d -h $maxSaltos -w $ESPERA_MS $ipDestino"
    $cmdTxt = "tracert $argumentos"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'tracert.exe'
    $psi.Arguments = $argumentos
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try { $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch {}
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return @{ salida = ''; aviso = "Error al lanzar tracert: $($_.Exception.Message)"; cmd = $cmdTxt }
    }
    $lectura = $proc.StandardOutput.ReadToEndAsync()
    $aviso = ''
    if (-not $proc.WaitForExit($limiteSeg * 1000)) {
        try { $proc.Kill() } catch {}
        $aviso = "El rastreo supero $limiteSeg s y se corto."
    }
    $salida = ''
    try { if ($lectura.Wait(5000)) { $salida = $lectura.Result } } catch {}
    return @{ salida = $salida; aviso = $aviso; cmd = $cmdTxt }
}

function Clasificar-Salto($num, $ip, $nombre, $avg, $diff, $esDestino) {
    $h = if ($nombre) { $nombre.ToLower() } else { '' }
    $partes = $h -split '[^a-z]+' | Where-Object { $_ }
    $nivel = 'verde'
    if ($diff -ge 70 -or $avg -ge 250) { $nivel = 'rojo' }
    elseif ($diff -ge 40 -or $avg -ge 120) { $nivel = 'amarillo' }
    if ($num -eq '1') { return @('verde', 'Red local') }
    if ($esDestino) { return @('verde', 'Destino Final') }
    if ($ip -and (Es-IpPrivada $ip)) { return @($nivel, 'Red privada del operador') }
    if (Test-Contiene $h $KW_HOSTING) { return @($nivel, 'Red del proveedor de destino') }
    if ((Test-Contiene $h $KW_HOTEL_RED) -or ($partes | Where-Object { $TOK_HOTEL_RED -contains $_ })) { return @($nivel, 'Datacenter / IXP') }
    if (Test-Contiene $h $KW_SUBMARINO) { return @($nivel, 'Operador de cable submarino') }
    if (Test-Contiene $h $KW_TRANSITO) { return @($nivel, 'Transito internacional') }
    if (Test-Contiene $h $KW_GOOGLE) { return @($nivel, 'Red Google') }
    if ((Test-Contiene $h $KW_ISP_NACIONAL) -or $h.EndsWith('.cl')) { return @($nivel, 'ISP / red nacional') }
    if ($nivel -eq 'rojo') { return @($nivel, 'Cruce Oceanico o Cuello de botella') }
    if ($nivel -eq 'amarillo') { return @($nivel, 'Enlace submarino / Cruce fronterizo') }
    return @($nivel, 'Transito normal')
}

function Procesar-Ruta($ipDestino, $maxSaltos = $MAX_SALTOS, $limiteSeg = $LIMITE_SEG) {
    $tr = Ejecutar-Tracert $ipDestino $maxSaltos $limiteSeg
    $crudos = @()
    $lineasFiltradas = New-Object System.Collections.Generic.List[string]
    foreach ($linea in ($tr.salida -split "`r?`n")) {
        if ($linea -match 'Traza completa\.|Trace complete\.') { continue }
        $lineasFiltradas.Add($linea)
        $m = [regex]::Match($linea.Trim(), $RE_SALTO_WIN)
        if (-not $m.Success) { continue }
        $num = $m.Groups[1].Value; $grupo = $m.Groups[2].Value; $resto = $m.Groups[3].Value
        $sondeos = [regex]::Matches($grupo, '<?[\d\.]+\s*ms|\*') | ForEach-Object { $_.Value }
        $valores = @($sondeos | Where-Object { $_ -ne '*' } | ForEach-Object { [int][math]::Floor([double]($_ -replace '[^\d\.]', '')) })
        $ipM = [regex]::Match($resto, $RE_IP)
        $ip = if ($ipM.Success) { $ipM.Value } else { $null }
        $crudos += ,@{ num = $num; valores = $valores; ip = $ip; resto = $resto.Trim() }
        if ($ip -eq $ipDestino) {
            $lineasFiltradas.Add("`nTraza completa.")
            break
        }
    }
    $ips = $crudos | Where-Object { $_.ip } | ForEach-Object { $_.ip } | Select-Object -Unique
    $nombres = Resolver-Nombres $ips
    $saltos = @()
    $prevMs = 0
    $ipTrans = 'No detectada'
    foreach ($c in $crudos) {
        $ip = $c.ip
        $nombre = if ($ip -and $nombres.ContainsKey($ip)) { $nombres[$ip] } else { '' }
        if ($nombre -eq $ip) { $nombre = '' }
        if ($c.valores.Count -gt 0) {
            $avg = [math]::Floor(($c.valores | Measure-Object -Sum).Sum / $c.valores.Count)
            $diff = $avg - $prevMs
            $esDestino = ($ip -eq $ipDestino) -or ($nombre.ToLower().Contains('your-server'))
            $clas = Clasificar-Salto $c.num $ip $nombre $avg $diff $esDestino
            $hostTxt = if ($nombre -and $ip) { "$nombre [$ip]" } elseif ($ip) { $ip } elseif ($c.resto) { $c.resto } else { 'Nodo sin identificar' }
            $saltos += ,@{ num = $c.num; host = $hostTxt; ms = $avg; nivel = $clas[0]; categoria = $clas[1] }
            $prevMs = $avg
            $cat = $clas[1].ToLower()
            if ($ipTrans -eq 'No detectada' -and ($cat.Contains('cruce') -or $cat.Contains('submarino') -or ($diff -ge 70 -and $avg -ge 90))) {
                if ($ip -and -not (Es-IpPrivada $ip)) { $ipTrans = "$ip (Identificada en el salto #$($c.num))" }
            }
            if ($esDestino) { break }
        } else {
            $saltos += ,@{ num = $c.num; host = 'Nodo protegido o tiempo de espera agotado (* * *)'; ms = '-'; nivel = 'gris'; categoria = 'Sin respuesta ICMP' }
        }
    }
    $cuerpo = ($lineasFiltradas -join "`r`n").Trim()
    if (-not $cuerpo) { $cuerpo = '(tracert no devolvio salida)' }
    $raw = "=== REGISTRO CRUDO DE TRACEROUTE ===`r`nComando  : $($tr.cmd)`r`n`r`n$cuerpo"
    if ($tr.aviso) { $raw += "`r`n`r`n$($tr.aviso)" }
    return @{ saltos = $saltos; raw = $raw; transatlantica = $ipTrans }
}

function Escribir-Paso($texto) { Write-Host "  > $texto" -ForegroundColor Cyan }

# ------------------------------------------------------------------
# Ejecucion del diagnostico
# ------------------------------------------------------------------

# Resolver el dominio SAP a IP (si falla, se usa el nombre directamente)
$SERVER_IP = Resolver-IP $SAP_HOST
if (-not $SERVER_IP) { $SERVER_IP = $SAP_HOST }

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '   INFORME TECNICO DE CONECTIVIDAD' -ForegroundColor Cyan
Write-Host '   Servicios Google + SAP' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host 'Analizando red... (aprox. 3-4 minutos por rutas completas)' -ForegroundColor Yellow
Write-Host ''

Escribir-Paso 'Detectando ubicacion e IP publica...'
$geo = Obtener-UbicacionPublica
$pais = if ($geo.pais -and $REFERENCIAS.ContainsKey($geo.pais)) { $geo.pais } else { 'Chile' }
if ($geo.ok) {
    Write-Host "    Ubicacion detectada: $($geo.ciudad), $($geo.pais)  |  IP Publica: $($geo.ip)" -ForegroundColor Gray
} else {
    Write-Host '    Ubicacion no detectada (sin acceso al servicio de geolocalizacion).' -ForegroundColor Yellow
}

$region = Detectar-RegionServidor $SERVER_IP
$refs = $REFERENCIAS[$pais]
$refMs = if ($region -eq 'EU') { $refs.EU } elseif ($region -eq 'US') { $refs.US } else { [math]::Min($refs.EU, $refs.US) }
$umbralRojo     = [math]::Ceiling($refMs * 1.20)
$umbralAmarillo = [math]::Ceiling($refMs * 1.10)

Escribir-Paso 'Identificando equipo local...'
$datosHost = Obtener-DatosHostLocal

Escribir-Paso 'Evaluando gateway (red local)...'
$gwIp = Obtener-Gateway
$gwRes = @{ latencia = 'SIN RESPUESTA'; jitter = 0; perdida = 100; est_gw = 'SIN RESPUESTA'; ip_gw = $gwIp }
if ($gwIp) {
    $tiemposGw = Hacer-Pings $gwIp 10
    if ($tiemposGw.Count -gt 0) {
        $avgGw = [math]::Floor(($tiemposGw | Measure-Object -Sum).Sum / $tiemposGw.Count)
        $gwRes = @{
            latencia = "$avgGw ms"
            jitter   = Calcular-Jitter $tiemposGw
            perdida  = [math]::Round(((10 - $tiemposGw.Count) / 10) * 100, 1)
            est_gw   = if ($avgGw -gt 20) { 'ALTO' } elseif ($avgGw -gt 5) { 'ELEVADO' } else { 'OK' }
            ip_gw    = $gwIp
        }
    }
}

# Verificar salida HTTPS (puerto 443 hacia internet)
Escribir-Paso 'Verificando salida puerto 443 (HTTPS) hacia internet...'
$puerto443Salida = Comprobar-Puerto 'www.google.com' 443

# ------------------------------------------------------------------
# Analisis servicios Google
# ------------------------------------------------------------------

$resultadosGoogle = [ordered]@{}
$idx = 0
foreach ($nombre in $SERVICIOS_GOOGLE.Keys) {
    $idx++
    $hostG = $SERVICIOS_GOOGLE[$nombre]
    Escribir-Paso "[$idx/4] Analizando $nombre ($hostG)..."

    $res = @{
        nombre   = $nombre
        host     = $hostG
        ip       = 'No resuelta'
        lat_tcp  = 9999
        jitter   = 0
        perdida  = 100
        est_lat  = 'SIN RESPUESTA'
        est_jit  = 'OK'
        est_perd = 'ALTA'
        puerto   = 'CERRADO/FILTRADO'
        ruta     = $null
    }

    $ipG = Resolver-IP $hostG
    if ($ipG) { $res.ip = $ipG }

    $tiemposTcp = Medir-LatenciaTCP $hostG $PUERTO_GOOGLE 5
    if ($tiemposTcp.Count -gt 0) {
        $avgTcp       = [math]::Floor(($tiemposTcp | Measure-Object -Sum).Sum / $tiemposTcp.Count)
        $res.lat_tcp  = $avgTcp
        $res.jitter   = Calcular-Jitter $tiemposTcp
        $res.perdida  = [math]::Round(((5 - $tiemposTcp.Count) / 5) * 100, 1)
        $res.est_lat  = if ($avgTcp -ge $GOOGLE_UMBRAL_ROJO) { 'SOBRE UMBRAL' } elseif ($avgTcp -ge $GOOGLE_UMBRAL_OK) { 'ELEVADO' } else { 'OK' }
        $res.est_jit  = if ($res.jitter -ge 30) { 'ALTO' } elseif ($res.jitter -ge 15) { 'ELEVADO' } else { 'OK' }
        $res.est_perd = if ($res.perdida -ge 3) { 'ALTA' } elseif ($res.perdida -ge 1) { 'LEVE' } else { 'OK' }
    }

    $res.puerto = Comprobar-Puerto $hostG $PUERTO_GOOGLE

    if ($res.ip -ne 'No resuelta') {
        Write-Host "    Rastreando ruta hacia $nombre..." -ForegroundColor DarkCyan
        $res.ruta = Procesar-Ruta $res.ip $MAX_SALTOS_GOOGLE $LIMITE_SEG_GOOGLE
    }

    $resultadosGoogle[$nombre] = $res
}

# ------------------------------------------------------------------
# Analisis SAP
# ------------------------------------------------------------------

Escribir-Paso 'Midiendo latencia, jitter y perdida hacia el servicio SAP...'
$tiemposSrv = Hacer-Pings $SERVER_IP 10
$srv = Evaluar-MetricasPing $tiemposSrv $umbralRojo $refMs

Escribir-Paso 'Comprobando puerto TCP SAP...'
$puertoSap = Comprobar-Puerto $SERVER_IP $SERVER_PORT

Escribir-Paso 'Rastreando ruta hacia SAP...'
$ruta = Procesar-Ruta $SERVER_IP $MAX_SALTOS $LIMITE_SEG

if ($srv.latencia -ge $umbralRojo -or $srv.perdida -ge 3 -or $puertoSap -ne 'ABIERTO') {
    $diagTxt = 'ALERTA CRITICA: La conexion al servicio SAP presenta problemas criticos o los puertos estan bloqueados.'
    $diagColor = 'Red'
} elseif ($srv.latencia -ge $umbralAmarillo -or $srv.jitter -ge 15 -or $srv.perdida -gt 0) {
    $diagTxt = 'ELEVADO: Fluctuaciones moderadas o latencia superior a lo esperado hacia el servicio SAP. Rendimiento irregular.'
    $diagColor = 'Yellow'
} else {
    $diagTxt = 'OPTIMO (OK): Parametros dentro de rangos ideales. Conectividad estable y fluida hacia el servicio SAP.'
    $diagColor = 'Green'
}

# ------------------------------------------------------------------
# Generacion del informe de texto
# ------------------------------------------------------------------

$sb = New-Object System.Text.StringBuilder
function L($t = '') { [void]$sb.AppendLine($t) }

L '=============='
L '***RESUMEN***'
L '=============='
L ''
L '  ---- UBICACION DETECTADA ----'
L "  Pais               : $($geo.pais)"
L "  Ciudad             : $($geo.ciudad)"
L "  Proveedor (ISP)    : $($geo.isp)"
L "  IP Publica         : $($geo.ip)"
L "  Referencia SAP     : $pais (latencia esperada $refMs ms)"
L ''
L '  ---- IDENTIFICACION DEL HOST ----'
L "  Nombre del Host    : $($datosHost.nombre)"
L "  Direccion MAC      : $($datosHost.mac)"
L "  IP Local           : $($datosHost.ip_local)"
L ''
L '  ---- ESTADO RED LOCAL (GATEWAY) ----'
if ($gwRes.latencia -ne 'SIN RESPUESTA') {
    L "  Gateway            : $(if ($gwRes.ip_gw) { $gwRes.ip_gw } else { 'N/D' })"
    L "  Latencia gateway   : $($gwRes.latencia)  [$($gwRes.est_gw)]"
    L "  Jitter gateway     : $($gwRes.jitter) ms"
    L "  Perdida gateway    : $($gwRes.perdida) %"
} else {
    L '  Gateway            : SIN RESPUESTA'
}
L ''
L '  ---- CONECTIVIDAD DE SALIDA ----'
L '  Puerto 443 (HTTPS) : Prueba de conexion saliente a internet'
L "  Resultado          : $puerto443Salida"
L '  (ABIERTO = el firewall permite trafico HTTPS hacia internet)'
L ''

# =====================
# SECCION GOOGLE
# =====================
L '=================================================='
L '***SERVICIOS GOOGLE***'
L '=================================================='
L ''

foreach ($nombre in $resultadosGoogle.Keys) {
    $res = $resultadosGoogle[$nombre]
    $sepNombre = $res.nombre.ToUpper()
    L "  ---- $sepNombre ----"
    L "  Host               : $($res.host)"
    L "  IP resuelta        : $($res.ip)"
    if ($res.lat_tcp -ne 9999) {
        L "  Latencia TCP(443)  : $($res.lat_tcp) ms  [$($res.est_lat)]"
        L "  Jitter TCP         : $($res.jitter) ms  [$($res.est_jit)]"
        L "  Perdida conexion   : $($res.perdida) %  [$($res.est_perd)]"
    } else {
        L '  Latencia TCP(443)  : SIN RESPUESTA'
    }
    L "  Puerto 443 (HTTPS) : $($res.puerto)"
    L ''
    if ($res.ruta -and $res.ruta.saltos.Count -gt 0) {
        L "  --- RESUMEN DE RUTA HACIA $sepNombre ---"
        foreach ($s in $res.ruta.saltos) {
            $ms = if ($s.ms -eq '-') { '   --  ' } else { ('{0,4} ms' -f $s.ms) }
            L ('  #{0,-3} {1}  {2}  ({3})' -f $s.num, $ms, $s.host, $s.categoria)
        }
        L ''
        L "  Ruta transatlantica: $($res.ruta.transatlantica)"
        L ''
        L "  --- REGISTRO CRUDO TRACEROUTE $sepNombre ---"
        L ''
        L $res.ruta.raw
        L ''
    } else {
        L "  Ruta               : No disponible"
        L ''
    }
}

# =====================
# SECCION SAP
# =====================
L '=================================================='
L '***SERVICIO SAP***'
L '=================================================='
L ''
L "  Servidor SAP       : $SAP_HOST"
L "  IP Destino         : $SERVER_IP (Puerto $SERVER_PORT)"
L "  Region detectada   : $region (Umbral: $umbralRojo ms)"
L ''
if ($srv.latencia -ne 9999) {
    L "  Latencia ICMP      : $($srv.latencia) ms  [$($srv.est_lat)]"
    L "  Jitter             : $($srv.jitter) ms  [$($srv.est_jit)]"
    L "  Perdida            : $($srv.perdida) %  [$($srv.est_perd)]"
} else {
    L '  Latencia ICMP      : SIN RESPUESTA'
}
L "  Puerto SAP ($SERVER_PORT)  : $puertoSap"
L ''
L '  ---- DIAGNOSTICO SAP ----'
L "  $diagTxt"
L ''
L '  --- IP RUTA TRANSATLANTICA ---'
L "  Detectada          : $($ruta.transatlantica)"
L ''
L '  --- RESUMEN DE RUTA SAP ---'
foreach ($s in $ruta.saltos) {
    $ms = if ($s.ms -eq '-') { '   --  ' } else { ('{0,4} ms' -f $s.ms) }
    L ('  #{0,-3} {1}  {2}  ({3})' -f $s.num, $ms, $s.host, $s.categoria)
}
L ''
L '  --- REGISTRO CRUDO DE TRACEROUTE SAP ---'
L ''
L $ruta.raw
L ''
L ''
L "  Diagnostico completado el $(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')."

$escritorio = [Environment]::GetFolderPath('Desktop')
$rutaInforme = Join-Path $escritorio $NOMBRE_INFORME
$guardado = $true
try {
    [System.IO.File]::WriteAllText($rutaInforme, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
} catch {
    $guardado = $false
    $errorGuardado = $_.Exception.Message
}

# ------------------------------------------------------------------
# Resumen en pantalla
# ------------------------------------------------------------------

function Color-Estado($e) { switch ($e) { 'OK' { 'Green' } { $_ -in 'ELEVADO', 'LEVE' } { 'Yellow' } default { 'Red' } } }

Write-Host ''
Write-Host '---------------- RESULTADOS ----------------' -ForegroundColor Cyan
Write-Host ("  Ubicacion : {0}, {1}  |  IP Publica: {2}" -f $geo.ciudad, $geo.pais, $geo.ip) -ForegroundColor Gray
Write-Host ("  Puerto 443 salida (HTTPS): {0}" -f $puerto443Salida) -ForegroundColor $(if ($puerto443Salida -eq 'ABIERTO') { 'Green' } else { 'Red' })
Write-Host ''
Write-Host '  [SERVICIOS GOOGLE]' -ForegroundColor Cyan
foreach ($nombre in $resultadosGoogle.Keys) {
    $res = $resultadosGoogle[$nombre]
    $latTxt = if ($res.lat_tcp -eq 9999) { 'Sin Resp.' } else { "$($res.lat_tcp) ms" }
    $col = Color-Estado $res.est_lat
    Write-Host ("  {0,-14}: Latencia TCP {1,-10}  Puerto 443: {2}" -f $res.nombre, $latTxt, $res.puerto) -ForegroundColor $col
}
Write-Host ''
Write-Host '  [SERVICIO SAP]' -ForegroundColor Cyan
$latTxtSap = if ($srv.latencia -eq 9999) { 'Sin Resp.' } else { "$($srv.latencia) ms" }
Write-Host ("  Latencia SAP ({0} ms umbral): {1}" -f $umbralRojo, $latTxtSap) -ForegroundColor (Color-Estado $srv.est_lat)
Write-Host ("  Jitter           : {0} ms" -f $srv.jitter) -ForegroundColor (Color-Estado $srv.est_jit)
Write-Host ("  Perdida paquetes : {0} %" -f $srv.perdida) -ForegroundColor (Color-Estado $srv.est_perd)
Write-Host ("  Puerto SAP       : {0}" -f $puertoSap) -ForegroundColor $(if ($puertoSap -eq 'ABIERTO') { 'Green' } else { 'Red' })
Write-Host ''
Write-Host "  $diagTxt" -ForegroundColor $diagColor
Write-Host ''
if ($guardado) {
    Write-Host "Informe guardado en: $rutaInforme" -ForegroundColor Green
} else {
    Write-Host "No se pudo guardar el informe: $errorGuardado" -ForegroundColor Red
}
Write-Host ''
Read-Host 'Presione ENTER para cerrar'
