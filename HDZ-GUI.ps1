#requires -Version 7.0
# =========================================================================
# HDZ STUDIO — interfaz adaptativa para HDZnew.ps1 (WPF, tema oscuro)
# =========================================================================
# Al seleccionar la carpeta, ANALIZA los vídeos con ffprobe en segundo plano
# (códec, resolución, HDR/Dolby Vision, parejas híbridas, DTS, pistas sin
# idioma, PGS, idiomas de subtítulos, ambigüedades) y adapta cada tarjeta:
#  - desactiva las opciones sin efecto en ese lote (con el motivo),
#  - anota cada opción con lo detectado (contadores, archivos),
#  - sugiere título / año / serie a partir de los nombres de archivo,
#  - muestra los idiomas de subtítulos REALES para el filtro personalizado.
#
# La GUI decide TODAS las opciones: el montaje corre sin preguntar nada por
# consola. Ejecútala con doble clic en "HDZ Studio.cmd".
# =========================================================================

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "HDZ-Core.ps1")
. (Join-Path $PSScriptRoot "HDZ-Async.ps1")
. (Join-Path $PSScriptRoot "HDZ-History.ps1")
. (Join-Path $PSScriptRoot "HDZ-Jobs.ps1")
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms   # solo para el diálogo de carpeta

# Herramientas portables incluidas: si existe la carpeta bin\ junto al script, la anteponemos
# al PATH para que el programa use SIEMPRE esas versiones (probadas) en vez de las del sistema
# (resuelve "no está en el PATH" y "versiones antiguas"). Si no hay bin\, se usa el PATH normal.
$rutaBin = Join-Path $PSScriptRoot "bin"
if ((Test-Path -LiteralPath $rutaBin) -and ($env:PATH -notlike "*$rutaBin*")) { $env:PATH = "$rutaBin;$env:PATH" }

# Versión instalada (marcador en VERSION.txt; respaldo si no existe) y memoria de la versión
# que el usuario ya descartó actualizar (para no volver a avisarle de la MISMA).
$script:HDZVersion = "1.0.0"
try { $script:HDZVersion = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION.txt'))).Trim() } catch {}
$script:agSession = [guid]::NewGuid().ToString('N')
$script:agCompleted = [ordered]@{}
$script:ajusteVerDescartada = ""
$script:bienvenidaVista = $false   # ¿ya se mostró la ventana de bienvenida (primer arranque)?

$rutaScript  = Join-Path $PSScriptRoot "HDZnew.ps1"
$rutaTorrentMod = Join-Path $PSScriptRoot "HDZ-Torrent.ps1"
$rutaAjustes = Join-Path $env:APPDATA "HDZ-GUI.settings.json"
$rutaMemTorrents = Join-Path $env:APPDATA "HDZ-GUI.torrents.json"   # memoria de torrents pendientes
$script:modoTest = ($env:HDZ_GUI_TEST -eq "1")

# --- Sin privilegios de administrador --------------------------------------
# El programa NO necesita permisos de administrador. Si se ha lanzado elevado (p. ej. el
# auto-arranque justo tras instalar, que hereda el token del instalador), Windows OCULTA las
# unidades de red mapeadas a los procesos elevados → no se podrían elegir discos en red en los
# diálogos de archivo. Por eso, si detectamos elevación, nos relanzamos SIN elevar (vía el
# .vbs lanzado por el Explorador, que corre con el token normal del usuario) y cerramos esta
# instancia. Red de seguridad: si el relanzamiento no es posible, seguimos en marcha igualmente.
if (-not $script:modoTest) {
    try {
        $idActual = [Security.Principal.WindowsIdentity]::GetCurrent()
        $prActual = New-Object Security.Principal.WindowsPrincipal($idActual)
        if ($prActual.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
            $vbsLanz = Join-Path $PSScriptRoot "HDZ Studio.vbs"
            # Guarda anti-bucle: si ya intentamos de-elevar hace muy poco (caso raro de Explorador
            # también elevado), no reintentamos en bucle; seguimos abiertos aunque sea con privilegios.
            $flag = Join-Path $env:TEMP "hdz_deelev.flag"
            $reciente = (Test-Path -LiteralPath $flag) -and (((Get-Date) - (Get-Item -LiteralPath $flag).LastWriteTime).TotalSeconds -lt 25)
            if (-not $reciente -and (Test-Path -LiteralPath $vbsLanz)) {
                Set-Content -LiteralPath $flag -Value (Get-Date).Ticks -Encoding ASCII
                Start-Process "explorer.exe" -ArgumentList ('"' + $vbsLanz + '"')
                exit
            }
        }
    } catch {}
}

# Instancia única por sesión de Windows. Dos ventanas del programa podían enviar estados distintos
# al mismo panel remoto y el móvil alternaba entre ambas aunque el relay siguiera conectado.
# La primera instancia posee el mutex; cualquier intento posterior muestra el aviso y termina antes
# de inicializar la GUI, el agente o los trabajos de fondo.
$script:mutexInstancia = $null
if (-not $script:modoTest) {
    $mutexNueva = $false
    try {
        $script:mutexInstancia = [System.Threading.Mutex]::new($true, "Global\HDZStudio.InstanciaUnica", [ref]$mutexNueva)
        if (-not $mutexNueva) {
            [System.Windows.MessageBox]::Show(
                "HDZ Studio ya está abierto. Usa la ventana existente; no se abrirá una segunda instancia.",
                "HDZ Studio",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
            exit
        }
    } catch {
        # Si Windows no pudiera crear el mutex, no impedimos abrir el programa por un fallo del aviso.
        try { if ($script:mutexInstancia) { $script:mutexInstancia.Dispose() } } catch {}
        throw 'No se pudo garantizar una instancia única de HDZ Studio. Cierra la otra sesión o revisa permisos.'
    }
}

# Módulo compartido de creación de torrents (lo usa también HDZnew.ps1)
if (Test-Path -LiteralPath $rutaTorrentMod) { . $rutaTorrentMod }

# =========================================================================
# LOG POR PROYECTO — un archivo por CARPETA DE TRABAJO que acumula TODO el flujo
# (escaneo, identificación, audio/subs, montaje, capturas, torrent, imágenes y subida).
# Se guarda SIEMPRE fuera de la carpeta de instalación. En instalaciones bajo Program Files un
# usuario normal no puede crear "logs\" y, con ErrorActionPreference=Stop, ese intento podía acabar
# cerrando la interfaz durante un escaneo. AppData es la ubicación escribible correcta; TEMP queda
# como último respaldo. Las credenciales (token, passkey, contraseñas y claves) se CENSURAN.
# =========================================================================
$script:logRuta = $null
$script:logCarpeta = $null
$script:montajeInicio = $null
# COLA de montajes: si pulsas «Iniciar» mientras hay uno en marcha, el nuevo trabajo se guarda
# aquí y se lanza automáticamente al terminar el actual (uno tras otro, NUNCA en paralelo, para no
# colisionar en los temporales de la fusión DV ni en los .mkv de salida). Cada entrada es el job
# ya preparado (config + launcher escritos) listo para arrancar.
$script:colaMontaje = @()
$script:procMontaje = $null
# Películas (grupos) YA lanzadas/encoladas en esta tanda (clave = nombre del archivo principal). Evita
# encolar dos veces la misma cuando usas «Iniciar todas» tras haber lanzado alguna individual. Se
# resetea al reanalizar/cambiar de carpeta o de modo (nuevo conjunto de películas).
$script:gruposLanzados = @{}

function Get-DirLogs {
    $candidatos = @(
        $(if ($env:APPDATA)      { Join-Path $env:APPDATA      "HD ZERO Studio\logs" }),
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "HD ZERO Studio\logs" }),
        $(if ($env:TEMP)         { Join-Path $env:TEMP         "HD ZERO Studio\logs" })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") }

    foreach ($d in $candidatos) {
        try {
            [void][System.IO.Directory]::CreateDirectory($d)
            $probe = Join-Path $d ".w_$PID.tmp"
            [System.IO.File]::WriteAllText($probe, "1")
            [System.IO.File]::Delete($probe)
            return $d
        } catch {}
    }
    # Caso extremo: las escrituras que usan esta ruta ya están protegidas con try/catch.
    return $env:TEMP
}

# Log de DIAGNÓSTICO de las pestañas de subida: registra cada cambio de pestaña, cada comando del
# control web que toque un campo, y qué se envía al subir — con el contexto de la pestaña activa
# (título + torrent). Persiste en logs\diag_subidas.log para poder reconstruir con CERTEZA qué pasó
# si una pestaña vuelve a cruzarse. Es texto pequeño; se recorta si supera ~1 MB.
function Log-DiagSubida($msg) {
    try {
        $f = Join-Path (Get-DirLogs) "diag_subidas.log"
        try { if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 1MB) { $cola = Get-Content -LiteralPath $f -Tail 1500 -ErrorAction SilentlyContinue; Set-Content -LiteralPath $f -Value $cola -Encoding UTF8 } } catch {}
        Add-Content -LiteralPath $f -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), (Redacta-Log "$msg")) -Encoding UTF8
    } catch {}
}
# Contexto compacto de la pestaña de subida activa (índice, título, torrent) para las líneas de diag.
function Ctx-SubidaActiva {
    $n = @($script:tabs).Count
    if ($script:tabActual -lt 0 -or $script:tabActual -ge $n) { return "activa=$($script:tabActual)/$n (sin pestaña)" }
    $tit = "$($ui.upTitulo.Text)"
    $torR = "$($ui.txtTorrentSubir.Text)".Trim()
    $tor = if ($torR) { Split-Path $torR -Leaf } else { "(sin torrent)" }
    return "activa=$($script:tabActual)/$n titulo='$tit' torrent='$tor'"
}

# Censura cualquier secreto del usuario que aparezca en el texto a registrar.
function Redacta-Log($texto) {
    $t = "$texto"
    if ($ui) {
        $secretos = @(
            "$($ui.cfgTrackerToken.Text)".Trim(),
            "$($ui.txtAnnounce.Text)".Trim(),
            "$($ui.cfgImgbbKey.Text)".Trim(),
            $(if ($ui.cfgImgboxPass) { "$($ui.cfgImgboxPass.Password)" } else { "" })
        )
        foreach ($s in $secretos) { if ($s -and $s.Length -ge 6) { $t = $t.Replace($s, "[CENSURADO]") } }
    }
    $t = $t -replace '(?i)(passkey=)[A-Za-z0-9]+', '${1}[CENSURADO]'
    $t = $t -replace '(?i)(api_token=)[A-Za-z0-9\-_\.]+', '${1}[CENSURADO]'
    $t = $t -replace '(?i)(/announce/)[A-Za-z0-9]{8,}', '${1}[CENSURADO]'
    $t = $t -replace '(?i)(/torrent/download/\d+\.)[^\s"<>]+', '${1}[CENSURADO]'
    $t = $t -replace '(?i)((?:api_key|rsskey|token|password|key)=)[^&\s]+', '${1}[CENSURADO]'
    return $t
}

# Fija (o reutiliza) el log de la carpeta de trabajo dada. Mismo proyecto -> mismo archivo.
function Iniciar-LogProyecto($carpeta) {
    if ($script:modoTest) { return }
    $carpeta = "$carpeta".Trim()
    if ([string]::IsNullOrWhiteSpace($carpeta)) { return }
    if ($script:logCarpeta -eq $carpeta -and $script:logRuta) { return }
    try {
        $leaf = (Split-Path $carpeta -Leaf) -replace '[^\w\.\-]', '_'; if (-not $leaf) { $leaf = "proyecto" }
        $bytes = [System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($carpeta.ToLower()))
        $hash = (($bytes[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
        $script:logRuta = Join-Path (Get-DirLogs) ("proyecto_${leaf}_${hash}.log")
        $script:logCarpeta = $carpeta
        $nueva = -not (Test-Path -LiteralPath $script:logRuta)
        $ver = try { (Get-Content -LiteralPath (Join-Path $PSScriptRoot "VERSION.txt") -Raw -ErrorAction Stop).Trim() } catch { "$($script:HDZVersion)" }
        $sep = "==================================================================="
        $cab = @()
        if ($nueva) {
            $cab += $sep; $cab += " HD ZERO Studio · LOG DE PROYECTO"; $cab += " Carpeta: $carpeta"; $cab += $sep
        }
        $cab += ""; $cab += $sep
        $cab += " NUEVA SESIÓN · $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') · v$ver"
        $cab += $sep
        Add-Content -LiteralPath $script:logRuta -Value ($cab -join "`r`n") -Encoding UTF8
    } catch {}
}

function Log-Linea($msg) {
    if ($script:modoTest -or -not $script:logRuta) { return }
    Rotate-HdzLog $script:logRuta
    try { Add-Content -LiteralPath $script:logRuta -Value ("[$(Get-Date -Format 'HH:mm:ss')] " + (Redacta-Log $msg)) -Encoding UTF8 } catch {}
}
function Log-Sec($titulo) {
    if ($script:modoTest -or -not $script:logRuta) { return }
    try { Add-Content -LiteralPath $script:logRuta -Value ("`r`n----- " + (Redacta-Log $titulo) + " -----") -Encoding UTF8 } catch {}
}
function Log-Bloque($titulo, $texto) {
    Log-Sec $titulo
    if ($script:modoTest -or -not $script:logRuta) { return }
    Rotate-HdzLog $script:logRuta
    try { Add-Content -LiteralPath $script:logRuta -Value (Redacta-Log "$texto") -Encoding UTF8 } catch {}
}

# Resumen del escaneo (vídeos detectados con sus pistas de audio/subtítulos).
function Log-Escaneo($carpeta, $res) {
    if ($script:modoTest) { return }
    Iniciar-LogProyecto $carpeta
    Log-Sec "ESCANEO · $(@($res).Count) vídeo(s) en la carpeta"
    foreach ($f in @($res)) {
        Log-Linea "• $($f.Nombre)"
        foreach ($a in @($f.Audios)) {
            $ln = "    audio: $($a.Codec) | $($a.Lang) | $($a.Channels)ch"
            if ($a.Forced) { $ln += " | forced" }
            if ($a.Title)  { $ln += " | titulo: $($a.Title)" }
            Log-Linea $ln
        }
        foreach ($s in @($f.Subs)) {
            $ln = "    sub:   $($s.Codec) | $($s.Lang)"
            if ($s.Forced) { $ln += " | forced" }
            if ($s.Title)  { $ln += " | titulo: $($s.Title)" }
            Log-Linea $ln
        }
    }
}

# Anexa al log de proyecto el log detallado que generó el MOTOR (HDZnew.ps1) en este montaje.
function Anexar-LogMontaje($carpeta) {
    if ($script:modoTest -or -not $script:logRuta) { return }
    try {
        $desde = if ($script:montajeInicio) { $script:montajeInicio.AddSeconds(-5) } else { (Get-Date).AddHours(-6) }
        $dirs = @((Join-Path $PSScriptRoot "logs"), "$carpeta", (Join-Path $env:APPDATA "HD ZERO Studio\logs"))
        $cands = @()
        foreach ($d in $dirs) {
            if ($d -and (Test-Path -LiteralPath $d)) {
                $cands += @(Get-ChildItem -LiteralPath $d -File -Filter "hdz_montaje_*.log" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $desde })
            }
        }
        $log = $cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log) {
            Log-Sec "MONTAJE · log del motor ($($log.Name))"
            Add-Content -LiteralPath $script:logRuta -Value (Get-Content -LiteralPath $log.FullName -Raw -Encoding UTF8) -Encoding UTF8
        } else {
            Log-Linea "(no se encontró el log del motor para anexar)"
        }
    } catch {}
}

# --- Envío del log a soporte (vía relay propio; el token de Telegram vive SOLO en el servidor) ---
# La URL del relay y la clave compartida NO van en el código (este archivo es público en GitHub):
# se leen de "soporte.cfg", que viaja DENTRO del exe pero NO se publica en el repo. Si el archivo
# no está (p. ej. instalación que aún no lo trae), el botón queda "no configurado".
$script:soporteUrl = ""
$script:soporteKey = ""
$script:agentUrl   = ""   # URL del agente de control remoto (solo si tu soporte.cfg la trae; opt-in)
# Lee soporte.cfg desde la carpeta del programa o, si no, desde %APPDATA% (ahí lo deja la descarga
# silenciosa cuando un usuario migra al canal de actualización propio).
function Cargar-SoporteCfg {
    # Lee AMBOS ficheros (carpeta del programa y %APPDATA%) y toma cada campo del PRIMERO que lo traiga.
    # Sin 'return' temprano: así, si un soporte.cfg trae url+key pero NO 'agent', el 'agent' del otro
    # (p. ej. %APPDATA%) sí se recoge. Antes se cortaba en el primero y se perdía la URL del agente.
    $dbg = Join-Path $env:TEMP "hdz_agente.log"
    foreach ($p in @((Join-Path $env:APPDATA "HDZ-soporte.cfg"), (Join-Path $PSScriptRoot "soporte.cfg"))) {
        try {
            if (Test-Path -LiteralPath $p) {
                $sop = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
                if ("$($sop.key)".Length -lt 16) { continue }
                $script:soporteUrl = "$($sop.url)".Trim()
                $script:soporteKey = "$($sop.key)".Trim()
                $script:agentUrl = "$($sop.agent)".Trim()
                try { "[$(Get-Date -f 'HH:mm:ss')] cfg '$p': url=$([bool]$sop.url) key=$([bool]$sop.key) agent=$([bool]$sop.agent)" | Out-File $dbg -Append -Encoding UTF8 } catch {}
                return # Una identidad completa; nunca mezclar campos de equipos distintos.
            }
        } catch {}
    }
}
Cargar-SoporteCfg

function Get-UltimoLog {
    if ($script:logRuta -and (Test-Path -LiteralPath $script:logRuta)) { return $script:logRuta }
    try {
        $f = Get-ChildItem -LiteralPath (Get-DirLogs) -File -Filter "proyecto_*.log" -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($f) { return $f.FullName }
    } catch {}
    return $null
}

function Enviar-LogSoporte {
    param([switch]$ConfirmadoRemoto)
    if ([string]::IsNullOrWhiteSpace($script:soporteUrl)) { Cargar-SoporteCfg }
    if ([string]::IsNullOrWhiteSpace($script:soporteUrl)) {
        Set-Estado "El envío de logs a soporte aún no está configurado." "warn"; return
    }
    $log = Get-UltimoLog
    if (-not $log) { Set-Estado "Todavía no hay ningún log que enviar (procesa o sube algo primero)." "warn"; return }
    $proyecto = if ($script:logCarpeta) { Split-Path $script:logCarpeta -Leaf } else { [System.IO.Path]::GetFileNameWithoutExtension($log) }
    $confirm = if ($ConfirmadoRemoto) { $true } else { Show-DialogoHDZ -Owner $win -Icono "📤" -Titulo "Enviar log a soporte" `
        -Mensaje "Se enviará el log del proyecto «$proyecto» al soporte para diagnóstico.`n`nLas claves (token, passkey, contraseña) van censuradas en el log. ¿Enviar?" `
        -BotonSi "Enviar" -BotonNo "Cancelar" }
    if (-not $confirm) { return }
    $sanitizedLog = Join-Path $env:TEMP ('hdz_support_' + [guid]::NewGuid().ToString('N') + '.log')
    try {
        $safeText = Redacta-Log ([IO.File]::ReadAllText($log))
        # También se censuran logs de versiones antiguas justo antes de enviarlos.
        if ([Text.Encoding]::UTF8.GetByteCount($safeText) -gt 7MB) {
            $safeText = "[Diagnóstico reducido a las últimas líneas por tamaño]`r`n" + ($safeText.Substring([math]::Max(0,$safeText.Length-1500000)))
        }
        [IO.File]::WriteAllText($sanitizedLog,$safeText,[Text.UTF8Encoding]::new($false))
        $ver = try { (Get-Content -LiteralPath (Join-Path $PSScriptRoot "VERSION.txt") -Raw -ErrorAction Stop).Trim() } catch { "$($script:HDZVersion)" }
        $usuario = if ($ui.cfgUsuarioSoporte) { "$($ui.cfgUsuarioSoporte.Text)".Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($usuario)) { $usuario = "(sin alias)" }
        $form = @{
            log      = Get-Item -LiteralPath $sanitizedLog
            proyecto = "$proyecto"
            usuario  = "$usuario"
            equipo   = "$env:COMPUTERNAME / $env:USERNAME"
            version  = "$ver"
        }
        $headers = @{ Accept = "text/plain" }
        if ($script:soporteKey) { $headers["X-HDZ-Key"] = $script:soporteKey }
        Set-Estado "Enviando log a soporte…"
        if ($ui.btnEnviarLog) { $ui.btnEnviarLog.IsEnabled = $false }
        [void](Invoke-HdzRestMethod -Uri $script:soporteUrl -Method Post -Form $form -Headers $headers -TimeoutSec 60)
        Set-Estado "✓  Log enviado a soporte. ¡Gracias!" "ok"
    } catch {
        $det = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $det = $_.ErrorDetails.Message }
        Set-Estado "No se pudo enviar el log: $det" "error"
    } finally {
        if ($ui.btnEnviarLog) { $ui.btnEnviarLog.IsEnabled = $true }
        if (Test-Path -LiteralPath $sanitizedLog) { Remove-Item -LiteralPath $sanitizedLog -Force }
    }
}

# =========================================================================
# CATÁLOGOS Y NORMALIZACIÓN DE IDIOMAS (espejo de Get-LanguageCode del script)
# =========================================================================
$idiomasFiltro = @(
    @{Cod="es";     Nom="Castellano"},
    @{Cod="es-419"; Nom="Latino"},
    @{Cod="eng";    Nom="Inglés"},
    @{Cod="cat";    Nom="Catalán"},
    @{Cod="glg";    Nom="Gallego"},
    @{Cod="eus";    Nom="Euskera"},
    @{Cod="fre";    Nom="Francés"},
    @{Cod="ger";    Nom="Alemán"},
    @{Cod="ita";    Nom="Italiano"},
    @{Cod="por";    Nom="Portugués"},
    @{Cod="jpn";    Nom="Japonés"},
    @{Cod="chi";    Nom="Chino"},
    @{Cod="kor";    Nom="Coreano"},
    @{Cod="tha";    Nom="Tailandés"},
    @{Cod="rus";    Nom="Ruso"},
    @{Cod="nld";    Nom="Neerlandés"},
    @{Cod="ara";    Nom="Árabe"},
    @{Cod="pol";    Nom="Polaco"},
    @{Cod="hin";    Nom="Hindi"},
    @{Cod="tur";    Nom="Turco"},
    @{Cod="ell";    Nom="Griego"},
    @{Cod="ukr";    Nom="Ucraniano"},
    @{Cod="swe";    Nom="Sueco"},
    @{Cod="dan";    Nom="Danés"},
    @{Cod="nor";    Nom="Noruego"},
    @{Cod="fin";    Nom="Finés"},
    @{Cod="heb";    Nom="Hebreo"}
)
$nombresIdioma = @{
    "es"="Castellano"; "es-419"="Latino"; "eng"="Inglés"; "fre"="Francés"; "ger"="Alemán"
    "ita"="Italiano"; "por"="Portugués"; "jpn"="Japonés"; "chi"="Chino"; "kor"="Coreano"
    "tha"="Tailandés"; "cat"="Catalán"; "glg"="Gallego"; "eus"="Euskera"; "und"="Indeterminado"
}
foreach ($idioma in $idiomasFiltro) { $nombresIdioma[$idioma.Cod] = $idioma.Nom }
function NombreIdioma($cod) { if ($nombresIdioma.ContainsKey("$cod")) { $nombresIdioma["$cod"] } else { "$cod" } }

function ConvCanon($lang, $title = "") {
    $l = Convert-HdzLanguage "$lang"
    if ([string]::IsNullOrWhiteSpace($l) -or $l -eq "und") { return "und" }
    if ($l -match "^es-(419|mx|ar|co|cl|pe|ve|la|us)$" -or $l -eq "lat") { return "es-419" }
    if ($l -in @("es", "spa", "cas") -or $l -match "^es-") {
        if ("$title" -match "(?i)latino|latinoam|latam|hispanoam") { return "es-419" }
        return "es"
    }
    if ($l -in @("en", "eng") -or $l -match "^en-") { return "eng" }
    if ($l -in @("fr", "fra", "fre") -or $l -match "^fr-") { return "fre" }
    if ($l -in @("de", "ger", "deu") -or $l -match "^de-") { return "ger" }
    if ($l -in @("it", "ita")) { return "ita" }
    if ($l -in @("pt", "por") -or $l -match "^pt-") { return "por" }
    if ($l -in @("ja", "jpn", "jp")) { return "jpn" }
    if ($l -in @("zh", "chi", "zho", "cmn") -or $l -match "^zh-") { return "chi" }
    if ($l -in @("ko", "kor")) { return "kor" }
    if ($l -in @("th", "tha") -or $l -match "^th-") { return "tha" }
    if ($l -in @("ca", "cat")) { return "cat" }
    if ($l -in @("gl", "glg")) { return "glg" }
    if ($l -in @("eu", "eus", "baq")) { return "eus" }
    return $l
}

$script:idiomasManuales = @{}
function Get-IdiomaPistaGui($pista, $tipo) {
    $id = if ($null -ne $pista.TrackId) { $pista.TrackId } else { $pista.Index }
    $clave = "$($pista.Ruta)|$id|$tipo"
    if ($script:idiomasManuales.ContainsKey($clave)) { return ConvCanon $script:idiomasManuales[$clave] "" }
    return ConvCanon $pista.Lang $pista.Title
}
$opcionesIdiomaUnd = @(@{T="Automático (idioma del archivo)"; V="AUTO"}, @{T="Indeterminado (und)"; V="und"}) +
                     @($idiomasFiltro | ForEach-Object { @{T="$($_.Nom)  ·  $($_.Cod)"; V=$_.Cod} })
$codigosSelector = @($opcionesIdiomaUnd | ForEach-Object { $_.V })
foreach ($culture in [Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::NeutralCultures) | Sort-Object DisplayName) {
    if (-not $culture.Name -or $culture.ThreeLetterISOLanguageName -eq 'ivl') { continue }
    $codigo = ConvCanon $culture.ThreeLetterISOLanguageName ''
    if ($codigo -in $codigosSelector) { continue }
    $opcionesIdiomaUnd += @{ T = "$($culture.DisplayName) · $codigo"; V = $codigo }
    $codigosSelector += $codigo
    if (-not $nombresIdioma.ContainsKey($codigo)) { $nombresIdioma[$codigo] = $culture.DisplayName }
}

$plataformasGui = @("NF — Netflix","AMZN — Amazon Prime","DSNP — Disney+","MVSTP — Movistar+",
    "SKST — SkyShowtime","FLMN — Filmin","ATVP — Apple TV+","iT — iTunes","HMAX — HBO Max",
    "RTVP — RTVE Play","RKTN — Rakuten")
$formatosGui = @("UHDFull","BDFull","UHDRemux","BDRemux","UHDRip","BDRip","MHD","Remastered")

# Mismo normalizador de agrupación que usa HDZnew.ps1 para detectar parejas híbridas
$normalizadorAgrupacion = '(?i)[\._\s\-\(\)]+(Dolby[\._\s\-]Vision|DolbyVision|HDR10\+|HDR10|HDR|DV|2160p|1080p|UHD|WEB[\._\s\-]?DL|Apple[\._\s\-]?TV|iTunes|Disney\+?|Atmos|TrueHD|DTS[\._\s\-]?HD[\._\s\-]?MA|DTS[\._\s\-]?HD|DTS[\._\s\-]?X|DTS|E[\._\s\-]?AC[\._\s\-]?3|EAC3|AC3|DDP\+?|DD\+|DDP|DD|AAC|FLAC|MA|HRA)(?=[\._\s\-\(\)]|$)'

# =========================================================================
# XAML
# =========================================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HDZ Studio" Width="1200" Height="820" MinWidth="960" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#0C0C0F"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True"
        SnapsToDevicePixels="True" AllowDrop="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>

    <SolidColorBrush x:Key="BgBrush"          Color="#101318"/>
    <SolidColorBrush x:Key="SidebarBrush"     Color="#0B0E12"/>
    <SolidColorBrush x:Key="CardBrush"        Color="#181D24"/>
    <SolidColorBrush x:Key="CardBorderBrush"  Color="#303844"/>
    <SolidColorBrush x:Key="FieldBrush"       Color="#11161D"/>
    <SolidColorBrush x:Key="FieldBorderBrush" Color="#36404D"/>
    <SolidColorBrush x:Key="ChipBrush"        Color="#222A34"/>
    <SolidColorBrush x:Key="ChipBorderBrush"  Color="#36404D"/>
    <SolidColorBrush x:Key="TextBrush"        Color="#EDEDEF"/>
    <SolidColorBrush x:Key="SubBrush"         Color="#ABB7C6"/>
    <SolidColorBrush x:Key="MutedBrush"       Color="#8491A2"/>
    <SolidColorBrush x:Key="AccentBrush"      Color="#D92B2B"/>
    <SolidColorBrush x:Key="AccentHoverBrush" Color="#EF4444"/>
    <SolidColorBrush x:Key="OkBrush"          Color="#86D97C"/>
    <SolidColorBrush x:Key="WarnBrush"        Color="#F2C94C"/>
    <SolidColorBrush x:Key="ErrBrush"         Color="#FF6B81"/>
    <!-- Derivados de la MISMA paleta: degradados para dar profundidad sin salirse de la gama.
         (Sin DropShadow en tarjetas: en WPF un Effect rasteriza el contenido y emborrona el texto.) -->
    <LinearGradientBrush x:Key="CardBgGrad" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#17171C" Offset="0"/><GradientStop Color="#101014" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="CardBorderGrad" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#2C2C34" Offset="0"/><GradientStop Color="#1F1F25" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="AccentGrad" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#EF4444" Offset="0"/><GradientStop Color="#D92B2B" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="AccentGradHover" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#F75B5B" Offset="0"/><GradientStop Color="#E23838" Offset="1"/>
    </LinearGradientBrush>
    <SolidColorBrush x:Key="AccentSoftBrush"  Color="#271013"/>
    <SolidColorBrush x:Key="HoverBgBrush"     Color="#1F1F26"/>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="9"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand">
                    <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Rectangle Fill="Transparent"/></ControlTemplate></RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand">
                    <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Rectangle Fill="Transparent"/></ControlTemplate></RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border x:Name="tb" Background="#3A3A42" CornerRadius="4" Margin="2,1"/>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="tb" Property="Background" Value="#56565E"/></Trigger>
                          <Trigger Property="IsDragging" Value="True"><Setter TargetName="tb" Property="Background" Value="{StaticResource AccentBrush}"/></Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource CardBgGrad}"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardBorderGrad}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="13"/>
      <Setter Property="Padding" Value="18,15"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>

    <!-- Barras de progreso: pista y relleno redondeados (sin el marco cuadrado por defecto de WPF) -->
    <Style TargetType="ProgressBar">
      <Setter Property="Background" Value="#26262C"/>
      <Setter Property="Foreground" Value="{StaticResource AccentGrad}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="4"/>
              <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="4" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="H" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="FontSize" Value="14.5"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="D" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource SubBrush}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,3,0,0"/>
    </Style>
    <Style x:Key="Lbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#B4B4BE"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,12,0,5"/>
    </Style>
    <Style x:Key="Bdg" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="TextAlignment" Value="Right"/>
      <Setter Property="MaxWidth" Value="340"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="12,0,0,0"/>
    </Style>

    <Style x:Key="Chip" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#C8C8CE"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" Background="{StaticResource ChipBrush}" BorderBrush="{StaticResource ChipBorderBrush}"
                    BorderThickness="1" CornerRadius="16" Padding="14,6.5">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentSoftBrush}"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                <Setter Property="Foreground" Value="White"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ChipToggle" TargetType="ToggleButton">
      <Setter Property="Foreground" Value="#C8C8CE"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="bd" Background="{StaticResource ChipBrush}" BorderBrush="{StaticResource ChipBorderBrush}"
                    BorderThickness="1" CornerRadius="16" Padding="14,6.5">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentSoftBrush}"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                <Setter Property="Foreground" Value="White"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Grid Width="42" Height="23" VerticalAlignment="Center">
                <Border x:Name="track" CornerRadius="11.5" Background="#2E2E35"/>
                <Ellipse x:Name="thumb" Width="15" Height="15" Fill="#9C9CA8" HorizontalAlignment="Left" Margin="4,0,0,0"/>
              </Grid>
              <ContentPresenter Margin="11,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="thumb" Property="Fill" Value="White"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="thumb" Property="Margin" Value="0,0,4,0"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="track" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="Background" Value="{StaticResource FieldBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource FieldBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#56565E"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ComboItem" TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#C8C8CE"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="bd" Background="Transparent" CornerRadius="6" Margin="4,1" Padding="10,7">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A2A30"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentBrush}"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Combo" TargetType="ComboBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource ComboItem}"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="bd" Background="{StaticResource FieldBrush}" BorderBrush="{StaticResource FieldBorderBrush}"
                      BorderThickness="1" CornerRadius="8"/>
              <ToggleButton ClickMode="Press" Focusable="False" Background="Transparent"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton"><Border Background="Transparent"/></ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Margin="12,7,32,7" VerticalAlignment="Center" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                TextElement.Foreground="{StaticResource TextBrush}"/>
              <Path Data="M0,0 L4.5,4.5 L9,0" Stroke="#9C9CA8" StrokeThickness="1.6" StrokeLineJoin="Round"
                    HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,1,13,0" IsHitTestVisible="False"/>
              <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom"
                     AllowsTransparency="True" PopupAnimation="Slide" Focusable="False">
                <Border Background="#18181C" BorderBrush="#33333A" BorderThickness="1" CornerRadius="8"
                        Margin="0,5,0,8" Padding="0,4" MaxHeight="300"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                  <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="3" Opacity="0.45" Color="#000000"/></Border.Effect>
                  <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#56565E"/>
              </Trigger>
              <Trigger Property="IsDropDownOpen" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#A8A8B2"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="13,10"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" CornerRadius="9" Background="Transparent" Padding="{TemplateBinding Padding}" Margin="0,2">
              <Grid>
                <Rectangle x:Name="ind" Width="3" RadiusX="1.5" RadiusY="1.5" Fill="{StaticResource AccentBrush}"
                           HorizontalAlignment="Left" Margin="-7,2,0,2" Visibility="Collapsed"/>
                <ContentPresenter VerticalAlignment="Center"
                                  HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#15151A"/>
                <Setter Property="Foreground" Value="#D8D8DE"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentSoftBrush}"/>
                <Setter TargetName="ind" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="White"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{StaticResource AccentGrad}" CornerRadius="10" Padding="26,12"
                    BorderBrush="#F25555" BorderThickness="0,1,0,0">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentGradHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#A81E1E"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Variante compacta del botón rojo (mismo color, menos relleno) -->
    <Style x:Key="PrimarySmall" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{StaticResource AccentGrad}" CornerRadius="8" Padding="15,8"
                    BorderBrush="#F25555" BorderThickness="0,1,0,0">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentGradHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#A81E1E"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Foreground" Value="#C8C8CE"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{StaticResource ChipBrush}" BorderBrush="{StaticResource ChipBorderBrush}"
                    BorderThickness="1" CornerRadius="8" Padding="16,8">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="bd" Property="Background" Value="{StaticResource HoverBgBrush}"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentSoftBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostMini" TargetType="Button">
      <Setter Property="Foreground" Value="#C8C8CE"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="MinHeight" Value="36"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{StaticResource ChipBrush}" BorderBrush="{StaticResource ChipBorderBrush}"
                    BorderThickness="1" CornerRadius="6" Padding="11,4">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="bd" Property="Background" Value="{StaticResource HoverBgBrush}"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentSoftBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Botón-icono cuadrado para la barra BBCode -->
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#C8C8CE"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Width" Value="32"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{StaticResource ChipBrush}" BorderBrush="{StaticResource ChipBorderBrush}"
                    BorderThickness="1" CornerRadius="6">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Casilla de selección de archivo (lista de análisis) -->
    <Style x:Key="Check" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="17" Height="17" CornerRadius="4" VerticalAlignment="Center"
                      Background="{StaticResource FieldBrush}" BorderBrush="{StaticResource FieldBorderBrush}" BorderThickness="1">
                <Path x:Name="tick" Data="M1,5 L4,8 L9,1" Stroke="White" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                      Stretch="Uniform" Margin="3" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Asa de redimensión (esquina inferior derecha) para los campos de texto grandes -->
    <Style x:Key="ResizeGrip" TargetType="Thumb">
      <Setter Property="Width" Value="18"/>
      <Setter Property="Height" Value="18"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Bottom"/>
      <Setter Property="Cursor" Value="SizeNS"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border Background="Transparent" ToolTip="Arrastra para cambiar el alto">
              <Path Stroke="#7A7A86" StrokeThickness="1.4" Margin="0,0,3,3"
                    HorizontalAlignment="Right" VerticalAlignment="Bottom"
                    Data="M 13,5 L 5,13 M 13,9 L 9,13 M 13,13 L 12.5,13.5"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

  </Window.Resources>

  <Grid>
    <Grid.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
        <GradientStop Color="#0E0E13" Offset="0"/><GradientStop Color="#0A0A0D" Offset="1"/>
      </LinearGradientBrush>
    </Grid.Background>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- ============ SIDEBAR ============ -->
    <Border x:Name="sidebar" Width="216" Background="{StaticResource SidebarBrush}">
      <DockPanel Margin="12,18,12,18">
        <StackPanel DockPanel.Dock="Top">
          <!-- El logo ya incluye «STUDIO», por eso no hay texto «Studio» aparte debajo.
               BitmapScalingMode=HighQuality (Fant): el archivo viene a 464px y el control lo muestra
               a ~180px (reducción suave ~2.6×). El escalador por defecto de WPF NO promedia y deja
               grano en los bordes curvos (R, O); Fant promedia y los deja limpios sin emborronar. -->
          <Image x:Name="imgLogo" MaxHeight="68" HorizontalAlignment="Left" Margin="6,0,6,20"
                 Stretch="Uniform" Visibility="Collapsed"
                 RenderOptions.BitmapScalingMode="HighQuality"/>
          <StackPanel x:Name="panLogoTexto" Orientation="Horizontal" Margin="8,0,0,20">
            <TextBlock Text="HD" FontSize="27" FontWeight="Bold" Foreground="{StaticResource AccentBrush}"/>
            <TextBlock Text="ZERO" FontSize="27" FontWeight="Bold" Foreground="{StaticResource TextBrush}" Margin="2,0,0,0"/>
          </StackPanel>

          <!-- RAMA 1: creación del archivo (montaje). Una sola página «Proyecto» con todas las
               secciones (General, Proyecto, Audio, Subtítulos) apiladas y separadas por cabeceras. -->
          <TextBlock x:Name="lblSecMontaje" Text="① CREAR EL ARCHIVO" Foreground="{StaticResource AccentBrush}" FontSize="10.5"
                     FontWeight="Bold" Margin="10,0,0,7"/>
          <RadioButton x:Name="navProyecto" Style="{StaticResource Nav}" GroupName="nav" Content="🎬   Proyecto" IsChecked="True"/>

          <Border Height="1" Background="#2A2A3C" Margin="6,14,6,14"/>

          <!-- RAMA 2: torrent + subida al tracker -->
          <TextBlock x:Name="lblSecTorrent" Text="② TORRENT Y SUBIDA" Foreground="{StaticResource AccentBrush}" FontSize="10.5"
                     FontWeight="Bold" Margin="10,0,0,7"/>
          <RadioButton x:Name="navSubida"   Style="{StaticResource Nav}" GroupName="nav" Content="☁   Torrent y subida"/>

          <Border Height="1" Background="#2A2A3C" Margin="6,14,6,14"/>
          <RadioButton x:Name="navAjustes"  Style="{StaticResource Nav}" GroupName="nav" Content="⚙   Ajustes / claves"/>
        </StackPanel>
        <Grid x:Name="sidebarFooter" DockPanel.Dock="Bottom" Margin="2,12,2,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel x:Name="panVersionUpdate" Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="lblVersion" VerticalAlignment="Center" Foreground="#56565E"
                       FontSize="11" Margin="11,0,5,0" Text=""/>
            <Button x:Name="btnActualizar" Style="{StaticResource GhostMini}" Content="↑"
                    Visibility="Collapsed" MinWidth="36" MinHeight="36" Padding="7,2"
                    AutomationProperties.Name="Actualizar HDZ Studio" ToolTip="Actualizar HDZ Studio"/>
          </StackPanel>
          <Button x:Name="btnColapsar" Grid.Column="1" Style="{StaticResource GhostMini}" Content="☰"
                  FontSize="15" Padding="9,3" ToolTip="Ocultar / mostrar el menú"/>
        </Grid>
        <TextBlock x:Name="lblPie" DockPanel.Dock="Bottom" VerticalAlignment="Bottom" Foreground="#56565E" FontSize="11"
                   TextWrapping="Wrap" Margin="13,0,0,10"
                   Text="Las opciones se adaptan a lo detectado en tus vídeos. Todo se decide aquí: el montaje corre sin preguntar nada en consola."/>
        <Border/>
      </DockPanel>
    </Border>

    <!-- ============ CONTENIDO ============ -->
    <Grid Grid.Column="1" Margin="24,18,24,18">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Border Style="{StaticResource Card}" Padding="14,11">
        <StackPanel>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="📁" FontSize="17" VerticalAlignment="Center" Margin="2,0,0,0"/>
            <TextBox x:Name="txtCarpeta" Style="{StaticResource Input}" Grid.Column="1" Margin="11,0,11,0"
                     VerticalAlignment="Center" ToolTip="Carpeta con los vídeos. También puedes arrastrarla a la ventana."/>
            <StackPanel Grid.Column="2" Orientation="Horizontal">
              <Button x:Name="btnElegirVideos" Style="{StaticResource Ghost}" Content="Elegir vídeos…"/>
              <Button x:Name="btnAnadirTemporada" Style="{StaticResource Ghost}" Margin="9,0,0,0" Content="+ Temporada…"
                      ToolTip="Añade otra carpeta de temporada al mismo lote"/>
              <Button x:Name="btnExaminar" Style="{StaticResource Ghost}" Margin="9,0,0,0" Content="Carpeta…"/>
            </StackPanel>
          </Grid>
          <TextBlock x:Name="lblCarpetaDesc" Style="{StaticResource D}" Margin="2,8,0,0"
                     Text="Elige una carpeta o vídeos concretos. Añade temporadas para procesarlas en el mismo lote."/>
          <!-- Aviso: hay originales renombrados «.procesado» en la carpeta. Botón para revertirlos. -->
          <Border x:Name="panProcesado" Visibility="Collapsed" Background="#1C1407" BorderBrush="{StaticResource WarnBrush}"
                  BorderThickness="1" CornerRadius="8" Padding="13,11" Margin="2,11,0,2">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0" VerticalAlignment="Center">
                <TextBlock x:Name="lblProcesado" Foreground="{StaticResource WarnBrush}" FontWeight="SemiBold" FontSize="13" Text=""/>
                <TextBlock Style="{StaticResource D}" Margin="0,3,0,0"
                           Text="Se renombraron con «.procesado» al conservarse como originales. Quita ese sufijo para volver a trabajar con ellos."/>
              </StackPanel>
              <Button x:Name="btnQuitarProcesado" Grid.Column="1" Style="{StaticResource PrimarySmall}" VerticalAlignment="Center"
                      Margin="12,0,0,0" Content="Quitar «.procesado»"/>
            </Grid>
          </Border>
        </StackPanel>
      </Border>

      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="0,0,6,0">
        <Grid>

          <!-- Página única «Proyecto»: General + Proyecto + Audio + Subtítulos apilados en secciones,
               cada una con su cabecera. Antes cada sección era una entrada aparte del menú lateral. -->
          <StackPanel x:Name="panCrear">

          <!-- ============ GENERAL ============ -->
          <Border x:Name="secHdrGeneral" Background="Transparent" Cursor="Hand" Margin="0,2,0,10" Padding="4,2"
                  ToolTip="Mostrar / ocultar esta sección">
            <StackPanel>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Text="🏠  General" FontSize="15.5" FontWeight="SemiBold" Foreground="{StaticResource TextBrush}"/>
                <TextBlock x:Name="secChevGeneral" Grid.Column="1" Text="▸" FontSize="20" FontWeight="Bold" Foreground="{StaticResource TextBrush}" VerticalAlignment="Center" Margin="8,0,4,0"/>
              </Grid>
              <Border Height="1" Background="{StaticResource CardBorderBrush}" Margin="0,6,0,0"/>
            </StackPanel>
          </Border>
          <StackPanel x:Name="panGeneral" Visibility="Collapsed">
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Style="{StaticResource H}" Text="Remezcla (combinar versiones)"/>
                    <TextBlock Style="{StaticResource D}" Text="Elige archivos concretos para una remezcla manual, o dos carpetas de una serie para emparejar automáticamente cada capítulo por SxxEyy. Los títulos pueden ser distintos. Solo un origen aporta la imagen final; los demás pueden aportar pistas."/>
                  </StackPanel>
                  <CheckBox x:Name="swRemezcla" Style="{StaticResource Switch}" Grid.Column="1" VerticalAlignment="Top" Margin="12,2,0,0"/>
                </Grid>
                <StackPanel x:Name="panRemezcla" Visibility="Collapsed" Margin="0,12,0,0">
                  <StackPanel x:Name="panRemezclaCarpetas"/>
                  <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                    <Button x:Name="btnRemezclaAdd" Style="{StaticResource GhostMini}" Content="➕  Añadir vídeo(s)" HorizontalAlignment="Left"/>
                    <Button x:Name="btnRemezclaSerieAdd" Style="{StaticResource GhostMini}" Content="📁  Añadir carpeta de serie" HorizontalAlignment="Left" Margin="8,0,0,0"/>
                  </StackPanel>
                  <TextBlock x:Name="lblRemezclaInfo" Style="{StaticResource D}" Margin="0,9,0,0" Text=""/>
                  <StackPanel x:Name="panRemezclaInfo" Margin="0,8,0,0"/>
                  <!-- Selección de qué audios/subs conservar (se rellena al analizar). -->
                  <StackPanel x:Name="panRemezclaPistas" Visibility="Collapsed" Margin="0,12,0,0">
                    <TextBlock Style="{StaticResource Lbl}" Text="Audios a conservar (clic para quitar)"/>
                    <WrapPanel x:Name="panRemezclaAudios" Margin="0,4,0,0"/>
                    <TextBlock Style="{StaticResource Lbl}" Text="Subtítulos a conservar (clic para quitar)" Margin="0,10,0,0"/>
                    <WrapPanel x:Name="panRemezclaSubs" Margin="0,4,0,0"/>
                  </StackPanel>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border x:Name="cardModoLote" Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Modo de procesamiento"/>
                  <TextBlock x:Name="bdgModoLote" Style="{StaticResource Bdg}" Grid.Column="1"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Con varios títulos: ¿comparten proyecto (una temporada) o son títulos distintos?"/>
                <WrapPanel x:Name="chModoLote" Margin="0,11,0,-8"/>
              </StackPanel>
            </Border>
            <!-- Barra de pestañas de General (una por película), visible en «Cada archivo distinto». -->
            <StackPanel x:Name="panTabsGen" Visibility="Collapsed">
              <TextBlock Style="{StaticResource D}" Margin="2,0,0,8" Text="Cada pestaña es una película distinta del lote. Debajo verás y ajustarás SU vídeo (o pareja híbrida), sus originales, sufijo, torrent, carpeta de salida y episodio. El nombre de la pestaña es el archivo."/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <Button x:Name="btnTabGenIzq" Style="{StaticResource GhostMini}" Grid.Column="0" Content="◀" Margin="0,0,3,0" VerticalAlignment="Bottom" Visibility="Collapsed"/>
                <ScrollViewer x:Name="scrTabsGen" Grid.Column="1" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Disabled" VerticalAlignment="Bottom">
                  <StackPanel x:Name="panTabsGenInner" Orientation="Horizontal" HorizontalAlignment="Left"/>
                </ScrollViewer>
                <Button x:Name="btnTabGenDer" Style="{StaticResource GhostMini}" Grid.Column="2" Content="▶" Margin="3,0,0,0" VerticalAlignment="Bottom" Visibility="Collapsed"/>
              </Grid>
            </StackPanel>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Análisis del lote" VerticalAlignment="Center"/>
                  <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <TextBlock x:Name="lblResumen" Foreground="{StaticResource SubBrush}" FontSize="12" VerticalAlignment="Center" Margin="0,0,12,0"/>
                    <Button x:Name="btnSelTodos" Style="{StaticResource GhostMini}" Content="Todos"/>
                    <Button x:Name="btnSelNinguno" Style="{StaticResource GhostMini}" Content="Ninguno" Margin="6,0,0,0"/>
                  </StackPanel>
                </Grid>
                <!-- Lista redimensionable: arrastra la esquina inferior derecha para verlos todos. -->
                <Grid x:Name="gridListado" Height="250" Margin="0,9,0,0">
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel x:Name="panListado"/>
                  </ScrollViewer>
                  <Thumb x:Name="gripListado" Style="{StaticResource ResizeGrip}" Panel.ZIndex="10"/>
                </Grid>
              </StackPanel>
            </Border>
            <Border x:Name="cardMultiEp" Style="{StaticResource Card}" Visibility="Collapsed">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Episodios por vídeo (series)"/>
                <TextBlock Style="{StaticResource D}" Text="Si un mismo vídeo contiene varios episodios (dobles, triples…), indícalo aquí. Se numeran en cadena (E01-E02, E03-E04…) y puedes ajustar el rango de cada vídeo en la lista de arriba."/>
                <Grid Margin="0,10,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0" Margin="0,0,6,0">
                    <TextBlock Style="{StaticResource Lbl}" Text="Temporada"/>
                    <TextBox x:Name="txtTemporadaEp" Style="{StaticResource Input}"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" Margin="3,0,3,0">
                    <TextBlock Style="{StaticResource Lbl}" Text="Primer episodio"/>
                    <TextBox x:Name="txtPrimerEp" Style="{StaticResource Input}"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2" Margin="6,0,0,0">
                    <TextBlock Style="{StaticResource Lbl}" Text="Episodios por vídeo"/>
                    <ComboBox x:Name="cmbEpsPorVideo" Style="{StaticResource Combo}"/>
                  </StackPanel>
                </Grid>
                <Button x:Name="btnAplicarEp" Style="{StaticResource GhostMini}" Content="Aplicar numeración a la lista" Margin="0,11,0,0" HorizontalAlignment="Left"/>
              </StackPanel>
            </Border>
            <!-- Las capturas se configuran SIEMPRE en el panel «Proyecto» (en todos los modos). -->
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Archivos originales al terminar"/>
                <TextBlock Style="{StaticResource D}" Text="«Conservar» los renombra con «.procesado» (y van a la carpeta de Ajustes si la fijaste). «Mantener intactos» no toca nada. «Borrarlos» ahorra espacio."/>
                <WrapPanel x:Name="chOriginales" Margin="0,11,0,-8"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Sufijo «-HDZ» en el nombre final"/>
                <WrapPanel x:Name="chSufijo" Margin="0,11,0,-8"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Crear archivos .torrent"/>
                <TextBlock Style="{StaticResource D}" Text="Torrents PRIVADOS (no se distribuyen por la red DHT), listos para subir al tracker: uno por archivo, un PACK del lote completo (crea una carpeta con los MKV finales y su torrent multi-archivo), o ambos."/>
                <WrapPanel x:Name="chTorrent" Margin="0,11,0,0"/>
                <StackPanel x:Name="panTorrentDatos" Visibility="Collapsed">
                  <StackPanel x:Name="panPackNombre" Visibility="Collapsed">
                    <TextBlock Style="{StaticResource Lbl}" Text="Nombre del pack (se rellena solo con el nombre del episodio sin el «Exx»; puedes editarlo)"/>
                    <TextBox x:Name="txtPackNombre" Style="{StaticResource Input}" Width="520" HorizontalAlignment="Left"/>
                  </StackPanel>
                  <TextBlock Style="{StaticResource D}" Margin="0,4,0,0" Text="La URL de anuncio del tracker se configura una sola vez en «Ajustes / claves»."/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Carpetas de salida (opcional)"/>
                <TextBlock Style="{StaticResource D}" Text="Carpeta POR DEFECTO donde dejar el MKV final y el .torrent. Cada vídeo puede llevar su PROPIA carpeta de salida en la lista de arriba («Salida: 📂»); esta se usa solo para los que no tengan una propia. Si la dejas vacía, cada MKV se guarda junto a su vídeo de origen. Los originales .procesado y las capturas se archivan desde «Ajustes → Archivos procesados y capturas»."/>
                <TextBlock Style="{StaticResource Lbl}" Text="Archivo procesado (MKV final) — carpeta por defecto"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="txtSalidaArchivo" Style="{StaticResource Input}"/>
                  <Button x:Name="btnSalidaArchivo" Style="{StaticResource Ghost}" Grid.Column="1" Margin="8,0,0,0" Content="Examinar…"/>
                </Grid>
                <TextBlock x:Name="lblSalidaTorrent" Style="{StaticResource Lbl}" Text="Archivo .torrent"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="txtSalidaTorrent" Style="{StaticResource Input}"/>
                  <Button x:Name="btnSalidaTorrent" Style="{StaticResource Ghost}" Grid.Column="1" Margin="8,0,0,0" Content="Examinar…"/>
                </Grid>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- ============ PROYECTO ============ -->
          <Border x:Name="secHdrProyecto" Background="Transparent" Cursor="Hand" Margin="0,22,0,10" Padding="4,2"
                  ToolTip="Mostrar / ocultar esta sección">
            <StackPanel>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Text="🎬  Proyecto" FontSize="15.5" FontWeight="SemiBold" Foreground="{StaticResource TextBrush}"/>
                <TextBlock x:Name="secChevProyecto" Grid.Column="1" Text="▸" FontSize="20" FontWeight="Bold" Foreground="{StaticResource TextBrush}" VerticalAlignment="Center" Margin="8,0,4,0"/>
              </Grid>
              <Border Height="1" Background="{StaticResource CardBorderBrush}" Margin="0,6,0,0"/>
            </StackPanel>
          </Border>
          <StackPanel x:Name="panProyecto" Visibility="Collapsed">
            <!-- Datos de proyecto SIEMPRE activos: la GUI los define y los envía, sin prompts en consola.
                 El switch se conserva (oculto y marcado) por compatibilidad con la lógica existente. -->
            <Border Style="{StaticResource Card}" Visibility="Collapsed">
              <StackPanel>
                <CheckBox x:Name="swProyecto" Style="{StaticResource Switch}" IsChecked="True" Content="Definir aquí los datos del proyecto"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <TextBlock Style="{StaticResource D}" Margin="0"
                         Text="El título y el año se usan para nombrar el resultado. El título es obligatorio: el montaje no pregunta nada en consola."/>
            </Border>
            <!-- Barra de pestañas (una por película) — solo en modo «Cada archivo distinto».
                 Réplica de la tira de pestañas de «Torrent y subida»: cada pestaña tiene su propia
                 identidad (título, año, origen, plataforma) y el nombre completo del archivo. -->
            <StackPanel x:Name="panProyTabs" Visibility="Collapsed">
              <TextBlock Style="{StaticResource D}" Margin="2,0,0,8" Text="Cada pestaña es una película distinta del lote: dale a cada una su propio título, año, origen y plataforma. El nombre de la pestaña es el archivo."/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="btnTabProyIzq" Style="{StaticResource GhostMini}" Grid.Column="0" Content="◀" Margin="0,0,3,0" VerticalAlignment="Bottom" Visibility="Collapsed"/>
                <ScrollViewer x:Name="scrTabsProy" Grid.Column="1" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Disabled" VerticalAlignment="Bottom">
                  <StackPanel x:Name="panTabsProy" Orientation="Horizontal" HorizontalAlignment="Left"/>
                </ScrollViewer>
                <Button x:Name="btnTabProyDer" Style="{StaticResource GhostMini}" Grid.Column="2" Content="▶" Margin="3,0,0,0" VerticalAlignment="Bottom" Visibility="Collapsed"/>
              </Grid>
            </StackPanel>
            <StackPanel x:Name="panProyectoDatos">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Style="{StaticResource H}" Text="Identificación"/>
                  <TextBlock x:Name="lblSugerencia" Style="{StaticResource D}" Foreground="{StaticResource WarnBrush}" Visibility="Collapsed"/>
                  <TextBlock Style="{StaticResource Lbl}" Text="Título limpio"/>
                  <TextBox x:Name="txtTitulo" Style="{StaticResource Input}" MaxWidth="520" HorizontalAlignment="Left" Width="520"/>
                  <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
                    <StackPanel>
                      <TextBlock Style="{StaticResource Lbl}" Text="Año"/>
                      <TextBox x:Name="txtAno" Style="{StaticResource Input}" Width="120"/>
                    </StackPanel>
                    <CheckBox x:Name="swSerie" Style="{StaticResource Switch}" Content="Es una serie (detecta SxxEyy del nombre)"
                              Margin="30,0,0,6" VerticalAlignment="Bottom"/>
                  </StackPanel>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Style="{StaticResource H}" Text="Origen"/>
                  <WrapPanel x:Name="chOrigen" Margin="0,11,0,0"/>
                  <StackPanel x:Name="panWeb">
                    <TextBlock Style="{StaticResource Lbl}" Text="Tipo de WEB"/>
                    <WrapPanel x:Name="chWebTipo" Margin="0,0,0,-8"/>
                    <Grid Margin="0,2,0,0">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="250"/><ColumnDefinition Width="18"/><ColumnDefinition Width="250"/>
                      </Grid.ColumnDefinitions>
                      <StackPanel>
                        <TextBlock Style="{StaticResource Lbl}" Text="Plataforma"/>
                        <ComboBox x:Name="cmbPlataforma" Style="{StaticResource Combo}"/>
                      </StackPanel>
                      <StackPanel Grid.Column="2">
                        <TextBlock Style="{StaticResource Lbl}" Text="…o escribe otra etiqueta (opcional)"/>
                        <TextBox x:Name="txtPlataformaOtra" Style="{StaticResource Input}"/>
                      </StackPanel>
                    </Grid>
                  </StackPanel>
                  <StackPanel x:Name="panFisico" Visibility="Collapsed">
                    <Grid Margin="0,2,0,0">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="250"/><ColumnDefinition Width="18"/><ColumnDefinition Width="250"/>
                      </Grid.ColumnDefinitions>
                      <StackPanel>
                        <TextBlock Style="{StaticResource Lbl}" Text="Formato físico"/>
                        <ComboBox x:Name="cmbFormato" Style="{StaticResource Combo}"/>
                      </StackPanel>
                      <StackPanel Grid.Column="2">
                        <TextBlock Style="{StaticResource Lbl}" Text="…o escribe otro formato (opcional)"/>
                        <TextBox x:Name="txtFormatoOtro" Style="{StaticResource Input}"/>
                      </StackPanel>
                    </Grid>
                    <TextBlock Style="{StaticResource Lbl}" Text="Etiquetas extra (opcional)"/>
                    <TextBox x:Name="txtEtiquetas" Style="{StaticResource Input}" Width="518" HorizontalAlignment="Left"/>
                  </StackPanel>
                </StackPanel>
              </Border>
              <!-- Capturas POR PELÍCULA: solo visible en modo «Cada archivo distinto» (cada pestaña
                   puede tener su propio número de capturas). En modo homogéneo se usa el de «General». -->
              <Border x:Name="cardCapturasProy" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Style="{StaticResource H}" Text="Capturas por archivo"/>
                  <TextBlock Style="{StaticResource D}" Text="Imágenes PNG a resolución original (con tonemapping si el vídeo es HDR). En «Cada archivo distinto», cada película puede tener su propio número."/>
                  <WrapPanel x:Name="chCapturasProy" Margin="0,11,0,-8"/>
                </StackPanel>
              </Border>
              <!-- En modo heterogéneo aplicamos estos datos a todos los archivos (sin preguntar por
                   archivo en consola). El switch se conserva oculto y marcado. -->
              <Border Style="{StaticResource Card}" Visibility="Collapsed">
                <StackPanel>
                  <CheckBox x:Name="swAplicarTodos" Style="{StaticResource Switch}" Margin="0,12,0,0" IsChecked="True"
                            Content="Aplicar estos datos a TODOS los archivos sin preguntar"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </StackPanel>

          <!-- ============ AUDIO ============ -->
          <Border x:Name="secHdrAudio" Background="Transparent" Cursor="Hand" Margin="0,22,0,10" Padding="4,2"
                  ToolTip="Mostrar / ocultar esta sección">
            <StackPanel>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Text="🔊  Audio" FontSize="15.5" FontWeight="SemiBold" Foreground="{StaticResource TextBrush}"/>
                <TextBlock x:Name="secChevAudio" Grid.Column="1" Text="▸" FontSize="20" FontWeight="Bold" Foreground="{StaticResource TextBrush}" VerticalAlignment="Center" Margin="8,0,4,0"/>
              </Grid>
              <Border Height="1" Background="{StaticResource CardBorderBrush}" Margin="0,6,0,0"/>
            </StackPanel>
          </Border>
          <StackPanel x:Name="panAudio" Visibility="Collapsed">
            <!-- Pestañas por película (modo «Cada archivo distinto»): el audio se configura por peli. -->
            <StackPanel x:Name="panProyTabsA" Visibility="Collapsed">
              <TextBlock Style="{StaticResource D}" Margin="2,0,0,8" Text="Configurando el AUDIO de cada película por separado. Cambia de pestaña para otra."/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <Button x:Name="btnTabProyAIzq" Style="{StaticResource GhostMini}" Grid.Column="0" Content="◀" Margin="0,0,3,0" VerticalAlignment="Bottom" Visibility="Collapsed"/>
                <ScrollViewer x:Name="scrTabsProyA" Grid.Column="1" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Disabled" VerticalAlignment="Bottom">
                  <StackPanel x:Name="panTabsProyA" Orientation="Horizontal" HorizontalAlignment="Left"/>
                </ScrollViewer>
                <Button x:Name="btnTabProyADer" Style="{StaticResource GhostMini}" Grid.Column="2" Content="▶" Margin="3,0,0,0" VerticalAlignment="Bottom" Visibility="Collapsed"/>
              </Grid>
            </StackPanel>
            <Border x:Name="cardFiltroAudio" Style="{StaticResource Card}" Visibility="Collapsed">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Idiomas de audio a mantener"/>
                  <TextBlock x:Name="bdgFiltroAudio" Style="{StaticResource Bdg}" Grid.Column="1"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Todos están seleccionados de forma predeterminada. Desmarca los idiomas que no quieras conservar; se eliminarán todas sus pistas de audio."/>
                <WrapPanel x:Name="wrapIdiomasAudio" Margin="0,11,0,-8"/>
              </StackPanel>
            </Border>
            <Border x:Name="cardConvAudio" Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Convertir audio"/>
                  <TextBlock x:Name="bdgConvAudio" Style="{StaticResource Bdg}" Grid.Column="1"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Elige una pista y conviértela al formato que quieras (DD+, DD, AAC). Las opciones se adaptan a los canales de la pista (2.0, 5.1, 7.1). Puedes añadir varias conversiones; con «Mantener original» decides si la pista de origen se conserva o se sustituye. El delay (sincronía) se preserva."/>
                <StackPanel x:Name="panConvFilas" Margin="0,12,0,0"/>
                <Button x:Name="btnConvAdd" Style="{StaticResource Ghost}" Content="+ Añadir conversión" HorizontalAlignment="Left" Margin="0,4,0,0"/>
              </StackPanel>
            </Border>
            <Border x:Name="cardDefAudio" Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Pista de audio predeterminada"/>
                  <TextBlock x:Name="bdgDefAudio" Style="{StaticResource Bdg}" Grid.Column="1"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Cuando el idioma principal tiene audio Dolby Y DTS, ¿cuál se marca como pista por defecto? (El orden de pistas no cambia.)"/>
                <WrapPanel x:Name="chDefAudio" Margin="0,11,0,-8"/>
              </StackPanel>
            </Border>
            <Border x:Name="cardUndAudio" Style="{StaticResource Card}" Visibility="Collapsed">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Corregir idioma de las pistas de audio"/>
                  <TextBlock x:Name="bdgUndAudio" Style="{StaticResource Bdg}" Grid.Column="1"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Elige el idioma real de cualquier pista, aunque el archivo indique otro. Automático conserva la identificación original. No modifica el archivo de origen."/>
                <StackPanel x:Name="panUndAudio" Margin="0,10,0,0"/>
              </StackPanel>
            </Border>
            <Border x:Name="phAudio" Style="{StaticResource Card}" Visibility="Collapsed">
              <TextBlock Style="{StaticResource D}" Margin="0"
                         Text="✓  Nada que configurar aquí para este lote: sin audio DTS, sin convivencia Dolby+DTS y todas las pistas con idioma definido."/>
            </Border>
          </StackPanel>

          <!-- ============ SUBTÍTULOS ============ -->
          <Border x:Name="secHdrSubs" Background="Transparent" Cursor="Hand" Margin="0,22,0,10" Padding="4,2"
                  ToolTip="Mostrar / ocultar esta sección">
            <StackPanel>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Text="💬  Subtítulos" FontSize="15.5" FontWeight="SemiBold" Foreground="{StaticResource TextBrush}"/>
                <TextBlock x:Name="secChevSubs" Grid.Column="1" Text="▸" FontSize="20" FontWeight="Bold" Foreground="{StaticResource TextBrush}" VerticalAlignment="Center" Margin="8,0,4,0"/>
              </Grid>
              <Border Height="1" Background="{StaticResource CardBorderBrush}" Margin="0,6,0,0"/>
            </StackPanel>
          </Border>
          <StackPanel x:Name="panSubs" Visibility="Collapsed">
            <!-- Pestañas por película (modo «Cada archivo distinto»): los subtítulos se configuran por peli. -->
            <StackPanel x:Name="panProyTabsS" Visibility="Collapsed">
              <TextBlock Style="{StaticResource D}" Margin="2,0,0,8" Text="Configurando los SUBTÍTULOS de cada película por separado. Cambia de pestaña para otra."/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <Button x:Name="btnTabProySIzq" Style="{StaticResource GhostMini}" Grid.Column="0" Content="◀" Margin="0,0,3,0" VerticalAlignment="Bottom" Visibility="Collapsed"/>
                <ScrollViewer x:Name="scrTabsProyS" Grid.Column="1" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Disabled" VerticalAlignment="Bottom">
                  <StackPanel x:Name="panTabsProyS" Orientation="Horizontal" HorizontalAlignment="Left"/>
                </ScrollViewer>
                <Button x:Name="btnTabProySDer" Style="{StaticResource GhostMini}" Grid.Column="2" Content="▶" Margin="3,0,0,0" VerticalAlignment="Bottom" Visibility="Collapsed"/>
              </Grid>
            </StackPanel>
            <Border x:Name="cardUndSub" Style="{StaticResource Card}" Visibility="Collapsed">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Corregir idioma de las pistas de subtítulos"/>
                  <TextBlock x:Name="bdgUndSub" Style="{StaticResource Bdg}" Grid.Column="1"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Elige el idioma real de cualquier subtítulo, aunque su código sea erróneo. Automático conserva la identificación original. No modifica el archivo de origen."/>
                <StackPanel x:Name="panUndSub" Margin="0,10,0,0"/>
              </StackPanel>
            </Border>
            <Border x:Name="cardFiltro" Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Idiomas de subtítulos a mantener"/>
                  <TextBlock x:Name="bdgFiltro" Style="{StaticResource Bdg}" Grid.Column="1"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Quitar un idioma elimina todos sus subtítulos (forzados y completos). Los audios no se tocan."/>
                <WrapPanel x:Name="chFiltro" Margin="0,11,0,0"/>
                <WrapPanel x:Name="wrapIdiomas" Margin="0,6,0,-8" Visibility="Collapsed"/>
              </StackPanel>
            </Border>
            <Border x:Name="cardSubsUnicos" Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Subtítulos sin señal: ¿forzado o completo?"/>
                  <TextBlock x:Name="bdgSubsUnicos" Style="{StaticResource Bdg}" Grid.Column="1"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Estos subtítulos aparecen solos en su idioma y nada indica si son forzados o completos. Decide cada uno:"/>
                <StackPanel x:Name="panSubsUnicos" Margin="0,11,0,0"/>
              </StackPanel>
            </Border>
            <Border x:Name="cardPGS" Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Subtítulos PGS (OCR con Subtitle Edit)"/>
                  <TextBlock x:Name="bdgPGS" Style="{StaticResource Bdg}" Grid.Column="1"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Si se extraen, el script PAUSARÁ en la consola para que los conviertas a SRT con Subtitle Edit y continúe al pulsar ENTER."/>
                <TextBlock Style="{StaticResource Lbl}" Text="¿Extraer los PGS a archivos .sup?"/>
                <WrapPanel x:Name="chExtraerPGS"/>
                <TextBlock Style="{StaticResource Lbl}" Text="Tras convertirlos a SRT…"/>
                <WrapPanel x:Name="chConservarPGS" Margin="0,0,0,-8"/>
              </StackPanel>
            </Border>
            <Border x:Name="phSubs" Style="{StaticResource Card}" Visibility="Collapsed">
              <TextBlock Style="{StaticResource D}" Margin="0"
                         Text="✓  Nada que configurar aquí para este lote: sin PGS, sin ambigüedades, idiomas dentro del límite y todos los subtítulos con idioma definido."/>
            </Border>
          </StackPanel>

          </StackPanel><!-- /panCrear -->

          <!-- ============ SUBIR AL TRACKER ============ -->
          <StackPanel x:Name="panSubida" Visibility="Collapsed">
            <!-- TIRA DE PESTAÑAS: todo el panel de subida cuelga del cuerpo de abajo -->
            <TextBlock Style="{StaticResource D}" Margin="2,0,0,8" Text="Cada pestaña es una subida independiente (su propio torrent, capturas, descripción e IDs). Prepara varias —p.ej. 3 películas— y súbelas una a una."/>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="btnTabIzq" Style="{StaticResource GhostMini}" Grid.Column="0" Content="◀" Margin="0,0,3,0" VerticalAlignment="Bottom" Visibility="Collapsed"/>
              <ScrollViewer x:Name="scrTabs" Grid.Column="1" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Disabled" VerticalAlignment="Bottom">
                <StackPanel x:Name="panTabsSubida" Orientation="Horizontal" HorizontalAlignment="Left"/>
              </ScrollViewer>
              <Button x:Name="btnTabDer" Style="{StaticResource GhostMini}" Grid.Column="2" Content="▶" Margin="3,0,0,0" VerticalAlignment="Bottom" Visibility="Collapsed"/>
              <Button x:Name="btnNuevaSubida" Style="{StaticResource GhostMini}" Grid.Column="3" Content="➕ Nueva" Margin="10,0,0,0" VerticalAlignment="Bottom"/>
            </Grid>
            <!-- CUERPO de la pestaña activa (la barra de pestañas se conecta a su borde superior) -->
            <Border x:Name="panSubidaBody" Background="#0E0E11" BorderBrush="{StaticResource CardBorderBrush}"
                    BorderThickness="1" CornerRadius="0,10,10,10" Padding="14,16,14,14" Margin="0,0,0,12">
              <StackPanel>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Torrent a subir"/>
                <TextBlock Style="{StaticResource D}" Text="Carga un .torrent ya creado, o crea uno a partir de un archivo (o carpeta/pack) que YA tengas procesado. Se localiza el vídeo, se extrae el MediaInfo y las specs, se cargan las capturas que haya al lado y se rellenan los campos."/>
                <TextBlock Style="{StaticResource Lbl}" Text="Cargar un .torrent existente"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="txtTorrentSubir" Style="{StaticResource Input}" VerticalAlignment="Center" IsReadOnly="True"/>
                  <Button x:Name="btnTorrentExaminar" Style="{StaticResource Ghost}" Grid.Column="1" Content="Examinar…" Margin="9,0,0,0"/>
                  <Button x:Name="btnTorrentUltimo" Style="{StaticResource Ghost}" Grid.Column="2" Content="Último creado" Margin="9,0,0,0"/>
                </Grid>
                <TextBlock Style="{StaticResource Lbl}" Text="…o crear el torrent de algo ya procesado"/>
                <StackPanel Orientation="Horizontal">
                  <Button x:Name="btnCrearTorrentArchivo" Style="{StaticResource Ghost}" Content="🧲  De un archivo…"/>
                  <Button x:Name="btnCrearTorrentCarpeta" Style="{StaticResource Ghost}" Margin="9,0,0,0" Content="🧲  De una carpeta (pack)…"/>
                </StackPanel>
                <Border x:Name="panTorrentProgreso" Visibility="Collapsed" Margin="0,11,0,0"
                        Background="{StaticResource ChipBrush}" BorderBrush="{StaticResource ChipBorderBrush}"
                        BorderThickness="1" CornerRadius="8" Padding="12,9">
                  <StackPanel>
                    <Grid Margin="0,0,0,6">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBlock x:Name="lblTorrentProgreso" Foreground="{StaticResource TextBrush}" FontSize="12" FontWeight="SemiBold" Text="Creando torrent…"/>
                      <TextBlock x:Name="lblTorrentProgresoPct" Grid.Column="1" Foreground="{StaticResource SubBrush}" FontSize="12" FontWeight="SemiBold" Text="0%"/>
                    </Grid>
                    <ProgressBar x:Name="barTorrentProgreso" Height="6" Minimum="0" Maximum="100" Value="0"
                                 Background="#26262C" BorderThickness="0" Foreground="{StaticResource AccentBrush}"/>
                  </StackPanel>
                </Border>
                <TextBlock x:Name="lblTorrentInfo" Style="{StaticResource D}" Foreground="{StaticResource WarnBrush}" Margin="0,9,0,0" Visibility="Collapsed"/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Datos del torrent"/>
                <TextBlock Style="{StaticResource Lbl}" Text="Título (nombre de la release)"/>
                <TextBox x:Name="upTitulo" Style="{StaticResource Input}"/>
                <Grid Margin="0,2,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <StackPanel><TextBlock Style="{StaticResource Lbl}" Text="Categoría"/><ComboBox x:Name="upCategoria" Style="{StaticResource Combo}"/></StackPanel>
                  <StackPanel Grid.Column="2"><TextBlock Style="{StaticResource Lbl}" Text="Tipo"/><ComboBox x:Name="upTipo" Style="{StaticResource Combo}"/></StackPanel>
                  <StackPanel Grid.Column="4"><TextBlock Style="{StaticResource Lbl}" Text="Resolución"/><ComboBox x:Name="upResolucion" Style="{StaticResource Combo}"/></StackPanel>
                </Grid>
                <StackPanel x:Name="panTV" Visibility="Collapsed" Orientation="Horizontal" Margin="0,2,0,0">
                  <StackPanel><TextBlock Style="{StaticResource Lbl}" Text="Nº temporada"/><TextBox x:Name="upTemporada" Style="{StaticResource Input}" Width="120"/></StackPanel>
                  <StackPanel Margin="16,0,0,0"><TextBlock Style="{StaticResource Lbl}" Text="Nº episodio (0 = pack temporada)"/><TextBox x:Name="upEpisodio" Style="{StaticResource Input}" Width="220"/></StackPanel>
                </StackPanel>
                <TextBlock Style="{StaticResource Lbl}" Text="Palabras clave (separadas por comas)"/>
                <TextBox x:Name="upKeywords" Style="{StaticResource Input}"/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Identificación (TMDB / IMDB / TVDB / MAL)"/>
                  <Button x:Name="btnBuscarTmdb" Style="{StaticResource GhostMini}" Grid.Column="1" Content="🔍  Buscar en TMDB"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Busca por título y año. Si cambias el TMDB a mano, se sustituyen la categoría, IMDb, TVDB, keywords y logos de la ficha anterior."/>
                <StackPanel x:Name="panResultadosTmdb" Margin="0,8,0,0"/>
                <Grid Margin="0,4,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <StackPanel><TextBlock Style="{StaticResource Lbl}" Text="TMDB ID"/><TextBox x:Name="upTmdb" Style="{StaticResource Input}"/></StackPanel>
                  <StackPanel Grid.Column="2"><TextBlock Style="{StaticResource Lbl}" Text="IMDB (nº o tt…)"/><TextBox x:Name="upImdb" Style="{StaticResource Input}"/></StackPanel>
                  <StackPanel Grid.Column="4"><TextBlock Style="{StaticResource Lbl}" Text="TVDB ID"/><TextBox x:Name="upTvdb" Style="{StaticResource Input}"/></StackPanel>
                  <StackPanel Grid.Column="6"><TextBlock Style="{StaticResource Lbl}" Text="MAL ID"/><TextBox x:Name="upMal" Style="{StaticResource Input}"/></StackPanel>
                </Grid>
              </StackPanel>
            </Border>

            <Border x:Name="cardLogos" Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Logo de TMDB"/>
                  <TextBlock x:Name="bdgLogos" Style="{StaticResource Bdg}" Grid.Column="1"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Logos disponibles en TMDB para este título. Clic en uno para ponerlo como primera línea de la descripción con [img=700]."/>
                <Grid Margin="0,10,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Button x:Name="btnActualizarLogos" Style="{StaticResource Ghost}" Content="↻ Actualizar logos" VerticalAlignment="Center"/>
                  <TextBox x:Name="txtLogoPersonalizado" Style="{StaticResource Input}" Grid.Column="2" Margin="0" VerticalAlignment="Center" ToolTip="URL HTTPS directa de una imagen PNG, JPEG o WebP"/>
                  <Button x:Name="btnUsarLogoPersonalizado" Style="{StaticResource Ghost}" Grid.Column="4" Content="Añadir URL" VerticalAlignment="Center" ToolTip="Añade esta imagen como logo de la descripción"/>
                </Grid>
                <WrapPanel x:Name="panLogos" Margin="0,11,0,0"/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Capturas para la descripción"/>
                  <TextBlock x:Name="bdgCapturas" Style="{StaticResource Bdg}" Grid.Column="1" VerticalAlignment="Center"/>
                  <Button x:Name="btnCapColapsar" Style="{StaticResource GhostMini}" Grid.Column="2" Margin="10,0,0,0" Content="▾ Ocultar" VerticalAlignment="Center"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Si no hay capturas junto al vídeo, créalas aquí (📷). Marca las que quieras y pulsa «Subir y añadir»: se suben como PNG y se insertan como miniaturas enlazadas al original. Clic en una miniatura para verla a tamaño completo."/>
                <WrapPanel x:Name="panCapturas" Margin="0,11,0,0"/>
                <Grid Margin="0,10,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <Button x:Name="btnCapTodas" Style="{StaticResource GhostMini}" Grid.Column="0" Content="Todas" VerticalAlignment="Center"/>
                  <Button x:Name="btnCapNinguna" Style="{StaticResource GhostMini}" Grid.Column="1" Content="Ninguna" Margin="6,0,0,0" VerticalAlignment="Center"/>
                  <Button x:Name="btnCapGenerar" Style="{StaticResource GhostMini}" Grid.Column="2" Content="📷  Crear capturas" Margin="14,0,0,0" VerticalAlignment="Center"/>
                  <ComboBox x:Name="cmbNumCapturas" Style="{StaticResource Combo}" Grid.Column="3" Width="62" Margin="6,0,0,0" VerticalAlignment="Center"/>
                  <Button x:Name="btnCapAnadir" Style="{StaticResource GhostMini}" Grid.Column="4" Content="Añadir imágenes…" Margin="6,0,0,0" VerticalAlignment="Center"/>
                  <Button x:Name="btnCapInsertar" Style="{StaticResource PrimarySmall}" Grid.Column="6" Content="⬆  Subir y añadir a descripción" VerticalAlignment="Center"/>
                </Grid>
                <Border x:Name="panSubProgreso" Visibility="Collapsed" Margin="0,10,0,0"
                        Background="{StaticResource ChipBrush}" BorderBrush="{StaticResource ChipBorderBrush}"
                        BorderThickness="1" CornerRadius="8" Padding="12,9">
                  <StackPanel>
                    <Grid Margin="0,0,0,6">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBlock x:Name="lblSubProgreso" Foreground="{StaticResource TextBrush}" FontSize="12" FontWeight="SemiBold" Text="Subiendo imágenes…"/>
                      <TextBlock x:Name="lblSubProgresoPct" Grid.Column="1" Foreground="{StaticResource SubBrush}" FontSize="12" FontWeight="SemiBold" Text="0/0"/>
                    </Grid>
                    <ProgressBar x:Name="barSubProgreso" Height="6" Minimum="0" Maximum="100" Value="0"
                                 Background="#26262C" BorderThickness="0" Foreground="{StaticResource AccentBrush}"/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Descripción (BBCode)"/>
                <TextBlock Style="{StaticResource D}" Text="Va centrada (entre [center]…[/center]). El logo, las capturas y la firma se insertan aquí; da formato con los botones o escribe BBCode a mano."/>
                <!-- Pestañas Escribir / Vista previa (alternan en el mismo sitio, como el tracker) -->
                <StackPanel Orientation="Horizontal" Margin="0,8,0,8">
                  <RadioButton x:Name="tabEscribir" Style="{StaticResource Chip}" GroupName="descTab" Content="✎  Escribir" IsChecked="True"/>
                  <RadioButton x:Name="tabPrevia" Style="{StaticResource Chip}" GroupName="descTab" Content="👁  Vista previa"/>
                </StackPanel>
                <StackPanel x:Name="panEdicionTools">
                  <WrapPanel x:Name="panBbToolbar" Margin="0,2,0,4"/>
                  <Button x:Name="btnDescSubir" Style="{StaticResource GhostMini}" HorizontalAlignment="Left" Margin="0,0,0,6" Content="⬆  Subir imagen del PC…"/>
                </StackPanel>
                <Grid x:Name="gridDesc" Height="300">
                  <TextBox x:Name="upDescripcion" Style="{StaticResource Input}"
                           TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top"/>
                  <Border x:Name="panPreview" Visibility="Collapsed" Background="#0C0C0F"
                          BorderBrush="{StaticResource ChipBorderBrush}" BorderThickness="1" CornerRadius="8" ClipToBounds="True">
                    <FlowDocumentScrollViewer x:Name="fdPreview" Background="Transparent" Foreground="#E8E8EE"
                                              VerticalScrollBarVisibility="Auto" Padding="0" BorderThickness="0"/>
                  </Border>
                  <Thumb x:Name="gripDesc" Style="{StaticResource ResizeGrip}" Panel.ZIndex="10"/>
                </Grid>
              </StackPanel>
            </Border>

            <Border x:Name="cardFirmas" Style="{StaticResource Card}" Visibility="Collapsed">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="Firma"/>
                  <TextBlock x:Name="bdgFirmas" Style="{StaticResource Bdg}" Grid.Column="1"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Imágenes de la carpeta «firmas». La elegida se sube y se añade al final de la descripción (antes del último [/center]) al subir. Clic para elegir; clic de nuevo para quitar."/>
                <WrapPanel x:Name="panFirmas" Margin="0,11,0,0"/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource H}" Text="MediaInfo"/>
                  <Button x:Name="btnMediaRefrescar" Style="{StaticResource GhostMini}" Grid.Column="1" Content="Regenerar"/>
                </Grid>
                <TextBlock Style="{StaticResource D}" Text="Texto completo del archivo (del primer episodio si es una serie/pack). Se envía en el campo MediaInfo."/>
                <Grid x:Name="gridMediaInfo" Height="120" Margin="0,9,0,0">
                  <TextBox x:Name="upMediainfo" Style="{StaticResource Input}" FontFamily="Consolas"
                           TextWrapping="NoWrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" VerticalContentAlignment="Top"/>
                  <Thumb x:Name="gripMedia" Style="{StaticResource ResizeGrip}" Panel.ZIndex="10"/>
                </Grid>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Opciones"/>
                <WrapPanel Margin="0,11,0,0">
                  <CheckBox x:Name="upAnon" Style="{StaticResource Switch}" Content="Anónimo" Margin="0,0,28,10"/>
                  <CheckBox x:Name="upPersonal" Style="{StaticResource Switch}" Content="Personal release" Margin="0,0,28,10"/>
                  <CheckBox x:Name="upAudioEd" Style="{StaticResource Switch}" Content="Audio editado" Margin="0,0,28,10"/>
                  <CheckBox x:Name="upProper" Style="{StaticResource Switch}" Content="Proper" Margin="0,0,28,10"/>
                </WrapPanel>
                <WrapPanel>
                  <CheckBox x:Name="upDV" Style="{StaticResource Switch}" Content="Dolby Vision" Margin="0,0,28,10"/>
                  <CheckBox x:Name="upHDR10P" Style="{StaticResource Switch}" Content="HDR10+" Margin="0,0,28,10"/>
                  <CheckBox x:Name="upHDR10" Style="{StaticResource Switch}" Content="HDR10" Margin="0,0,28,10"/>
                  <CheckBox x:Name="upModQueue" Style="{StaticResource Switch}" Content="Cola de moderación" Margin="0,0,28,10"/>
                </WrapPanel>
                <TextBlock Style="{StaticResource Lbl}" Text="NFO (opcional)"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="upNfo" Style="{StaticResource Input}" VerticalAlignment="Center" IsReadOnly="True"/>
                  <Button x:Name="btnNfoExaminar" Style="{StaticResource Ghost}" Grid.Column="1" Content="Examinar…" Margin="9,0,0,0"/>
                </Grid>
              </StackPanel>
            </Border>

              </StackPanel>
            </Border>
          </StackPanel>

          <!-- ============ AJUSTES / CLAVES ============ -->
          <StackPanel x:Name="panAjustes" Visibility="Collapsed">
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Credenciales del tracker"/>
                <TextBlock Style="{StaticResource D}" Text="Se guardan solo en tu equipo (%APPDATA%). El token del tracker está en HDZERO → perfil → Configuración → Seguridad."/>
                <TextBlock Style="{StaticResource Lbl}" Text="URL base del tracker"/>
                <TextBox x:Name="cfgTrackerUrl" Style="{StaticResource Input}" Width="420" HorizontalAlignment="Left"/>
                <TextBlock Style="{StaticResource Lbl}" Text="Token de la API del tracker (api_token)"/>
                <TextBox x:Name="cfgTrackerToken" Style="{StaticResource Input}" Width="520" HorizontalAlignment="Left"/>
                <TextBlock Style="{StaticResource Lbl}" Text="URL de anuncio del tracker (announce, con tu passkey)"/>
                <TextBox x:Name="txtAnnounce" Style="{StaticResource Input}" Width="520" HorizontalAlignment="Left"/>
                <TextBlock Style="{StaticResource D}" Margin="0,3,0,0" Text="Se usa al crear los .torrent (en el montaje y en «Torrent y subida»). Se guarda y no se vuelve a pedir."/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Host de imágenes"/>
                <TextBlock Style="{StaticResource D}" Text="Elige tu servidor preferido. Si falla, se probarán automáticamente los demás. freeimage, imgbox y Pixhost no necesitan clave; imgbb solo se usará si tiene clave. Se conserva la imagen original y una miniatura proporcional enlazada."/>
                <WrapPanel x:Name="chHostImg" Margin="0,11,0,0"/>
                <StackPanel x:Name="panImgbbKey" Visibility="Collapsed">
                  <TextBlock Style="{StaticResource Lbl}" Text="Clave API de imgbb"/>
                  <TextBox x:Name="cfgImgbbKey" Style="{StaticResource Input}" Width="420" HorizontalAlignment="Left"/>
                </StackPanel>
                <StackPanel x:Name="panImgboxCuenta" Visibility="Collapsed" Margin="0,4,0,0">
                  <TextBlock Style="{StaticResource D}" Text="Cuenta imgbox (opcional). Si la rellenas, las galerías quedan en «Mis galerías» de tu cuenta. Si la dejas vacía, se sube de forma anónima (igual con galería). Se guarda SOLO en tu equipo; la contraseña, cifrada."/>
                  <Grid Margin="0,6,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0">
                      <TextBlock Style="{StaticResource Lbl}" Text="Usuario imgbox (opcional)"/>
                      <TextBox x:Name="cfgImgboxUser" Style="{StaticResource Input}"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2">
                      <TextBlock Style="{StaticResource Lbl}" Text="Contraseña imgbox (opcional)"/>
                      <PasswordBox x:Name="cfgImgboxPass" Height="34" Padding="9,0" VerticalContentAlignment="Center"
                                   Background="{StaticResource FieldBrush}" Foreground="{StaticResource TextBrush}"
                                   BorderBrush="{StaticResource CardBorderBrush}" BorderThickness="1" CaretBrush="{StaticResource TextBrush}"/>
                    </StackPanel>
                  </Grid>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="TMDB (búsqueda automática)"/>
                <TextBlock Style="{StaticResource D}" Text="De themoviedb.org → Ajustes → API. Vale cualquiera de las dos credenciales: la «Clave de la API» (corta) o el «Token de acceso de lectura» (largo, empieza por eyJ). Se detecta sola."/>
                <TextBlock Style="{StaticResource Lbl}" Text="Clave API o token de lectura de TMDB"/>
                <TextBox x:Name="cfgTmdbKey" Style="{StaticResource Input}" Width="420" HorizontalAlignment="Left"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Archivos procesados y capturas"/>
                <TextBlock Style="{StaticResource D}" Text="Carpeta donde archivar los ORIGINALES ya procesados (.procesado) y las CAPTURAS, fuera de la carpeta de trabajo. El programa crea dentro una subcarpeta por proyecto (con el nombre de la carpeta de trabajo). NO afecta al MKV resultado (ese va a su carpeta de salida o, si no, junto al origen). Si la dejas vacía, los .procesado y las capturas se quedan en la carpeta de origen, como siempre."/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="cfgCarpetaProcesados" Style="{StaticResource Input}"/>
                  <Button x:Name="btnCfgCarpetaProcesados" Style="{StaticResource Ghost}" Grid.Column="1" Margin="8,0,0,0" Content="Examinar…"/>
                </Grid>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Carpeta por defecto de los .torrent"/>
                <TextBlock Style="{StaticResource D}" Text="Carpeta donde guardar por defecto los .torrent que crea el programa y el .torrent que se descarga del tracker para sembrar. Es solo un valor por defecto: en cada montaje puedes cambiar la carpeta de salida del .torrent. Si la dejas vacía, el .torrent se guarda junto al vídeo, como siempre."/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="cfgCarpetaTorrent" Style="{StaticResource Input}"/>
                  <Button x:Name="btnCfgCarpetaTorrent" Style="{StaticResource Ghost}" Grid.Column="1" Margin="8,0,0,0" Content="Examinar…"/>
                </Grid>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Soporte"/>
                <TextBlock Style="{StaticResource D}" Text="Si algo falla, envía el registro (log) del proyecto al soporte para diagnóstico. Las claves van censuradas; nunca se comparten."/>
                <TextBlock Style="{StaticResource Lbl}" Text="Tu usuario / alias (para que el soporte sepa de quién es el log)"/>
                <TextBox x:Name="cfgUsuarioSoporte" Style="{StaticResource Input}" Width="420" HorizontalAlignment="Left"/>
                <Button x:Name="btnEnviarLog" Style="{StaticResource Ghost}" Content="📤  Enviar log a soporte" HorizontalAlignment="Left" Margin="0,12,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <TextBlock Style="{StaticResource D}" Margin="0"
                         Text="⚠  Estas claves dan acceso a tu cuenta. No las compartas. Si alguna se filtró, regenérala en el sitio correspondiente."/>
            </Border>
          </StackPanel>

        </Grid>
      </ScrollViewer>

      <StackPanel Grid.Row="2" Margin="0,14,0,0">
        <!-- Barra de progreso del montaje (oculta hasta lanzar) -->
        <Border x:Name="panProgreso" Visibility="Collapsed" Margin="0,0,0,12"
                Background="{StaticResource ChipBrush}" BorderBrush="{StaticResource ChipBorderBrush}"
                BorderThickness="1" CornerRadius="10" Padding="14,10">
          <StackPanel>
            <Grid Margin="0,0,0,7">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="lblProgreso" Foreground="{StaticResource TextBrush}" FontSize="12.5"
                         FontWeight="SemiBold" TextTrimming="CharacterEllipsis" Text="Preparando…"/>
              <TextBlock x:Name="lblProgresoPct" Grid.Column="1" Foreground="{StaticResource SubBrush}"
                         FontSize="12.5" FontWeight="SemiBold" Text="0%"/>
            </Grid>
            <ProgressBar x:Name="barProgreso" Height="8" Minimum="0" Maximum="100" Value="0"
                         Background="#26262C" BorderThickness="0" Foreground="{StaticResource AccentBrush}"/>
            <!-- 2ª barra: detalle de la tarea en curso (ensamblado del MKV actual). Oculta si no aplica. -->
            <StackPanel x:Name="panProgreso2" Visibility="Collapsed" Margin="0,9,0,0">
              <Grid Margin="0,0,0,5">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock x:Name="lblProgreso2" Foreground="{StaticResource SubBrush}" FontSize="11.5"
                           FontWeight="SemiBold" TextTrimming="CharacterEllipsis" Text="Ensamblando…"/>
                <TextBlock x:Name="lblProgreso2Pct" Grid.Column="1" Foreground="{StaticResource SubBrush}"
                           FontSize="11.5" FontWeight="SemiBold" Text="0%"/>
              </Grid>
              <ProgressBar x:Name="barProgreso2" Height="6" Minimum="0" Maximum="100" Value="0"
                           Background="#26262C" BorderThickness="0" Foreground="#6E6E78"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <!-- Torrent, capturas e imágenes pueden seguir trabajando fuera de la pestaña de subida.
             Este resumen queda junto al botón principal para que el progreso no desaparezca al cambiar de sección. -->
        <StackPanel x:Name="panTareasAux" Visibility="Collapsed" Margin="0,0,0,12"/>

        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="btnReset" Style="{StaticResource Ghost}" Grid.Column="0" Margin="0,0,10,0"
                  Content="🗑  Empezar de Zero" ToolTip="Borra la carpeta seleccionada y todas las opciones, dejando el programa como recién abierto."/>
          <TextBlock x:Name="lblEstado" Grid.Column="1" VerticalAlignment="Center" TextWrapping="Wrap"
                     Foreground="{StaticResource SubBrush}" FontSize="12.5" Margin="2,0,16,0"/>
          <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="0,0,10,0">
            <Button x:Name="btnConsola" Style="{StaticResource Ghost}" IsEnabled="False"
                    ToolTip="Muestra u oculta la ventana de consola donde corre el montaje (útil si el script hace alguna pregunta).">
              <TextBlock><Run FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Text="&#xE7B3;"/><Run Text="  Mostrar consola"/></TextBlock>
            </Button>
            <!-- Acciones no modales tras subir: no bloquean el agente remoto esperando una respuesta. -->
            <Button x:Name="btnAbrirTorrent" Style="{StaticResource Ghost}" Margin="0,0,8,0" Visibility="Collapsed"
                    Content="🌱  Abrir torrent" ToolTip="Abre en tu cliente el torrent del tracker que debes sembrar."/>
            <Button x:Name="btnVerWeb" Style="{StaticResource Ghost}" Visibility="Collapsed"
                    Content="🌐  Ver en la web" ToolTip="Abre la página del torrent recién subido en el navegador."/>
          </StackPanel>
          <Button x:Name="btnIniciar" Style="{StaticResource Primary}" Grid.Column="3" Content="▶   Iniciar montaje"/>
          <!-- Solo en «Cada archivo distinto»: encola CADA película que falte (una tras otra). Oculto en el resto. -->
          <Button x:Name="btnIniciarTodos" Style="{StaticResource Primary}" Grid.Column="4" Margin="10,0,0,0" Visibility="Collapsed"
                  Content="▶▶  Todas" ToolTip="Encola todas las películas pendientes (cada una en su propio proceso, una tras otra). Las que ya lanzaste se saltan."/>
          <!-- En «Torrent y subida» este sustituye a «Iniciar montaje» (misma celda) -->
          <Button x:Name="btnSubir" Style="{StaticResource Primary}" Grid.Column="3" Content="☁   Subir a HDZERO" Visibility="Collapsed"/>
        </Grid>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Parse($xaml)

# Red de seguridad para errores de callbacks/timers WPF. Antes una excepción no controlada en el
# Dispatcher podía cerrar toda la ventana sin dejar ninguna pista visible. Se registra en AppData,
# se marca como atendida para mantener abierta la interfaz y se muestra un estado recuperable.
$win.Dispatcher.add_UnhandledException({
    param($sender, $e)
    try {
        $ex = $e.Exception
        $detalle = @(
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] EXCEPCION UI NO CONTROLADA"
            "Tipo: $($ex.GetType().FullName)"
            "Mensaje: $(Redacta-Log $ex.Message)"
            "Origen: $($ex.Source)"
            "Stack: $(Redacta-Log $ex.StackTrace)"
            $(if ($ex.InnerException) { "Interna: $(Redacta-Log $ex.InnerException.ToString())" })
            ""
        ) -join [Environment]::NewLine
        $crashLog = Join-Path (Get-DirLogs) "crash_gui.log"
        [System.IO.File]::AppendAllText($crashLog, $detalle + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch {}
    try { $e.Handled = $true } catch {}
    try { Set-Estado "Se evitó un cierre inesperado. El detalle se guardó en el registro de diagnóstico." "error" } catch {}
})

# AppUserModelID propio: desacopla la ventana del proceso pwsh.exe para que la barra de tareas
# muestre NUESTRO icono (y no el de PowerShell) y agrupe la app por separado. Debe fijarse antes
# de crear el HWND de la ventana (antes de ShowDialog).
try {
    Add-Type -Namespace HdzNative -Name Shell -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError=true)]
public static extern void SetCurrentProcessExplicitAppUserModelID([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string AppID);
'@
    [HdzNative.Shell]::SetCurrentProcessExplicitAppUserModelID("HDZ.Studio")
} catch {}

# =========================================================================
# REFERENCIAS A CONTROLES
# =========================================================================
$refs = @("txtCarpeta","btnExaminar","btnElegirVideos","btnAnadirTemporada","lblResumen","panListado","imgLogo","panLogoTexto",
          "swRemezcla","panRemezcla","panRemezclaCarpetas","btnRemezclaAdd","btnRemezclaSerieAdd","lblRemezclaInfo","panRemezclaInfo",
          "panRemezclaPistas","panRemezclaAudios","panRemezclaSubs",
          "btnSelTodos","btnSelNinguno","panProcesado","lblProcesado","btnQuitarProcesado",
          "cardMultiEp","txtTemporadaEp","txtPrimerEp","cmbEpsPorVideo","btnAplicarEp",
          "sidebar","sidebarFooter","panVersionUpdate","btnColapsar","lblVersion","btnActualizar","lblSecMontaje","lblSecTorrent","lblPie","panSubidaBody","lblCarpetaDesc",
          "navProyecto",
          "panCrear","panGeneral","panProyecto","panAudio","panSubs",
          "secHdrGeneral","secChevGeneral","secHdrProyecto","secChevProyecto",
          "secHdrAudio","secChevAudio","secHdrSubs","secChevSubs",
          "chModoLote","chOriginales","chSufijo",
          "chTorrent","panTorrentDatos","txtAnnounce","panPackNombre","txtPackNombre",
          "txtSalidaArchivo","btnSalidaArchivo","txtSalidaTorrent","btnSalidaTorrent","lblSalidaTorrent",
          "bdgModoLote","bdgFiltroAudio","bdgConvAudio","bdgDefAudio","bdgUndAudio","bdgUndSub",
          "bdgFiltro","bdgSubsUnicos","bdgPGS","lblSugerencia",
          "cardModoLote","cardFiltroAudio","wrapIdiomasAudio","cardConvAudio","panConvFilas","btnConvAdd","cardDefAudio","cardUndAudio","cardUndSub",
          "cardFiltro","cardSubsUnicos","cardPGS","phAudio","phSubs","panUndAudio","panUndSub",
          "swProyecto","panProyectoDatos","txtTitulo","txtAno","swSerie",
          "panTabsGen","panTabsGenInner","scrTabsGen","btnTabGenIzq","btnTabGenDer",
          "panProyTabs","panTabsProy","scrTabsProy","btnTabProyIzq","btnTabProyDer","cardCapturasProy","chCapturasProy",
          "panProyTabsA","panTabsProyA","scrTabsProyA","btnTabProyAIzq","btnTabProyADer",
          "panProyTabsS","panTabsProyS","scrTabsProyS","btnTabProySIzq","btnTabProySDer",
          "chOrigen","panWeb","chWebTipo","cmbPlataforma","txtPlataformaOtra",
          "panFisico","cmbFormato","txtFormatoOtro","txtEtiquetas","swAplicarTodos",
          "chDefAudio",
          "chFiltro","wrapIdiomas","panSubsUnicos","chExtraerPGS","chConservarPGS",
          "lblEstado","btnIniciar","btnIniciarTodos","btnReset","btnConsola",
          "panProgreso","barProgreso","lblProgreso","lblProgresoPct",
          "panProgreso2","barProgreso2","lblProgreso2","lblProgreso2Pct","gridListado","gripListado",
          "panTareasAux",
          "navSubida","navAjustes","panSubida","panAjustes",
          "txtTorrentSubir","btnTorrentExaminar","btnTorrentUltimo","lblTorrentInfo",
          "btnCrearTorrentArchivo","btnCrearTorrentCarpeta","panTorrentProgreso","barTorrentProgreso","lblTorrentProgreso","lblTorrentProgresoPct",
          "btnNuevaSubida","panTabsSubida","scrTabs","btnTabIzq","btnTabDer",
          "upTitulo","upCategoria","upTipo","upResolucion","panTV","upTemporada","upEpisodio","upKeywords",
          "btnBuscarTmdb","panResultadosTmdb","upTmdb","upImdb","upTvdb","upMal",
          "cardLogos","bdgLogos","panLogos","btnActualizarLogos","txtLogoPersonalizado","btnUsarLogoPersonalizado",
          "bdgCapturas","btnCapColapsar","panCapturas","btnCapTodas","btnCapNinguna","btnCapInsertar","btnCapAnadir","btnCapGenerar","cmbNumCapturas",
          "upDescripcion","upMediainfo","btnMediaRefrescar","gridDesc","gripDesc","gridMediaInfo","gripMedia",
          "panBbToolbar","btnDescSubir","cardFirmas","bdgFirmas","panFirmas",
          "tabEscribir","tabPrevia","panEdicionTools","panPreview","fdPreview",
          "panSubProgreso","barSubProgreso","lblSubProgreso","lblSubProgresoPct",
          "upAnon","upPersonal","upAudioEd","upProper","upDV","upHDR10P","upHDR10","upModQueue",
          "upNfo","btnNfoExaminar","btnSubir","btnAbrirTorrent","btnVerWeb",
          "cfgTrackerUrl","cfgTrackerToken","chHostImg","panImgbbKey","cfgImgbbKey","cfgTmdbKey",
          "panImgboxCuenta","cfgImgboxUser","cfgImgboxPass","btnEnviarLog","cfgUsuarioSoporte",
          "cfgCarpetaProcesados","btnCfgCarpetaProcesados","cfgCarpetaTorrent","btnCfgCarpetaTorrent")
$ui = @{}
foreach ($r in $refs) { $ui[$r] = $win.FindName($r) }

$script:bc = New-Object System.Windows.Media.BrushConverter
function Brocha($hex) { return $script:bc.ConvertFromString($hex) }

# =========================================================================
# HELPERS DE CHIPS, COMBOS Y PÍLDORAS
# =========================================================================
$script:gruposChips = @{}

function Add-ChipGroup($panel, $nombre, $opciones, $indiceDefecto = 0, [scriptblock]$alCambiar = $null) {
    $lista = @()
    foreach ($o in $opciones) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $win.Resources["Chip"]
        $rb.Content = $o.T
        $rb.GroupName = $nombre
        if ($alCambiar) { $rb.Add_Checked($alCambiar) }
        [void]$panel.Children.Add($rb)
        $lista += [PSCustomObject]@{ Radio = $rb; Valor = $o.V }
    }
    $script:gruposChips[$nombre] = $lista
    if ($indiceDefecto -ge 0 -and $indiceDefecto -lt $lista.Count) { $lista[$indiceDefecto].Radio.IsChecked = $true }
}

function Get-ChipValor($nombre) {
    foreach ($e in $script:gruposChips[$nombre]) { if ($e.Radio.IsChecked) { return $e.Valor } }
    return $null
}
function Set-ChipValor($nombre, $valor) {
    foreach ($e in $script:gruposChips[$nombre]) {
        if ("$($e.Valor)" -eq "$valor") { $e.Radio.IsChecked = $true; return }
    }
}

function Init-Combo($cmb, $opciones, $indiceDefecto = 0) {
    if([object]::ReferenceEquals($opciones,$opcionesIdiomaUnd)){
        # Centenares de pistas comparten el catálogo; no añadir cientos de
        # cadenas por separado a cada selector durante el análisis.
        if(-not $script:undOptionLabels){$script:undOptionLabels=[string[]]@($opcionesIdiomaUnd | ForEach-Object {$_.T})}
        $cmb.ItemsSource=$script:undOptionLabels
    }else{foreach ($o in $opciones) { [void]$cmb.Items.Add($o.T) }}
    $cmb.Tag = $opciones
    if ($indiceDefecto -ge 0 -and $indiceDefecto -lt $opciones.Count) { $cmb.SelectedIndex = $indiceDefecto }
}
function Get-ComboValor($cmb) {
    if ($cmb.SelectedIndex -lt 0) { return $null }
    return $cmb.Tag[$cmb.SelectedIndex].V
}
function Set-ComboValor($cmb, $valor) {
    for ($i = 0; $i -lt $cmb.Tag.Count; $i++) {
        if ("$($cmb.Tag[$i].V)" -eq "$valor") { $cmb.SelectedIndex = $i; return }
    }
}
function Get-CodigoPlataforma($texto) {
    $t = "$texto".Trim()
    if ($t -match "^(\S+)\s+—") { return $Matches[1] }
    return $t
}

# Definiciones AMPLIAS de plataformas: por cada plataforma del combo, todas las formas que pueden
# aparecer en el nombre — código de release, nombre completo, sin coletilla, multipalabra, con/sin
# "+", abreviaturas. 'Alias' = formas inequívocas (se buscan en cualquier parte de las etiquetas).
# 'Ambig' = formas cortas/comunes que SOLO valen si van justo antes de WEB-DL (evitan falsos
# positivos como "It", "Mad Max" o un título que diga "Amazon"). Todo se compara en MAYÚSCULAS.
$script:platDefs = @(
    @{ Cod='NF';    Alias=@('NETFLIX');                                                      Ambig=@('NF') }
    @{ Cod='AMZN';  Alias=@('AMAZON PRIME VIDEO','AMAZON PRIME','PRIME VIDEO','AMAZON','AMZN'); Ambig=@('AMZ') }
    @{ Cod='DSNP';  Alias=@('DISNEY PLUS','DISNEY+','DISNEY','DSNP');                         Ambig=@('DSP') }
    @{ Cod='HMAX';  Alias=@('HBO MAX','HBOMAX','HBO','HMAX');                                 Ambig=@('MAX') }
    @{ Cod='ATVP';  Alias=@('APPLE TV PLUS','APPLE TV+','APPLE TV','APPLETV','ATVP');         Ambig=@('ATV') }
    @{ Cod='iT';    Alias=@('ITUNES','APPLE ITUNES');                                         Ambig=@('IT') }
    @{ Cod='SKST';  Alias=@('SKY SHOWTIME','SKYSHOWTIME','SKST');                             Ambig=@('SKY') }
    @{ Cod='FLMN';  Alias=@('FILMIN','FLMN');                                                 Ambig=@() }
    @{ Cod='MVSTP'; Alias=@('MOVISTAR PLUS','MOVISTAR+','MOVISTAR','MVSTP');                  Ambig=@('M+') }
    @{ Cod='RTVP';  Alias=@('RTVE PLAY','RTVE','RTVP');                                       Ambig=@() }
    @{ Cod='RKTN';  Alias=@('RAKUTEN TV','RAKUTEN','RKTN');                                   Ambig=@() }
)
# Convierte un alias (posiblemente multipalabra) en un regex de palabra completa con separadores
# flexibles entre palabras (espacio/punto/guion/guion bajo). Ej.: "HBO MAX" -> \bHBO[._ -]+MAX\b.
function ConvertTo-RegexAlias($a) {
    $parts = @(($a -split '\s+') | ForEach-Object { [regex]::Escape($_) })
    return '(?<![A-Z0-9])' + ($parts -join '[\s\.\-_]+') + '(?![A-Z0-9])'
}
# Detecta la plataforma SOLO del nombre del archivo (no consulta nada externo). Dos vías:
#  1) La sigla/nombre que va JUSTO antes de WEB-DL/WEBRip (convención de release). Admite también las
#     formas ambiguas cortas (NF, MAX, IT, M+…) porque la posición las hace fiables.
#  2) Cualquier alias inequívoco (nombre completo, sin coletilla, multipalabra…) que aparezca DE LA
#     RESOLUCIÓN EN ADELANTE — la zona de etiquetas —, para no confundir un título que diga "Amazon".
function Detectar-Plataforma($base) {
    $txt = "$base".ToUpperInvariant()
    # 1) Token (incluida "+") inmediatamente antes de WEB-DL/WEBRip.
    if ($txt -match '([A-Z0-9\+]{2,18})[\s\.\-_]+WEB[\s\.\-_]?(?:DL|RIP)\b') {
        $cand = "$($Matches[1])"
        foreach ($d in $script:platDefs) {
            foreach ($a in (@($d.Alias) + @($d.Ambig))) {
                if ($cand -eq ($a -replace '\s+', '')) { return $d.Cod }   # compara sin espacios (HBOMAX = HBO MAX)
            }
        }
    }
    # 2) Búsqueda de alias inequívocos en la zona de etiquetas (de la resolución en adelante; si no
    #    hay resolución reconocible, en todo el nombre).
    $cola = $txt
    if ($txt -match '\b(?:2160P|1080P|720P|576P|480P|UHD|4K)\b') { $cola = $txt.Substring($txt.IndexOf($Matches[0])) }
    foreach ($d in $script:platDefs) {
        foreach ($a in @($d.Alias)) {
            if ($cola -match (ConvertTo-RegexAlias $a)) { return $d.Cod }
        }
    }
    return $null
}
# Índice del item del combo cuyo código coincide con $codigo (-1 si no está).
function Get-IndicePlataforma($codigo) {
    if (-not $codigo) { return -1 }
    for ($i = 0; $i -lt $ui.cmbPlataforma.Items.Count; $i++) {
        if ((Get-CodigoPlataforma $ui.cmbPlataforma.Items[$i]) -eq $codigo) { return $i }
    }
    return -1
}

# Píldora pequeña para la lista de análisis ("2160p", "DV", "DTS-HD MA spa"...)
function New-Pill($texto, $estilo = "gris") {
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = [System.Windows.CornerRadius]::new(5)
    $b.Padding = [System.Windows.Thickness]::new(7, 1, 7, 2)
    $b.Margin  = [System.Windows.Thickness]::new(0, 3, 5, 0)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $texto
    $t.FontSize = 10.5
    switch ($estilo) {
        "accent" { $b.Background = Brocha "#3A1518"; $t.Foreground = Brocha "#FF9B9B" }
        "hdr"    { $b.Background = Brocha "#3A2440"; $t.Foreground = Brocha "#E8A8D8" }
        "warn"   { $b.Background = Brocha "#3E3624"; $t.Foreground = Brocha "#F2C94C" }
        default  { $b.Background = Brocha "#222227"; $t.Foreground = Brocha "#9C9CA8" }
    }
    $b.Child = $t
    return $b
}

# =========================================================================
# LÓGICA DE LA INTERFAZ (antes de crear los chips: sus eventos se disparan ya
# durante la construcción al marcar el chip por defecto)
# =========================================================================
function Set-Estado($texto, $tipo = "info") {
    $ui.lblEstado.Text = $texto
    $ui.lblEstado.Foreground = switch ($tipo) {
        "ok"    { $win.Resources["OkBrush"] }
        "error" { $win.Resources["ErrBrush"] }
        default { $win.Resources["SubBrush"] }
    }
}

function Set-Badge($nombre, $texto, $tipo = "muted") {
    $ui[$nombre].Text = $texto
    $ui[$nombre].Foreground = switch ($tipo) {
        "ok"   { $win.Resources["OkBrush"] }
        "warn" { $win.Resources["WarnBrush"] }
        "sub"  { $win.Resources["SubBrush"] }
        default { $win.Resources["MutedBrush"] }
    }
}

function Actualizar-Proyecto {
    if (-not $ui -or -not $ui.panProyectoDatos) { return }
    $on = [bool]$ui.swProyecto.IsChecked
    $ui.panProyectoDatos.IsEnabled = $on
    $ui.panProyectoDatos.Opacity = if ($on) { 1.0 } else { 0.45 }
    $esWeb = ((Get-ChipValor "origen") -ne "FISICO")
    $ui.panWeb.Visibility    = if ($esWeb) { "Visible" }   else { "Collapsed" }
    $ui.panFisico.Visibility = if ($esWeb) { "Collapsed" } else { "Visible" }
}

function Actualizar-Filtro {
    if (-not $ui -or -not $ui.wrapIdiomas) { return }
    $ui.wrapIdiomas.Visibility = if ((Get-ChipValor "filtro") -eq "PERSONALIZADA") { "Visible" } else { "Collapsed" }
}

function Actualizar-Torrent {
    if (-not $ui -or -not $ui.panTorrentDatos) { return }
    $v = Get-ChipValor "torrent"
    $crearTorrent = ("$v" -in @("INDIVIDUAL", "PACK", "AMBOS"))
    $ui.panTorrentDatos.Visibility = if ($crearTorrent) { "Visible" } else { "Collapsed" }
    $ui.panPackNombre.Visibility   = if ("$v" -in @("PACK", "AMBOS")) { "Visible" } else { "Collapsed" }
    # La ubicación del torrent solo aparece tras elegir que se cree uno.
    if ($ui.txtSalidaTorrent) { $ui.txtSalidaTorrent.IsEnabled = $crearTorrent }
    if ($ui.btnSalidaTorrent) { $ui.btnSalidaTorrent.IsEnabled = $crearTorrent }
    if ($ui.lblSalidaTorrent) { $ui.lblSalidaTorrent.Visibility = if ($crearTorrent) { 'Visible' } else { 'Collapsed' } }
    if ($ui.txtSalidaTorrent) { $ui.txtSalidaTorrent.Parent.Visibility = if ($crearTorrent) { 'Visible' } else { 'Collapsed' } }
    Rellenar-PackNombre
}

# Último valor que la identificación automática escribió en Título/Año/Serie. Sirve para que, al
# CAMBIAR de carpeta de vídeos, la sugerencia se actualice sola SIN pisar lo que el usuario haya
# editado a mano: solo se sobrescribe si el campo sigue conteniendo el último valor automático
# (o está vacío). Mismo criterio que usa el nombre del pack.
$script:tituloAutoVal = ""
$script:anoAutoVal    = ""
$script:serieAutoVal  = $null   # $null = aún no sugerido automáticamente
# Carpeta cuya identificación ya se aplicó. Si la carpeta escaneada NO coincide con esta, es que el
# usuario ha cambiado de carpeta → se fuerza la reidentificación (aunque el campo tuviera un valor
# heredado de la sesión anterior). Dentro de la MISMA carpeta se respetan las ediciones manuales.
$script:carpetaIdentificada = ""

# Nombre automático del pack: el del primer episodio seleccionado quitándole el "Exx" (S01E01 → S01),
# es decir el nombre del episodio sin el número de capítulo. Coincide con la convención que usa
# HDZnew para nombrar el .torrent del pack.
$script:packNombreAutoVal = ""
function Get-NombrePackAuto {
    # Previsualización del nombre del pack con el NAMING PROCESADO (título del proyecto + año +
    # temporada), no el del vídeo original. Si no hay título de proyecto todavía, respalda al nombre
    # original (sin el episodio). El nombre definitivo del pack lo pone el motor desde el archivo ya
    # procesado (con resolución/plataforma/códec), salvo que edites este campo a mano.
    $nombres = @($script:ultimoScan | Where-Object { $script:seleccion[$_.Nombre] -ne $false } |
                 ForEach-Object { $_.Nombre } | Sort-Object)
    if ($nombres.Count -eq 0) { return "" }
    $tit = "$($ui.txtTitulo.Text)".Trim()
    $ano = "$($ui.txtAno.Text)".Trim()
    $epTag = if ($script:episodiosMap.ContainsKey($nombres[0])) { "$($script:episodiosMap[$nombres[0]])" } else { Detectar-EpisodioGui $nombres[0] }
    $temp = if ($epTag -match "(?i)S(\d{1,4})") { "S$($Matches[1].PadLeft(2,'0'))" } else { "" }
    if ($tit) {
        $p = $tit
        if ($ano) { $p += " ($ano)" }
        if ($temp) { $p += " $temp" }
        return ($p -replace '\s+', ' ').Trim()
    }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($nombres[0])
    return (($base -replace '(?i)\b(S\d{1,3})E\d{1,4}(?:-E?\d{1,4})*\b', '$1') -replace '\s+', ' ').Trim()
}
# Rellena el campo del nombre del pack cuando el torrent está en modo PACK/AMBOS. Respeta una
# edición manual: solo escribe si el campo está vacío o aún contiene el último valor automático.
function Rellenar-PackNombre {
    if (-not $ui -or -not $ui.txtPackNombre) { return }
    if ((Get-ChipValor "torrent") -notin @("PACK", "AMBOS")) { return }
    $auto = Get-NombrePackAuto
    if ([string]::IsNullOrWhiteSpace($auto)) { return }
    $actual = "$($ui.txtPackNombre.Text)"
    if ([string]::IsNullOrWhiteSpace($actual) -or $actual -eq $script:packNombreAutoVal) {
        $ui.txtPackNombre.Text = $auto
        $script:packNombreAutoVal = $auto
    }
}

# Reconstruye los chips de idiomas del filtro personalizado. $detectados = lista de
# @{Cod;Nom;Count} (idiomas reales del lote) o $null para el catálogo completo.
$script:chipsIdiomas = @()
function Reconstruir-ChipsIdiomas($detectados = $null) {
    $marcadosPrev = @($script:chipsIdiomas | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
    $ui.wrapIdiomas.Children.Clear()
    $script:chipsIdiomas = @()
    $fuente = if ($detectados) { $detectados } else { @($idiomasFiltro | ForEach-Object { @{Cod=$_.Cod; Nom=$_.Nom; Count=$null} }) }
    foreach ($idi in $fuente) {
        $tb = New-Object System.Windows.Controls.Primitives.ToggleButton
        $tb.Style = $win.Resources["ChipToggle"]
        $tb.Content = if ($idi.Count) { "$($idi.Nom)  ·  $($idi.Count)" } else { "$($idi.Nom)" }
        $tb.Tag = $idi.Cod
        if ($marcadosPrev -contains "$($idi.Cod)") { $tb.IsChecked = $true }
        [void]$ui.wrapIdiomas.Children.Add($tb)
        $script:chipsIdiomas += $tb
    }
}

# Selector independiente para AUDIO. A diferencia del filtro de subtítulos, aquí no hay modos:
# se muestran los idiomas realmente detectados y todos arrancan marcados. El usuario solo desmarca.
$script:chipsIdiomasAudio = @()
$script:idiomasAudioSeleccionUsuario = $false
function Reconstruir-ChipsIdiomasAudio($detectados = $null) {
    # Solo preservamos una selección previa si el usuario (en la GUI o en la web) ya la cambió.
    # Durante el primer análisis la interfaz puede reconstruirse más de una vez; eso no debe dejar
    # todos los ToggleButton desmarcados por haber encontrado una colección intermedia vacía.
    $teniaSeleccion = $script:idiomasAudioSeleccionUsuario -and (@($script:chipsIdiomasAudio).Count -gt 0)
    $marcadosPrev = @($script:chipsIdiomasAudio | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
    $ui.wrapIdiomasAudio.Children.Clear()
    $script:chipsIdiomasAudio = @()
    foreach ($idi in @($detectados)) {
        $tb = New-Object System.Windows.Controls.Primitives.ToggleButton
        $tb.Style = $win.Resources["ChipToggle"]
        $tb.Content = "$($idi.Nom)  ·  $($idi.Count)"
        $tb.Tag = "$($idi.Cod)"
        $tb.IsChecked = if ($teniaSeleccion) { $marcadosPrev -contains "$($idi.Cod)" } else { $true }
        $tb.Add_Click({ $script:idiomasAudioSeleccionUsuario = $true })
        [void]$ui.wrapIdiomasAudio.Children.Add($tb)
        $script:chipsIdiomasAudio += $tb
    }
}

# =========================================================================
# CONSTRUCCIÓN DE GRUPOS DE OPCIONES
# =========================================================================
# Sin opción «Preguntar»: la GUI decide TODO, el montaje corre sin prompts en consola.
# El primer valor de cada grupo es el predeterminado (índice 0, salvo que se indique otro).
# El chip «modoLote» se registra MÁS ABAJO (tras definir Actualizar-ModoLote), porque su callback
# se dispara al marcar la opción por defecto durante la creación y la función debe existir ya.
# Capturas por archivo (SIEMPRE en el panel «Proyecto», en todos los modos).
Add-ChipGroup $ui.chCapturasProy "capturasProy" @(0,1,2,3,4,5,6,8,10,15,20,30 | ForEach-Object { @{T=$(if ($_ -eq 0) { "Ninguna" } else { "$_" }); V=$_} }) 6
Add-ChipGroup $ui.chOriginales "originales" @(
    @{T="Conservar (.procesado)"; V="PROCESADO"},
    @{T="Mantener intactos"; V="INTACTO"},
    @{T="Borrarlos"; V="BORRAR"}
)
Add-ChipGroup $ui.chSufijo "sufijo" @(@{T="Sí"; V=$true}, @{T="No"; V=$false})
Add-ChipGroup $ui.chTorrent "torrent" @(
    @{T="No"; V="NO"},
    @{T="Uno por archivo"; V="INDIVIDUAL"},
    @{T="Pack del lote"; V="PACK"},
    @{T="Ambos"; V="AMBOS"}
) 0 { Actualizar-Torrent }

Add-ChipGroup $ui.chOrigen "origen" @(
    @{T="WEB (streaming)"; V="WEB"},
    @{T="Físico (disco)"; V="FISICO"}
) 0 { Actualizar-Proyecto }
Add-ChipGroup $ui.chWebTipo "webTipo" @(@{T="WEB-DL"; V="WEB-DL"}, @{T="WEBRip"; V="WEBRip"})

Add-ChipGroup $ui.chDefAudio "defAudio" @(
    @{T="Dolby (DD+ / TrueHD / DD)"; V="DOLBY"},
    @{T="DTS (DTS-HD MA / DTS)"; V="DTS"}
)
Add-ChipGroup $ui.chFiltro "filtro" @(
    @{T="Mantener todos"; V="TODOS"},
    @{T="Solo castellano e inglés"; V="CAST_ENG"},
    @{T="Personalizada"; V="PERSONALIZADA"}
) 0 { Actualizar-Filtro }
Add-ChipGroup $ui.chExtraerPGS "extraerPGS" @(
    @{T="No extraer"; V=$false},
    @{T="Sí, extraer y pausar"; V=$true}
)
Add-ChipGroup $ui.chConservarPGS "conservarPGS" @(
    @{T="Mantener PGS + SRT"; V="CONSERVAR_PGS"},
    @{T="Solo SRT (borrar PGS)"; V="ELIMINAR_PGS"}
)

Reconstruir-ChipsIdiomas
Init-Combo $ui.cmbPlataforma (@($plataformasGui | ForEach-Object { @{T=$_; V=(Get-CodigoPlataforma $_)} }))
Init-Combo $ui.cmbFormato    (@($formatosGui    | ForEach-Object { @{T=$_; V=$_} })) 2

# =========================================================================
# MOTOR DE ANÁLISIS DE VÍDEOS
# =========================================================================
# El trabajo pesado (ffprobe por archivo) corre en un runspace aparte para no
# congelar la interfaz. Devuelve filas con la información cruda de cada vídeo.
$scanWorker = {
    param($rutas)
    $resultado = @()
    foreach ($ruta in $rutas) {
        $fila = @{ Ruta = $ruta; Nombre = (Split-Path $ruta -Leaf); Error = $null; Video = $null; Audios = @(); Subs = @() }
        try {
            $raw = & ffprobe -v error -show_streams -of json "$ruta" 2>$null | Out-String
            $json = $raw | ConvertFrom-Json
            if (-not $json -or -not $json.streams) { throw "ffprobe no devolvió datos" }
            # ffprobe y mkvmerge no siempre usan los mismos IDs (MP4/TS, por ejemplo).
            $trackIds = @{ audio = @(); subtitle = @() }
            $ident = & mkvmerge -J "$ruta" 2>$null | Out-String | ConvertFrom-Json
            if ($ident -and $ident.tracks) {
                $trackIds.audio = @($ident.tracks | Where-Object type -eq 'audio' | ForEach-Object { [int]$_.id })
                $trackIds.subtitle = @($ident.tracks | Where-Object type -eq 'subtitles' | ForEach-Object { [int]$_.id })
            }
            foreach ($s in $json.streams) {
                $tipo = "$($s.codec_type)"
                $lang  = ""
                $title = ""
                if ($s.PSObject.Properties.Name -contains "tags" -and $s.tags) {
                    if ($s.tags.PSObject.Properties.Name -contains "language") { $lang = "$($s.tags.language)" }
                    if ($s.tags.PSObject.Properties.Name -contains "title")    { $title = "$($s.tags.title)" }
                }
                $forced = $false
                if ($s.PSObject.Properties.Name -contains "disposition" -and $s.disposition) {
                    $forced = ("$($s.disposition.forced)" -eq "1")
                    if ("$($s.disposition.attached_pic)" -eq "1") { continue }   # carátulas: ignorar
                }
                if ($tipo -eq "video" -and -not $fila.Video) {
                    $esDV = $false
                    if ($s.PSObject.Properties.Name -contains "side_data_list" -and $s.side_data_list) {
                        foreach ($sd in $s.side_data_list) {
                            if ($sd.PSObject.Properties.Name -contains "dv_profile") { $esDV = $true }
                        }
                    }
                    $fila.Video = @{
                        Codec  = "$($s.codec_name)"
                        Width  = [int]"0$($s.width)"
                        Height = [int]"0$($s.height)"
                        FieldOrder = "$($s.field_order)"
                        EsDV   = $esDV
                        EsHDR  = ("$($s.color_transfer)" -match "smpte2084|arib-std-b67")
                    }
                } elseif ($tipo -eq "audio") {
                    $canales = [int]"0$($s.channels)"
                    $chLayout = ""
                    if ($s.PSObject.Properties.Name -contains "channel_layout") { $chLayout = "$($s.channel_layout)" }
                    $trackId = if ($fila.Audios.Count -lt $trackIds.audio.Count) { $trackIds.audio[$fila.Audios.Count] } else { [int]$s.index }
                    $fila.Audios += @{ Ruta = $ruta; TrackId = $trackId; Index = [int]"0$($s.index)"; Codec = "$($s.codec_name)"; Profile = "$($s.profile)"; Lang = $lang; Title = $title; Forced = $forced; Channels = $canales; ChannelLayout = $chLayout }
                } elseif ($tipo -eq "subtitle") {
                    $trackId = if ($fila.Subs.Count -lt $trackIds.subtitle.Count) { $trackIds.subtitle[$fila.Subs.Count] } else { [int]$s.index }
                    $fila.Subs += @{ Ruta = $ruta; TrackId = $trackId; Index = [int]"0$($s.index)"; Codec = "$($s.codec_name)"; Lang = $lang; Title = $title; Forced = $forced
                                     EsPGS = ("$($s.codec_name)" -match "pgs") }
                }
            }
        } catch {
            $fila.Error = "$($_.Exception.Message)"
        }
        $resultado += $fila
    }
    return $resultado
}

function Get-VideosCarpeta($carpeta) {
    return @(Get-ChildItem -LiteralPath $carpeta -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -match "(?i)^\.(mkv|mp4|ts)$" -and $_.Name -notmatch "_FINAL" } |
             Sort-Object Name)
}

# Sugerencia de título / año / serie a partir del nombre del primer archivo
function Sugerir-Proyecto($nombres) {
    $n = @($nombres | Select-Object -First 1)
    if (-not $n) { return $null }
    $base = ([System.IO.Path]::GetFileNameWithoutExtension("$n") -replace "[._]", " ")
    $serie = $false
    $corte = $base.Length
    $idxEp = -1; $lenEp = 0
    if ($base -match "(?i)\bS(\d{1,3})\s?E(\d{1,4})\b") {
        $serie = $true
        $idx = $base.IndexOf($Matches[0])
        if ($idx -ge 0) { $idxEp = $idx; $lenEp = $Matches[0].Length; $corte = [Math]::Min($corte, $idx) }
    } elseif ($base -match "(?i)\b(\d{1,2})x(\d{2,4})\b") {
        $serie = $true
        $idx = $base.IndexOf($Matches[0])
        if ($idx -ge 0) { $idxEp = $idx; $lenEp = $Matches[0].Length; $corte = [Math]::Min($corte, $idx) }
    }
    $ano = ""
    if ($base -match "\b(19\d{2}|20\d{2})\b") {
        $ano = $Matches[1]
        $idx = $base.IndexOf($Matches[1]); if ($idx -gt 0) { $corte = [Math]::Min($corte, $idx) }
    }
    $titulo = $base.Substring(0, $corte)
    $titulo = (($titulo -replace "[\(\)\[\]]+", " ") -replace "\s+", " ").Trim().Trim('-').Trim()
    # Releases como «7x01 - Young Sheldon [x265]» empiezan POR el episodio. Antes el texto
    # anterior a «7x01» quedaba vacío y se descartaba también Serie=true, por lo que todos los
    # capítulos terminaban con el mismo nombre y sufijos (1), (2)... Tomar el título de DESPUÉS
    # del código; cortar al llegar a una etiqueta técnica entre corchetes o de calidad/códec.
    if ([string]::IsNullOrWhiteSpace($titulo) -and $serie -and $idxEp -ge 0) {
        $despues = $base.Substring($idxEp + $lenEp)
        $despues = ($despues -replace '^[\s\-–—:]+', '').Trim()
        $mTec = [regex]::Match($despues, '(?i)(?:\s*[\[\{]|\s+\b(?:2160p|1080p|720p|576p|480p|WEB[\s-]?(?:DL|Rip)|BluRay|BDRip|REMUX|x26[45]|H[\s.]?26[45]|HEVC|AVC)\b)')
        if ($mTec.Success -and $mTec.Index -gt 0) { $despues = $despues.Substring(0, $mTec.Index) }
        $titulo = (($despues -replace "[\(\)\[\]]+", " ") -replace "\s+", " ").Trim().Trim('-').Trim()
    }
    # Aunque el release no contenga ningún título aprovechable, conservar la detección de serie:
    # la GUI puede mantener el título escrito por el usuario, pero debe activar episodios.
    if ([string]::IsNullOrWhiteSpace($titulo) -and -not $serie) { return $null }
    # Origen / tipo web / plataforma de streaming desde el nombre.
    $origen = $null; $webTipo = $null; $plat = $null
    if ($base -match "(?i)\bWEB[\s\.\-_]?Rip\b")    { $origen = "WEB"; $webTipo = "WEBRip" }
    elseif ($base -match "(?i)\bWEB[\s\.\-_]?DL\b") { $origen = "WEB"; $webTipo = "WEB-DL" }
    elseif ($base -match "(?i)\bWEB\b")             { $origen = "WEB"; $webTipo = "WEB-DL" }
    # La plataforma se detecta del nombre AUNQUE no aparezca «WEB-DL» (p.ej. «... Disney+ ...»).
    $plat = Detectar-Plataforma $base
    # Si se reconoce una plataforma de streaming y el nombre NO indica disco (BluRay/Remux/BDRip),
    # el origen es WEB (por defecto WEB-DL): así se autorrellena la plataforma como antes.
    if ($plat -and -not $origen -and $base -notmatch "(?i)\b(blu[\s\.\-_]?ray|bd[\s\.\-_]?remux|bd[\s\.\-_]?rip|hd[\s\.\-_]?dvd|blu[\s\.\-_]?disc)\b") {
        $origen = "WEB"; $webTipo = "WEB-DL"
    }
    return @{ Titulo = $titulo; Ano = $ano; Serie = $serie; Origen = $origen; WebTipo = $webTipo; Plataforma = $plat }
}

# Estado neutro de las adaptaciones (sin análisis): tarjetas genéricas visibles,
# sin badges. Las tarjetas de pistas 'und' solo existen con análisis (listan pistas
# concretas), así que arrancan ocultas.
function Reset-Adaptacion {
    if($ui.cardAudioTracks){$ui.cardAudioTracks.Visibility='Collapsed';$ui.panAudioTracks.Children.Clear();$script:audioTrackRows=@()}
    foreach ($b in @("bdgModoLote","bdgFiltroAudio","bdgConvAudio","bdgDefAudio","bdgUndAudio","bdgUndSub","bdgFiltro","bdgSubsUnicos","bdgPGS")) {
        Set-Badge $b ""
    }
    # Las tarjetas condicionales empiezan ocultas mientras llega el nuevo análisis. Así no se
    # muestran durante unos instantes opciones que no aplican al lote (PGS o audio DTS, por ejemplo).
    foreach ($c in @("cardModoLote","cardConvAudio","cardDefAudio","cardFiltro","cardSubsUnicos","cardPGS")) {
        $ui[$c].Visibility = "Collapsed"
    }
    $ui.panConvFilas.Children.Clear(); $script:convRows = @(); $script:convTrackOpts = @()
    foreach ($c in @("cardUndAudio","cardUndSub","phAudio","phSubs")) {
        $ui[$c].Visibility = "Collapsed"
    }
    $ui.panUndAudio.Children.Clear()
    $ui.panUndSub.Children.Clear()
    $ui.panSubsUnicos.Children.Clear()
    $script:undRows = @()
    $script:subsUnicosRows = @()
    $ui.lblSugerencia.Visibility = "Collapsed"
    Reconstruir-ChipsIdiomas
    $ui.cardFiltroAudio.Visibility = "Collapsed"
    Reconstruir-ChipsIdiomasAudio
}

# Crea una sección por cada subtítulo único ambiguo: etiqueta (idioma · formato) + elección
# Completo/Forzado para ESE sub. Guarda las filas para leerlas al lanzar.
$script:subsUnicosRows = @()
function Construir-FilasSubsUnicos($lista) {
    $ui.panSubsUnicos.Children.Clear()
    $script:subsUnicosRows = @()
    $n = 0
    foreach ($it in @($lista)) {
        $n++
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::new(250)
        [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $it.Label; $t.VerticalAlignment = "Center"; $t.FontSize = 13
        $t.Foreground = $win.Resources["TextBrush"]; $t.TextTrimming = "CharacterEllipsis"
        $t.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
        [void]$g.Children.Add($t)
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = "Horizontal"
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $grupo = "subuni_$n"
        $rbC = New-Object System.Windows.Controls.RadioButton
        $rbC.Style = $win.Resources["Chip"]; $rbC.Content = "Completo"; $rbC.GroupName = $grupo; $rbC.IsChecked = $true
        $rbF = New-Object System.Windows.Controls.RadioButton
        $rbF.Style = $win.Resources["Chip"]; $rbF.Content = "Forzado"; $rbF.GroupName = $grupo
        [void]$sp.Children.Add($rbC); [void]$sp.Children.Add($rbF)
        [void]$g.Children.Add($sp)
        [void]$ui.panSubsUnicos.Children.Add($g)
        $script:subsUnicosRows += [PSCustomObject]@{ Cod = $it.Cod; Fmt = $it.Fmt; RbForzado = $rbF }
    }
}

# Construye las filas de asignación de idioma POR PISTA para las tarjetas 'und'.
# $pistas = lista de @{Archivo; Id; Tipo("Audio"/"Sub"); Etiqueta}. Si hay varias,
# añade una fila maestra "aplicar a todas".
$script:undRows = @()
function Construir-FilasUnd($panel, $pistas, $tipo) {
    $panel.Children.Clear()
    $nuevaFila = {
        param($etiqueta, $esMaestra)
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = [System.Windows.Thickness]::new(0, 0, 0, 7)
        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        $c2 = New-Object System.Windows.Controls.ColumnDefinition
        $c2.Width = [System.Windows.GridLength]::new(250)
        [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $etiqueta
        $t.FontSize = 12
        $t.VerticalAlignment = "Center"
        $t.TextTrimming = "CharacterEllipsis"
        $t.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
        $t.Foreground = if ($esMaestra) { $win.Resources["SubBrush"] } else { $win.Resources["TextBrush"] }
        if ($esMaestra) { $t.FontStyle = [System.Windows.FontStyles]::Italic }
        [void]$g.Children.Add($t)
        $cmb = New-Object System.Windows.Controls.ComboBox
        $cmb.Style = $win.Resources["Combo"]
        [System.Windows.Controls.Grid]::SetColumn($cmb, 1)
        Init-Combo $cmb $opcionesIdiomaUnd
        [void]$g.Children.Add($cmb)
        [void]$panel.Children.Add($g)
        return $cmb
    }
    if ($pistas.Count -gt 1) {
        $cmbMaestra = & $nuevaFila "Aplicar a todas las pistas de abajo:" $true
        $tipoCap = $tipo
        $cmbMaestra.Add_SelectionChanged({
            $idx = $cmbMaestra.SelectedIndex
            foreach ($fila in $panel.Children) {
                $destino = $fila.Children[1]
                if ($destino -is [Windows.Controls.ComboBox] -and $destino -ne $cmbMaestra) { $destino.SelectedIndex = $idx }
            }
        }.GetNewClosure())
    }
    foreach ($p in $pistas) {
        $cmb = & $nuevaFila $p.Etiqueta $false
        $clave = "$($p.Archivo)|$($p.Id)|$tipo"
        if ($script:idiomasManuales.ContainsKey($clave)) { Set-ComboValor $cmb $script:idiomasManuales[$clave] }
        $script:undRows += [PSCustomObject]@{ Archivo = $p.Archivo; Id = $p.Id; Tipo = $tipo; Combo = $cmb; Etiqueta = $p.Etiqueta }
        $mapaIdiomas = $script:idiomasManuales
        $timerIdiomas = $script:timerIdiomasManuales
        $cmb.Add_SelectionChanged({
            $valor = Get-ComboValor $cmb
            if (-not $valor) { return }
            if ($valor -eq 'AUTO') { [void]$mapaIdiomas.Remove($clave) }
            else { $mapaIdiomas[$clave] = "$valor" }
            $timerIdiomas.Stop(); $timerIdiomas.Start()
        }.GetNewClosure())
    }
}

# Recalcula filtros sin reiniciar la selección, la cola ni las pestañas.
$script:timerIdiomasManuales = [Windows.Threading.DispatcherTimer]::new()
$script:timerIdiomasManuales.Interval = [TimeSpan]::FromMilliseconds(300)
function Actualizar-IdiomasManuales {
    $script:timerIdiomasManuales.Stop()
    if (@($script:ultimoScan).Count -eq 0) { return }
    $d = Snapshot-DecisionesTab
    $scope = @($script:ultimoScan | Where-Object { $script:seleccion[$_.Nombre] -ne $false })
    if ((Get-ChipValor 'modoLote') -eq 'HETEROGENEO' -and $script:tabProyActual -ge 0) {
        $nombres = @($script:tabsProy[$script:tabProyActual].Archivos)
        $scope = @($scope | Where-Object { $nombres -contains $_.Nombre })
    }
    Construir-Adaptacion $scope
    # Los idiomas recién corregidos deben quedar disponibles y seleccionados.
    $d.AudioLangs = @($d.AudioLangs) + @($script:idiomasManuales.Values)
    $d.FiltroLangs = @($d.FiltroLangs) + @($script:idiomasManuales.Values)
    Restore-DecisionesTab $d
    if ($ui.swRemezcla.IsChecked) { Construir-PistasRemezcla }
    Construir-ListadoLote
}
$script:timerIdiomasManuales.Add_Tick({ Actualizar-IdiomasManuales })

# =========================================================================
# CONVERSOR DE AUDIO MANUAL (por pista) — sustituye a la antigua conversión DTS.
# Tarjeta con N filas; cada fila = una pista de origen -> un formato destino, con
# su interruptor «Mantener original». El segundo selector es DINÁMICO según los
# canales de la pista (2.0/5.1/7.1). Estado en $script:convRows; se serializa a
# $cfg.ConversionesAudioManual y se guarda por pestaña en modo heterogéneo.
# =========================================================================
$script:convRows = @()        # filas activas (objetos UI)
$script:convTrackOpts = @()   # opciones del selector de origen (pistas del archivo representativo)

# Nombre comercial del códec de una pista de origen.
function Get-CodecComercial($codec, $profile) {
    switch -Regex ("$codec") {
        "^eac3$"   { return "DD+" }
        "^ac3$"    { return "DD" }
        "^truehd$" { return "TrueHD" }
        "^dts$"    { if ("$profile" -match "MA") { return "DTS-HD MA" } else { return "DTS" } }
        "^aac$"    { return "AAC" }
        "^flac$"   { return "FLAC" }
        "^opus$"   { return "Opus" }
        default    { return ("$codec").ToUpper() }
    }
}
# Nombre de disposición de canales a partir del nº de canales.
function Get-NombreLayout($canales) {
    switch ([int]$canales) {
        1 { return "1.0" }
        2 { return "2.0" }
        6 { return "5.1" }
        8 { return "7.1" }
        default { return "$canales ch" }
    }
}
# Opciones de destino DINÁMICAS según los canales de la pista de origen.
# Devuelve lista de @{T=etiqueta; V="codec|canales|bitrate"}.
function Get-OpcionesDestino($canales) {
    $c = [int]$canales
    # Layouts destino: el mismo que el origen; si es 7.1 (8 ch), también 5.1 (downmix).
    $layouts = @()
    if     ($c -ge 8) { $layouts = @(8, 6) }   # 7.1 -> 7.1 y 5.1
    elseif ($c -ge 6) { $layouts = @(6) }      # 5.1 -> 5.1
    elseif ($c -le 2) { $layouts = @(2) }      # 2.0/1.0 -> 2.0
    else              { $layouts = @($c, 2) }  # raros (5.0, 6.1): su nº y 2.0
    # Bitrate (kbps) por (códec, canales).
    $brFn = {
        param($cod, $ch)
        switch ("$cod") {
            "ac3"  { if ($ch -le 2) { 256 } else { 640 } }
            "eac3" { if ($ch -le 2) { 256 } elseif ($ch -le 6) { 1024 } else { 1280 } }
            "aac"  { if ($ch -le 2) { 256 } elseif ($ch -le 6) { 640 } else { 896 } }
            default { 256 }
        }
    }
    # Familias comerciales; orden DD+, DD, AAC. LÍMITES REALES del codificador ffmpeg:
    # DD+ (eac3) y DD (ac3) NO pasan de 5.1 (6 canales) — el encoder rechaza 7.1. El único
    # destino 7.1 posible con estos formatos es AAC (hasta 8 canales).
    $codecs = @(
        @{ Cod = "eac3"; Nom = "DD+"; MaxCh = 6 },
        @{ Cod = "ac3";  Nom = "DD";  MaxCh = 6 },
        @{ Cod = "aac";  Nom = "AAC"; MaxCh = 8 }
    )
    $ops = @()
    foreach ($ly in $layouts) {
        foreach ($cd in $codecs) {
            if ($ly -gt $cd.MaxCh) { continue }
            $br = & $brFn $cd.Cod $ly
            $ops += @{ T = "$($cd.Nom) $(Get-NombreLayout $ly)"; V = "$($cd.Cod)|$ly|$br" }
        }
    }
    return $ops
}

# Rellena el ComboBox de destino con las opciones válidas para una pista de N canales.
function Llenar-ComboDestino($cmbDest, $canales) {
    $cmbDest.Items.Clear()
    $ops = Get-OpcionesDestino $canales
    foreach ($o in $ops) { [void]$cmbDest.Items.Add($o.T) }
    $cmbDest.Tag = $ops
    if ($ops.Count -gt 0) { $cmbDest.SelectedIndex = 0 }
}

# Añade UNA fila de conversión al panel. $estado opcional = @{Index; Dest; Mant} para restaurar.
function Add-FilaConv($estado = $null) {
    if (@($script:convTrackOpts).Count -eq 0) { return }
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = [System.Windows.Thickness]::new(0, 0, 0, 9)
    $col0 = New-Object System.Windows.Controls.ColumnDefinition; $col0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $col1 = New-Object System.Windows.Controls.ColumnDefinition; $col1.Width = [System.Windows.GridLength]::Auto
    $col2 = New-Object System.Windows.Controls.ColumnDefinition; $col2.Width = [System.Windows.GridLength]::new(185)
    $col3 = New-Object System.Windows.Controls.ColumnDefinition; $col3.Width = [System.Windows.GridLength]::Auto
    $col4 = New-Object System.Windows.Controls.ColumnDefinition; $col4.Width = [System.Windows.GridLength]::Auto
    foreach ($c in @($col0,$col1,$col2,$col3,$col4)) { [void]$g.ColumnDefinitions.Add($c) }

    # Selector de ORIGEN (pista del vídeo).
    $cmbO = New-Object System.Windows.Controls.ComboBox
    $cmbO.Style = $win.Resources["Combo"]
    $cmbO.VerticalAlignment = "Center"
    Init-Combo $cmbO $script:convTrackOpts 0
    [System.Windows.Controls.Grid]::SetColumn($cmbO, 0)
    [void]$g.Children.Add($cmbO)

    # Flecha.
    $flecha = New-Object System.Windows.Controls.TextBlock
    $flecha.Text = "→"; $flecha.FontSize = 15; $flecha.VerticalAlignment = "Center"
    $flecha.Margin = [System.Windows.Thickness]::new(10, 0, 10, 0)
    $flecha.Foreground = $win.Resources["SubBrush"]
    [System.Windows.Controls.Grid]::SetColumn($flecha, 1)
    [void]$g.Children.Add($flecha)

    # Selector de DESTINO (formato), dinámico.
    $cmbD = New-Object System.Windows.Controls.ComboBox
    $cmbD.Style = $win.Resources["Combo"]
    $cmbD.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($cmbD, 2)
    [void]$g.Children.Add($cmbD)

    # Interruptor «Mantener original».
    $sw = New-Object System.Windows.Controls.CheckBox
    $sw.Style = $win.Resources["Switch"]
    $sw.Content = "Mantener original"
    $sw.IsChecked = $true
    $sw.VerticalAlignment = "Center"
    $sw.Margin = [System.Windows.Thickness]::new(16, 0, 6, 0)
    [System.Windows.Controls.Grid]::SetColumn($sw, 3)
    [void]$g.Children.Add($sw)

    # Botón quitar.
    $btnX = New-Object System.Windows.Controls.Button
    $btnX.Style = $win.Resources["GhostMini"]
    $btnX.Content = "✕"
    $btnX.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($btnX, 4)
    [void]$g.Children.Add($btnX)

    # Al cambiar la pista de origen, recalcular las opciones de destino según sus canales.
    $cmbO.Add_SelectionChanged({
        $i = $cmbO.SelectedIndex
        if ($i -lt 0) { return }
        Llenar-ComboDestino $cmbD ([int]$cmbO.Tag[$i].Channels)
    }.GetNewClosure())

    # Quitar la fila.
    $btnX.Add_Click({
        [void]$ui.panConvFilas.Children.Remove($g)
        $script:convRows = @($script:convRows | Where-Object { $_.Grid -ne $g })
    }.GetNewClosure())

    [void]$ui.panConvFilas.Children.Add($g)
    $fila = [PSCustomObject]@{ Grid = $g; CmbOrigen = $cmbO; CmbDestino = $cmbD; SwMant = $sw }
    $script:convRows += $fila

    # Poblar destino una primera vez (la selección de origen ya está en 0).
    Llenar-ComboDestino $cmbD ([int]$script:convTrackOpts[0].Channels)

    # Restaurar estado guardado (pestaña): pista, formato e interruptor.
    if ($estado) {
        for ($k = 0; $k -lt @($script:convTrackOpts).Count; $k++) {
            $selectionKey = if ($null -ne $estado.SelectionKey) { $estado.SelectionKey } else { $estado.Index }
            if ("$($script:convTrackOpts[$k].V)" -eq "$selectionKey") { $cmbO.SelectedIndex = $k; break }
        }
        if ($estado.Dest) { Set-ComboValor $cmbD $estado.Dest }
        $sw.IsChecked = [bool]$estado.MantenerOriginal
    }
    return $fila
}

# Reconstruye TODAS las filas de conversión. $estados = lista de @{Index;Dest;Mant} (vacío = 1 fila nueva).
function Reconstruir-FilasConv($estados = @()) {
    $ui.panConvFilas.Children.Clear()
    $script:convRows = @()
    if (@($script:convTrackOpts).Count -eq 0) { return }
    # Sin filas por defecto: solo se muestra una conversión si el usuario la añade con
    # «+ Añadir conversión» (o si se restaura una guardada de una pestaña). Antes se autoañadía
    # una fila vacía y, al darle a la ✕, podía colarse igualmente al motor.
    foreach ($e in @($estados)) { [void](Add-FilaConv $e) }
}

# Construye el conversor para un ámbito (homogéneo = selección; heterogéneo = archivos de la peli).
# Toma el PRIMER archivo con audio como representante: en homogéneo todos comparten estructura, y la
# conversión se aplica por índice de pista a cada archivo procesado.
function Initialize-HdzAudioTracks {
    $script:audioTracksExcluded=@{};$script:audioTrackRows=@()
    $card=[Windows.Controls.Border]::new();$card.Style=$win.Resources['Card'];$card.Visibility='Collapsed'
    $body=[Windows.Controls.StackPanel]::new();$title=[Windows.Controls.TextBlock]::new();$title.Style=$win.Resources['H'];$title.Text='Pistas de audio a mantener';[void]$body.Children.Add($title)
    $help=[Windows.Controls.TextBlock]::new();$help.Style=$win.Resources['D'];$help.Text='Marca cada pista que quieras incluir. También se aplica el filtro de idiomas. Las pistas desmarcadas no se convierten.';$help.TextWrapping='Wrap';[void]$body.Children.Add($help)
    $list=[Windows.Controls.StackPanel]::new();$list.Margin='0,12,0,0';[void]$body.Children.Add($list);$card.Child=$body
    $ui.cardAudioTracks=$card;$ui.panAudioTracks=$list;$ui.panAudio.Children.Insert(1,$card)
}
function Build-HdzAudioTracks($scope) {
    if(-not $ui.panAudioTracks){return}
    $ui.panAudioTracks.Children.Clear();$script:audioTrackRows=@();$seen=@{}
    foreach($file in @($scope)) {foreach($audio in @($file.Audios)) {
        $source=if($audio.HdzSource){"$($audio.HdzSource)"}else{"$($file.Ruta)"}
        $id=if($null -ne $audio.TrackId){[int]$audio.TrackId}else{[int]$audio.Index};$key="$source|$id"
        if($seen.ContainsKey($key)){continue};$seen[$key]=$true
        $language=Get-IdiomaPistaGui $audio 'Audio';$label="$(Split-Path $source -Leaf) · pista $id · $(NombreIdioma $language) · $(Get-CodecComercial $audio.Codec $audio.Profile) $(Get-NombreLayout $audio.Channels)"
        if($audio.Title){$label+=" · $($audio.Title)"}
        $choice=[Windows.Controls.CheckBox]::new();$choice.Foreground=$win.Resources['TextBrush'];$choice.Margin='0,4,0,8';$choice.MinHeight=32
        $text=[Windows.Controls.TextBlock]::new();$text.Text=$label;$text.TextWrapping='Wrap';$choice.Content=$text
        $row=[pscustomobject]@{Key=$key;Archivo=$source;Id=$id;Index=[int]$audio.Index;Etiqueta=$label;Choice=$choice};$choice.Tag=$row;$choice.IsChecked=-not $script:audioTracksExcluded.ContainsKey($key)
        $choice.Add_Click({param($sender) $r=$sender.Tag;if($sender.IsChecked){$script:audioTracksExcluded.Remove($r.Key)}else{$script:audioTracksExcluded[$r.Key]=@{Archivo=$r.Archivo;Id=$r.Id;Index=$r.Index}}})
        [void]$ui.panAudioTracks.Children.Add($choice);$script:audioTrackRows+=$row
    }}
    $ui.cardAudioTracks.Visibility=if($script:audioTrackRows.Count){'Visible'}else{'Collapsed'}
}
function Get-HdzExcludedAudioTracks { @($script:audioTracksExcluded.Values) }
function Construir-Conversor($scope) {
    Build-HdzAudioTracks $scope
    $rep = @($scope | Where-Object { @($_.Audios).Count -gt 0 } | Select-Object -First 1)
    $script:convSource = if ($rep.Count) { "$($rep[0].Ruta)" } else { '' }
    if (-not $rep) {
        $ui.cardConvAudio.Visibility = "Collapsed"
        $ui.panConvFilas.Children.Clear(); $script:convRows = @(); $script:convTrackOpts = @()
        return
    }
    $script:convTrackOpts = @()
    foreach ($a in $rep.Audios) {
        $lng  = Get-IdiomaPistaGui $a 'Audio'
        $nomL = if ($lng -eq "und") { "sin idioma" } else { NombreIdioma $lng }
        $cc   = Get-CodecComercial $a.Codec $a.Profile
        $lay  = Get-NombreLayout $a.Channels
        $source = if ($a.HdzSource) { "$($a.HdzSource)" } else { "$script:convSource" }
        $choiceKey = if ($ui.swRemezcla.IsChecked) { 100000 + $script:convTrackOpts.Count } else { $a.Index }
        $label = "pista $($a.Index) · $nomL · $cc $lay"
        if ($ui.swRemezcla.IsChecked) { $label = "$(Split-Path $source -Leaf) · $label" }
        $script:convTrackOpts += @{ T = $label; V = $choiceKey; TrackIndex = $a.Index; Source=$source; Channels = $a.Channels; Lang = $lng; Codec = "$($a.Codec)" }
    }
    $ui.cardConvAudio.Visibility = "Visible"
    Reconstruir-FilasConv @()
    Set-Badge "bdgConvAudio" "$(@($rep.Audios).Count) pista(s) en este vídeo" "muted"
}

# Lee las filas de conversión actuales como lista de hashtables (para $cfg / snapshot).
function Leer-ConversionesActuales {
    $lista = @()
    foreach ($r in @($script:convRows)) {
        # Solo cuentan las filas que SIGUEN en el panel. La ✕ las quita de la vista, pero su
        # baja en $script:convRows ocurre dentro de un GetNewClosure (scope aislado) y no llega
        # al scope real → sin este filtro, una conversión "borrada" se enviaba igual al motor.
        if ($ui.panConvFilas -and -not $ui.panConvFilas.Children.Contains($r.Grid)) { continue }
        $idx = Get-ComboValor $r.CmbOrigen
        $dst = Get-ComboValor $r.CmbDestino
        if ($null -eq $idx -or [string]::IsNullOrWhiteSpace("$dst")) { continue }   # fila incompleta: ignorar
        $partes = "$dst" -split "\|"
        if ($partes.Count -lt 3) { continue }
        $opO = @($script:convTrackOpts | Where-Object { "$($_.V)" -eq "$idx" } | Select-Object -First 1)
        $lista += [ordered]@{
            Index            = if ($opO) { [int]$opO.TrackIndex } else { [int]$idx }
            SelectionKey     = $idx
            ArchivoFuente    = if ($opO) { "$($opO.Source)" } else { "$script:convSource" }
            FuenteExacta     = [bool]$ui.swRemezcla.IsChecked
            FuentePorEpisodio = ([bool]$ui.swRemezcla.IsChecked -and (Es-RemezclaSeriePorEpisodio))
            CodecOrigen      = if ($opO) { "$($opO.Codec)" } else { '' }
            CanalesOrigen    = if ($opO) { [int]$opO.Channels } else { 0 }
            Lang             = if ($opO) { "$($opO.Lang)" } else { "" }
            CodecDestino     = "$($partes[0])"
            CanalesDestino   = [int]$partes[1]
            BitrateK         = [int]$partes[2]
            MantenerOriginal = [bool]$r.SwMant.IsChecked
            Dest             = "$dst"   # "codec|canales|bitrate" para restaurar la fila
        }
    }
    return $lista
}

# Wiring del botón «+ Añadir conversión».
if ($ui.btnConvAdd) { $ui.btnConvAdd.Add_Click({ [void](Add-FilaConv) }) }

# Lista rápida de nombres (feedback inmediato mientras llega el análisis)
function Actualizar-ListaRapida {
    $ui.panListado.Children.Clear()
    $carpetasEntrada = @(Get-CarpetasEntrada)
    $carpeta = if ($carpetasEntrada.Count -gt 0) { $carpetasEntrada[0] } else { $ui.txtCarpeta.Text }
    if ([string]::IsNullOrWhiteSpace($carpeta) -or -not (Test-Path -LiteralPath $carpeta)) {
        $ui.lblResumen.Text = "carpeta no válida"
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = "Selecciona o arrastra una carpeta con los vídeos."
        $t.Foreground = $win.Resources["SubBrush"]; $t.FontSize = 12
        [void]$ui.panListado.Children.Add($t)
        return
    }
    $vids = if (@($script:videosElegidos).Count -gt 0) { @($script:videosElegidos | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object { Get-Item -LiteralPath $_ }) } else { @(Get-VideosCarpeta $carpeta) }
    $ui.lblResumen.Text = "$($vids.Count) vídeo(s)"
    if ($vids.Count -eq 0) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = "No hay vídeos (.mkv / .mp4 / .ts) en esta carpeta."
        $t.Foreground = $win.Resources["SubBrush"]; $t.FontSize = 12
        [void]$ui.panListado.Children.Add($t)
        return
    }
    foreach ($v in $vids) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = "•  $($v.Name)"
        $t.Foreground = $win.Resources["TextBrush"]
        $t.FontSize = 12.5
        $t.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $t.TextTrimming = "CharacterEllipsis"
        [void]$ui.panListado.Children.Add($t)
    }
}

# --- Selección de archivos: qué vídeos del análisis se procesarán ---
$script:seleccion = @{}        # nombre de archivo -> $true/$false (ausente = seleccionado)
$script:videosElegidos = @()
$script:restringirSeleccion = $null   # si es una lista de nombres, SOLO esos quedan marcados tras el análisis
                                       # (lo usa «Elegir vídeos…»); se aplica una vez y se limpia
$script:ultimoScan = @()       # último resultado de análisis (para re-adaptar sin re-escanear)
$script:carpetaScan = ""       # carpeta a la que pertenece la selección actual
$script:construyendoLista = $false   # evita que los eventos de las casillas se disparen al reconstruir
# Varias temporadas de una misma serie. Se analizan juntas para compartir decisiones, pero al
# lanzar se crea UN trabajo por carpeta: cada temporada conserva su pack/torrent independiente.
$script:carpetasTemporadas = @()
$script:cambioCarpetaInterno = $false

function Get-CarpetasEntrada {
    $validas = @($script:carpetasTemporadas | Where-Object {
        -not [string]::IsNullOrWhiteSpace("$_") -and (Test-Path -LiteralPath "$_" -PathType Container)
    })
    if ($validas.Count -gt 0) { return @($validas) }
    $p = "$($ui.txtCarpeta.Text)".Trim()
    if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { return @($p) }
    return @()
}

function Actualizar-DescripcionCarpetas {
    $cs = @(Get-CarpetasEntrada)
    if ($cs.Count -gt 1) {
        $nombres = @($cs | ForEach-Object { Split-Path $_ -Leaf })
        $ui.lblCarpetaDesc.Text = "Lote de $($cs.Count) temporadas: $($nombres -join ' · '). Se analizarán juntas y se procesarán en cola, una carpeta por trabajo."
        $ui.lblCarpetaDesc.ToolTip = ($cs -join "`n")
    } else {
        $ui.lblCarpetaDesc.Text = "Elige una carpeta o vídeos concretos. Añade temporadas para procesarlas en el mismo lote."
        $ui.lblCarpetaDesc.ToolTip = $null
    }
}

function Set-CarpetasTemporadas($carpetas) {
    $unicas = @()
    foreach ($p0 in @($carpetas)) {
        $p = "$p0".Trim().TrimEnd('\')
        if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { continue }
        if (-not (@($unicas | Where-Object { $_.Equals($p, [StringComparison]::OrdinalIgnoreCase) }).Count)) {
            $unicas += $p
        }
    }
    $script:carpetasTemporadas = @($unicas)
    $script:videosElegidos = @()
    $script:restringirSeleccion = $null
    $script:seleccion = @{}
    $script:gruposLanzados = @{}
    if ($unicas.Count -gt 0) {
        $script:cambioCarpetaInterno = $true
        try { $ui.txtCarpeta.Text = $unicas[0] } finally { $script:cambioCarpetaInterno = $false }
    }
    Actualizar-DescripcionCarpetas
}

# =========================================================================
# MULTI-EPISODIO POR VÍDEO (series): un mismo vídeo puede contener 2+ episodios.
# La GUI calcula el tag de episodio por archivo (posible rango, p.ej. S01E01-E02),
# lo deja editable por archivo y lo envía al motor en EpisodiosPorArchivo.
# =========================================================================
$script:episodiosMap = @{}     # nombreArchivo -> "S01E01-E02" (editable por archivo)
$script:epTextboxes  = @{}     # nombreArchivo -> TextBox (para refrescar tras numerar)
$script:salidaMap    = @{}     # nombreArchivo -> carpeta de salida propia del MKV (opcional)
$script:salidaBtns   = @{}     # nombreArchivo -> Button (para refrescar el texto)
$script:gruposLote   = @()     # @( @{ Principal=<nombre>; Miembros=@(nombres) } ) — parejas híbridas = 1 grupo

function Formatear-ListaEpisodiosGui($prefijo, $lista) {
    # Plex representa una secuencia consecutiva por sus extremos:
    # S01E01-E02-E03 -> S01E01-E03. Si la lista tiene saltos, se conserva explícita.
    $nums = @($lista | ForEach-Object { [int]$_ })
    if ($nums.Count -eq 0) { return "" }
    $consecutivos = $true
    for ($i = 1; $i -lt $nums.Count; $i++) {
        if ($nums[$i] -ne ($nums[$i - 1] + 1)) { $consecutivos = $false; break }
    }
    $eps = @($nums | ForEach-Object { "E{0:D2}" -f $_ })
    if ($consecutivos -and $eps.Count -gt 1) { return "$prefijo$($eps[0])-$($eps[-1])" }
    return "$prefijo" + ($eps -join "-")
}

function Detectar-EpisodioGui($nombre) {
    # Espejo simplificado de Detectar-Episodio del motor: "S01E02-E04" / "E02" / "".
    $capturar = {
        param($resto)
        $extras = @(); $rx = [regex]"(?i)^(?:\s*-\s*(?:E|EP)?\s*(\d{1,4})|(?:E|EP)(\d{1,4}))"; $pos = 0
        while ($pos -lt $resto.Length) {
            $m = $rx.Match($resto.Substring($pos)); if (-not $m.Success) { break }
            $extras += $(if ($m.Groups[1].Value) { $m.Groups[1].Value } else { $m.Groups[2].Value }); $pos += $m.Length
        }
        return $extras
    }
    if ($nombre -match "(?i)S(\d{1,4})[\.\s-]*E(\d{1,4})") {
        $t = $Matches[1].PadLeft(2,'0'); $e1 = $Matches[2].PadLeft(2,'0')
        $resto = $nombre.Substring($nombre.IndexOf($Matches[0]) + $Matches[0].Length)
        $lista = @($e1) + @((& $capturar $resto) | ForEach-Object { $_.PadLeft(2,'0') })
        return (Formatear-ListaEpisodiosGui "S$t" $lista)
    }
    if ($nombre -match "(?i)(\d{1,4})x(\d{1,4})") {
        $t = $Matches[1].PadLeft(2,'0'); $e1 = $Matches[2].PadLeft(2,'0')
        $resto = $nombre.Substring($nombre.IndexOf($Matches[0]) + $Matches[0].Length)
        $resto = [regex]::Replace($resto, "(?i)(-\s*)\d{1,4}x(\d{1,4})", '${1}${2}')
        $lista = @($e1) + @((& $capturar $resto) | ForEach-Object { $_.PadLeft(2,'0') })
        return (Formatear-ListaEpisodiosGui "S$t" $lista)
    }
    if ($nombre -match "(?i)(?:^|[\s_.-])(?:E|EP|Cap)[\.\s-]*(\d{1,4})") {
        $e1 = $Matches[1].PadLeft(2,'0')
        $resto = $nombre.Substring($nombre.IndexOf($Matches[0]) + $Matches[0].Length)
        $lista = @($e1) + @((& $capturar $resto) | ForEach-Object { $_.PadLeft(2,'0') })
        return (Formatear-ListaEpisodiosGui "" $lista)
    }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($nombre)
    if ($base -match "^(\d{1,4})(?:[\s_.-]|$)") { return "E$($Matches[1].PadLeft(2,'0'))" }
    return ""
}

function Construir-TagEpisodio([int]$temp, [int]$primerEp, [int]$n) {
    # Rango Plex de N episodios consecutivos: "S01E01-E03" (o "S01E01" si N=1).
    $prefijo = "S{0:D2}" -f $temp
    if ($n -le 1) { return "$prefijo$("E{0:D2}" -f $primerEp)" }
    return "$prefijo$("E{0:D2}" -f $primerEp)-$("E{0:D2}" -f ($primerEp + $n - 1))"
}

function Guardar-EpisodioManual($control) {
    # Los eventos WPF no deben dejar escapar una excepción: con ErrorActionPreference=Stop podría
    # terminar ShowDialog y cerrar toda la aplicación. Guardamos mientras se escribe, sin depender
    # de LostFocus, y aceptamos tanto el rango Plex como una lista no consecutiva explícita.
    try {
        if ($null -eq $control) { return }
        $valor = "$($control.Text)".Trim().ToUpperInvariant()
        $miembros = @("$($control.Tag)" -split '\|' | Where-Object { $_ })
        foreach ($m in $miembros) { $script:episodiosMap["$m"] = $valor }
    } catch {
        try { Set-Estado "No se pudo guardar el episodio editado: $($_.Exception.Message)" "error" } catch {}
    }
}

function Actualizar-VisibilidadMultiEp {
    if ($ui.cardMultiEp) { $ui.cardMultiEp.Visibility = if ([bool]$ui.swSerie.IsChecked) { "Visible" } else { "Collapsed" } }
}

function Aplicar-NumeracionEpisodios {
    # Numera EN ORDEN los vídeos seleccionados: cada uno recibe N episodios consecutivos.
    $temp   = [int]("0" + ("$($ui.txtTemporadaEp.Text)" -replace '\D','')); if ($temp -le 0) { $temp = 1 }
    $primer = [int]("0" + ("$($ui.txtPrimerEp.Text)"    -replace '\D','')); if ($primer -le 0) { $primer = 1 }
    $n      = [int](Get-ComboValor $ui.cmbEpsPorVideo); if ($n -le 0) { $n = 1 }
    # Se numera por GRUPO (una pareja híbrida = un solo vídeo/episodio), no por archivo suelto.
    $grps = @(@($script:gruposLote) | Where-Object { $script:seleccion[$_.Principal] -ne $false } | Sort-Object { "$($_.Principal)" })
    if ($grps.Count -eq 0) { Set-Estado "No hay vídeos seleccionados para numerar." "warn"; return }
    $ep = $primer
    foreach ($g in $grps) {
        $tag = Construir-TagEpisodio $temp $ep $n
        foreach ($m in @($g.Miembros)) { $script:episodiosMap[$m] = $tag }   # ambos miembros del par, mismo episodio
        if ($script:epTextboxes.ContainsKey($g.Principal)) { $script:epTextboxes[$g.Principal].Text = $tag }
        $ep += $n
    }
    Set-Estado "Numeración aplicada: $($grps.Count) vídeo(s) · $n episodio(s) cada uno (T$temp desde E$primer)." "ok"
}

# --- Carpeta de salida del MKV POR ARCHIVO (opcional; si no, la global / junto al origen) ---
function Etiqueta-SalidaArchivo($nombre) {
    if ($script:salidaMap.ContainsKey($nombre) -and "$($script:salidaMap[$nombre])".Trim()) {
        return "📂 " + (Split-Path "$($script:salidaMap[$nombre])" -Leaf)
    }
    return "📂 Elegir carpeta de salida…"
}
function Elegir-SalidaArchivo($nombresJoin) {
    # $nombresJoin = miembros del grupo separados por «|» (una pareja híbrida comparte carpeta).
    $nombres = @("$nombresJoin" -split '\|' | Where-Object { $_ })
    if ($nombres.Count -eq 0) { return }
    $primero = $nombres[0]
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Carpeta de salida del MKV para: $primero"
    $ini = if ($script:salidaMap.ContainsKey($primero) -and (Test-Path -LiteralPath "$($script:salidaMap[$primero])")) { "$($script:salidaMap[$primero])" }
           elseif ($ui.txtSalidaArchivo.Text -and (Test-Path -LiteralPath $ui.txtSalidaArchivo.Text)) { "$($ui.txtSalidaArchivo.Text)" } else { "" }
    if ($ini) { $dlg.SelectedPath = $ini }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($m in $nombres) { $script:salidaMap[$m] = $dlg.SelectedPath }
        if ($script:salidaBtns.ContainsKey($primero)) { $script:salidaBtns[$primero].Content = Etiqueta-SalidaArchivo $primero }
    }
}
function Limpiar-SalidaArchivo($nombresJoin) {
    $nombres = @("$nombresJoin" -split '\|' | Where-Object { $_ })
    foreach ($m in $nombres) { [void]$script:salidaMap.Remove($m) }
    if ($nombres.Count -gt 0 -and $script:salidaBtns.ContainsKey($nombres[0])) { $script:salidaBtns[$nombres[0]].Content = Etiqueta-SalidaArchivo $nombres[0] }
}

function Refrescar-Adaptacion {
    if (@($script:ultimoScan).Count -gt 0) { Aplicar-Analisis $script:ultimoScan }
}

# Aplica el resultado del análisis: lista enriquecida (con casillas de selección)
# + adaptación de tarjetas calculada SOLO sobre los archivos seleccionados.
$script:gruposRender = $null   # $grupos del último análisis (para re-render de la lista por pestaña)
$script:clavesHibRender = @()

# En remezcla hay un único resultado final, pero esta lista es una confirmación visual de las
# fuentes implicadas. No son casillas de selección: las pistas se eligen en el bloque Remezcla.
function Construir-ListadoRemezcla($escaneo) {
    $script:construyendoLista = $true
    $ui.panListado.Children.Clear()
    $script:epTextboxes = @{}
    $script:salidaBtns = @{}
    $cfgSerie = @(Leer-RemezclaCarpetas)
    if (Es-RemezclaSeriePorEpisodio $cfgSerie) {
        # La lista del lote representa los MKV finales (uno por episodio), no mezcla los archivos
        # de las dos carpetas como si fuesen trabajos independientes.
        foreach ($f in @($script:ultimoScan)) {
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Margin = [System.Windows.Thickness]::new(0, 3, 0, 6)
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = "$($f.Nombre)"; $tb.Foreground = $win.Resources["TextBrush"]; $tb.FontSize = 12.5; $tb.TextTrimming = "CharacterEllipsis"
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Style = $win.Resources["Check"]; $cb.Content = $tb; $cb.IsChecked = $true; $cb.IsHitTestVisible = $false
            $cb.ToolTip = "Capítulo de la remezcla; se empareja por SxxEyy."
            [void]$sp.Children.Add($cb)
            $wp = New-Object System.Windows.Controls.WrapPanel
            $wp.Margin = [System.Windows.Thickness]::new(26, 0, 0, 0)
            $ep = Get-ClaveRemezcla ([System.IO.Path]::GetFileNameWithoutExtension("$($f.Nombre)"))
            [void]$wp.Children.Add((New-Pill "REMEZCLA SERIE · $($ep.ToUpper())" "accent"))
            [void]$wp.Children.Add((New-Pill "♪ $(@($f.Audios).Count) audio(s)"))
            [void]$wp.Children.Add((New-Pill "💬 $(@($f.Subs).Count) sub(s)"))
            [void]$sp.Children.Add($wp)
            foreach($sourceCfg in @($cfgSerie | Where-Object { -not $_.Video -and ($_.Audio -or $_.Subs) })) {
                foreach($donor in @($escaneo | Where-Object { (Split-Path $_.Ruta -Parent).TrimEnd('\') -eq "$($sourceCfg.Ruta)".TrimEnd('\') -and (Test-HdzEpisodeMatch (Get-ClaveRemezcla ([IO.Path]::GetFileNameWithoutExtension($_.Nombre))) $ep) })) {
                    $sourceText=[Windows.Controls.TextBlock]::new();$sourceText.Text="↳ $($donor.Nombre) · $(if($sourceCfg.Audio){'Audio '})$(if($sourceCfg.Subs){'Subtítulos'})";$sourceText.Foreground=$win.Resources['SubBrush'];$sourceText.TextWrapping='Wrap';$sourceText.Margin='26,3,0,3';[void]$sp.Children.Add($sourceText)
                }
            }
            $rowSal = New-Object System.Windows.Controls.StackPanel
            $rowSal.Orientation = "Horizontal"; $rowSal.Margin = [System.Windows.Thickness]::new(26, 5, 0, 0)
            $lblSal = New-Object System.Windows.Controls.TextBlock
            $lblSal.Text = "Salida:"; $lblSal.Foreground = $win.Resources["SubBrush"]; $lblSal.FontSize = 11.5; $lblSal.VerticalAlignment = "Center"
            $lblSal.Margin = [System.Windows.Thickness]::new(0, 0, 7, 0)
            $btnSal = New-Object System.Windows.Controls.Button
            $btnSal.Style = $win.Resources["GhostMini"]; $btnSal.FontSize = 11.5; $btnSal.Content = Etiqueta-SalidaArchivo $f.Nombre; $btnSal.Tag = $f.Nombre
            $btnSal.ToolTip = "Carpeta donde irá el MKV final de este capítulo."
            $btnSal.Add_Click({ param($s, $e) Elegir-SalidaArchivo "$($s.Tag)" }.GetNewClosure())
            $script:salidaBtns[$f.Nombre] = $btnSal
            [void]$rowSal.Children.Add($lblSal); [void]$rowSal.Children.Add($btnSal); [void]$sp.Children.Add($rowSal)
            [void]$ui.panListado.Children.Add($sp)
        }
        Actualizar-VisibilidadMultiEp; $script:construyendoLista = $false; return
    }
    foreach ($cfg in @(Leer-RemezclaCarpetas)) {
        if (-not "$($cfg.Archivo)" -or (-not $cfg.Video -and -not $cfg.Audio -and -not $cfg.Subs)) { continue }
        $f = @($escaneo | Where-Object { "$($_.Ruta)" -eq "$($cfg.Archivo)" } | Select-Object -First 1)
        if (-not $f) { continue }
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Margin = [System.Windows.Thickness]::new(0, 3, 0, 6)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = "$($f.Nombre)"; $tb.Foreground = $win.Resources["TextBrush"]; $tb.FontSize = 12.5; $tb.TextTrimming = "CharacterEllipsis"
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $win.Resources["Check"]; $cb.Content = $tb; $cb.IsChecked = $true; $cb.IsHitTestVisible = $false
        $cb.ToolTip = "Fuente obligatoria de la remezcla; sus pistas se configuran arriba."
        [void]$sp.Children.Add($cb)
        $wp = New-Object System.Windows.Controls.WrapPanel
        $wp.Margin = [System.Windows.Thickness]::new(26, 0, 0, 0)
        $roles = @(); if ($cfg.Video) { $roles += "VÍDEO FINAL" }; if ($cfg.Audio) { $roles += "AUDIO" }; if ($cfg.Subs) { $roles += "SUBS" }
        [void]$wp.Children.Add((New-Pill ("REMEZCLA · " + ($roles -join " + ")) "accent"))
        if ($f.Error) {
            [void]$wp.Children.Add((New-Pill "error al analizar: $($f.Error)" "warn"))
        } else {
            if ($f.Video) {
                $res = Get-HdzVideoResolution $f.Video; if (-not $res) { $res = '?' }
                [void]$wp.Children.Add((New-Pill $res))
            }
            if (@($f.Audios).Count -gt 0) { [void]$wp.Children.Add((New-Pill "♪ $(@($f.Audios).Count) audio(s)")) }
            if (@($f.Subs).Count -gt 0) { [void]$wp.Children.Add((New-Pill "💬 $(@($f.Subs).Count) sub(s)")) }
        }
        [void]$sp.Children.Add($wp)
        if ($cfg.Video -and -not $f.Error) {
            $rowSal = New-Object System.Windows.Controls.StackPanel
            $rowSal.Orientation = "Horizontal"; $rowSal.Margin = [System.Windows.Thickness]::new(26, 5, 0, 0)
            $lblSal = New-Object System.Windows.Controls.TextBlock
            $lblSal.Text = "Salida:"; $lblSal.Foreground = $win.Resources["SubBrush"]; $lblSal.FontSize = 11.5; $lblSal.VerticalAlignment = "Center"
            $lblSal.Margin = [System.Windows.Thickness]::new(0, 0, 7, 0)
            $btnSal = New-Object System.Windows.Controls.Button
            $btnSal.Style = $win.Resources["GhostMini"]; $btnSal.FontSize = 11.5; $btnSal.Content = Etiqueta-SalidaArchivo $f.Nombre; $btnSal.Tag = $f.Nombre
            $btnSal.ToolTip = "Carpeta donde irá el MKV final de esta remezcla."
            $btnSal.Add_Click({ param($s, $e) Elegir-SalidaArchivo "$($s.Tag)" }.GetNewClosure())
            $script:salidaBtns[$f.Nombre] = $btnSal
            [void]$rowSal.Children.Add($lblSal); [void]$rowSal.Children.Add($btnSal); [void]$sp.Children.Add($rowSal)
        }
        [void]$ui.panListado.Children.Add($sp)
    }
    Actualizar-VisibilidadMultiEp
    $script:construyendoLista = $false
}

# Pinta la lista de vídeos. En «Cada archivo distinto» filtra a la película de la pestaña activa.
function Construir-ListadoLote {
    $grupos = $script:gruposRender
    if (-not $grupos) { return }
    if ($script:remixScanActivo -and @($script:remixScanCrudo).Count -gt 0) { Construir-ListadoRemezcla $script:remixScanCrudo; return }
    $clavesHibridas = @($script:clavesHibRender)
    $script:construyendoLista = $true
    $ui.panListado.Children.Clear()
    $script:epTextboxes = @{}
    $script:salidaBtns  = @{}
    $esSerieUI = [bool]$ui.swSerie.IsChecked
    # Filtro por pestaña activa: en heterogéneo, cada pestaña muestra SOLO su película (grupo).
    $esHetero = ((Get-ChipValor "modoLote") -eq "HETEROGENEO")
    $activoPrin = $null
    if ($esHetero -and $script:tabProyActual -ge 0 -and $script:tabProyActual -lt @($script:tabsProy).Count) {
        $activoPrin = "$($script:tabsProy[$script:tabProyActual].Principal)"
    }
    foreach ($k in $grupos.Keys) {
        $miembrosK = @($grupos[$k] | ForEach-Object { $_.Nombre })
        if ($esHetero -and $activoPrin -and $miembrosK[0] -ne $activoPrin) { continue }
        $joinK = ($miembrosK -join "|")
        $idxK = -1
        foreach ($f in $grupos[$k]) {
            $idxK++
            $esPrimeroK = ($idxK -eq 0)   # una pareja híbrida = un grupo; controles solo en el 1º
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Margin = [System.Windows.Thickness]::new(0, 3, 0, 6)
            $marcado = ($script:seleccion[$f.Nombre] -ne $false)
            $sp.Opacity = if ($marcado) { 1.0 } else { 0.45 }
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = $f.Nombre
            $tb.Foreground = $win.Resources["TextBrush"]
            $tb.FontSize = 12.5
            $tb.TextTrimming = "CharacterEllipsis"
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Style = $win.Resources["Check"]
            $cb.Content = $tb
            $cb.IsChecked = $marcado
            $cb.Tag = $f.Nombre
            $cb.Add_Click({
                param($s, $e)
                if ($script:construyendoLista) { return }
                $script:seleccion["$($s.Tag)"] = [bool]$s.IsChecked
                Refrescar-Adaptacion
            })
            [void]$sp.Children.Add($cb)
            $wp = New-Object System.Windows.Controls.WrapPanel
            $wp.Margin = [System.Windows.Thickness]::new(26, 0, 0, 0)
            if ($f.Error) {
                [void]$wp.Children.Add((New-Pill "error al analizar: $($f.Error)" "warn"))
            } else {
                if ($f.Video) {
                    $res = Get-HdzVideoResolution $f.Video; if (-not $res) { $res = '?' }
                    [void]$wp.Children.Add((New-Pill $res "accent"))
                    $cod = switch -Regex ("$($f.Video.Codec)") { "hevc" { "HEVC" } "h264" { "H.264" } "av1" { "AV1" } default { "$($f.Video.Codec)".ToUpper() } }
                    [void]$wp.Children.Add((New-Pill $cod))
                    if ($f.Video.EsDV)  { [void]$wp.Children.Add((New-Pill "Dolby Vision" "hdr")) }
                    if ($f.Video.EsHDR) { [void]$wp.Children.Add((New-Pill "HDR" "hdr")) }
                }
                $resAud = @()
                foreach ($a in $f.Audios) {
                    $cA = switch -Regex ("$($a.Codec)") {
                        "^eac3$"   { "DD+" } "^ac3$" { "DD" } "^truehd$" { "TrueHD" }
                        "^dts$"    { if ("$($a.Profile)" -match "MA") { "DTS-HD MA" } else { "DTS" } }
                        default    { "$($a.Codec)".ToUpper() }
                    }
        $lA = Get-IdiomaPistaGui $a 'Audio'
                    $resAud += "$cA $(if ($lA -eq 'und') { '¿?' } else { $lA })"
                }
                if ($resAud.Count -gt 0) { [void]$wp.Children.Add((New-Pill ("♪ " + (($resAud | Select-Object -First 4) -join " · ") + $(if ($resAud.Count -gt 4) { " +$($resAud.Count-4)" } else { "" })))) }
                $nPgs = @($f.Subs | Where-Object { $_.EsPGS }).Count
                $nTxt = @($f.Subs | Where-Object { -not $_.EsPGS }).Count
                if ($f.Subs.Count -gt 0) { [void]$wp.Children.Add((New-Pill "💬 $nTxt texto · $nPgs PGS")) }
                if ($clavesHibridas -contains $k) { [void]$wp.Children.Add((New-Pill "PAREJA HÍBRIDA DV+HDR10" "warn")) }
                $undsArchivo = @($f.Audios | Where-Object { (Get-IdiomaPistaGui $_ 'Audio') -eq "und" }).Count + @($f.Subs | Where-Object { (Get-IdiomaPistaGui $_ 'Sub') -eq "und" }).Count
                if ($undsArchivo -gt 0) { [void]$wp.Children.Add((New-Pill "$undsArchivo pista(s) sin idioma" "warn")) }
            }
            [void]$sp.Children.Add($wp)
            if ($esSerieUI -and -not $f.Error -and $esPrimeroK) {
                $rowEp = New-Object System.Windows.Controls.StackPanel
                $rowEp.Orientation = "Horizontal"; $rowEp.Margin = [System.Windows.Thickness]::new(26, 5, 0, 0)
                $lblEp = New-Object System.Windows.Controls.TextBlock
                $lblEp.Text = "Episodio(s):"; $lblEp.Foreground = $win.Resources["SubBrush"]; $lblEp.FontSize = 11.5
                $lblEp.VerticalAlignment = "Center"; $lblEp.Margin = [System.Windows.Thickness]::new(0, 0, 7, 0)
                $txtEp = New-Object System.Windows.Controls.TextBox
                $txtEp.Style = $win.Resources["Input"]; $txtEp.Width = 160; $txtEp.FontSize = 11.5
                $txtEp.Padding = [System.Windows.Thickness]::new(7, 3, 7, 3)
                $txtEp.ToolTip = "Episodio(s) de este vídeo. Rango Plex si trae varios (ej: S01E01-E03)."
                $txtEp.Text = if ($script:episodiosMap.ContainsKey($f.Nombre)) { "$($script:episodiosMap[$f.Nombre])" } else { Detectar-EpisodioGui $f.Nombre }
                $txtEp.Tag = $joinK
                # No usar GetNewClosure aquí: crea un módulo dinámico que no ve las funciones del
                # script principal y convertiría la edición en una excepción de evento WPF.
                $txtEp.Add_TextChanged({ param($s, $e) Guardar-EpisodioManual $s })
                $script:epTextboxes[$miembrosK[0]] = $txtEp
                [void]$rowEp.Children.Add($lblEp); [void]$rowEp.Children.Add($txtEp)
                [void]$sp.Children.Add($rowEp)
            }
            if (-not $f.Error -and $esPrimeroK) {
                $rowSal = New-Object System.Windows.Controls.StackPanel
                $rowSal.Orientation = "Horizontal"; $rowSal.Margin = [System.Windows.Thickness]::new(26, 5, 0, 0)
                $lblSal = New-Object System.Windows.Controls.TextBlock
                $lblSal.Text = "Salida:"; $lblSal.Foreground = $win.Resources["SubBrush"]; $lblSal.FontSize = 11.5
                $lblSal.VerticalAlignment = "Center"; $lblSal.Margin = [System.Windows.Thickness]::new(0, 0, 7, 0)
                $btnSal = New-Object System.Windows.Controls.Button
                $btnSal.Style = $win.Resources["GhostMini"]; $btnSal.FontSize = 11.5
                $btnSal.Content = Etiqueta-SalidaArchivo $miembrosK[0]
                $btnSal.Tag = $joinK
                $btnSal.ToolTip = "Carpeta donde irá el MKV final de este vídeo. Vacío = la carpeta de salida general o junto al origen."
                $btnSal.Add_Click({ param($s, $e) Elegir-SalidaArchivo "$($s.Tag)" }.GetNewClosure())
                $btnLimpSal = New-Object System.Windows.Controls.Button
                $btnLimpSal.Style = $win.Resources["GhostMini"]; $btnLimpSal.FontSize = 11.5; $btnLimpSal.Content = "✕"
                $btnLimpSal.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0); $btnLimpSal.Tag = $joinK
                $btnLimpSal.ToolTip = "Quitar la carpeta propia (vuelve a la general)"
                $btnLimpSal.Add_Click({ param($s, $e) Limpiar-SalidaArchivo "$($s.Tag)" }.GetNewClosure())
                $script:salidaBtns[$miembrosK[0]] = $btnSal
                [void]$rowSal.Children.Add($lblSal); [void]$rowSal.Children.Add($btnSal); [void]$rowSal.Children.Add($btnLimpSal)
                [void]$sp.Children.Add($rowSal)
            }
            [void]$ui.panListado.Children.Add($sp)
        }
    }
    Actualizar-VisibilidadMultiEp
    $script:construyendoLista = $false
}
function Aplicar-Analisis($filas) {
    $filas = @($filas | Where-Object { $_ })
    if ($filas.Count -eq 0) { Reset-Adaptacion; return }
    $script:ultimoScan = $filas
    $script:gruposLanzados = @{}   # nuevo análisis = conjunto de películas nuevo: nadie lanzado aún

    # Entradas de selección nuevas: marcadas por defecto. $sel = subconjunto marcado.
    # Si «Elegir vídeos…» dejó una restricción, SOLO esos archivos quedan marcados (el resto, fuera);
    # se aplica una única vez y se limpia, para que los toques manuales posteriores manden.
    if ($null -ne $script:restringirSeleccion) {
        $permit = @($script:restringirSeleccion)
        foreach ($f in $filas) { $script:seleccion[$f.Nombre] = ($permit -contains $f.Nombre) }
        $script:restringirSeleccion = $null
    } else {
        foreach ($f in $filas) {
            if (-not $script:seleccion.ContainsKey($f.Nombre)) { $script:seleccion[$f.Nombre] = $true }
        }
    }
    $sel = @($filas | Where-Object { $script:seleccion[$_.Nombre] -ne $false })

    # ---- agrupación (mismo criterio que el script) e híbridos ----
    $grupos = [ordered]@{}
    foreach ($f in $filas) {
        $k = (([System.IO.Path]::GetFileNameWithoutExtension($f.Nombre) -replace $normalizadorAgrupacion, "") -replace "\s+", " ").Trim()
        if (-not $grupos.Contains($k)) { $grupos[$k] = @() }
        $grupos[$k] += $f
    }
    $clavesHibridas = @()
    foreach ($k in $grupos.Keys) {
        $g = $grupos[$k]
        if ($g.Count -ge 2) {
            $conDV = @($g | Where-Object { $_.Video -and $_.Video.EsDV })
            $sinDV = @($g | Where-Object { $_.Video -and -not $_.Video.EsDV })
            if ($conDV.Count -gt 0 -and $sinDV.Count -gt 0) { $clavesHibridas += $k }
        }
    }
    # Estructura de grupos (cada grupo = un MKV final; una pareja híbrida DV+HDR10 es UN grupo con 2
    # archivos). Se usa para mostrar los controles por-grupo (episodio, salida) una sola vez.
    $script:gruposLote = @()
    foreach ($k in $grupos.Keys) {
        $miembros = @($grupos[$k] | ForEach-Object { $_.Nombre })
        if ($miembros.Count -gt 0) { $script:gruposLote += @{ Principal = $miembros[0]; Miembros = $miembros } }
    }

    # Agrupación SOLO de los seleccionados (la adaptación de tarjetas se basa en esto)
    $gruposSel = [ordered]@{}
    foreach ($f in $sel) {
        $k = (([System.IO.Path]::GetFileNameWithoutExtension($f.Nombre) -replace $normalizadorAgrupacion, "") -replace "\s+", " ").Trim()
        if (-not $gruposSel.Contains($k)) { $gruposSel[$k] = @() }
        $gruposSel[$k] += $f
    }
    # Grupos (= películas) para las pestañas de proyecto del modo heterogéneo: cada grupo aporta
    # su archivo principal (1º) y la lista de archivos que comparten identidad.
    $script:gruposProy = @()
    foreach ($k in $gruposSel.Keys) {
        $archs = @($gruposSel[$k] | ForEach-Object { $_.Nombre })
        if ($archs.Count -gt 0) { $script:gruposProy += @{ Clave = $k; Principal = $archs[0]; Archivos = $archs } }
    }

    # ---- detecciones globales (sobre los SELECCIONADOS) ----
    $archivosDTS  = @($sel | Where-Object { @($_.Audios | Where-Object { $_.Codec -match "dts" }).Count -gt 0 })
    $archivosPGS  = @($sel | Where-Object { @($_.Subs | Where-Object { $_.EsPGS }).Count -gt 0 })
    $pistasUndAudio = @()
    $pistasUndSub   = @()
    $archUndAudio = @{}
    $archUndSub   = @{}
    $idiomasAudio = [ordered]@{}
    $idiomasSubs = [ordered]@{}
    foreach ($f in $sel) {
        foreach ($a in $f.Audios) {
            $cAudio = Get-IdiomaPistaGui $a 'Audio'
            # Todas las pistas se pueden corregir, incluso si ya declaran idioma.
                $archUndAudio[$f.Nombre] = $true
                $etCodec = switch -Regex ("$($a.Codec)") {
                    "^eac3$" { "DD+" } "^ac3$" { "DD" } "^truehd$" { "TrueHD" }
                    "^dts$"  { if ("$($a.Profile)" -match "MA") { "DTS-HD MA" } else { "DTS" } }
                    default  { "$($a.Codec)".ToUpper() }
                }
                $etiq = "$($f.Nombre)  —  pista $($a.Index) · $etCodec · detectado: $(NombreIdioma (ConvCanon $a.Lang $a.Title))"
                if ($a.Title) { $etiq += " · «$($a.Title)»" }
                $id = if ($null -ne $a.TrackId) { $a.TrackId } else { $a.Index }
                $pistasUndAudio += @{ Archivo = $f.Ruta; Id = $id; Etiqueta = $etiq }
            if ($cAudio -ne 'und') {
                if (-not $idiomasAudio.Contains($cAudio)) { $idiomasAudio[$cAudio] = 0 }
                $idiomasAudio[$cAudio] = $idiomasAudio[$cAudio] + 1
            }
        }
        foreach ($s in $f.Subs) {
            $c = Get-IdiomaPistaGui $s 'Sub'
            # Todas las pistas se pueden corregir, incluso si ya declaran idioma.
                $archUndSub[$f.Nombre] = $true
                $fmt = if ($s.EsPGS) { "PGS" } else { "Texto" }
                $etiq = "$($f.Nombre)  —  pista $($s.Index) · $fmt · detectado: $(NombreIdioma (ConvCanon $s.Lang $s.Title))"
                if ($s.Title) { $etiq += " · «$($s.Title)»" }
                $id = if ($null -ne $s.TrackId) { $s.TrackId } else { $s.Index }
                $pistasUndSub += @{ Archivo = $f.Ruta; Id = $id; Etiqueta = $etiq }
            if ($c -ne 'und') {
                if (-not $idiomasSubs.Contains($c)) { $idiomasSubs[$c] = 0 }
                $idiomasSubs[$c] = $idiomasSubs[$c] + 1
            }
        }
    }

    # Caso Dolby+DTS en el mismo idioma (por grupo): "SI" directo, "CONV" solo si se
    # convierte DTS (idioma con DTS y sin AC3/EAC3), o "NO".
    $casoDolbyDTS = "NO"
    foreach ($k in $gruposSel.Keys) {
        $porIdioma = @{}
        foreach ($f in $gruposSel[$k]) {
            foreach ($a in $f.Audios) {
        $lng = Get-IdiomaPistaGui $a 'Audio'
                if (-not $porIdioma.ContainsKey($lng)) { $porIdioma[$lng] = @{ DTS = $false; Dolby = $false; AC3 = $false } }
                if ($a.Codec -match "dts") { $porIdioma[$lng].DTS = $true }
                if ($a.Codec -match "^(ac3|eac3|truehd)$") { $porIdioma[$lng].Dolby = $true }
                if ($a.Codec -match "^(ac3|eac3)$") { $porIdioma[$lng].AC3 = $true }
            }
        }
        foreach ($lng in $porIdioma.Keys) {
            $i = $porIdioma[$lng]
            if ($i.DTS -and $i.Dolby) { $casoDolbyDTS = "SI" }
            elseif ($i.DTS -and -not $i.AC3 -and $casoDolbyDTS -eq "NO") { $casoDolbyDTS = "CONV" }
        }
        if ($casoDolbyDTS -eq "SI") { break }
    }

    # Subs únicos ambiguos: por grupo, (idioma+formato) con UN solo sub sin señal de forzado/completo.
    # Guardamos un objeto por combinación (clave canónica "cod|Text/PGS") para crear una sección por sub.
    $ambiguosMap = [ordered]@{}
    foreach ($k in $gruposSel.Keys) {
        $combos = @{}
        foreach ($f in $gruposSel[$k]) {
            foreach ($s in $f.Subs) {
        $c = Get-IdiomaPistaGui $s 'Sub'
                $fmt = if ($s.EsPGS) { "PGS" } else { "Text" }
                $kk = "$c|$fmt"
                if (-not $combos.ContainsKey($kk)) { $combos[$kk] = @() }
                $combos[$kk] += $s
            }
        }
        foreach ($kk in $combos.Keys) {
            $lista = $combos[$kk]
            if ($lista.Count -ne 1) { continue }
            $s = $lista[0]
            $tieneSenal = $s.Forced -or ("$($s.Title)" -match "(?i)forced|forzado") -or ("$($s.Title)" -match "(?i)completos?|complete|full")
            if (-not $tieneSenal -and -not $ambiguosMap.Contains($kk)) {
                $parts = $kk -split "\|"
                $fmtDisp = if ($parts[1] -eq "PGS") { "PGS" } else { "Texto" }
                $ambiguosMap[$kk] = [PSCustomObject]@{ Cod = $parts[0]; Fmt = $parts[1]; Label = "$(NombreIdioma $parts[0]) · $fmtDisp" }
            }
        }
    }
    $script:subsAmbiguos = @($ambiguosMap.Values)


    # ---- lista enriquecida: se pinta en Construir-ListadoLote (filtra por pestaña en heterogéneo) ----
    $script:gruposRender = $grupos
    $script:clavesHibRender = @($clavesHibridas)
    Construir-ListadoLote
    $ui.lblResumen.Text = "$($sel.Count) de $($filas.Count) seleccionado(s) · $($grupos.Keys.Count) título(s) · $($clavesHibridas.Count) híbrido(s)"

    # ---- adaptación de tarjetas: lo que no aplica DESAPARECE (no se atenúa) ----
    # Modo de lote
    if ($gruposSel.Keys.Count -gt 1) {
        $ui.cardModoLote.Visibility = "Visible"
        Set-Badge "bdgModoLote" "$($gruposSel.Keys.Count) títulos distintos seleccionados" "ok"
    } else {
        $ui.cardModoLote.Visibility = "Collapsed"
    }
    # Tarjetas de audio/subtítulos: en modo HOMOGÉNEO se construyen aquí del agregado; en
    # HETEROGENEO las construye Aplicar-TabActiva por pestaña (con el archivo de cada película).
    if ((Get-ChipValor "modoLote") -ne "HETEROGENEO") {
    # Filtro de idiomas de audio: solo aporta una decisión cuando hay más de uno.
    if ($idiomasAudio.Keys.Count -gt 1) {
        $ui.cardFiltroAudio.Visibility = "Visible"
        $detAudio = @($idiomasAudio.Keys | ForEach-Object { @{Cod=$_; Nom=(NombreIdioma $_); Count=$idiomasAudio[$_]} })
        Reconstruir-ChipsIdiomasAudio $detAudio
        Set-Badge "bdgFiltroAudio" "$($idiomasAudio.Keys.Count) idiomas: $(@($idiomasAudio.Keys | ForEach-Object { NombreIdioma $_ }) -join ', ')" $(if ($idiomasAudio.Keys.Count -gt 3) { "warn" } else { "ok" })
    } else {
        $ui.cardFiltroAudio.Visibility = "Collapsed"
        Reconstruir-ChipsIdiomasAudio
    }
    # Conversor de audio (sustituye a la antigua tarjeta DTS)
    Construir-Conversor $sel
    # Default audio
    switch ($casoDolbyDTS) {
        "SI"   { $ui.cardDefAudio.Visibility = "Visible"; Set-Badge "bdgDefAudio" "Dolby y DTS conviven en el mismo idioma" "ok" }
        "CONV" { $ui.cardDefAudio.Visibility = "Visible"; Set-Badge "bdgDefAudio" "aplicará si conviertes DTS a E-AC3" "warn" }
        default { $ui.cardDefAudio.Visibility = "Collapsed" }
    }
    # und audio / und subs: una fila con selector POR PISTA
    if ($pistasUndAudio.Count -gt 0) {
        $ui.cardUndAudio.Visibility = "Visible"
        Construir-FilasUnd $ui.panUndAudio $pistasUndAudio "Audio"
        Set-Badge "bdgUndAudio" "$($pistasUndAudio.Count) pista(s) editables en $($archUndAudio.Keys.Count) archivo(s)" "muted"
    } else {
        $ui.cardUndAudio.Visibility = "Collapsed"
        $ui.panUndAudio.Children.Clear()
    }
    if ($pistasUndSub.Count -gt 0) {
        $ui.cardUndSub.Visibility = "Visible"
        Construir-FilasUnd $ui.panUndSub $pistasUndSub "Sub"
        Set-Badge "bdgUndSub" "$($pistasUndSub.Count) subtítulo(s) editables en $($archUndSub.Keys.Count) archivo(s)" "muted"
    } else {
        $ui.cardUndSub.Visibility = "Collapsed"
        $ui.panUndSub.Children.Clear()
    }
    # Filtro de idiomas: chips con los idiomas REALES y sus recuentos
    if ($idiomasSubs.Keys.Count -gt 0) {
        $ui.cardFiltro.Visibility = "Visible"
        $det = @($idiomasSubs.Keys | ForEach-Object { @{Cod=$_; Nom=(NombreIdioma $_); Count=$idiomasSubs[$_]} })
        Reconstruir-ChipsIdiomas $det
        $nota = if ($idiomasSubs.Keys.Count -gt 3) { " — más de 3: revisa el filtro" } else { "" }
        Set-Badge "bdgFiltro" "$($idiomasSubs.Keys.Count) idioma(s): $(@($idiomasSubs.Keys | ForEach-Object { NombreIdioma $_ }) -join ', ')$nota" $(if ($idiomasSubs.Keys.Count -gt 3) { "warn" } else { "ok" })
    } else {
        $ui.cardFiltro.Visibility = "Collapsed"
        Reconstruir-ChipsIdiomas
    }
    # Subs únicos ambiguos: una sección por sub (Construir-FilasSubsUnicos crea una fila por cada uno)
    if (@($script:subsAmbiguos).Count -gt 0) {
        $ui.cardSubsUnicos.Visibility = "Visible"
        Set-Badge "bdgSubsUnicos" "$(@($script:subsAmbiguos).Count) sin definir" "warn"
        Construir-FilasSubsUnicos $script:subsAmbiguos
    } else {
        $ui.cardSubsUnicos.Visibility = "Collapsed"
        $ui.panSubsUnicos.Children.Clear()
        $script:subsUnicosRows = @()
    }
    # PGS
    if ($archivosPGS.Count -gt 0) {
        $ui.cardPGS.Visibility = "Visible"
        $totPgs = 0; foreach ($f in $sel) { $totPgs += @($f.Subs | Where-Object { $_.EsPGS }).Count }
        Set-Badge "bdgPGS" "$totPgs pista(s) PGS en $($archivosPGS.Count) archivo(s)" "ok"
    } else {
        $ui.cardPGS.Visibility = "Collapsed"
    }
    # Tarjetas de "sección sin nada que configurar"
    $audioVacio = ($ui.cardFiltroAudio.Visibility -ne "Visible") -and ($ui.cardConvAudio.Visibility -ne "Visible") -and ($ui.cardDefAudio.Visibility -ne "Visible") -and ($ui.cardUndAudio.Visibility -ne "Visible")
    $ui.phAudio.Visibility = if ($audioVacio) { "Visible" } else { "Collapsed" }
    $subsVacio = ($ui.cardUndSub.Visibility -ne "Visible") -and ($ui.cardFiltro.Visibility -ne "Visible") -and
                 ($ui.cardSubsUnicos.Visibility -ne "Visible") -and ($ui.cardPGS.Visibility -ne "Visible")
    $ui.phSubs.Visibility = if ($subsVacio) { "Visible" } else { "Collapsed" }
    }  # fin tarjetas modo HOMOGÉNEO

    # Selección vacía: no hay nada que adaptar ni sugerir; avisar y salir.
    if ($sel.Count -eq 0) {
        $ui.phAudio.Visibility = "Collapsed"
        $ui.phSubs.Visibility = "Collapsed"
        $ui.lblSugerencia.Visibility = "Collapsed"
        Set-Estado "Ningún archivo seleccionado: marca al menos uno en la lista para poder procesar." "error"
        return
    }

    # ---- identificación de proyecto ----
    # En modo «Cada archivo distinto» (HETEROGENEO) la identidad es POR pestaña/película:
    # reconstruimos las pestañas (autorrellenando cada una de su nombre) en vez de la identidad única.
    if ((Get-ChipValor "modoLote") -eq "HETEROGENEO") {
        $ui.lblSugerencia.Visibility = "Collapsed"
        Reconstruir-TabsProy
        Set-Estado "Análisis completado: $($sel.Count) de $($filas.Count) vídeo(s), $($gruposSel.Keys.Count) película(s) — revisa cada pestaña."
        Rellenar-PackNombre
        return
    }
    # ---- sugerencia de proyecto (modo homogéneo: una sola identidad para todo el lote) ----
    $sug = Sugerir-Proyecto @($sel | ForEach-Object { $_.Nombre })
    if ($sug) {
        $cambios = @()
        # ¿Es la primera identificación de ESTA carpeta? Si cambiaste de carpeta, se fuerza la
        # reidentificación (sobrescribe aunque el campo tuviera un valor heredado). Dentro de la
        # misma carpeta NO se fuerza: se respeta lo que hayas escrito a mano.
        $forzar = ($script:carpetaScan -ne $script:carpetaIdentificada)
        # Título: sobrescribir si se fuerza, o si está vacío, o si aún contiene la última sugerencia.
        $tActual = "$($ui.txtTitulo.Text)"
        if ($sug.Titulo -and ($forzar -or [string]::IsNullOrWhiteSpace($tActual) -or $tActual -eq $script:tituloAutoVal)) {
            if ($tActual -ne $sug.Titulo) { $cambios += "título" }
            $ui.txtTitulo.Text = $sug.Titulo
            $script:tituloAutoVal = $sug.Titulo
        }
        # Año: mismo criterio. Si la nueva carpeta no aporta año, se limpia el heredado.
        $aActual = "$($ui.txtAno.Text)"
        if ($forzar -or [string]::IsNullOrWhiteSpace($aActual) -or $aActual -eq $script:anoAutoVal) {
            if ($aActual -ne "$($sug.Ano)") { if ($sug.Ano) { $cambios += "año" } }
            $ui.txtAno.Text = "$($sug.Ano)"
            $script:anoAutoVal = "$($sug.Ano)"
        }
        # Serie: se ajusta al forzar, o si no la has tocado desde la última sugerencia.
        if ($forzar -or ($null -eq $script:serieAutoVal) -or ([bool]$ui.swSerie.IsChecked -eq $script:serieAutoVal)) {
            if ([bool]$ui.swSerie.IsChecked -ne [bool]$sug.Serie) { $cambios += "serie" }
            $ui.swSerie.IsChecked = [bool]$sug.Serie
            $script:serieAutoVal  = [bool]$sug.Serie
        }
        # Plataforma / tipo web desde el nombre (solo WEB-DL/WEBRip). Se aplica al IDENTIFICAR una
        # carpeta nueva ($forzar); dentro de la misma carpeta NO se re-toca, para respetar lo que
        # hayas elegido a mano. No pisa una plataforma escrita en «Otra…».
        if ($forzar -and $sug.Origen -eq "WEB") {
            Set-ChipValor "origen" "WEB"
            if ($sug.WebTipo) { Set-ChipValor "webTipo" $sug.WebTipo }
            $idxPlat = Get-IndicePlataforma $sug.Plataforma
            if ($idxPlat -ge 0 -and [string]::IsNullOrWhiteSpace($ui.txtPlataformaOtra.Text)) {
                if ($ui.cmbPlataforma.SelectedIndex -ne $idxPlat) { $cambios += "plataforma" }
                $ui.cmbPlataforma.SelectedIndex = $idxPlat
            }
        }
        # Esta carpeta ya queda identificada: los próximos escaneos de la MISMA carpeta no fuerzan.
        $script:carpetaIdentificada = $script:carpetaScan
        if ($cambios.Count -gt 0) {
            $ui.lblSugerencia.Text = "✦ Identificado del nombre de archivo ($($cambios -join ', ')) — revísalo."
            $ui.lblSugerencia.Visibility = "Visible"
        }
    }

    Set-Estado "Análisis completado: $($sel.Count) de $($filas.Count) vídeo(s) seleccionados, $($gruposSel.Keys.Count) título(s)$(if ($clavesHibridas.Count) { ", $($clavesHibridas.Count) pareja(s) híbrida(s)" })."

    # Autorrellenar el nombre del pack (si está activo el torrent en modo PACK/AMBOS)
    Rellenar-PackNombre
}

# --- Orquestación del escaneo (asíncrono con debounce; síncrono en modo test) ---
$script:scanGen = 0
$script:scanPS = $null
$script:scanAsync = $null
$script:scanGenLanzado = -1

$script:pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:pollTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:pollTimer.Add_Tick({
    if ($script:scanAsync -and $script:scanAsync.IsCompleted) {
        $script:pollTimer.Stop()
        $res = @()
        try { $res = @($script:scanPS.EndInvoke($script:scanAsync)) } catch {}
        try { $script:scanPS.Dispose() } catch {}
        $script:scanPS = $null; $script:scanAsync = $null
        if ($script:scanGenLanzado -eq $script:scanGen) {
            if ($script:remixScanActivo) { $script:remixScanCrudo = @($res); $res = @(Combinar-EscaneoRemezcla $res $script:remixScanFolders) }
            Aplicar-Analisis $res
            if ($script:remixScanActivo) { Construir-InfoRemezcla $script:remixScanCrudo; Construir-PistasRemezcla }
            try { Log-Escaneo "$($ui.txtCarpeta.Text)" $res } catch {}
        }
    }
})

# Detecta originales renombrados «.procesado» en la carpeta actual y muestra/oculta el aviso.
$script:archivosProcesado = @()
function Actualizar-Procesado {
    if (-not $ui -or -not $ui.panProcesado) { return }
    $carpeta = "$($ui.txtCarpeta.Text)".Trim()
    $procesados = @()
    if ($carpeta -and (Test-Path -LiteralPath $carpeta)) {
        try { $procesados = @(Get-ChildItem -LiteralPath $carpeta -File -Filter "*.procesado" -ErrorAction SilentlyContinue) } catch {}
    }
    $script:archivosProcesado = $procesados
    if ($procesados.Count -gt 0) {
        $ui.lblProcesado.Text = "⚠  Hay $($procesados.Count) archivo(s) marcados como «.procesado» en esta carpeta."
        $ui.panProcesado.Visibility = "Visible"
    } else {
        $ui.panProcesado.Visibility = "Collapsed"
    }
}

# =========================================================================
# PESTAÑAS DE PROYECTO (modo «Cada archivo distinto»): una por película, cada una
# con su propia identidad. Mismo patrón que las pestañas de «Torrent y subida»:
# snapshot del estado actual al cambiar de pestaña y restauración del estado destino.
# =========================================================================
$script:tabsProy = @()         # cada elem: @{ Principal=<nombre archivo>; Archivos=@(...); Estado=@{...} }
$script:tabProyActual = -1
$script:gruposProy = @()       # grupos (películas) del último análisis: @{ Clave; Principal; Archivos }

function Nuevo-EstadoProy {
    # Capturas por defecto = el valor global del panel General (chip «capturas»), para no sorprender.
    $capDef = Get-ChipValor "capturasProy"; if ($null -eq $capDef) { $capDef = 6 }
    @{ Titulo=""; Ano=""; EsSerie=$false; Origen="WEB"; WebTipo="WEB-DL"
       PlatIdx=0; PlatOtra=""; FmtIdx=0; FmtOtro=""; Etiquetas=""; Capturas=$capDef
       Originales=(Get-ChipValor "originales"); Sufijo=(Get-ChipValor "sufijo"); Torrent=(Get-ChipValor "torrent") }
}
function Snapshot-Proyecto {
    @{
        Titulo  = "$($ui.txtTitulo.Text)"; Ano = "$($ui.txtAno.Text)"; EsSerie = [bool]$ui.swSerie.IsChecked
        Origen  = (Get-ChipValor "origen"); WebTipo = (Get-ChipValor "webTipo")
        PlatIdx = $ui.cmbPlataforma.SelectedIndex; PlatOtra = "$($ui.txtPlataformaOtra.Text)"
        FmtIdx  = $ui.cmbFormato.SelectedIndex;    FmtOtro  = "$($ui.txtFormatoOtro.Text)"
        Etiquetas = "$($ui.txtEtiquetas.Text)"; Capturas = (Get-ChipValor "capturasProy")
        # Ajustes de General que en «Cada archivo distinto» son propios de cada película.
        Originales = (Get-ChipValor "originales"); Sufijo = (Get-ChipValor "sufijo"); Torrent = (Get-ChipValor "torrent")
    }
}
function Restore-Proyecto($s) {
    $ui.txtTitulo.Text = "$($s.Titulo)"; $ui.txtAno.Text = "$($s.Ano)"; $ui.swSerie.IsChecked = [bool]$s.EsSerie
    if ($s.Origen)  { Set-ChipValor "origen"  $s.Origen }
    if ($s.WebTipo) { Set-ChipValor "webTipo" $s.WebTipo }
    if ([int]$s.PlatIdx -ge 0 -and [int]$s.PlatIdx -lt $ui.cmbPlataforma.Items.Count) { $ui.cmbPlataforma.SelectedIndex = [int]$s.PlatIdx }
    $ui.txtPlataformaOtra.Text = "$($s.PlatOtra)"
    if ([int]$s.FmtIdx -ge 0 -and [int]$s.FmtIdx -lt $ui.cmbFormato.Items.Count) { $ui.cmbFormato.SelectedIndex = [int]$s.FmtIdx }
    $ui.txtFormatoOtro.Text = "$($s.FmtOtro)"
    $ui.txtEtiquetas.Text   = "$($s.Etiquetas)"
    if ($null -ne $s.Capturas) { Set-ChipValor "capturasProy" $s.Capturas }
    if ($null -ne $s.Originales) { Set-ChipValor "originales" $s.Originales }
    if ($null -ne $s.Sufijo)     { Set-ChipValor "sufijo"     $s.Sufijo }
    if ($null -ne $s.Torrent)    { Set-ChipValor "torrent"    $s.Torrent }
    Actualizar-Proyecto   # ajusta visibilidad WEB/Físico según el origen restaurado
}
# Las 3 barras de pestañas (Proyecto, Audio, Subtítulos) comparten estado y se dibujan iguales.
function Get-ScrollersProy {
    @($ui.scrTabsProy, $ui.scrTabsProyA, $ui.scrTabsProyS)
}
function Get-PanelesTabsProy {
    @(
        @{ Pan = $ui.panTabsGenInner; Scr = $ui.scrTabsGen;  Izq = $ui.btnTabGenIzq;  Der = $ui.btnTabGenDer },
        @{ Pan = $ui.panTabsProy;  Scr = $ui.scrTabsProy;  Izq = $ui.btnTabProyIzq;  Der = $ui.btnTabProyDer },
        @{ Pan = $ui.panTabsProyA; Scr = $ui.scrTabsProyA; Izq = $ui.btnTabProyAIzq; Der = $ui.btnTabProyADer },
        @{ Pan = $ui.panTabsProyS; Scr = $ui.scrTabsProyS; Izq = $ui.btnTabProySIzq; Der = $ui.btnTabProySDer }
    )
}
function Update-FlechasTabsProy {
    foreach ($b in Get-PanelesTabsProy) {
        if (-not $b.Scr -or -not $b.Pan) { continue }
        $vp = $b.Scr.ViewportWidth
        if ($vp -le 1) { $b.Izq.Visibility = "Collapsed"; $b.Der.Visibility = "Collapsed"; continue }
        $vis = if ($b.Scr.ExtentWidth -gt ($vp + 1)) { "Visible" } else { "Collapsed" }
        $b.Izq.Visibility = $vis; $b.Der.Visibility = $vis
    }
}
function Construir-TabBarProy {
    foreach ($b in Get-PanelesTabsProy) {
        if (-not $b.Pan) { continue }
        $b.Pan.Children.Clear()
        for ($i = 0; $i -lt @($script:tabsProy).Count; $i++) {
            $idx = $i
            $titulo = "$($script:tabsProy[$i].Principal)"
            if ([string]::IsNullOrWhiteSpace($titulo)) { $titulo = "Película $($i+1)" }
            $cont = New-Object System.Windows.Controls.Border
            $cont.CornerRadius = [System.Windows.CornerRadius]::new(7,7,0,0)
            $cont.Cursor = [System.Windows.Input.Cursors]::Hand
            if ($i -eq $script:tabProyActual) {
                $cont.Background = (Brocha "#0E0E11"); $cont.BorderBrush = $win.Resources["AccentBrush"]
                $cont.BorderThickness = [System.Windows.Thickness]::new(0,2,0,0); $cont.Margin = [System.Windows.Thickness]::new(0,0,3,-1)
                $cont.Padding = [System.Windows.Thickness]::new(13,7,13,8)
            } else {
                $cont.Background = (Brocha "#17171C"); $cont.BorderBrush = $win.Resources["CardBorderBrush"]
                $cont.BorderThickness = [System.Windows.Thickness]::new(1); $cont.Margin = [System.Windows.Thickness]::new(0,4,3,0)
                $cont.Padding = [System.Windows.Thickness]::new(13,5,13,6)
            }
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = $titulo; $t.VerticalAlignment = "Center"; $t.FontSize = 12; $t.ToolTip = $titulo
            $t.Foreground = $(if ($i -eq $script:tabProyActual) { [System.Windows.Media.Brushes]::White } else { $win.Resources["SubBrush"] })
            $cont.Child = $t
            $cont.Add_MouseLeftButtonUp({ param($snd, $e) Cambiar-TabProy $idx }.GetNewClosure())
            [void]$b.Pan.Children.Add($cont)
        }
    }
    Update-FlechasTabsProy
}
function Cambiar-TabProy($idx) {
    if ($idx -eq $script:tabProyActual -or $idx -lt 0 -or $idx -ge @($script:tabsProy).Count) { return }
    if ($script:tabProyActual -ge 0 -and $script:tabProyActual -lt @($script:tabsProy).Count) {
        $script:tabsProy[$script:tabProyActual].Estado = Snapshot-Proyecto
        $script:tabsProy[$script:tabProyActual].Decisiones = Snapshot-DecisionesTab
    }
    $script:tabProyActual = $idx
    Restore-Proyecto $script:tabsProy[$idx].Estado
    Aplicar-TabActiva          # reconstruye las tarjetas de audio/subs de esta peli y aplica sus decisiones
    Construir-TabBarProy
    Construir-ListadoLote      # la lista de General muestra SOLO la película de la pestaña activa
    if (Get-Command Actualizar-BotonesIniciar -EA SilentlyContinue) { Actualizar-BotonesIniciar }  # «Procesar esta»: on/off según la peli
}
# Reconstruye las pestañas a partir de los grupos del último análisis ($script:gruposProy),
# conservando lo que el usuario ya hubiera editado (indexado por archivo principal) y
# autorrellenando las pestañas nuevas desde el nombre del archivo.
function Reconstruir-TabsProy {
    if (-not $ui.panTabsProy) { return }
    if ($script:tabProyActual -ge 0 -and $script:tabProyActual -lt @($script:tabsProy).Count) {
        $script:tabsProy[$script:tabProyActual].Estado = Snapshot-Proyecto
        $script:tabsProy[$script:tabProyActual].Decisiones = Snapshot-DecisionesTab
    }
    $previos = @{}
    foreach ($t in @($script:tabsProy)) { if ($t.Principal) { $previos[$t.Principal] = $t } }
    $nuevas = @()
    foreach ($g in @($script:gruposProy)) {
        if ($previos.ContainsKey($g.Principal)) {
            $t = $previos[$g.Principal]; $t.Archivos = $g.Archivos; $nuevas += $t
        } else {
            $est = Nuevo-EstadoProy
            $sug = Sugerir-Proyecto @($g.Principal)
            if ($sug) {
                $est.Titulo = "$($sug.Titulo)"; $est.Ano = "$($sug.Ano)"; $est.EsSerie = [bool]$sug.Serie
                if ($sug.Origen -eq "WEB") {
                    $est.Origen = "WEB"
                    if ($sug.WebTipo) { $est.WebTipo = $sug.WebTipo }
                    $ip = Get-IndicePlataforma $sug.Plataforma
                    if ($ip -ge 0) { $est.PlatIdx = $ip }
                }
            }
            # Decisiones = $null → al activar la pestaña se usan los valores por defecto de sus tarjetas.
            $nuevas += @{ Principal = $g.Principal; Archivos = $g.Archivos; Estado = $est; Decisiones = $null }
        }
    }
    $script:tabsProy = @($nuevas)
    if (@($script:tabsProy).Count -eq 0) { $script:tabProyActual = -1; Construir-TabBarProy; return }
    if ($script:tabProyActual -lt 0 -or $script:tabProyActual -ge @($script:tabsProy).Count) { $script:tabProyActual = 0 }
    # Pre-cargar las decisiones por defecto de CADA pestaña (construyendo sus tarjetas una vez), para
    # poder enviar valores correctos aunque el usuario no llegue a abrir esa pestaña (p.ej. pistas und).
    for ($i = 0; $i -lt @($script:tabsProy).Count; $i++) {
        if ($null -eq $script:tabsProy[$i].Decisiones) {
            $nombresI = @($script:tabsProy[$i].Archivos)
            $scopeI = @($script:ultimoScan | Where-Object { $nombresI -contains $_.Nombre })
            Construir-Adaptacion $scopeI
            $script:tabsProy[$i].Decisiones = Snapshot-DecisionesTab
        }
    }
    Restore-Proyecto $script:tabsProy[$script:tabProyActual].Estado
    Aplicar-TabActiva          # deja en pantalla las tarjetas de la pestaña activa
    Construir-TabBarProy
    Construir-ListadoLote      # lista filtrada a la película activa
    # Limpia el registro de películas lanzadas de las pestañas que ya no existen (reanálisis, cambios
    # de selección). Así «Todas» y «Procesar esta» vuelven a habilitarse para el conjunto vigente.
    $vigentes = @{}; foreach ($tb in @($script:tabsProy)) { $vigentes["$($tb.Principal)"] = $true }
    foreach ($k in @($script:gruposLanzados.Keys)) { if (-not $vigentes.ContainsKey($k)) { [void]$script:gruposLanzados.Remove($k) } }
    if (Get-Command Actualizar-BotonesIniciar -EA SilentlyContinue) { Actualizar-BotonesIniciar }
}
# --- FASE 2: tarjetas de audio/subtítulos POR PESTAÑA ---
# Reconstruye SOLO las tarjetas de adaptación (DTS, audio por defecto, pistas und, filtro de
# idiomas, subs únicos, PGS) a partir de un subconjunto de archivos ($selScope = entradas de
# $script:ultimoScan). Es una copia parametrizada de la misma lógica de Aplicar-Analisis, para
# poder mostrar las tarjetas del archivo de la pestaña activa sin tocar el camino homogéneo.
function Construir-Adaptacion($selScope) {
    $selScope = @($selScope | Where-Object { $_ })
    # Construir-FilasUnd ACUMULA en $script:undRows (no lo resetea): al construir varias pestañas
    # seguidas se mezclarían las pistas. Lo limpiamos aquí para que cada ámbito empiece de cero.
    $script:undRows = @()
    $gruposScope = [ordered]@{}
    foreach ($f in $selScope) {
        $k = (([System.IO.Path]::GetFileNameWithoutExtension($f.Nombre) -replace $normalizadorAgrupacion, "") -replace "\s+", " ").Trim()
        if (-not $gruposScope.Contains($k)) { $gruposScope[$k] = @() }
        $gruposScope[$k] += $f
    }
    # Detecciones
    $archivosDTS  = @($selScope | Where-Object { @($_.Audios | Where-Object { $_.Codec -match "dts" }).Count -gt 0 })
    $archivosPGS  = @($selScope | Where-Object { @($_.Subs | Where-Object { $_.EsPGS }).Count -gt 0 })
    $pistasUndAudio = @(); $pistasUndSub = @(); $archUndAudio = @{}; $archUndSub = @{}
    $idiomasAudio = [ordered]@{}; $idiomasSubs = [ordered]@{}
    foreach ($f in $selScope) {
        foreach ($a in $f.Audios) {
            $cAudio = Get-IdiomaPistaGui $a 'Audio'
            # Todas las pistas se pueden corregir, incluso si ya declaran idioma.
                $archUndAudio[$f.Nombre] = $true
                $etCodec = switch -Regex ("$($a.Codec)") {
                    "^eac3$" { "DD+" } "^ac3$" { "DD" } "^truehd$" { "TrueHD" }
                    "^dts$"  { if ("$($a.Profile)" -match "MA") { "DTS-HD MA" } else { "DTS" } }
                    default  { "$($a.Codec)".ToUpper() }
                }
                $etiq = "$($f.Nombre)  —  pista $($a.Index) · $etCodec · detectado: $(NombreIdioma (ConvCanon $a.Lang $a.Title))"
                if ($a.Title) { $etiq += " · «$($a.Title)»" }
                $id = if ($null -ne $a.TrackId) { $a.TrackId } else { $a.Index }
                $pistasUndAudio += @{ Archivo = $f.Ruta; Id = $id; Etiqueta = $etiq }
            if ($cAudio -ne 'und') {
                if (-not $idiomasAudio.Contains($cAudio)) { $idiomasAudio[$cAudio] = 0 }
                $idiomasAudio[$cAudio] = $idiomasAudio[$cAudio] + 1
            }
        }
        foreach ($s in $f.Subs) {
            $c = Get-IdiomaPistaGui $s 'Sub'
            # Todas las pistas se pueden corregir, incluso si ya declaran idioma.
                $archUndSub[$f.Nombre] = $true
                $fmt = if ($s.EsPGS) { "PGS" } else { "Texto" }
                $etiq = "$($f.Nombre)  —  pista $($s.Index) · $fmt · detectado: $(NombreIdioma (ConvCanon $s.Lang $s.Title))"
                if ($s.Title) { $etiq += " · «$($s.Title)»" }
                $id = if ($null -ne $s.TrackId) { $s.TrackId } else { $s.Index }
                $pistasUndSub += @{ Archivo = $f.Ruta; Id = $id; Etiqueta = $etiq }
            if ($c -ne 'und') {
                if (-not $idiomasSubs.Contains($c)) { $idiomasSubs[$c] = 0 }
                $idiomasSubs[$c] = $idiomasSubs[$c] + 1
            }
        }
    }
    $casoDolbyDTS = "NO"
    foreach ($k in $gruposScope.Keys) {
        $porIdioma = @{}
        foreach ($f in $gruposScope[$k]) {
            foreach ($a in $f.Audios) {
        $lng = Get-IdiomaPistaGui $a 'Audio'
                if (-not $porIdioma.ContainsKey($lng)) { $porIdioma[$lng] = @{ DTS = $false; Dolby = $false; AC3 = $false } }
                if ($a.Codec -match "dts") { $porIdioma[$lng].DTS = $true }
                if ($a.Codec -match "^(ac3|eac3|truehd)$") { $porIdioma[$lng].Dolby = $true }
                if ($a.Codec -match "^(ac3|eac3)$") { $porIdioma[$lng].AC3 = $true }
            }
        }
        foreach ($lng in $porIdioma.Keys) {
            $i = $porIdioma[$lng]
            if ($i.DTS -and $i.Dolby) { $casoDolbyDTS = "SI" }
            elseif ($i.DTS -and -not $i.AC3 -and $casoDolbyDTS -eq "NO") { $casoDolbyDTS = "CONV" }
        }
        if ($casoDolbyDTS -eq "SI") { break }
    }
    $ambiguosMap = [ordered]@{}
    foreach ($k in $gruposScope.Keys) {
        $combos = @{}
        foreach ($f in $gruposScope[$k]) {
            foreach ($s in $f.Subs) {
        $c = Get-IdiomaPistaGui $s 'Sub'
                $fmt = if ($s.EsPGS) { "PGS" } else { "Text" }
                $kk = "$c|$fmt"
                if (-not $combos.ContainsKey($kk)) { $combos[$kk] = @() }
                $combos[$kk] += $s
            }
        }
        foreach ($kk in $combos.Keys) {
            $lista = $combos[$kk]
            if ($lista.Count -ne 1) { continue }
            $s = $lista[0]
            $tieneSenal = $s.Forced -or ("$($s.Title)" -match "(?i)forced|forzado") -or ("$($s.Title)" -match "(?i)completos?|complete|full")
            if (-not $tieneSenal -and -not $ambiguosMap.Contains($kk)) {
                $parts = $kk -split "\|"
                $fmtDisp = if ($parts[1] -eq "PGS") { "PGS" } else { "Texto" }
                $ambiguosMap[$kk] = [PSCustomObject]@{ Cod = $parts[0]; Fmt = $parts[1]; Label = "$(NombreIdioma $parts[0]) · $fmtDisp" }
            }
        }
    }
    $script:subsAmbiguos = @($ambiguosMap.Values)
    # Aplicación de tarjetas (idéntico criterio que Aplicar-Analisis, ámbito = $selScope)
    if ($idiomasAudio.Keys.Count -gt 1) {
        $ui.cardFiltroAudio.Visibility = "Visible"
        $detAudio = @($idiomasAudio.Keys | ForEach-Object { @{Cod=$_; Nom=(NombreIdioma $_); Count=$idiomasAudio[$_]} })
        Reconstruir-ChipsIdiomasAudio $detAudio
        Set-Badge "bdgFiltroAudio" "$($idiomasAudio.Keys.Count) idiomas: $(@($idiomasAudio.Keys | ForEach-Object { NombreIdioma $_ }) -join ', ')" $(if ($idiomasAudio.Keys.Count -gt 3) { "warn" } else { "ok" })
    } else { $ui.cardFiltroAudio.Visibility = "Collapsed"; Reconstruir-ChipsIdiomasAudio }
    Construir-Conversor $selScope
    switch ($casoDolbyDTS) {
        "SI"   { $ui.cardDefAudio.Visibility = "Visible"; Set-Badge "bdgDefAudio" "Dolby y DTS conviven en el mismo idioma" "ok" }
        "CONV" { $ui.cardDefAudio.Visibility = "Visible"; Set-Badge "bdgDefAudio" "aplicará si conviertes DTS a E-AC3" "warn" }
        default { $ui.cardDefAudio.Visibility = "Collapsed" }
    }
    if ($pistasUndAudio.Count -gt 0) {
        $ui.cardUndAudio.Visibility = "Visible"; Construir-FilasUnd $ui.panUndAudio $pistasUndAudio "Audio"
        Set-Badge "bdgUndAudio" "$($pistasUndAudio.Count) pista(s) editables en $($archUndAudio.Keys.Count) archivo(s)" "muted"
    } else { $ui.cardUndAudio.Visibility = "Collapsed"; $ui.panUndAudio.Children.Clear() }
    if ($pistasUndSub.Count -gt 0) {
        $ui.cardUndSub.Visibility = "Visible"; Construir-FilasUnd $ui.panUndSub $pistasUndSub "Sub"
        Set-Badge "bdgUndSub" "$($pistasUndSub.Count) subtítulo(s) editables en $($archUndSub.Keys.Count) archivo(s)" "muted"
    } else { $ui.cardUndSub.Visibility = "Collapsed"; $ui.panUndSub.Children.Clear() }
    if ($idiomasSubs.Keys.Count -gt 0) {
        $ui.cardFiltro.Visibility = "Visible"
        $det = @($idiomasSubs.Keys | ForEach-Object { @{Cod=$_; Nom=(NombreIdioma $_); Count=$idiomasSubs[$_]} })
        Reconstruir-ChipsIdiomas $det
        $nota = if ($idiomasSubs.Keys.Count -gt 3) { " — más de 3: revisa el filtro" } else { "" }
        Set-Badge "bdgFiltro" "$($idiomasSubs.Keys.Count) idioma(s): $(@($idiomasSubs.Keys | ForEach-Object { NombreIdioma $_ }) -join ', ')$nota" $(if ($idiomasSubs.Keys.Count -gt 3) { "warn" } else { "ok" })
    } else { $ui.cardFiltro.Visibility = "Collapsed"; Reconstruir-ChipsIdiomas }
    if (@($script:subsAmbiguos).Count -gt 0) {
        $ui.cardSubsUnicos.Visibility = "Visible"; Set-Badge "bdgSubsUnicos" "$(@($script:subsAmbiguos).Count) sin definir" "warn"
        Construir-FilasSubsUnicos $script:subsAmbiguos
    } else { $ui.cardSubsUnicos.Visibility = "Collapsed"; $ui.panSubsUnicos.Children.Clear(); $script:subsUnicosRows = @() }
    if ($archivosPGS.Count -gt 0) {
        $ui.cardPGS.Visibility = "Visible"
        $totPgs = 0; foreach ($f in $selScope) { $totPgs += @($f.Subs | Where-Object { $_.EsPGS }).Count }
        Set-Badge "bdgPGS" "$totPgs pista(s) PGS en $($archivosPGS.Count) archivo(s)" "ok"
    } else { $ui.cardPGS.Visibility = "Collapsed" }
    $audioVacio = ($ui.cardFiltroAudio.Visibility -ne "Visible") -and ($ui.cardConvAudio.Visibility -ne "Visible") -and ($ui.cardDefAudio.Visibility -ne "Visible") -and ($ui.cardUndAudio.Visibility -ne "Visible")
    $ui.phAudio.Visibility = if ($audioVacio) { "Visible" } else { "Collapsed" }
    $subsVacio = ($ui.cardUndSub.Visibility -ne "Visible") -and ($ui.cardFiltro.Visibility -ne "Visible") -and
                 ($ui.cardSubsUnicos.Visibility -ne "Visible") -and ($ui.cardPGS.Visibility -ne "Visible")
    $ui.phSubs.Visibility = if ($subsVacio) { "Visible" } else { "Collapsed" }
}
# Snapshot de las decisiones de audio/subs de la pestaña activa (lee las tarjetas actuales).
function Snapshot-DecisionesTab {
    $und = @{}
    foreach ($r in @($script:undRows)) { $und["$($r.Archivo)|$($r.Id)|$($r.Tipo)"] = (Get-ComboValor $r.Combo) }
    $su = @{}
    foreach ($r in @($script:subsUnicosRows)) { $su["$($r.Cod)|$($r.Fmt)"] = $(if ($r.RbForzado.IsChecked) { "Forzado" } else { "Completo" }) }
    @{
        Conv = (Leer-ConversionesActuales); DefAudio = (Get-ChipValor "defAudio"); Filtro = (Get-ChipValor "filtro")
        AudioLangs = @($script:chipsIdiomasAudio | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
        AudioLangsTodos = @($script:chipsIdiomasAudio | ForEach-Object { "$($_.Tag)" })
        AudioTracksExcluded = @($script:audioTrackRows | Where-Object {-not $_.Choice.IsChecked} | ForEach-Object {@{Archivo=$_.Archivo;Id=$_.Id;Index=$_.Index}})
        FiltroLangs = @($script:chipsIdiomas | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
        ExtraerPGS = (Get-ChipValor "extraerPGS"); ConservarPGS = (Get-ChipValor "conservarPGS")
        Und = $und; SubsUnicos = $su
    }
}
# Aplica las decisiones guardadas sobre las tarjetas YA reconstruidas (Construir-Adaptacion antes).
function Restore-DecisionesTab($d) {
    if (-not $d) { return }
    if($d.ContainsKey('AudioTracksExcluded')){
        foreach($row in @($script:audioTrackRows)){$script:audioTracksExcluded.Remove($row.Key);$row.Choice.IsChecked=$true}
        foreach($item in @($d.AudioTracksExcluded)){$key="$($item.Archivo)|$($item.Id)";$script:audioTracksExcluded[$key]=$item;foreach($row in @($script:audioTrackRows)){if($row.Key -eq $key){$row.Choice.IsChecked=$false}}}
    }
    if ($null -ne $d.Conv) { Reconstruir-FilasConv @($d.Conv) }
    if ($d.DefAudio)     { Set-ChipValor "defAudio" $d.DefAudio }
    if ($d.ContainsKey("AudioLangs")) {
        foreach ($tb in $script:chipsIdiomasAudio) { $tb.IsChecked = (@($d.AudioLangs) -contains "$($tb.Tag)") }
    }
    if ($d.ExtraerPGS)   { Set-ChipValor "extraerPGS" $d.ExtraerPGS }
    if ($d.ConservarPGS) { Set-ChipValor "conservarPGS" $d.ConservarPGS }
    if ($d.Filtro)       { Set-ChipValor "filtro" $d.Filtro; Actualizar-Filtro }
    if ($d.Filtro -eq "PERSONALIZADA" -and $d.FiltroLangs) {
        foreach ($tb in $script:chipsIdiomas) { $tb.IsChecked = (@($d.FiltroLangs) -contains "$($tb.Tag)") }
    }
    if ($d.Und) {
        foreach ($r in @($script:undRows)) {
            $k = "$($r.Archivo)|$($r.Id)|$($r.Tipo)"
            if ($d.Und.ContainsKey($k) -and $null -ne $d.Und[$k]) { Set-ComboValor $r.Combo $d.Und[$k] }
        }
    }
    if ($d.SubsUnicos) {
        foreach ($r in @($script:subsUnicosRows)) {
            $k = "$($r.Cod)|$($r.Fmt)"
            if ($d.SubsUnicos.ContainsKey($k) -and $d.SubsUnicos[$k] -eq "Forzado") { $r.RbForzado.IsChecked = $true }
        }
    }
}
# Reconstruye las tarjetas de audio/subs para la pestaña activa y aplica sus decisiones guardadas.
function Aplicar-TabActiva {
    if ($script:tabProyActual -lt 0 -or $script:tabProyActual -ge @($script:tabsProy).Count) { return }
    $tab = $script:tabsProy[$script:tabProyActual]
    $nombres = @($tab.Archivos)
    $scope = @($script:ultimoScan | Where-Object { $nombres -contains $_.Nombre })
    Construir-Adaptacion $scope
    Restore-DecisionesTab $tab.Decisiones
}
# Muestra/oculta la barra de pestañas según el modo de lote.
function Actualizar-ModoLote {
    if (-not $ui -or -not $ui.panProyTabs) { return }
    $het = ((Get-ChipValor "modoLote") -eq "HETEROGENEO")
    $visTabs = if ($het) { "Visible" } else { "Collapsed" }
    # Ahora todo va en una sola página: basta UNA barra de pestañas de película (la de arriba,
    # panTabsGen, justo bajo «Modo de procesamiento»). Las otras 3 (réplicas que había en cada
    # sub-menú) quedan siempre ocultas para no duplicar la tira. La lógica de cambio de pestaña
    # sigue igual: todas comparten $script:tabsProy y solo cambia cuál se dibuja.
    if ($ui.panTabsGen) { $ui.panTabsGen.Visibility = $visTabs }
    foreach ($p in @($ui.panProyTabs, $ui.panProyTabsA, $ui.panProyTabsS)) { if ($p) { $p.Visibility = "Collapsed" } }
    # Capturas: la tarjeta vive SIEMPRE en Proyecto (no se oculta). En heterogéneo el valor es por
    # pestaña; en homogéneo es un único valor que se envía como NumCapturas global.
    if ($het) { Reconstruir-TabsProy } else { Construir-ListadoLote }   # homogéneo: lista completa sin filtrar
    Update-FlechasTabsProy
    # Cambiar de modo cambia la agrupación: descarta el registro de lanzadas y refresca los botones
    # (en homogéneo se vuelve a un único «Iniciar montaje»; en heterogéneo salen «Procesar esta» + «Todas»).
    $script:gruposLanzados = @{}
    if (Get-Command Actualizar-BotonesIniciar -EA SilentlyContinue) { Actualizar-BotonesIniciar }
}
# Registro del chip «modoLote» (aquí, ya con Actualizar-ModoLote definida: su callback se dispara
# al fijar la opción por defecto durante la creación).
Add-ChipGroup $ui.chModoLote "modoLote" @(
    @{T="Mismo proyecto (temporada)"; V="HOMOGENEO"},
    @{T="Cada archivo distinto"; V="HETEROGENEO"}
) 0 { Actualizar-ModoLote }

# Combina los resultados de escaneo de varias carpetas (remezcla) en una fila por grupo: vídeo de la
# REMEZCLA MANUAL: las fuentes las elige el usuario, no se intentan emparejar por nombre. El único
# resultado usa el archivo marcado como Vídeo y recoge audio/subs de CADA archivo marcado.
function Combinar-EscaneoRemezcla($res, $folders) {
    foreach ($sourceRow in @($res)) {
        foreach ($track in @($sourceRow.Audios)) { $track | Add-Member -NotePropertyName HdzSource -NotePropertyValue "$($sourceRow.Ruta)" -Force }
    }
    $videoCfg = @($folders | Where-Object { $_.Video }) | Select-Object -First 1
    if (-not $videoCfg) { return @() }
    if (Es-RemezclaSeriePorEpisodio $folders) {
        $salidas = @()
        $fuentes = @($folders | Where-Object { -not $_.Video -and ($_.Audio -or $_.Subs) })
        foreach ($video in @($res | Where-Object { (Split-Path "$($_.Ruta)" -Parent) -eq "$($videoCfg.Ruta)" })) {
            $clave = Get-ClaveRemezcla ([System.IO.Path]::GetFileNameWithoutExtension("$($video.Nombre)"))
            if ($clave -notmatch '^s\d+e\d+(?:-\d+)*$') { continue }
            $audios = @(); $subs = @()
            foreach ($cfgFuente in $fuentes) {
                $pareja = @($res | Where-Object { (Split-Path "$($_.Ruta)" -Parent) -eq "$($cfgFuente.Ruta)" -and (Test-HdzEpisodeMatch (Get-ClaveRemezcla ([System.IO.Path]::GetFileNameWithoutExtension("$($_.Nombre)"))) $clave) })
                if ($pareja.Count -gt 1) { continue } # La validación muestra el conflicto y no deja iniciar.
                if (-not $pareja) { continue }
                if ([bool]$cfgFuente.Audio) { $audios += @($pareja.Audios) }
                if ([bool]$cfgFuente.Subs)  { $subs += @($pareja.Subs) }
            }
            if ([bool]$videoCfg.Audio) { $audios = @($video.Audios) + $audios }
            if ([bool]$videoCfg.Subs)  { $subs = @($video.Subs) + $subs }
            $salidas += @{ Ruta=$video.Ruta; Nombre=$video.Nombre; Error=$video.Error; Video=$video.Video; Audios=@($audios); Subs=@($subs) }
        }
        return @($salidas)
    }
    if (-not "$($videoCfg.Archivo)") { return @() }
    $video = @($res | Where-Object { "$($_.Ruta)" -eq "$($videoCfg.Archivo)" } | Select-Object -First 1)
    if (-not $video) { return @() }
    $audios = @(); $subs = @()
    foreach ($cfgFuente in @($folders)) {
        $fila = @($res | Where-Object { "$($_.Ruta)" -eq "$($cfgFuente.Archivo)" } | Select-Object -First 1)
        if (-not $fila) { continue }
        if ([bool]$cfgFuente.Audio) { $audios += @($fila.Audios) }
        if ([bool]$cfgFuente.Subs)  { $subs += @($fila.Subs) }
    }
    return @(@{ Ruta = $video.Ruta; Nombre = $video.Nombre; Error = $video.Error; Video = $video.Video; Audios = @($audios); Subs = @($subs) })
}

function Lanzar-Escaneo {
    $script:remixPresentationKey=$null
    $script:scanGen++
    # Una carpeta/lote nuevo empieza conservando todos sus idiomas. Las reconstrucciones dentro del
    # mismo análisis sí preservan después cualquier cambio explícito del usuario.
    $script:idiomasAudioSeleccionUsuario = $false
    Reset-Adaptacion
    Actualizar-Procesado
    Actualizar-ListaRapida
    $script:ultimoScan = @()
    $script:remixScanActivo = $false
    $script:remixScanCrudo = @()

    $rutas = @()
    if ($ui.swRemezcla -and $ui.swRemezcla.IsChecked) {
        # MODO REMEZCLA: archivos concretos (manual) o carpetas completas de una serie (SxxEyy).
        $cs = Leer-RemezclaCarpetas
        $cv = @($cs | Where-Object { $_.Video }) | Select-Object -First 1
        if (@($cs).Count -lt 2 -or -not $cv) { Set-Estado "Remezcla: añade al menos 2 vídeos y marca cuál aporta la imagen." "warn"; return }
        $seriePorEpisodio = Es-RemezclaSeriePorEpisodio $cs
        if ($seriePorEpisodio) {
            $pruebaSerie = Test-RemezclaSeriePorEpisodio $cs
            if (-not $pruebaSerie.Ok) { Set-Estado "Remezcla de serie: $($pruebaSerie.Mensaje)" "error"; return }
        } elseif (@($cs | Where-Object { -not "$($_.Archivo)" -or -not (Test-Path -LiteralPath "$($_.Archivo)") }).Count -gt 0) {
            Set-Estado "Remezcla: elige todos los archivos manualmente, o deja todas las filas en «Todos los vídeos» para una serie." "warn"; return
        }
        $script:remixScanFolders = $cs
        $script:remixScanActivo = $true
        $script:carpetaScan = "$($cv.Ruta)"; $script:seleccion = @{}
        foreach ($c in $cs) {
            if (-not $c.Video -and -not ($c.Audio -or $c.Subs)) { continue }
            if ($seriePorEpisodio) { $rutas += @(Get-VideosCarpeta $c.Ruta | ForEach-Object { $_.FullName }) }
            else { $rutas += "$($c.Archivo)" }
        }
        $rutas = @($rutas | Select-Object -Unique)
        if ($rutas.Count -eq 0) { Set-Estado "Remezcla: no hay vídeos válidos que analizar."; return }
        $etqRz = if ($seriePorEpisodio) { "serie: $($pruebaSerie.Total) capítulo(s) por episodio" } else { "$($rutas.Count) vídeo(s) elegidos" }
        $ui.lblResumen.Text = "⏳ analizando remezcla $etqRz…"
        Set-Estado "Analizando remezcla $etqRz con ffprobe…"
    } else {
        $carpetas = @(Get-CarpetasEntrada)
        if ($carpetas.Count -eq 0) { return }
        $claveCarpetas = ($carpetas | ForEach-Object { "$_".ToLowerInvariant().TrimEnd('\') }) -join '|'
        # La selección pertenece a este conjunto de carpetas: al cambiar el lote se reinicia.
        if ($claveCarpetas -ne $script:carpetaScan) {
            $script:seleccion = @{}
            $script:carpetaScan = $claveCarpetas
        }
        # El nombre de la release no decide qué vídeos se pueden procesar.
        $objetivo = if (@($script:videosElegidos).Count -gt 0) {
            @($script:videosElegidos | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object { Get-Item -LiteralPath $_ })
        } else { @($carpetas | ForEach-Object {
            Get-VideosCarpeta $_
        }) }
        if ($objetivo.Count -eq 0) { Set-Estado "No hay vídeos que analizar en las carpetas seleccionadas."; return }
        if ($carpetas.Count -gt 1) {
            $duplicados = @($objetivo | Group-Object Name | Where-Object Count -gt 1 | Select-Object -ExpandProperty Name)
            if ($duplicados.Count -gt 0) {
                Set-Estado "Hay archivos con el mismo nombre en varias temporadas ($($duplicados[0])). Renómbralos con su SxxExx para poder decidir cada episodio sin cruces." "error"
                return
            }
        }
        $rutas = @($objetivo | ForEach-Object { $_.FullName })
        $sufCarpetas = if ($carpetas.Count -gt 1) { " de $($carpetas.Count) temporadas" } else { "" }
        $ui.lblResumen.Text = "⏳ analizando $($rutas.Count) vídeo(s)$sufCarpetas…"
        Set-Estado "Analizando pistas de $($rutas.Count) vídeo(s)$sufCarpetas con ffprobe…"
    }

    if ($script:modoTest) {
        # Sin bucle de mensajes en modo test: escaneo síncrono.
        $res = @(& $scanWorker $rutas)
        if ($script:remixScanActivo) { $script:remixScanCrudo = @($res); $res = @(Combinar-EscaneoRemezcla $res $script:remixScanFolders) }
        Aplicar-Analisis @($res)
        if ($script:remixScanActivo) { Construir-InfoRemezcla $script:remixScanCrudo; Construir-PistasRemezcla }
        return
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($scanWorker.ToString()).AddArgument($rutas)
    $script:scanPS = $ps
    $script:scanAsync = $ps.BeginInvoke()
    $script:scanGenLanzado = $script:scanGen
    $script:pollTimer.Start()
}

# Debounce: re-analiza 600 ms después del último cambio en la ruta
$script:debounceTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:debounceTimer.Interval = [TimeSpan]::FromMilliseconds(600)
$script:debounceTimer.Add_Tick({
    $script:debounceTimer.Stop()
    Lanzar-Escaneo
})

# =========================================================================
# EVENTOS
# =========================================================================
$script:todosPaneles = @("panCrear","panSubida","panAjustes")
function Mostrar-Panel($nombre) {
    foreach ($p in $script:todosPaneles) { $ui[$p].Visibility = "Collapsed" }
    $ui[$nombre].Visibility = "Visible"
    # Barra inferior: en «Torrent y subida» el botón de acción es «Subir a HDZERO»
    # (y no «Iniciar montaje»); la consola del montaje solo aplica a la rama de montaje.
    $esSubida = ($nombre -eq "panSubida")
    if ($ui.btnSubir)   { $ui.btnSubir.Visibility   = if ($esSubida) { "Visible" } else { "Collapsed" } }
    $esProyecto = ($nombre -eq 'panCrear')
    if ($ui.btnIniciar) { $ui.btnIniciar.Visibility = if ($esProyecto) { "Visible" } else { "Collapsed" } }
    if ($ui.btnIniciarTodos -and -not $esProyecto) { $ui.btnIniciarTodos.Visibility = "Collapsed" }
    if ($ui.btnConsola) { $ui.btnConsola.Visibility = if ($esProyecto) { "Visible" } else { "Collapsed" } }
    if ($script:barraEntrada) { $script:barraEntrada.Visibility = if ($esProyecto) { 'Visible' } else { 'Collapsed' } }
    if ($esProyecto -and (Get-Command Actualizar-BotonesIniciar -EA SilentlyContinue)) { Actualizar-BotonesIniciar }
    # «Ver en la web» solo en subida y si ya hay un torrent subido en esta pestaña.
    if ($ui.btnVerWeb) { $ui.btnVerWeb.Visibility = if ($esSubida -and $script:urlTorrentWeb) { "Visible" } else { "Collapsed" } }
    if ($ui.btnAbrirTorrent) { $ui.btnAbrirTorrent.Visibility = if ($esSubida -and $script:rutaTorrentTracker -and (Test-Path -LiteralPath $script:rutaTorrentTracker)) { "Visible" } else { "Collapsed" } }
    # Texto contextual de la barra de carpeta: el uso de la carpeta cambia según la pantalla.
    if ($ui.lblCarpetaDesc) {
        $ui.lblCarpetaDesc.Text = switch ($nombre) {
            "panSubida"  { "Carpeta de trabajo: aquí se buscan por defecto los .torrent y las capturas al subir (botón «Último creado» y al localizar el vídeo de un torrent)." }
            "panAjustes" { "Carpeta de trabajo (común a todo el programa). No se usa en Ajustes; configura aquí tus claves." }
            default      { "Elige una carpeta o vídeos concretos. Añade temporadas para procesarlas en el mismo lote." }
        }
        if ($nombre -eq "panCrear" -and @(Get-CarpetasEntrada).Count -gt 1) { Actualizar-DescripcionCarpetas }
    }
    if (Get-Command Update-HdzProductState -ErrorAction SilentlyContinue) { Update-HdzProductState }
}
$ui.navProyecto.Add_Checked({ Mostrar-Panel "panCrear" })
$ui.navSubida.Add_Checked({
    Mostrar-Panel "panSubida"
    # Al mostrar el panel ya tiene ancho real → recalcular si las pestañas desbordan (flechas).
    $ui.scrTabs.Dispatcher.InvokeAsync({ Update-FlechasTabs }, [System.Windows.Threading.DispatcherPriority]::ContextIdle) | Out-Null
})
$ui.navAjustes.Add_Checked({  Mostrar-Panel "panAjustes" })

# --- Secciones plegables de la página «Proyecto» (para no tener scroll infinito) ---
# Cada cabecera (Border) muestra/oculta su panel y voltea el chevron ▾/▸, igual que
# el botón «Ocultar/Mostrar» de la rejilla de capturas.
function Wire-SeccionColapsable($hdr, $chev, $panel) {
    if (-not $hdr -or -not $panel) { return }
    $hdr.Add_MouseLeftButtonUp({
        param($snd, $e)
        if ($panel.Visibility -eq "Visible") { $panel.Visibility = "Collapsed"; $chev.Text = "▸" }
        else                                 { $panel.Visibility = "Visible";   $chev.Text = "▾" }
    }.GetNewClosure())
}
Wire-SeccionColapsable $ui.secHdrGeneral  $ui.secChevGeneral  $ui.panGeneral
Wire-SeccionColapsable $ui.secHdrProyecto $ui.secChevProyecto $ui.panProyecto
Wire-SeccionColapsable $ui.secHdrAudio    $ui.secChevAudio    $ui.panAudio
Wire-SeccionColapsable $ui.secHdrSubs     $ui.secChevSubs     $ui.panSubs

# --- Menú lateral colapsable (solo iconos) ---
$script:sidebarColapsado = $false
$script:logoCargado = $false
$script:navItems = @(
    @{ C = $ui.navProyecto; I = "🎬"; L = "Proyecto" },
    @{ C = $ui.navSubida;   I = "☁"; L = "Torrent y subida" },
    @{ C = $ui.navAjustes;  I = "⚙"; L = "Ajustes / claves" }
)
function Aplicar-Sidebar {
    $col = $script:sidebarColapsado
    $ui.sidebar.Width = if ($col) { 72 } else { 216 }
    $visTxt = if ($col) { "Collapsed" } else { "Visible" }
    foreach ($e in @($ui.lblSecMontaje, $ui.lblSecTorrent, $ui.lblPie, $ui.lblVersion)) { if ($e) { $e.Visibility = $visTxt } }
    $ui.imgLogo.Visibility      = if (-not $col -and $script:logoCargado)      { "Visible" } else { "Collapsed" }
    $ui.panLogoTexto.Visibility = if (-not $col -and -not $script:logoCargado) { "Visible" } else { "Collapsed" }
    $padCol = [System.Windows.Thickness]::new(2, 10, 2, 10)
    $padExp = [System.Windows.Thickness]::new(13, 10, 13, 10)
    foreach ($n in $script:navItems) {
        if ($col) { $n.C.Content = $n.I; $n.C.HorizontalContentAlignment = "Center"; $n.C.FontSize = 18; $n.C.Padding = $padCol; $n.C.ToolTip = $n.L }
        else      { $n.C.Content = "$($n.I)   $($n.L)"; $n.C.HorizontalContentAlignment = "Left"; $n.C.FontSize = 13.5; $n.C.Padding = $padExp; $n.C.ToolTip = $null }
    }
    # Compacto: actualización encima del menú, en filas distintas y a ancho completo.
    # Expandido: actualización a la derecha de la versión, menú en su columna derecha.
    # Se conserva el mismo botón/manejador y su visibilidad depende solo de la versión.
    [System.Windows.Controls.Grid]::SetColumnSpan($ui.panVersionUpdate, $(if ($col) { 2 } else { 1 }))
    $ui.panVersionUpdate.HorizontalAlignment = if ($col) { 'Center' } else { 'Left' }
    $ui.btnActualizar.Margin = if ($col) { [Windows.Thickness]::new(0,0,0,8) } else { [Windows.Thickness]::new(0) }
    $ui.btnActualizar.MinWidth = if ($col) { 40 } else { 36 }
    $ui.btnActualizar.MinHeight = if ($col) { 40 } else { 36 }
    [System.Windows.Controls.Grid]::SetRow($ui.btnColapsar, $(if ($col) { 1 } else { 0 }))
    [System.Windows.Controls.Grid]::SetColumn($ui.btnColapsar, $(if ($col) { 0 } else { 1 }))
    [System.Windows.Controls.Grid]::SetColumnSpan($ui.btnColapsar, $(if ($col) { 2 } else { 1 }))
    $ui.btnColapsar.HorizontalAlignment = if ($col) { "Center" } else { "Right" }
    if (Get-Command Set-HdzNavigationDesign -ErrorAction SilentlyContinue) { Set-HdzNavigationDesign }
}
$ui.btnColapsar.Add_Click({ $script:sidebarColapsado = -not $script:sidebarColapsado; Aplicar-Sidebar })

$ui.btnExaminar.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Selecciona la carpeta con los vídeos a procesar"
    if ($ui.txtCarpeta.Text -and (Test-Path -LiteralPath $ui.txtCarpeta.Text)) { $dlg.SelectedPath = $ui.txtCarpeta.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Set-CarpetasTemporadas @($dlg.SelectedPath)   # carpeta nueva: sustituye el lote anterior
        if ($script:modoTest) { Lanzar-Escaneo } else { $script:debounceTimer.Stop(); $script:debounceTimer.Start() }
    }
})

# Añade otra carpeta al lote. El selector nativo de Windows solo admite una carpeta por apertura,
# pero el botón puede repetirse tantas veces como temporadas se quieran acumular.
$ui.btnAnadirTemporada.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Añade otra carpeta de temporada al lote"
    $actuales = @(Get-CarpetasEntrada)
    if ($actuales.Count -gt 0) {
        $padre = Split-Path $actuales[-1] -Parent
        if ($padre -and (Test-Path -LiteralPath $padre)) { $dlg.SelectedPath = $padre }
    }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    Set-CarpetasTemporadas (@($actuales) + @($dlg.SelectedPath))
    $cs = @(Get-CarpetasEntrada)
    Set-Estado "Añadida «$([System.IO.Path]::GetFileName($dlg.SelectedPath))». Lote actual: $($cs.Count) temporada(s)." "ok"
    if ($script:modoTest) { Lanzar-Escaneo } else { $script:debounceTimer.Stop(); $script:debounceTimer.Start() }
})

# «Elegir vídeos…»: al contrario que el selector de carpeta (que no muestra archivos), abre un
# diálogo de archivos con multiselección para VER y marcar uno o varios vídeos. La carpeta de trabajo
# pasa a ser la de esos archivos y SOLO los elegidos quedan marcados para procesar (el resto de la
# carpeta se analiza pero queda desmarcado; se puede re-marcar con las casillas de la lista).
function Set-VideosElegidos([string[]]$archivos) {
    if (-not $archivos -or $archivos.Count -gt 1000) { throw 'Elige entre 1 y 1000 vídeos de una misma carpeta.' }
    # Validar todo antes de modificar la selección. No aceptar rutas relativas ni carpetas.
    $rutas = @($archivos | Select-Object -Unique)
    foreach ($p in $rutas) {
        if (-not [IO.Path]::IsPathFullyQualified($p) -or -not (Test-Path -LiteralPath $p -PathType Leaf)) {
            throw "El archivo seleccionado ya no está disponible: $p"
        }
    }
    $carpeta = Split-Path $rutas[0] -Parent
    if (@($rutas | Where-Object { (Split-Path $_ -Parent) -ne $carpeta }).Count) {
        throw 'Selecciona vídeos de una misma carpeta.'
    }
    $nombres = @($rutas | ForEach-Object { Split-Path $_ -Leaf })
    $misma = ("$($ui.txtCarpeta.Text)".Trim() -eq "$carpeta".Trim()) -and (@(Get-CarpetasEntrada).Count -eq 1)
    Set-CarpetasTemporadas @($carpeta)
    $script:videosElegidos = @($rutas)
    $script:restringirSeleccion = $nombres
    if ($misma) {
        Lanzar-Escaneo
    } else {
        if ($script:modoTest) { Lanzar-Escaneo } else { $script:debounceTimer.Stop(); $script:debounceTimer.Start() }
    }
    Set-Estado "Seleccionados $($nombres.Count) vídeo(s) de «$([IO.Path]::GetFileName($carpeta))»." 'ok'
}
$ui.btnElegirVideos.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Vídeos (*.mkv;*.mp4;*.ts)|*.mkv;*.mp4;*.ts|Todos|*.*"
    $dlg.Multiselect = $true
    $dlg.Title = "Elige uno o varios vídeos (todos de la misma carpeta)"
    if ($ui.txtCarpeta.Text -and (Test-Path -LiteralPath $ui.txtCarpeta.Text)) { $dlg.InitialDirectory = $ui.txtCarpeta.Text }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $archivos = @($dlg.FileNames)
    if ($archivos.Count -eq 0) { return }
    $carpeta  = Split-Path $archivos[0] -Parent
    $nombres  = @($archivos | ForEach-Object { Split-Path $_ -Leaf })
    # Aviso si mezcló archivos de varias carpetas: solo se puede trabajar sobre una.
    $otras = @($archivos | Where-Object { (Split-Path $_ -Parent) -ne $carpeta })
    if ($otras.Count -gt 0) {
        Set-Estado "Solo puedo procesar vídeos de una misma carpeta: uso «$([System.IO.Path]::GetFileName($carpeta))». Ignoro los de otras carpetas." "warn"
        $nombres = @($archivos | Where-Object { (Split-Path $_ -Parent) -eq $carpeta } | ForEach-Object { Split-Path $_ -Leaf })
    }
    try { Set-VideosElegidos @($nombres | ForEach-Object { Join-Path $carpeta $_ }) }
    catch { Set-Estado $_.Exception.Message 'warn' }
})

# =========================================================================
# REMEZCLA — archivos origen con roles (vídeo / audio / subs)
# =========================================================================
$script:remezclaCarpetas = @()   # filas: @{ Grid; Ruta; Archivo; Video(radio); Audio(cb); Subs(cb) }

# Clave de emparejado de remezcla. SERIE: SOLO temporada+episodio (SxxEyy), ignorando el título —
# así casan releases del mismo show con TÍTULO EN DISTINTO IDIOMA (4K inglés vs 1080p español) y/o
# sin año. El usuario ya eligió las carpetas, así que SxxEyy identifica el capítulo. PELÍCULA (sin
# episodio): título+año (si los títulos están en idiomas distintos puede no casar). Igual en el motor.
function Get-ClaveRemezcla($baseName) {
    $episodeKey = Get-HdzEpisodeKey "$baseName"
    if ($episodeKey) { return $episodeKey }
    $b = ("$baseName" -replace '[._]', ' ')
    if ($b -match '(?i)\bS(\d{1,3})\s?E(\d{1,4})\b') { return ('s{0}e{1}' -f [int]$Matches[1], [int]$Matches[2]) }
    if ($b -match '(?i)\b(\d{1,3})x(\d{1,4})\b')     { return ('s{0}e{1}' -f [int]$Matches[1], [int]$Matches[2]) }
    $corte = $b.Length
    if ($b -match '\b(19\d{2}|20\d{2})\b') { $anio = $Matches[1]; $i = $b.IndexOf($Matches[1]); if ($i -gt 0) { $corte = [Math]::Min($corte, $i) } } else { $anio = '' }
    $titulo = (($b.Substring(0, $corte) -replace '[\(\)\[\]]', ' ') -replace '\s+', ' ').Trim().ToLower()
    return "$titulo|$anio"
}
# Lee la lista actual de carpetas (solo las que siguen en el panel — la ✕ las quita de la vista).
function Leer-RemezclaCarpetas {
    $lista = @()
    foreach ($r in @($script:remezclaCarpetas)) {
        if ($ui.panRemezclaCarpetas -and -not $ui.panRemezclaCarpetas.Children.Contains($r.Grid)) { continue }
        $lista += [PSCustomObject]@{ Ruta = "$($r.Ruta)"; Archivo = "$(Get-ComboValor $r.Archivo)"; Video = [bool]$r.Video.IsChecked; Audio = [bool]$r.Audio.IsChecked; Subs = [bool]$r.Subs.IsChecked }
    }
    return $lista
}
# Cuenta de vídeos válidos de una carpeta (por nombre) y sus claves.
function Get-ClavesCarpeta($ruta, $archivo = "") {
    if (-not (Test-Path -LiteralPath $ruta)) { return @() }
    $vids = if ($archivo -and (Test-Path -LiteralPath $archivo)) { @(Get-Item -LiteralPath $archivo) } else { @(Get-ChildItem -LiteralPath $ruta -File -ErrorAction SilentlyContinue) }
    @($vids |
        Where-Object { $_.Extension -match "(?i)\.(mkv|mp4|ts)$" -and $_.Name -notmatch "(?i)_FINAL" -and $_.Name -notmatch "(?i)^Ensamblaje_" } |
        ForEach-Object { Get-ClaveRemezcla $_.BaseName })
}

# En la remezcla de una SERIE la carpeta marcada como Vídeo aporta la imagen de cada capítulo y
# las otras carpetas aportan Audio/Subs del MISMO SxxEyy. Jamás se usa el título para emparejar.
function Get-MapaEpisodiosRemezcla($ruta) {
    $mapa = @{}
    foreach ($f in @(Get-VideosCarpeta $ruta)) {
        $clave = Get-ClaveRemezcla $f.BaseName
        if ($clave -notmatch '^s\d+e\d+(?:-\d+)*$') { continue }
        if (-not $mapa.ContainsKey($clave)) { $mapa[$clave] = @() }
        $mapa[$clave] += $f.FullName
    }
    return $mapa
}
function Es-RemezclaSeriePorEpisodio($cs = @(Leer-RemezclaCarpetas)) {
    return (@($cs).Count -ge 2 -and @($cs | Where-Object { "$($_.Archivo)".Trim() }).Count -eq 0)
}
function Test-RemezclaSeriePorEpisodio($cs = @(Leer-RemezclaCarpetas)) {
    $videoCfg = @($cs | Where-Object { $_.Video }) | Select-Object -First 1
    if (-not $videoCfg) { return @{ Ok=$false; Mensaje="Marca la carpeta que aporta el vídeo."; Total=0; Coinciden=0 } }
    $mapaVideo = Get-MapaEpisodiosRemezcla $videoCfg.Ruta
    if ($mapaVideo.Count -eq 0) { return @{ Ok=$false; Mensaje="La carpeta de vídeo no contiene capítulos con SxxEyy o 1x01."; Total=0; Coinciden=0 } }
    $fuentes = @($cs | Where-Object { -not $_.Video -and ($_.Audio -or $_.Subs) })
    if ($fuentes.Count -eq 0) { return @{ Ok=$false; Mensaje="Marca Audio o Subs en al menos otra carpeta."; Total=$mapaVideo.Count; Coinciden=0 } }
    $errores = @(); $faltan = @(); $coinciden = @{}
    foreach ($fuente in $fuentes) {
        $mapaFuente = Get-MapaEpisodiosRemezcla $fuente.Ruta
        $duplicados = @($mapaFuente.Keys | Where-Object { @($mapaFuente[$_]).Count -gt 1 })
        if ($duplicados.Count -gt 0) { $errores += "hay capítulos duplicados ($($duplicados[0])) en «$(Split-Path $fuente.Ruta -Leaf)»"; continue }
        foreach ($clave in $mapaVideo.Keys) {
            $matchesFuente = @($mapaFuente.Keys | Where-Object { Test-HdzEpisodeMatch $_ $clave })
            if ($matchesFuente.Count -gt 1) { $errores += "emparejado ambiguo de $clave en «$(Split-Path $fuente.Ruta -Leaf)»" }
            elseif ($matchesFuente.Count -eq 1) { $coinciden[$clave] = $true }
            else { $faltan += "$clave en $(Split-Path $fuente.Ruta -Leaf)" }
        }
    }
    $dupVideo = @($mapaVideo.Keys | Where-Object { @($mapaVideo[$_]).Count -gt 1 })
    if ($dupVideo.Count -gt 0) { $errores += "hay capítulos duplicados ($($dupVideo[0])) en la carpeta de vídeo" }
    if ($errores.Count -gt 0) { return @{ Ok=$false; Mensaje=("Remezcla de serie: " + ($errores -join '; ') + "."); Total=$mapaVideo.Count; Coinciden=$coinciden.Count } }
    if ($faltan.Count -gt 0) {
        $muestra = @($faltan | Select-Object -First 3) -join ', '
        return @{ Ok=$false; Mensaje="Faltan pistas emparejadas por episodio: $muestra$(if($faltan.Count -gt 3){'…'})."; Total=$mapaVideo.Count; Coinciden=$coinciden.Count }
    }
    return @{ Ok=$true; Mensaje="$($mapaVideo.Count) capítulo(s) emparejados por SxxEyy."; Total=$mapaVideo.Count; Coinciden=$coinciden.Count }
}

# Preview de la remezcla: manual por archivos o serie por números de episodio.
function Actualizar-PreviewRemezcla {
    $cs = Leer-RemezclaCarpetas
    if ($cs.Count -lt 2) { $ui.lblRemezclaInfo.Text = "Añade al menos 2 vídeos y marca qué aporta cada uno."; return }
    $cv = @($cs | Where-Object { $_.Video }) | Select-Object -First 1
    if (-not $cv) { $ui.lblRemezclaInfo.Text = "Marca qué vídeo aporta la imagen."; return }
    if (Es-RemezclaSeriePorEpisodio $cs) {
        $serie = Test-RemezclaSeriePorEpisodio $cs
        $ui.lblRemezclaInfo.Text = if ($serie.Ok) { "Remezcla de serie: $($serie.Mensaje) El título se ignora; se une solo por el número de episodio." } else { "Remezcla de serie: $($serie.Mensaje)" }
        if (Get-Command Show-HdzRemixPairs -ErrorAction SilentlyContinue) { Show-HdzRemixPairs }
        if ($ui.swRemezcla -and $ui.swRemezcla.IsChecked -and -not $script:modoTest) { $script:debounceTimer.Stop(); $script:debounceTimer.Start() }
        return
    }
    if (@($cs | Where-Object { -not "$($_.Archivo)".Trim() }).Count -gt 0) { $ui.lblRemezclaInfo.Text = "No mezcles carpetas de serie y archivos individuales en la misma remezcla."; return }
    if (-not "$($cv.Archivo)" -or -not (Test-Path -LiteralPath "$($cv.Archivo)")) { $ui.lblRemezclaInfo.Text = "El vídeo elegido no es válido."; return }
    $otras = @($cs | Where-Object { -not $_.Video -and ($_.Audio -or $_.Subs) -and "$($_.Archivo)" })
    if ($otras.Count -eq 0) { $ui.lblRemezclaInfo.Text = "Marca Audio o Subs en al menos otro vídeo."; return }
    $nombreVideo = if ($cv.Archivo) { Split-Path $cv.Archivo -Leaf } else { Split-Path $cv.Ruta -Leaf }
    $ui.lblRemezclaInfo.Text = "Remezcla manual: imagen de «$nombreVideo» + pistas de $($otras.Count) vídeo(s) seleccionado(s)."
    # Re-analiza (con debounce) para mostrar idiomas de audios/subs y detectar el título de la remezcla.
    if ($ui.swRemezcla -and $ui.swRemezcla.IsChecked -and -not $script:modoTest) { $script:debounceTimer.Stop(); $script:debounceTimer.Start() }
}

# Muestra únicamente las fuentes que forman la remezcla. Se alimenta del escaneo crudo, antes de
# combinar las pistas, para que el usuario pueda comprobar que no se ha colado ningún vídeo de la carpeta.
function Construir-InfoRemezcla($escaneo) {
    if (-not $ui.panRemezclaInfo) { return }
    $ui.panRemezclaInfo.Children.Clear()
    $cfgsInfo = @(Leer-RemezclaCarpetas)
    $esSerieInfo = Es-RemezclaSeriePorEpisodio $cfgsInfo
    foreach ($cfg in $cfgsInfo) {
        $f = @($escaneo | Where-Object { "$($_.Ruta)" -eq "$($cfg.Archivo)" } | Select-Object -First 1)
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Margin = [System.Windows.Thickness]::new(0, 2, 0, 3)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = if ($esSerieInfo) { "• $(Split-Path "$($cfg.Ruta)" -Leaf)" } else { "• $(Split-Path "$($cfg.Archivo)" -Leaf)" }
        $tb.FontSize = 12; $tb.TextTrimming = "CharacterEllipsis"; $tb.Foreground = $win.Resources["TextBrush"]
        [void]$sp.Children.Add($tb)
        $wp = New-Object System.Windows.Controls.WrapPanel
        $wp.Margin = [System.Windows.Thickness]::new(14, 2, 0, 0)
        $roles = @(); if ($cfg.Video) { $roles += "Vídeo" }; if ($cfg.Audio) { $roles += "Audio" }; if ($cfg.Subs) { $roles += "Subs" }
        [void]$wp.Children.Add((New-Pill ($roles -join " + ") "accent"))
        if ($esSerieInfo) {
            # Una tabla es un único objeto al ponerla entre @(); contamos sus claves, no la tabla.
            $nEps = @((Get-MapaEpisodiosRemezcla $cfg.Ruta).Keys).Count
            [void]$wp.Children.Add((New-Pill "$nEps capítulo(s) detectados"))
        } elseif ($f -and $f.Video) {
            $res = Get-HdzVideoResolution $f.Video; if (-not $res) { $res = '?' }
            [void]$wp.Children.Add((New-Pill $res))
            [void]$wp.Children.Add((New-Pill ("♪ $(@($f.Audios).Count) audio(s)")))
            [void]$wp.Children.Add((New-Pill ("💬 $(@($f.Subs).Count) sub(s)")))
        } elseif ($f.Error) { [void]$wp.Children.Add((New-Pill "error al analizar: $($f.Error)" "warn")) }
        [void]$sp.Children.Add($wp)
        [void]$ui.panRemezclaInfo.Children.Add($sp)
    }
}

# Rellena los chips de idiomas de audio y subtítulos a conservar (a partir del análisis combinado).
# Cada chip marcado = conservar ese idioma; al desmarcarlo, se descarta. Idiomas normalizados con
# ConvCanon para que coincidan con el filtro del motor.
$script:remezclaChipsAudio = @()
$script:remezclaChipsSub = @()
# Prioridad de orden de idiomas (común a audios y subs, para que ambas listas vayan igual).
function Get-PesoIdiomaGui($cod) {
    switch ("$cod") {
        "es"     { 0 }; "es-419" { 1 }; "eng" { 2 }
        "cat"    { 3 }; "glg" { 4 }; "eus" { 5 }
        "fre"    { 10 }; "ger" { 11 }; "ita" { 12 }; "por" { 13 }; "jpn" { 14 }; "chi" { 15 }
        "und"    { 999 }
        default  { 50 }
    }
}
function Construir-PistasRemezcla {
    if (-not $ui.panRemezclaAudios) { return }
    $ui.panRemezclaAudios.Children.Clear(); $ui.panRemezclaSubs.Children.Clear()
    $script:remezclaChipsAudio = @(); $script:remezclaChipsSub = @()
    if (-not ($ui.swRemezcla -and $ui.swRemezcla.IsChecked)) { $ui.panRemezclaPistas.Visibility = "Collapsed"; return }
    $audMap = @{}; $subMap = @{}
    foreach ($f in @($script:ultimoScan)) {
        foreach ($a in @($f.Audios)) {
        $cod = Get-IdiomaPistaGui $a 'Audio'
            if (-not $audMap.ContainsKey($cod)) {
                $cc = Get-CodecComercial $a.Codec $a.Profile
                $audMap[$cod] = "$(if ($cod -eq 'und') { 'sin idioma' } else { NombreIdioma $cod }) · $cc $(Get-NombreLayout $a.Channels)"
            }
        }
        foreach ($s in @($f.Subs)) {
        $cod = Get-IdiomaPistaGui $s 'Sub'
            if (-not $subMap.ContainsKey($cod)) { $subMap[$cod] = $(if ($cod -eq 'und') { 'sin idioma' } else { NombreIdioma $cod }) }
        }
    }
    # Orden ÚNICO (unión de códigos) por prioridad y nombre; ambas listas lo siguen.
    $orden = @(@($audMap.Keys) + @($subMap.Keys) | Select-Object -Unique |
        Sort-Object @{Expression = { Get-PesoIdiomaGui $_ }}, @{Expression = { "$(NombreIdioma $_)" }})
    foreach ($cod in $orden) {
        if ($audMap.ContainsKey($cod)) {
            $tb = New-Object System.Windows.Controls.Primitives.ToggleButton
            $tb.Style = $win.Resources["ChipToggle"]; $tb.Content = "$($audMap[$cod])"; $tb.Tag = "$cod"; $tb.IsChecked = $true
            [void]$ui.panRemezclaAudios.Children.Add($tb); $script:remezclaChipsAudio += $tb
        }
    }
    foreach ($cod in $orden) {
        if ($subMap.ContainsKey($cod)) {
            $tb = New-Object System.Windows.Controls.Primitives.ToggleButton
            $tb.Style = $win.Resources["ChipToggle"]; $tb.Content = "$($subMap[$cod])"; $tb.Tag = "$cod"; $tb.IsChecked = $true
            [void]$ui.panRemezclaSubs.Children.Add($tb); $script:remezclaChipsSub += $tb
        }
    }
    $ui.panRemezclaPistas.Visibility = if (($script:remezclaChipsAudio.Count + $script:remezclaChipsSub.Count) -gt 0) { "Visible" } else { "Collapsed" }
}
# Etiqueta de resolución de una carpeta (mira el primer vídeo por su nombre).
function Get-EtiquetaCarpeta($ruta) {
    $primero = @(Get-ChildItem -LiteralPath $ruta -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match "(?i)\.(mkv|mp4|ts)$" } | Select-Object -First 1)
    if ($primero -and $primero[0].Name -match "(?i)\b(2160p|1080p|720p|480p)\b") { return $Matches[1] }
    return ""
}
function Add-FilaRemezcla($ruta, $archivo = "") {
    if ([string]::IsNullOrWhiteSpace($ruta)) { return }
    # Una misma carpeta puede aportar dos fuentes distintas: por ejemplo, el vídeo de un MKV y
    # los audios/subs de otro MKV que están juntos. Cada fila representa una FUENTE, no una ruta única.
    $esPrimera = (@(Leer-RemezclaCarpetas).Count -eq 0)
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = [System.Windows.Thickness]::new(0, 0, 0, 7)
    $defs = @(@{W="*";T="Star"}, @{W=205;T="Pix"}, @{W=120;T="Pix"}, @{W="Auto";T="Auto"}, @{W="Auto";T="Auto"}, @{W="Auto";T="Auto"})
    foreach ($d in $defs) {
        $c = New-Object System.Windows.Controls.ColumnDefinition
        $c.Width = switch ($d.T) { "Star" { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } "Pix" { [System.Windows.GridLength]::new($d.W) } default { [System.Windows.GridLength]::Auto } }
        [void]$g.ColumnDefinitions.Add($c)
    }
    $etq = if ($archivo) { Get-EtiquetaCarpeta (Split-Path $archivo -Parent) } else { Get-EtiquetaCarpeta $ruta }
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $(if ($archivo) { Split-Path $archivo -Leaf } else { Split-Path $ruta -Leaf }) + $(if ($etq) { "  ·  $etq" } else { "" })
    $tb.ToolTip = $(if ($archivo) { $archivo } else { $ruta }); $tb.VerticalAlignment = "Center"; $tb.TextTrimming = "CharacterEllipsis"
    $tb.Foreground = $win.Resources["TextBrush"]; $tb.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
    [System.Windows.Controls.Grid]::SetColumn($tb, 0); [void]$g.Children.Add($tb)

    $cmbArchivo = New-Object System.Windows.Controls.ComboBox
    $cmbArchivo.Style = $win.Resources["Combo"]; $cmbArchivo.VerticalAlignment = "Center"
    $opArch = @(@{T="Todos los vídeos";V=""}) + @((Get-VideosCarpeta $ruta | ForEach-Object { @{T="$($_.Name)";V="$($_.FullName)"} }))
    Init-Combo $cmbArchivo $opArch
    if ($archivo) { Set-ComboValor $cmbArchivo $archivo }
    [System.Windows.Controls.Grid]::SetColumn($cmbArchivo, 1); [void]$g.Children.Add($cmbArchivo)

    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $win.Resources["Chip"]; $rb.Content = "Vídeo"; $rb.GroupName = "remezclaVideo"; $rb.VerticalAlignment = "Center"
    $rb.IsChecked = $esPrimera
    [System.Windows.Controls.Grid]::SetColumn($rb, 2); [void]$g.Children.Add($rb)

    $cbA = New-Object System.Windows.Controls.CheckBox
    $cbA.Style = $win.Resources["Switch"]; $cbA.Content = "Audio"; $cbA.VerticalAlignment = "Center"; $cbA.Margin = [System.Windows.Thickness]::new(14, 0, 0, 0)
    $cbA.IsChecked = (-not $esPrimera)
    [System.Windows.Controls.Grid]::SetColumn($cbA, 3); [void]$g.Children.Add($cbA)

    $cbS = New-Object System.Windows.Controls.CheckBox
    $cbS.Style = $win.Resources["Switch"]; $cbS.Content = "Subs"; $cbS.VerticalAlignment = "Center"; $cbS.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
    $cbS.IsChecked = (-not $esPrimera)
    [System.Windows.Controls.Grid]::SetColumn($cbS, 4); [void]$g.Children.Add($cbS)

    $btnX = New-Object System.Windows.Controls.Button
    $btnX.Style = $win.Resources["GhostMini"]; $btnX.Content = "✕"; $btnX.VerticalAlignment = "Center"; $btnX.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
    [System.Windows.Controls.Grid]::SetColumn($btnX, 5); [void]$g.Children.Add($btnX)
    $btnX.Add_Click({ [void]$ui.panRemezclaCarpetas.Children.Remove($g); Actualizar-PreviewRemezcla }.GetNewClosure())

    foreach ($ctrl in @($rb, $cbA, $cbS)) {
        $ctrl.Add_Checked({ Actualizar-PreviewRemezcla })
        $ctrl.Add_Unchecked({ Actualizar-PreviewRemezcla })
    }
    $cmbArchivo.Add_SelectionChanged({
        $nuevo = "$(Get-ComboValor $cmbArchivo)"
        if ($nuevo) { $tb.Text = (Split-Path $nuevo -Leaf) + $(if ($nuevo -match "(?i)\b(2160p|1080p|720p|480p)\b") { "  ·  $($Matches[1])" } else { "" }); $tb.ToolTip = $nuevo }
        Actualizar-PreviewRemezcla
    }.GetNewClosure())

    [void]$ui.panRemezclaCarpetas.Children.Add($g)
    $script:remezclaCarpetas += [PSCustomObject]@{ Grid = $g; Ruta = "$ruta"; Archivo = $cmbArchivo; Video = $rb; Audio = $cbA; Subs = $cbS }
    Actualizar-PreviewRemezcla
}
$ui.swRemezcla.Add_Checked({
    $ui.panRemezcla.Visibility = "Visible"
    Actualizar-PreviewRemezcla
})
$ui.swRemezcla.Add_Unchecked({ $ui.panRemezcla.Visibility = "Collapsed"; if (-not $script:modoTest) { $script:debounceTimer.Stop(); $script:debounceTimer.Start() } })
$ui.btnRemezclaAdd.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Elige dos o más vídeos para la remezcla"
    $dlg.Filter = "Vídeos (*.mkv;*.mp4;*.ts)|*.mkv;*.mp4;*.ts|Todos|*.*"
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($f in @($dlg.FileNames)) { Add-FilaRemezcla (Split-Path $f -Parent) $f }
    }
})
$ui.btnRemezclaSerieAdd.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Carpeta de una versión de la serie (se emparejará por SxxEyy)"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Add-FilaRemezcla "$($dlg.SelectedPath)"
        Set-Estado "Carpeta de serie añadida. Añade la otra versión y marca qué aporta cada una." "ok"
    }
})

# Quitar el sufijo «.procesado» a los originales de la carpeta para volver a procesarlos.
$ui.btnQuitarProcesado.Add_Click({
    $carpeta = "$($ui.txtCarpeta.Text)".Trim()
    if (-not ($carpeta -and (Test-Path -LiteralPath $carpeta))) { return }
    $procesados = @($script:archivosProcesado)
    if ($procesados.Count -eq 0) { return }
    $ok = Show-DialogoHDZ -Owner $win -Icono "♻️" -Titulo "Quitar «.procesado»" `
        -Mensaje "Se quitará el sufijo «.procesado» de $($procesados.Count) archivo(s), devolviéndoles su nombre original para poder trabajar con ellos de nuevo.`n`n¿Continuar?" `
        -BotonSi "Sí, quitar sufijo" -BotonNo "Cancelar"
    if (-not $ok) { return }
    $restaurados = 0; $omitidos = 0
    foreach ($f in $procesados) {
        $nuevo = $f.Name -replace '\.procesado$', ''
        if ($nuevo -eq $f.Name) { continue }
        $destino = Join-Path $f.DirectoryName $nuevo
        if (Test-Path -LiteralPath $destino) { $omitidos++; continue }   # ya existe el original: no se pisa
        try { Rename-Item -LiteralPath $f.FullName -NewName $nuevo -ErrorAction Stop; $restaurados++ }
        catch { $omitidos++ }
    }
    if ($omitidos -gt 0) {
        Set-Estado "Restaurados $restaurados archivo(s). $omitidos no se pudieron (ya existía un archivo con el nombre original)." "warn"
    } else {
        Set-Estado "Restaurados $restaurados archivo(s): listos para procesar." "ok"
    }
    Lanzar-Escaneo   # re-escanea: los vídeos restaurados ya aparecen en la lista
})
# Carpetas de salida (rama de montaje): selectores de carpeta
$ui.btnSalidaArchivo.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Carpeta donde guardar el MKV procesado y sus capturas"
    if ($ui.txtSalidaArchivo.Text -and (Test-Path -LiteralPath $ui.txtSalidaArchivo.Text)) { $dlg.SelectedPath = $ui.txtSalidaArchivo.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ui.txtSalidaArchivo.Text = $dlg.SelectedPath }
})

# Examinar de la carpeta para archivar los .procesado + capturas (ajuste): subcarpeta por proyecto.
$ui.btnCfgCarpetaProcesados.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Carpeta donde archivar los originales .procesado y las capturas (una subcarpeta por proyecto)"
    if ($ui.cfgCarpetaProcesados.Text -and (Test-Path -LiteralPath $ui.cfgCarpetaProcesados.Text)) { $dlg.SelectedPath = $ui.cfgCarpetaProcesados.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ui.cfgCarpetaProcesados.Text = $dlg.SelectedPath; Guardar-Ajustes }
})
$ui.btnCfgCarpetaTorrent.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Carpeta por defecto donde guardar los .torrent"
    if ($ui.cfgCarpetaTorrent.Text -and (Test-Path -LiteralPath $ui.cfgCarpetaTorrent.Text)) { $dlg.SelectedPath = $ui.cfgCarpetaTorrent.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ui.cfgCarpetaTorrent.Text = $dlg.SelectedPath
        # Si la casilla de salida del .torrent está vacía, la sembramos con este valor por defecto.
        if ([string]::IsNullOrWhiteSpace($ui.txtSalidaTorrent.Text)) { $ui.txtSalidaTorrent.Text = $dlg.SelectedPath }
        Guardar-Ajustes
    }
})
$ui.btnSalidaTorrent.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Carpeta donde guardar el archivo .torrent"
    if ($ui.txtSalidaTorrent.Text -and (Test-Path -LiteralPath $ui.txtSalidaTorrent.Text)) { $dlg.SelectedPath = $ui.txtSalidaTorrent.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ui.txtSalidaTorrent.Text = $dlg.SelectedPath }
})
$ui.txtCarpeta.Add_TextChanged({
    if ($script:cambioCarpetaInterno) { return }
    # Una ruta escrita/pegada manualmente pasa a ser el único origen.
    $pManual = "$($ui.txtCarpeta.Text)".Trim()
    $script:carpetasTemporadas = if ($pManual) { @($pManual) } else { @() }
    $script:videosElegidos = @()
    $script:restringirSeleccion = $null
    Actualizar-DescripcionCarpetas
    Actualizar-ListaRapida
    if (-not $script:modoTest) {
        $script:debounceTimer.Stop()
        $script:debounceTimer.Start()
    }
})

$win.Add_PreviewDragOver({
    param($s, $e)
    if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
        $e.Effects = [Windows.DragDropEffects]::Copy
        $e.Handled = $true
    }
})
$win.Add_PreviewDrop({
    param($s, $e)
    if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
        $items = $e.Data.GetData([Windows.DataFormats]::FileDrop)
        if ($items -and $items.Count -gt 0) {
            $carpetasDrop = @($items | ForEach-Object {
                if (Test-Path -LiteralPath $_ -PathType Container) { "$_" }
                elseif (Test-Path -LiteralPath $_ -PathType Leaf) { Split-Path $_ -Parent }
            })
            if ($carpetasDrop.Count -gt 0) {
                Set-CarpetasTemporadas $carpetasDrop
                Set-Estado "Cargadas $(@(Get-CarpetasEntrada).Count) carpeta(s) para procesar en lote." "ok"
                if ($script:modoTest) { Lanzar-Escaneo } else { $script:debounceTimer.Stop(); $script:debounceTimer.Start() }
            }
        }
        $e.Handled = $true
    }
})

$ui.swProyecto.Add_Checked({ Actualizar-Proyecto })
$ui.swProyecto.Add_Unchecked({ Actualizar-Proyecto })

# Selección de archivos: marcar/desmarcar todos
$ui.btnSelTodos.Add_Click({
    foreach ($f in $script:ultimoScan) { $script:seleccion[$f.Nombre] = $true }
    Refrescar-Adaptacion
})
$ui.btnSelNinguno.Add_Click({
    foreach ($f in $script:ultimoScan) { $script:seleccion[$f.Nombre] = $false }
    Refrescar-Adaptacion
})

# =========================================================================
# SUBIR AL TRACKER — catálogos del formulario de HDZERO (IDs reales)
# =========================================================================
$catsHDZ = @(
    @{T="Películas"; V=1; Tipo="movie"}, @{T="Series"; V=2; Tipo="tv"}, @{T="Series Emisión"; V=5; Tipo="tv"},
    @{T="Animación Películas"; V=6; Tipo="movie"}, @{T="Animación Series"; V=7; Tipo="tv"},
    @{T="Anime Películas"; V=8; Tipo="movie"}, @{T="Anime Series"; V=9; Tipo="tv"},
    @{T="Documentales"; V=10; Tipo="movie"}, @{T="Documentales Series"; V=11; Tipo="tv"},
    @{T="Programas TV"; V=12; Tipo="tv"}, @{T="Telenovelas"; V=13; Tipo="tv"}
)
$tiposHDZ = @(
    @{T="WEB-DL"; V=6}, @{T="Full UHD"; V=3}, @{T="Custom UHD"; V=4}, @{T="UHDRemux"; V=5},
    @{T="Full BluRay"; V=1}, @{T="Custom BD"; V=8}, @{T="BDRemux"; V=2}, @{T="Remastered"; V=9},
    @{T="BDrip"; V=7}, @{T="UHDRip"; V=10}, @{T="MicroHD"; V=11}, @{T="DVDRemux"; V=13}, @{T="Rips AV1"; V=14}
)
$resolucionesHDZ = @(
    @{T="2160p"; V=2}, @{T="1080p"; V=3}, @{T="4320p"; V=1}, @{T="1080i"; V=4}, @{T="720p"; V=5},
    @{T="576p"; V=6}, @{T="576i"; V=7}, @{T="480p"; V=8}, @{T="480i"; V=9}, @{T="Other"; V=10}
)
Init-Combo $ui.upCategoria $catsHDZ 0
Init-Combo $ui.upTipo $tiposHDZ 0
Init-Combo $ui.upResolucion $resolucionesHDZ 0
Init-Combo $ui.cmbNumCapturas @(@{T="3";V=3},@{T="4";V=4},@{T="5";V=5},@{T="6";V=6},@{T="8";V=8},@{T="10";V=10}) 3
# Multi-episodio por vídeo (series): combo 1..6, defaults y numeración.
Init-Combo $ui.cmbEpsPorVideo @(1..6 | ForEach-Object { @{T="$_"; V=$_} }) 0
$ui.txtTemporadaEp.Text = "1"; $ui.txtPrimerEp.Text = "1"
$ui.btnAplicarEp.Add_Click({ Aplicar-NumeracionEpisodios })
$ui.swSerie.Add_Checked({   Actualizar-VisibilidadMultiEp; if (-not $script:construyendoLista) { Refrescar-Adaptacion } })
$ui.swSerie.Add_Unchecked({ Actualizar-VisibilidadMultiEp; if (-not $script:construyendoLista) { Refrescar-Adaptacion } })
Actualizar-VisibilidadMultiEp
# Muestra/oculta los paneles de cada host según el seleccionado (clave imgbb / cuenta imgbox).
function Actualizar-PanelHost {
    if (-not $ui) { return }
    $h = Get-ChipValor "hostImg"
    if ($ui.panImgbbKey)     { $ui.panImgbbKey.Visibility     = if ($h -eq "IMGBB")  { "Visible" } else { "Collapsed" } }
    if ($ui.panImgboxCuenta) { $ui.panImgboxCuenta.Visibility = if ($h -eq "IMGBOX") { "Visible" } else { "Collapsed" } }
}
Add-ChipGroup $ui.chHostImg "hostImg" @(
    @{T="freeimage.host (rectangular 350 px)"; V="FREEIMAGE"},
    @{T="imgbb (rectangular 350 px, con clave)"; V="IMGBB"},
    @{T="imgbox (rectangular 350 px)"; V="IMGBOX"},
    @{T="Pixhost (350 px, hasta 10 MB)"; V="PIXHOST"}
) 0 { Actualizar-PanelHost }

# Estado de la subida
$script:capRows = @()            # capturas: @{Ruta; Check; Subida(url)}
$script:videoSubir = $null       # ruta del vídeo (o 1er episodio) asociado al .torrent
$script:videosPackSubir = @()    # PACK: rutas de TODOS los episodios (para capturas por episodio)
$script:tmdbTipo = "movie"       # movie|tv según la categoría elegida

# --- Lee el campo 'name' de un .torrent (bencode mínimo) ---
function Get-NombreTorrent($rutaTorrent) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($rutaTorrent)
        $txt = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
        $m = [regex]::Match($txt, '4:name(\d+):')
        if (-not $m.Success) { return $null }
        $len = [int]$m.Groups[1].Value
        $ini = $m.Index + $m.Length
        $nombreBytes = $bytes[$ini..($ini + $len - 1)]
        return [System.Text.Encoding]::UTF8.GetString($nombreBytes)
    } catch { return $null }
}

# --- Localiza el vídeo (o 1er episodio si es carpeta/pack) a partir del nombre del torrent ---
function Resolve-VideoDeTorrent($rutaTorrent, $nombreInterno) {
    $dir = Split-Path $rutaTorrent -Parent
    $cand = Join-Path $dir $nombreInterno
    if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }            # single-file
    if (Test-Path -LiteralPath $cand -PathType Container) {                       # pack: 1er vídeo
        $v = @(Get-ChildItem -LiteralPath $cand -File -Recurse |
               Where-Object { $_.Extension -match "(?i)^\.(mkv|mp4|ts)$" } | Sort-Object FullName | Select-Object -First 1)
        if ($v.Count -gt 0) { return $v[0].FullName }
    }
    # Respaldo: por nombre base en la carpeta del .torrent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($nombreInterno)
    $v2 = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match "(?i)^\.(mkv|mp4|ts)$" -and $_.BaseName -eq $base } | Select-Object -First 1)
    if ($v2.Count -gt 0) { return $v2[0].FullName }
    # Respaldo extra: el vídeo puede estar en una carpeta de salida distinta a la del .torrent.
    # Buscamos por nombre base (recursivo) en las carpetas conocidas: salida del archivo y trabajo.
    $otras = @("$($ui.txtSalidaArchivo.Text)", "$($ui.txtCarpeta.Text)") |
             Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    foreach ($od in $otras) {
        if ($od -eq $dir) { continue }
        $vx = @(Get-ChildItem -LiteralPath $od -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match "(?i)^\.(mkv|mp4|ts)$" -and $_.BaseName -eq $base } | Select-Object -First 1)
        if ($vx.Count -gt 0) { return $vx[0].FullName }
    }
    return $null
}

# Ejecuta MediaInfo escribiendo su informe a un FICHERO (--LogFile), que MediaInfo genera SIEMPRE en
# UTF-8 con independencia de la codepage de la consola (OEM/CP850). Capturar el stdout con
# «& mediainfo | Out-String» lo decodificaba con la consola y rompía las tildes («Último» -> «├Ültimo»).
function Get-MediaInfoUtf8($ruta, [string[]]$extra = @()) {
    $tmp = Join-Path $env:TEMP ("hdz_mi_" + [guid]::NewGuid().ToString('N') + ".txt")
    try {
        $argsMi = @($extra) + @("--LogFile=$tmp", "$ruta")
        & mediainfo @argsMi 2>$null | Out-Null
        if (Test-Path -LiteralPath $tmp) { return (Get-Content -LiteralPath $tmp -Raw -Encoding UTF8) }
    } catch {}
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    return ""
}

# --- MediaInfo en texto plano completo ---
function Get-MediaInfoTexto($ruta) {
    try { $t = Get-MediaInfoUtf8 $ruta; if ("$t".Trim()) { return "$t".TrimEnd() } } catch {}
    # Respaldo por si --LogFile fallara en alguna build: captura directa (puede romper tildes).
    try { return (& mediainfo "$ruta" | Out-String).TrimEnd() } catch { return "" }
}

# --- Detección de specs desde mediainfo JSON (para preseleccionar combos y flags) ---
function Get-SpecsVideo($ruta) {
    $r = @{ Resolucion=$null; EsWebDl=$false; DV=$false; HDR10=$false; HDR10P=$false; Codec="" }
    try {
        $jsonMi = Get-MediaInfoUtf8 $ruta @("--Output=JSON")
        if (-not "$jsonMi".Trim()) { $jsonMi = (& mediainfo --Output=JSON "$ruta" | Out-String) }
        $j = $jsonMi | ConvertFrom-Json
        $v = $j.media.track | Where-Object { $_.'@type' -eq "Video" } | Select-Object -First 1
        if ($v) {
            $r.Resolucion = Get-HdzResolutionTrackerId (Get-HdzVideoResolution $v)
            $hdr = "$($v.HDR_Format) $($v.HDR_Format_Compatibility) $($v.HDR_Format_String)"
            if ($hdr -match "(?i)Dolby Vision") { $r.DV = $true }
            if ($hdr -match "(?i)HDR10\+|SMPTE ST 2094") { $r.HDR10P = $true }
            if ($hdr -match "(?i)HDR10") { $r.HDR10 = $true }
            $r.Codec = "$($v.Format)"
        }
    } catch {}
    return $r
}

# --- Estado de hosts (galería imgbox + miniatura/página por URL original) ---
$script:imgboxGal = $null               # @{ Id; Secret; Titulo } de la galería de la release actual
$script:imageHostMeta = @{}              # urlFull -> @{ Thumb; Page } para construir miniatura→página

# DPAPI (por usuario de Windows) vía SecureString: cifra/descifra la contraseña de imgbox en reposo.
function Protect-Texto($plano) {
    if ([string]::IsNullOrEmpty($plano)) { return "" }
    try { ConvertFrom-SecureString (ConvertTo-SecureString $plano -AsPlainText -Force) } catch { "" }
}
function Unprotect-Texto($cifrado) {
    if ([string]::IsNullOrEmpty($cifrado)) { return "" }
    try { [System.Net.NetworkCredential]::new('', (ConvertTo-SecureString $cifrado)).Password } catch { "" }
}

# Título de la galería imgbox:
#   · Película:            «Título (Año)»
#   · Serie, temporada:    «Título (Año) SXX»          (episodio 0/vacío = pack de temporada)
#   · Serie, un episodio:  «Título (Año) SXXEXX»
# El TÍTULO+AÑO sale de la info del programa (título de la subida) y, si no hay, DEL NOMBRE DE LAS
# CAPTURAS (su archivo conserva el nombre del vídeo). La TEMPORADA/EPISODIO se buscan, por orden, en
# los campos de la subida, en el título y en el nombre de las capturas.
function Get-GaleriaTitulo($rutasCapturas = @()) {
    $esTv = ($script:tmdbTipo -eq "tv")
    # Nombre base de la 1ª captura (sin extensión ni sufijo «_cap_NNNN»).
    $nombreCap = ""
    foreach ($ruta in @($rutasCapturas)) {
        $n = [System.IO.Path]::GetFileNameWithoutExtension("$ruta") -replace '(?i)_cap_\d+$', ''
        if (-not [string]::IsNullOrWhiteSpace($n)) { $nombreCap = $n; break }
    }
    # Título + año: del título de la subida; si no hay, del nombre de las capturas.
    $ta = Get-TituloAnioLimpio "$($ui.upTitulo.Text)"
    if ([string]::IsNullOrWhiteSpace("$($ta.Titulo)") -and $nombreCap) { $ta = Get-TituloAnioLimpio $nombreCap }
    $t = "$($ta.Titulo)".Trim()
    if ([string]::IsNullOrWhiteSpace($t)) {
        $raw = "$($ui.upTitulo.Text)".Trim()
        return $(if (-not [string]::IsNullOrWhiteSpace($raw)) { $raw } else { "HD ZERO" })
    }
    $base = if ($ta.Anio) { "$t ($($ta.Anio))" } else { $t }
    if (-not $esTv) { return $base }
    # Temporada/episodio: campos -> título de la subida -> nombre de las capturas.
    $temp = [int]("0" + (("$($ui.upTemporada.Text)") -replace '\D', ''))
    $epi  = [int]("0" + (("$($ui.upEpisodio.Text)")  -replace '\D', ''))
    if ($temp -le 0) {
        foreach ($src in @("$($ui.upTitulo.Text)", $nombreCap)) {
            if ($temp -le 0 -and "$src" -match '(?i)S(\d{1,3})(E(\d{1,4}))?') {
                $temp = [int]$matches[1]
                if ($matches[3] -and $epi -le 0) { $epi = [int]$matches[3] }
            }
        }
    }
    if ($temp -gt 0) {
        $sxx = "S{0:00}" -f $temp
        if ($epi -gt 0) { return "$base $sxx" + ("E{0:00}" -f $epi) }
        return "$base $sxx"
    }
    return $base
}

# Servidores compartidos por escritorio, web y menú contextual.
$script:imageHostModulePath = Join-Path $PSScriptRoot 'HDZ-ImageHosts.ps1'
. $script:imageHostModulePath

function Send-Imagenes([string[]]$rutas) {
    if($script:subSync -and -not $script:subSync.Fin){throw 'Ya hay una subida de imágenes en curso.'}
    $settings=@{ImgbbKey="$($ui.cfgImgbbKey.Text)".Trim();ImgboxUser="$($ui.cfgImgboxUser.Text)".Trim();ImgboxPass="$($ui.cfgImgboxPass.Password)"}
    $sync=[hashtable]::Synchronized(@{Done=0;Total=$rutas.Count;Fin=$false;Fase='Preparando subida con respaldo automático…'})
    $script:subSync=$sync
    $ui.panSubProgreso.Visibility='Visible'
    $timer=[Windows.Threading.DispatcherTimer]::new()
    $timer.Interval=[TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        $s=$script:subSync
        if($s){
            $ui.lblSubProgreso.Text="$($s.Fase)"
            $ui.lblSubProgresoPct.Text="$($s.Done)/$($s.Total)"
            $ui.barSubProgreso.Value=if($s.Total){100*$s.Done/$s.Total}else{0}
            Actualizar-PanelTareasAux
        }
    })
    try {
        $timer.Start()
        $result=Invoke-HdzBackground {
            param($a)
            . $a.Module
            Invoke-HdzImageUploadBatch -Paths $a.Paths -Preferred $a.Preferred -Settings $a.Settings -Title $a.Title -Gallery $a.Gallery -Sync $a.Sync
        } @{Module=$script:imageHostModulePath;Paths=$rutas;Preferred=(Get-ChipValor 'hostImg');Settings=$settings;Title=(Get-GaleriaTitulo $rutas);Gallery=$script:imgboxGal;Sync=$sync}
    } finally {
        $timer.Stop();$sync.Fin=$true;$script:subSync=$null
        $ui.panSubProgreso.Visibility='Collapsed'
        Actualizar-PanelTareasAux
    }
    foreach($event in $result.Events){Log-Linea "Imágenes: $event"}
    if($result.Gal){$script:imgboxGal=$result.Gal}
    foreach($item in $result.Items){if($item.Full){$script:imageHostMeta[$item.Full]=@{Thumb=$item.Thumb;Page=$item.Page}}}
    if($result.Aviso){Set-Estado $result.Aviso 'warn'}
    return $result
}

function Send-Imagen($ruta) {
    $result=Send-Imagenes @($ruta)
    if($result.Error){throw $result.Error}
    return $result.Items[0].Full
}

$subidaWorker = {
    param($rutas, $hostType, $imgbbKey, $sync, $imgboxUser, $imgboxPass, $galTitulo, $galInicial, $modulePath)
    try {
        . $modulePath
        $settings=@{ImgbbKey=$imgbbKey;ImgboxUser=$imgboxUser;ImgboxPass=$imgboxPass}
        $result=Invoke-HdzImageUploadBatch -Paths $rutas -Preferred $hostType -Settings $settings -Title $galTitulo -Gallery $galInicial -Sync $sync
        $meta=@{}; $urls=@()
        foreach($it in $result.Items){if($it.Full){$urls+=$it.Full;$meta[$it.Full]=@{Thumb=$it.Thumb;Page=$it.Page}}}
        $sync.Urls=$urls; $sync.Meta=$meta; $sync.Items=$result.Items
        $sync.GalInfo=$result.Gal; $sync.Error=$result.Error; $sync.Aviso=$result.Aviso; $sync.Events=$result.Events
    } catch {$sync.Error=$_.Exception.Message}
    finally {$sync.Fin=$true}
}

# Sube imágenes de forma ASÍNCRONA con barra de progreso; al terminar llama a $onComplete(urls)
# en el hilo de UI. $botones se deshabilitan mientras dura. La UI NO se bloquea.
$script:subTimer = $null; $script:subSync = $null; $script:subPS = $null
$script:subAsync = $null; $script:subOnComplete = $null; $script:subBotones = @()
function Start-SubidaAsync($rutas, [scriptblock]$onComplete, $botones = @()) {
    if($script:subSync -and -not $script:subSync.Fin){Set-Estado 'Ya hay una subida de imágenes en curso.' 'warn'; return}
    $rutas = @($rutas)
    if ($rutas.Count -eq 0) { return }
    $hostType = Get-ChipValor "hostImg"
    $imgbbKey = "$($ui.cfgImgbbKey.Text)".Trim()
    # imgbox: credenciales (opcionales) y título de la galería (= «Título (Año)»), leídos en el hilo UI.
    # También se necesitan estos datos si imgbox actúa como respaldo.
    $imgboxUser = "$($ui.cfgImgboxUser.Text)".Trim()
    $imgboxPass = if ($ui.cfgImgboxPass) { "$($ui.cfgImgboxPass.Password)" } else { "" }
    $galTitulo  = Get-GaleriaTitulo $rutas
    $script:subOnComplete = $onComplete
    $script:subBotones = @($botones)
    foreach ($b in $script:subBotones) { if ($b) { $b.IsEnabled = $false } }

    $sync = [hashtable]::Synchronized(@{ Done = 0; Total = $rutas.Count; Urls = @(); Fin = $false; Error = $null; Meta = $null; GalInfo = $null; Aviso = $null; Events=@(); Items=@(); Video=$script:videoSubir; Host=$hostType; Fase='Preparando subida con respaldo automático…' })
    $script:subSync = $sync
    $ui.panSubProgreso.Visibility = "Visible"
    $ui.barSubProgreso.Value = 0
    $ui.lblSubProgreso.Text = if ($hostType -eq "IMGBOX") { "Subiendo imágenes a imgbox (galería)…" } else { "Subiendo imágenes al host…" }
    $ui.lblSubProgresoPct.Text = "0/$($rutas.Count)"
    Actualizar-PanelTareasAux

    $ps = [powershell]::Create()
    [void]$ps.AddScript($subidaWorker.ToString()).AddArgument($rutas).AddArgument($hostType).AddArgument($imgbbKey).AddArgument($sync).AddArgument($imgboxUser).AddArgument($imgboxPass).AddArgument($galTitulo).AddArgument($script:imgboxGal).AddArgument($script:imageHostModulePath)
    $script:subPS = $ps
    $script:subAsync = $ps.BeginInvoke()

    if (-not $script:subTimer) {
        $script:subTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:subTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:subTimer.Add_Tick({
            $s = $script:subSync
            if (-not $s) { $script:subTimer.Stop(); return }
            $done = [int]$s.Done; $tot = [int]$s.Total
            $ui.barSubProgreso.Value = if ($tot -gt 0) { [int](100 * $done / $tot) } else { 0 }
            $ui.lblSubProgresoPct.Text = "$done/$tot"
            if($s.Fase){$ui.lblSubProgreso.Text="$($s.Fase)"}
            Actualizar-PanelTareasAux
            if($s.Fin -and ($script:capPreviewSync -or $script:suprimirRehacerCaps)){return}
            if ($s.Fin) {
                $script:subTimer.Stop()
                try { $script:subPS.EndInvoke($script:subAsync) } catch {}
                try { $script:subPS.Dispose() } catch {}
                $script:subPS = $null; $script:subAsync = $null
                $ui.panSubProgreso.Visibility = "Collapsed"
                foreach ($b in $script:subBotones) { if ($b) { $b.IsEnabled = $true } }
                $cb = $script:subOnComplete; $err = $s.Error; $urls = @($s.Urls)
                # Guardar página y miniatura antes de construir el BBCode.
                if ($s.GalInfo) { $script:imgboxGal = $s.GalInfo }
                if ($s.Meta) { foreach ($k in $s.Meta.Keys) { $script:imageHostMeta[$k] = $s.Meta[$k] } }
                if ($s.Aviso) { Set-Estado $s.Aviso "warn" }
                $script:subSync = $null; $script:subOnComplete = $null
                Actualizar-PanelTareasAux
                try {
                    if ($s.Video) { Iniciar-LogProyecto (Split-Path $s.Video -Parent) }
                    Log-Sec "IMÁGENES · subidas al host «$($s.Host)» ($(@($urls).Count))"
                    if ($script:imgboxGal) { Log-Linea "Galería imgbox: «$($script:imgboxGal.Titulo)» (id $($script:imgboxGal.Id))" }
                    foreach ($u in @($urls)) { Log-Linea "  $u" }
                    foreach ($event in @($s.Events)) { Log-Linea "  $event" }
                    if ($err) { Log-Linea "ERROR: $err" }
                } catch {}
                if ($err) { Set-Estado $err "error" }
                elseif ($cb) {
                    try { & $cb $urls; if($s.Aviso){Set-Estado "Imágenes subidas. $($s.Aviso)" 'warn'} }
                    catch { Set-Estado "Imágenes subidas, pero no se pudieron añadir a la descripción: $($_.Exception.Message)" 'error' }
                }
            }
        })
    }
    $script:subTimer.Start()
}

# Genera capturas en el momento (mismo cálculo y ffmpeg que el motor New-Capturas de HDZnew),
# en un runspace aparte para no bloquear la UI. Reporta progreso por hashtable sincronizado y
# escribe los PNG "<base>_cap_<seg>.png". $sync.Hechas = rutas creadas.
#  - $videos: LISTA de vídeos (en un PACK/temporada, TODOS los episodios -> N capturas por episodio).
#  - $dirDest: carpeta destino de las capturas. Si está vacía, cada captura se queda junto a su vídeo.
$capturaWorker = {
    param($videos, $numCapturas, $esHdr, $dirDest, $sync, $modulePath)
    try {
        . $modulePath
        $creadas = @(); $completed = 0; $incidents = [Collections.Generic.List[string]]::new()
        foreach ($video in @($videos)) {
            $baseDone = $completed * $numCapturas
            $result = New-HdzCapturas -ArchivoVideo "$video" -NumCapturas $numCapturas -EsHdr (Test-HdzVideoHdr "$video") -DirCapturas $dirDest -OnProgress {
                param($pct, $phase)
                $sync.Done = $baseDone + [int]($numCapturas * $pct / 100)
            } -OnIncident { param($file, $message) $incidents.Add("$file : $message") }
            $creadas += @($result.Capturas)
            $completed++
        }
        $sync.Hechas = @($creadas | Select-Object -Unique)
        if ($incidents.Count) { $sync.Error = $incidents -join '; ' }
    } catch { $sync.Error = $_.Exception.Message }
    finally { $sync.Fin = $true }
}

# Crea capturas de forma ASÍNCRONA con barra de progreso (reutiliza panSubProgreso). Al terminar
# refresca la rejilla de capturas con las antiguas + las nuevas.
$script:capTimer = $null; $script:capSync = $null; $script:capPS = $null; $script:capAsync = $null
function Start-CapturasAsync {
    if ($script:capAsync -and -not $script:capAsync.IsCompleted) { throw 'Ya se están generando capturas.' }
    if (-not ($script:videoSubir -and (Test-Path -LiteralPath $script:videoSubir))) {
        Set-Estado "No hay vídeo asociado: carga o crea un torrent primero para saber de qué vídeo sacar las capturas." "error"; return
    }
    $num = Get-ComboValor $ui.cmbNumCapturas; if (-not $num) { $num = 6 }
    $script:capTabInicio = $script:subidaTabId # identidad estable, aunque se cierre otra pestaña
    # Si el torrent es un PACK (temporada), generamos N capturas POR EPISODIO, no N en total.
    $videos = @(@($script:videosPackSubir) | Where-Object { $_ -and (Test-Path -LiteralPath "$_") } | Select-Object -Unique)
    if (@($videos).Count -lt 2) { $videos = @($script:videoSubir) }
    $esPack = (@($videos).Count -gt 1)
    # Destino de las capturas: el ajuste «Archivos procesados y capturas» (con subcarpeta por proyecto),
    # igual que en el montaje. Si está vacío, cada captura se queda junto a su vídeo, como siempre.
    $dirDest = ""
    $carpProc = "$($ui.cfgCarpetaProcesados.Text)".Trim()
    if ($carpProc) { $dirDest = Join-Path $carpProc (Split-Path (Split-Path $videos[0] -Parent) -Leaf) }
    $totalCaps = [int]$num * @($videos).Count
    $esHdr = [bool]$ui.upDV.IsChecked -or [bool]$ui.upHDR10.IsChecked -or [bool]$ui.upHDR10P.IsChecked
    $sync = [hashtable]::Synchronized(@{ Done = 0; Total = $totalCaps; Hechas = @(); Fin = $false; Error = $null })
    $script:capSync = $sync
    foreach ($b in @($ui.btnCapGenerar, $ui.btnCapInsertar, $ui.btnCapAnadir)) { if ($b) { $b.IsEnabled = $false } }
    $ui.panSubProgreso.Visibility = "Visible"
    $ui.barSubProgreso.Value = 0
    $ui.lblSubProgreso.Text = "Generando capturas$(if ($esPack) { " ($($videos.Count) episodios)" } else { '' })$(if ($esHdr) { ' · tonemap HDR' } else { '' })…"
    $ui.lblSubProgresoPct.Text = "0/$totalCaps"
    Actualizar-PanelTareasAux

    $ps = [powershell]::Create()
    [void]$ps.AddScript($capturaWorker.ToString()).AddArgument($videos).AddArgument([int]$num).AddArgument($esHdr).AddArgument($dirDest).AddArgument($sync).AddArgument((Join-Path $PSScriptRoot 'HDZ-Capturas.ps1'))
    $script:capPS = $ps
    $script:capAsync = $ps.BeginInvoke()

    if (-not $script:capTimer) {
        $script:capTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:capTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:capTimer.Add_Tick({
            $s = $script:capSync
            if (-not $s) { $script:capTimer.Stop(); return }
            $done = [int]$s.Done; $tot = [int]$s.Total
            $ui.barSubProgreso.Value = if ($tot -gt 0) { [int](100 * $done / $tot) } else { 0 }
            $ui.lblSubProgresoPct.Text = "$done/$tot"
            Actualizar-PanelTareasAux
            if ($s.Fin) {
                $script:capTimer.Stop()
                try { $script:capPS.EndInvoke($script:capAsync) } catch {}
                try { $script:capPS.Dispose() } catch {}
                $script:capPS = $null; $script:capAsync = $null
                $ui.panSubProgreso.Visibility = "Collapsed"
                foreach ($b in @($ui.btnCapGenerar, $ui.btnCapInsertar, $ui.btnCapAnadir)) { if ($b) { $b.IsEnabled = $true } }
                $err = $s.Error; $nuevas = @($s.Hechas); $script:capSync = $null
                Actualizar-PanelTareasAux
                if ($err) { Set-Estado "No se pudieron crear las capturas: $err" "error"; return }
                # Si el usuario cambió de pestaña mientras se generaban, las capturas pertenecen a la
                # pestaña que las LANZÓ, no a la activa ahora: las volcamos en el snapshot de aquella
                # (sin tocar la rejilla que estás viendo) para no mezclar capturas entre películas.
                $capIdx=-1
                for($i=0;$i -lt @($script:tabs).Count;$i++){if($script:tabs[$i].Id -eq $script:capTabInicio){$capIdx=$i;break}}
                if($capIdx -lt 0){Set-Estado 'Capturas creadas en disco; su pestaña se cerró y no se han añadido a otra película.' 'warn';return}
                if ($script:capTabInicio -ne $script:subidaTabId) {
                    $snap = $script:tabs[$capIdx]
                    $previasT = @(@($snap.Caps) | ForEach-Object { $_.Ruta })
                    $todasT = @($previasT + $nuevas | Select-Object -Unique)
                    $conocidas=@{};foreach($c in @($snap.Caps)){$conocidas["$($c.Ruta)"]=$c}
                    $snap.Caps = @($todasT | ForEach-Object {if($conocidas.ContainsKey("$_")){$conocidas["$_"]}else{@{ Ruta = $_; Marcada = $true; Subida = $null }}})
                    $script:tabs[$capIdx] = $snap
                    Set-Estado "✓  $($nuevas.Count) captura(s) creada(s) para «$($snap.Titulo)» (en su pestaña)." "ok"
                    return
                }
                # Une las que ya había con las nuevas (sin duplicar) y refresca la rejilla.
                $previas = @($script:capRows | ForEach-Object { $_.Ruta })
                $todas = @($previas + $nuevas | Select-Object -Unique)
                Construir-Capturas $todas
                $dondeCaps = if (@($nuevas).Count -gt 0) { Split-Path $nuevas[0] -Parent }
                Set-Estado "✓  $($nuevas.Count) captura(s) creada(s)$(if ($dondeCaps) { " en $dondeCaps" })." "ok"
                try {
                    if ($script:videoSubir) { Iniciar-LogProyecto (Split-Path $script:videoSubir -Parent) }
                    Log-Sec "CAPTURAS · generadas ($($nuevas.Count))"
                    Log-Linea "Vídeo: $(Split-Path $script:videoSubir -Leaf)"
                    foreach ($c in @($nuevas)) { Log-Linea "  + $(Split-Path $c -Leaf)" }
                } catch {}
            }
        })
    }
    $script:capTimer.Start()
}

# --- Llamada genérica a TMDB. Acepta INDISTINTAMENTE las dos credenciales de TMDB:
#     - "Clave de la API" (v3, 32 hex)         -> va como ?api_key=
#     - "Token de acceso de lectura" (v4, JWT) -> va como header Authorization: Bearer
#     Se detecta por el formato ("eyJ..." = JWT). Así funciona pegue el usuario la que pegue. ---
function Invoke-Tmdb($ruta, $params = @{}, [switch]$Fresh) {
    $cred = "$($ui.cfgTmdbKey.Text)".Trim()
    if ([string]::IsNullOrWhiteSpace($cred)) { throw "falta la clave/token de TMDB (pestaña Ajustes)" }
    $esJwt = ($cred -match '^eyJ' -or $cred.Length -gt 60)
    $qs = @()
    foreach ($k in $params.Keys) { if ("$($params[$k])" -ne "") { $qs += "$k=$([uri]::EscapeDataString("$($params[$k])"))" } }
    if (-not $esJwt) { $qs = @("api_key=$cred") + $qs }
    $uri = "https://api.themoviedb.org/3/$ruta" + $(if ($qs.Count) { "?" + ($qs -join "&") } else { "" })
    $headers = @{ Accept = "application/json" }
    if ($Fresh) { $headers['Cache-Control']='no-cache'; $headers['Pragma']='no-cache' }
    if ($esJwt) { $headers["Authorization"] = "Bearer $cred" }
    return Invoke-HdzRestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec 60
}

# --- Búsqueda TMDB (movie|tv) tolerante con el año, como UNIT3D ---
# El año NUNCA excluye resultados: se busca sin año (base amplia) y, si se indicó,
# también con año para priorizar; luego se ordena por coincidencia/cercanía de año y
# popularidad. Así, aunque el año del nombre esté mal, el título sigue encontrando.
function Search-Tmdb($titulo, $anio, $tipo) {
    $campoAnio = if ($tipo -eq "tv") { "first_air_date_year" } else { "year" }
    $vistos = @{}
    $acc = New-Object System.Collections.Generic.List[object]
    $agregar = {
        param($res, $conAnio)
        foreach ($x in @($res)) {
            if (-not $x -or $vistos.ContainsKey("$($x.id)")) { continue }
            $vistos["$($x.id)"] = $true
            $fecha = if ($tipo -eq "tv") { "$($x.first_air_date)" } else { "$($x.release_date)" }
            $aR = if ($fecha -match "^(\d{4})") { [int]$Matches[1] } else { 0 }
            $acc.Add([PSCustomObject]@{
                Id = $x.id
                Titulo = if ($tipo -eq "tv") { $x.name } else { $x.title }
                Fecha = $fecha
                AnioR = $aR
                Pop = [double]("0$($x.popularity)" -replace ',', '.')
                CoincideAnio = ($conAnio -and $aR -gt 0 -and $anio -and [int]$anio -eq $aR)
                Generos = @($x.genre_ids)
                Lang = "$($x.original_language)"
            })
        }
    }
    # 1) con año (los resultados más precisos, si el año es correcto)
    if ($anio) {
        try { & $agregar (Invoke-Tmdb "search/$tipo" @{ language="es-ES"; query=$titulo; $campoAnio=$anio }).results $true } catch {}
    }
    # 2) sin año SIEMPRE: aunque el año del nombre esté mal, el título sigue encontrando
    try { & $agregar (Invoke-Tmdb "search/$tipo" @{ language="es-ES"; query=$titulo }).results $false } catch {}

    # Orden: coincidencia exacta de año > cercanía al año pedido > popularidad
    $aPedido = if ($anio) { [int]$anio } else { 0 }
    return @($acc | Sort-Object `
        @{ Expression = { if ($_.CoincideAnio) { 0 } else { 1 } } }, `
        @{ Expression = { if ($aPedido -and $_.AnioR) { [Math]::Abs($_.AnioR - $aPedido) } else { 9999 } } }, `
        @{ Expression = { $_.Pop }; Descending = $true } | Select-Object -First 10)
}

# --- IDs externos (imdb, tvdb) de un elemento de TMDB ---
function Get-TmdbExternos($id, $tipo) {
    try { return Invoke-Tmdb "$tipo/$id/external_ids" }
    catch { throw "No se pudieron consultar los IDs externos de TMDB. La ficha anterior se conserva." }
}

# --- Palabras clave de TMDB (string separado por comas), como hace la web ---
function Get-TmdbKeywords($id, $tipo) {
    try {
        $r = Invoke-Tmdb "$tipo/$id/keywords"
        $lista = if ($tipo -eq "tv") { $r.results } else { $r.keywords }
        return (@($lista | ForEach-Object { $_.name } | Where-Object { $_ }) -join ", ")
    } catch { throw 'No se pudieron consultar las palabras clave de TMDB. La ficha anterior se conserva.' }
}

# --- Logos de TMDB (full-size + dimensiones); prioriza español, luego inglés, luego sin idioma ---
function Get-TmdbLogos($id, $tipo, [switch]$Fresh) {
    try {
        $r = Invoke-Tmdb "$tipo/$id/images" @{ language='es-ES'; include_image_language = "es,en,null" } -Fresh:$Fresh
        $todos = @($r.logos | ForEach-Object {
            [PSCustomObject]@{
                Url = "https://image.tmdb.org/t/p/original$($_.file_path)"
                Width = [int]"0$($_.width)"; Height = [int]"0$($_.height)"
                Lang = "$($_.iso_639_1)"
                Voto = [double]("0$($_.vote_average)" -replace ',', '.')
            }
        })
        # Mostramos TODOS, pero ordenados: primero los de español (es / es-419), luego inglés, luego
        # el resto/sin idioma; dentro de cada grupo, por valoración descendente.
        $rango = { param($l) if ($l.Lang -eq "es" -or $l.Lang -eq "es-419") { 0 } elseif ($l.Lang -eq "en") { 1 } else { 2 } }
        return @($todos | Sort-Object `
            @{ Expression = { & $rango $_ } }, `
            @{ Expression = { $_.Voto }; Descending = $true })
    } catch { throw 'No se pudieron consultar los logos de TMDB. La ficha anterior se conserva.' }
}

# --- Limpia un nombre de release para buscar en TMDB: devuelve @{Titulo; Anio} ---
function Get-TituloAnioLimpio($titulo) {
    $t = "$titulo"
    $anio = ""
    if ($t -match "\b(19\d{2}|20\d{2})\b") { $anio = $Matches[1] }
    $t = ($t -replace "(?i)\bS\d{1,3}(E\d{1,4})?\b.*$", "")     # corta en SxxEyy
    $t = ($t -replace "\(?\b(19\d{2}|20\d{2})\b\)?.*$", "")      # corta en el año
    $t = ($t -replace "[._]", " ").Trim()
    return @{ Titulo = $t; Anio = $anio }
}

# =========================================================================
# SUBIR AL TRACKER — lógica de interfaz
# =========================================================================
function Actualizar-TipoCategoria {
    $cat = Get-ComboValor $ui.upCategoria
    $entry = $catsHDZ | Where-Object { $_.V -eq $cat } | Select-Object -First 1
    $script:tmdbTipo = if ($entry -and $entry.Tipo -eq "tv") { "tv" } else { "movie" }
    $ui.panTV.Visibility = if ($script:tmdbTipo -eq "tv") { "Visible" } else { "Collapsed" }
}

# Plantilla de descripción centrada (la descripción siempre va dentro de [center]…[/center])
$script:descVacia = "[center]`n`n[/center]"
function Reset-Descripcion { $ui.upDescripcion.Text = $script:descVacia }

# Inserta/envuelve la selección de la descripción con etiquetas BBCode
function Insert-Bb($apertura, $cierre) {
    $tb = $ui.upDescripcion
    $s = $tb.SelectionStart; $l = $tb.SelectionLength
    if ($s -lt 0) { $s = $tb.Text.Length; $l = 0 }
    $sel = $tb.Text.Substring($s, $l)
    $rep = "$apertura$sel$cierre"
    $tb.Text = $tb.Text.Remove($s, $l).Insert($s, $rep)
    $tb.SelectionStart = $s + $apertura.Length
    $tb.SelectionLength = $sel.Length
    $tb.Focus()
}

# Pone el logo como primera línea dentro de [center] (sustituye uno previo si lo había)
function Insert-LogoEnDescripcion($url) {
    $tb = $ui.upDescripcion
    $txt = $tb.Text
    if ([string]::IsNullOrWhiteSpace($txt)) { $txt = $script:descVacia }
    $txt = [regex]::Replace($txt, '(?i)\[img=700\][^\[\]]*\[/img\]\r?\n?', '')   # quita logo anterior
    $linea = "[img=700]$url" + "[/img]"
    $idx = $txt.IndexOf("[center]")
    if ($idx -ge 0) {
        $pos = $idx + "[center]".Length
        $tb.Text = $txt.Substring(0, $pos) + "`n" + $linea + $txt.Substring($pos)
    } else {
        $tb.Text = "[center]`n$linea`n`n$txt`n[/center]"
    }
}

# Una URL escrita a mano no se descarga ni se transforma: se inserta tal cual como
# imagen directa. Esto admite, por ejemplo, image.tmdb.org/t/p/original/...png.
function Get-HdzLogoPersonalizadoUrl([string]$url) {
    $valor = "$url".Trim()
    $uri = $null
    if (-not [uri]::TryCreate($valor, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $valor -match '[\[\]\s]' -or $uri.AbsolutePath -notmatch '(?i)\.(png|jpe?g|webp)$') {
        throw 'La URL del logo debe ser HTTPS y apuntar directamente a una imagen PNG, JPEG o WebP.'
    }
    return $valor
}
function Usar-LogoPersonalizado([string]$url = "$($ui.txtLogoPersonalizado.Text)") {
    $url = Get-HdzLogoPersonalizadoUrl $url
    Insert-LogoEnDescripcion $url
    $script:logoSel = $url
    Refresh-LogoSel
    $ui.txtLogoPersonalizado.Text = ''
    Set-Estado 'Logo personalizado añadido a la descripción.' 'ok'
}

# Imagen directa: 350 limita el ancho mostrado, sin enlace a la página del host.
function Get-CapturaBbcode($url) {
    $uri=$null
    if(-not [uri]::TryCreate("$url",[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or "$url" -match '[\[\]\s]' -or $uri.AbsolutePath -notmatch '(?i)\.(png|jpe?g)$' -or ($uri.Host -match '(^|\.)pixhost\.(to|cc)$' -and $uri.AbsolutePath -like '/show/*')){
        throw 'La captura necesita un enlace HTTPS directo a una imagen PNG o JPEG, no a una página del servidor.'
    }
    return "[img=350]$url" + "[/img]"
}

# Inserta imágenes directas antes del [/center] de cierre.
# Cinco capturas por línea, con un salto de línea entre grupos.
function Insert-ImagenesEnDescripcion($urls) {
    if (-not $urls -or @($urls).Count -eq 0) { return }
    $ui.upDescripcion.Text = Add-HdzImageTags "$($ui.upDescripcion.Text)" $urls
}
function Add-HdzImageTags([string]$txt,$urls) {
    if ([string]::IsNullOrWhiteSpace($txt)) { $txt = $script:descVacia }
    $tags = @($urls | ForEach-Object { Get-CapturaBbcode $_ })
    $rows=@()
    for($i=0;$i -lt $tags.Count;$i+=5){$rows+=($tags[$i..([Math]::Min($i+4,$tags.Count-1))] -join '   ')}
    $bloque = $rows -join "`n"
    $idx = $txt.LastIndexOf("[/center]")
    if ($idx -ge 0) {
        # No usar TrimEnd(): los saltos manuales antes de las capturas también forman
        # parte de la descripción y el tracker los convierte en <br> al publicarla.
        $antes = $txt.Substring(0, $idx)
        if ($antes -notmatch "(?:\r?\n)$") { $antes += "`n" }
        return $antes + $bloque + "`n" + $txt.Substring($idx)
    } else {
        $antes = $txt
        if ($antes -and $antes -notmatch "(?:\r?\n)$") { $antes += "`n" }
        return $antes + "[center]$bloque[/center]"
    }
}

# Rehace el bloque de capturas de la descripción para que refleje EXACTAMENTE las casillas marcadas
# (y ya subidas): quita todas las capturas conocidas y reinserta solo las marcadas. Así, al desmarcar
# una captura ya subida desaparece de la descripción, y al volver a marcarla reaparece. NO toca el
# banner ([img=700]) ni la firma (son otras URLs, no de capturas).
$script:suprimirRehacerCaps = $false
function Rehacer-CapturasDescripcion {
    if ($script:suprimirRehacerCaps) { return }
    $tb = $ui.upDescripcion
    if (-not $tb) { return }
    $caps=@($script:capRows | ForEach-Object {@{Ruta=$_.Ruta;Subida=$_.Subida;Marcada=[bool]$_.Check.IsChecked}})
    $tb.Text=Get-HdzCaptureDescription "$($tb.Text)" $caps
    Actualizar-ContadorCapturas
}
function Get-HdzCaptureDescription([string]$txt,$caps) {
    # 1) Quitar TODOS los tags de capturas conocidas (las de capRows ya subidas), con su separador.
    foreach ($r in @($caps)) {
        if ($r.Subida) {
            $meta=$script:imageHostMeta["$($r.Subida)"]
            # Quitar primero el formato anterior completo, sin dejar [url] vacío
            # ni duplicar capturas al marcar/desmarcar una ficha ya abierta.
            $tagsConocidos = @(
                $(if($meta.Page -and $meta.Thumb){"[url=$($meta.Page)][img=350]$($meta.Thumb)[/img][/url]"}),
                $(if($meta.Page){"[url=$($meta.Page)][img=350]$($r.Subida)[/img][/url]"}),
                $(if($meta.Thumb){"[img=350]$($meta.Thumb)[/img]"}),
                (Get-CapturaBbcode $r.Subida),
                ("[img=350]$($r.Subida)[/img]")
            ) | Where-Object {$_} | Select-Object -Unique
            foreach ($tag in $tagsConocidos) {
                $esc = [regex]::Escape($tag)
                $txt = $txt -replace "$esc(   )?", ""
            }
        }
    }
    # 2) Limpiar separadores y líneas en blanco que dejó el borrado.
    $txt = $txt -replace "   (\r?\n)", '$1'
    $txt = $txt -replace "(\r?\n)   ", '$1'
    $txt = $txt -replace "[ \t]+(\r?\n)", '$1'
    # 3) Reinsertar SOLO las capturas marcadas y subidas, en orden.
    $urls = @($caps | Where-Object { $_.Marcada -and $_.Subida } | ForEach-Object { $_.Subida } | Select-Object -Unique)
    if ($urls.Count -gt 0) { return Add-HdzImageTags $txt $urls }
    return $txt
}

# Muestra en la insignia del panel cuántas capturas hay marcadas del total (se actualiza al
# marcar/desmarcar, con «Todas/Ninguna», y al generar/añadir capturas).
function Actualizar-ContadorCapturas {
    if (-not $ui.bdgCapturas) { return }
    $total = @($script:capRows).Count
    if ($total -eq 0) { $ui.bdgCapturas.Text = ""; return }
    $sel = @(@($script:capRows) | Where-Object { $_.Check.IsChecked }).Count
    $ui.bdgCapturas.Text = "$sel de $total seleccionada(s)"
}

# Resalta el logo actualmente elegido (el que se insertó en la descripción)
$script:logoSel = $null
$script:logoBordes = @()
function Refresh-LogoSel {
    foreach ($e in $script:logoBordes) {
        if ($e.Url -eq $script:logoSel) {
            $e.Borde.BorderBrush = $win.Resources["AccentBrush"]; $e.Borde.BorderThickness = [System.Windows.Thickness]::new(2)
        } else {
            $e.Borde.BorderBrush = (Brocha "#33333A"); $e.Borde.BorderThickness = [System.Windows.Thickness]::new(1)
        }
    }
}

# Muestra los logos de TMDB como miniaturas clicables, con su tamaño debajo
function Construir-Logos($logos) {
    $ui.panLogos.Children.Clear()
    $script:logoBordes = @()
    $script:logoSel = $null
    $script:logosActuales = @($logos)   # guardado para snapshot/restore de pestañas
    if (-not $logos -or @($logos).Count -eq 0) {
        $ui.cardLogos.Visibility = "Visible"
        $ui.bdgLogos.Text = '0 logos'
        return
    }
    $ui.cardLogos.Visibility = "Visible"
    $ui.bdgLogos.Text = "$(@($logos).Count) logo(s)"
    foreach ($lg in @($logos)) {
        $cont = New-Object System.Windows.Controls.StackPanel
        $cont.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
        $b = New-Object System.Windows.Controls.Border
        $b.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $b.Background = Brocha "#3A3A42"      # gris medio: hace visibles logos blancos y oscuros
        $b.BorderBrush = Brocha "#33333A"; $b.BorderThickness = [System.Windows.Thickness]::new(1)
        $b.Padding = [System.Windows.Thickness]::new(8, 6, 8, 6)
        $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $b.ToolTip = "Usar este logo  ·  $($lg.Width)×$($lg.Height) px"
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.UriSource = [Uri]$lg.Url; $bmp.DecodePixelWidth = 240
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $bmp.EndInit()
            $img = New-Object System.Windows.Controls.Image
            $img.Source = $bmp; $img.Stretch = "Uniform"; $img.Height = 42; $img.MaxWidth = 240
            $b.Child = $img
        } catch {
            $t = New-Object System.Windows.Controls.TextBlock; $t.Text = "logo"; $t.Foreground = $win.Resources["SubBrush"]
            $b.Child = $t
        }
        [void]$cont.Children.Add($b)
        $tam = New-Object System.Windows.Controls.TextBlock
        $tam.Text = "$($lg.Width)×$($lg.Height)$(if ($lg.Lang) { "  ·  $($lg.Lang)" })"
        $tam.FontSize = 10.5; $tam.Foreground = $win.Resources["SubBrush"]
        $tam.HorizontalAlignment = "Center"; $tam.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
        [void]$cont.Children.Add($tam)
        # OJO: handler SIN .GetNewClosure() (igual que en las firmas): así la escritura de
        # $script:logoSel propaga al scope real y el resaltado funciona. La ruta va en el Tag.
        $b.Tag = $lg.Url
        $b.Add_MouseLeftButtonUp({
            param($sender, $e)
            $script:logoSel = $sender.Tag
            Insert-LogoEnDescripcion $sender.Tag
            Refresh-LogoSel
            Set-Estado "Logo añadido a la descripción (resaltado abajo)."
        })
        $script:logoBordes += [PSCustomObject]@{ Url = $lg.Url; Borde = $b }
        [void]$ui.panLogos.Children.Add($cont)
    }
}

# Refresca solo el catálogo: no reaplica TMDB ni modifica el texto de la descripción.
function Update-HdzTmdbLogos {
    $id="$($ui.upTmdb.Text)".Trim()
    if ($id -notmatch '^\d+$' -or $id -eq '0') { throw 'Indica primero el ID de TMDB de esta ficha.' }
    if ($script:networkBusy) { throw 'Espera a que termine la consulta en curso.' }
    $tabId=$script:subidaTabId
    $tipo=if($script:tmdbTipo -eq 'tv'){'tv'}else{'movie'}
    $selected=$script:logoSel
    $ui.btnActualizarLogos.IsEnabled=$false
    try {
        Set-Estado 'Consultando los logos de TMDB…'
        $logos=@(Get-TmdbLogos $id $tipo -Fresh)
        if($tabId -ne $script:subidaTabId -or $id -ne "$($ui.upTmdb.Text)".Trim() -or $tipo -ne $script:tmdbTipo){
            throw 'La ficha cambió durante la consulta. No se han sustituido sus logos.'
        }
        Construir-Logos $logos
        $script:logoSel=$selected
        Refresh-LogoSel
        Set-Estado "TMDB devuelve $($logos.Count) logo(s). Descripción y selección conservadas." 'ok'
    } catch {
        Set-Estado 'No se pudieron actualizar los logos. Se conserva la ficha; vuelve a intentarlo.' 'warn'
        throw
    } finally { $ui.btnActualizarLogos.IsEnabled=$true }
}
$ui.btnActualizarLogos.Add_Click({try { Update-HdzTmdbLogos } catch { Set-Estado $_.Exception.Message 'warn' }})
$ui.btnUsarLogoPersonalizado.Add_Click({try { Usar-LogoPersonalizado } catch { Set-Estado $_.Exception.Message 'warn' }})

# --- Firmas: imágenes de la carpeta «firmas» junto al script ---
$script:firmaSel = $null          # ruta de la firma elegida (o $null)
$script:firmaBordes = @()         # @{Ruta;Borde} para resaltar la selección
$script:firmaCacheUrl = @{}       # ruta -> URL subida (cache de sesión)
$rutaFirmas = Join-Path $PSScriptRoot "firmas"

function Refresh-FirmaSel {
    foreach ($e in $script:firmaBordes) {
        if ($e.Ruta -eq $script:firmaSel) { $e.Borde.BorderBrush = $win.Resources["AccentBrush"]; $e.Borde.BorderThickness = [System.Windows.Thickness]::new(2) }
        else { $e.Borde.BorderBrush = (Brocha "#33333A"); $e.Borde.BorderThickness = [System.Windows.Thickness]::new(1) }
    }
}
function Construir-Firmas {
    $ui.panFirmas.Children.Clear()
    $script:firmaBordes = @()
    if (-not (Test-Path -LiteralPath $rutaFirmas)) { $ui.cardFirmas.Visibility = "Collapsed"; return }
    $imgs = @(Get-ChildItem -LiteralPath $rutaFirmas -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Extension -match "(?i)^\.(jpg|jpeg|png|gif|webp)$" } | Sort-Object Name)
    if ($imgs.Count -eq 0) { $ui.cardFirmas.Visibility = "Collapsed"; return }
    $ui.cardFirmas.Visibility = "Visible"
    $ui.bdgFirmas.Text = "$($imgs.Count) firma(s) en la carpeta"
    foreach ($f in $imgs) {
        $cont = New-Object System.Windows.Controls.StackPanel
        $cont.Width = 220; $cont.Margin = [System.Windows.Thickness]::new(0, 0, 10, 10)
        $b = New-Object System.Windows.Controls.Border
        $b.CornerRadius = [System.Windows.CornerRadius]::new(6); $b.Background = Brocha "#14141E"
        $b.BorderBrush = Brocha "#33333A"; $b.BorderThickness = [System.Windows.Thickness]::new(1)
        $b.Padding = [System.Windows.Thickness]::new(6); $b.Cursor = [System.Windows.Input.Cursors]::Hand
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.UriSource = [Uri]$f.FullName; $bmp.DecodePixelWidth = 220
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $bmp.EndInit()
            $img = New-Object System.Windows.Controls.Image
            $img.Source = $bmp; $img.Stretch = "Uniform"; $img.MaxHeight = 70
            $b.Child = $img
        } catch {}
        [void]$cont.Children.Add($b)
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $f.Name; $t.FontSize = 10.5; $t.Foreground = $win.Resources["SubBrush"]
        $t.TextTrimming = "CharacterEllipsis"; $t.MaxWidth = 210; $t.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
        [void]$cont.Children.Add($t)
        # OJO: nada de .GetNewClosure() aquí. Con GetNewClosure, "$script:firmaSel = …" escribe en
        # una copia aislada del scope y la selección no se propaga (bug que dejaba la firma sin
        # seleccionar). Usamos un handler normal y leemos la ruta del Tag del propio borde.
        $b.Tag = $f.FullName
        $b.Add_MouseLeftButtonUp({
            param($sender, $e)
            $ruta = $sender.Tag
            if ($script:firmaSel -eq $ruta) { $script:firmaSel = $null } else { $script:firmaSel = $ruta }
            Refresh-FirmaSel
        })
        $script:firmaBordes += [PSCustomObject]@{ Ruta = $f.FullName; Borde = $b }
        [void]$ui.panFirmas.Children.Add($cont)
    }
    Refresh-FirmaSel
}

# Convierte los géneros de TMDB en la categoría del tracker. El documental (género 99)
# tiene prioridad sobre animación (16), ya que también existen documentales animados.
# Solo recalculamos categorías que el programa gestiona automáticamente; Anime, Programas TV,
# Telenovelas, etc. se consideran elecciones deliberadas del usuario y no se pisan.
function Set-CategoriaDesdeTmdb($generos, $tipoTmdb) {
    $tipo = if ("$tipoTmdb" -eq "tv") { "tv" } else { "movie" }
    $ids = @($generos | ForEach-Object { [int]$_ })
    $objetivo = if ($ids -contains 99) {
        if ($tipo -eq "tv") { 11 } else { 10 }
    } elseif ($ids -contains 16) {
        if ($tipo -eq "tv") { 7 } else { 6 }
    } else {
        if ($tipo -eq "tv") { 2 } else { 1 }
    }
    $actual = Get-ComboValor $ui.upCategoria
    if ($actual -in @(1, 2, 6, 7, 10, 11)) { Set-ComboValor $ui.upCategoria $objetivo }
    $script:tmdbTipo = $tipo
    $ui.panTV.Visibility = if ($tipo -eq "tv") { "Visible" } else { "Collapsed" }
    return $objetivo
}

# Obtiene una ficha completa a partir de un ID escrito a mano. Se prueba primero el tipo de la
# categoría actual y, si el ID no existe ahí, el otro tipo; así también se corrige película/serie.
function Get-ResultadoTmdbPorId($id, $tipoPreferido) {
    $idTxt = "$id".Trim()
    if ($idTxt -notmatch '^\d+$') { throw "el ID de TMDB debe contener solo números" }
    $primero = if ("$tipoPreferido" -eq "tv") { "tv" } else { "movie" }
    $tipos = @($primero, $(if ($primero -eq "tv") { "movie" } else { "tv" }))
    $ultimoError = $null
    foreach ($tipo in $tipos) {
        try {
            $x = Invoke-Tmdb "$tipo/$idTxt" @{ language = "es-ES" }
            if (-not $x -or -not $x.id) { continue }
            $fecha = if ($tipo -eq "tv") { "$($x.first_air_date)" } else { "$($x.release_date)" }
            return [PSCustomObject]@{
                Id       = $x.id
                Titulo   = if ($tipo -eq "tv") { "$($x.name)" } else { "$($x.title)" }
                Fecha    = $fecha
                Generos  = @($x.genres | ForEach-Object { [int]$_.id })
                Lang     = "$($x.original_language)"
                TipoTmdb = $tipo
            }
        } catch { $ultimoError = $_.Exception }
    }
    if ($ultimoError) { throw "TMDB no encontró el ID $idTxt como película ni como serie" }
    throw "TMDB no encontró el ID $idTxt"
}

$script:aplicandoTmdb = $false
$script:ultimoTmdbAplicado = ""

# Al cambiar de ficha, elimina de la descripción únicamente el logo que procedía de TMDB.
# Las capturas ([img=350]) y cualquier otra imagen del usuario se conservan intactas.
function Limpiar-LogoTmdbDescripcion {
    $txt = "$($ui.upDescripcion.Text)"
    if ([string]::IsNullOrEmpty($txt)) { return }
    $ui.upDescripcion.Text = [regex]::Replace(
        $txt,
        '(?im)^\s*\[img=700\]https?://image\.tmdb\.org/[^\r\n]*\[/img\]\s*\r?\n?',
        ''
    )
}

# Aplica un resultado de TMDB: categoría, IDs externos, keywords y logos.
function Aplicar-ResultadoTmdb($item) {
    $tipoItem = if ($item.PSObject.Properties['TipoTmdb']) { "$($item.TipoTmdb)" } else { "$script:tmdbTipo" }
    if ($tipoItem -notin @("movie", "tv")) { $tipoItem = "movie" }
    $idNuevo = "$($item.Id)"
    $idAnterior = "$script:ultimoTmdbAplicado"
    $cambioFicha = (-not [string]::IsNullOrWhiteSpace($idAnterior) -and ($idAnterior -ne $idNuevo -or "$script:tmdbTipo" -ne $tipoItem))
    # Todas las consultas deben completarse antes de modificar la ficha visible.
    $ext = Get-TmdbExternos $item.Id $tipoItem
    $newKeywords = Get-TmdbKeywords $item.Id $tipoItem
    $newLogos = Get-TmdbLogos $item.Id $tipoItem

    if ($cambioFicha) {
        # MAL no forma parte de los IDs externos de TMDB. Al no poder recalcularlo con fiabilidad,
        # se vacía para que jamás viaje el MAL de la ficha equivocada.
        $ui.upMal.Text = ""
        Limpiar-LogoTmdbDescripcion
        $script:logoSel = $null
    }
    $script:tmdbTipo = $tipoItem
    $ui.upTmdb.Text = $idNuevo
    [void](Set-CategoriaDesdeTmdb @($item.Generos) $tipoItem)

    # Al cambiar de ficha también se eliminan los IDs/keywords que pertenecían a la ficha anterior.
    $ui.upImdb.Text = if ($ext -and $ext.imdb_id) { "$($ext.imdb_id)" } else { "" }
    $ui.upTvdb.Text = if ($ext -and $ext.tvdb_id) { "$($ext.tvdb_id)" } else { "" }
    $ui.upKeywords.Text = "$newKeywords"
    Construir-Logos $newLogos
    $script:ultimoTmdbAplicado = $idNuevo
}

# Valida y aplica un ID escrito directamente en el campo TMDB (escritorio o web remota).
function Invoke-AplicarTmdbManual($id = $null, [bool]$forzar = $false) {
    if ($script:aplicandoTmdb) { return $false }
    $idTxt = if ($null -ne $id) { "$id".Trim() } else { "$($ui.upTmdb.Text)".Trim() }
    if ([string]::IsNullOrWhiteSpace($idTxt) -or (-not $forzar -and $idTxt -eq $script:ultimoTmdbAplicado)) { return $true }
    $script:aplicandoTmdb = $true
    try {
        Set-Estado "Comprobando TMDB $idTxt y actualizando la categoría…"
        $item = Get-ResultadoTmdbPorId $idTxt $script:tmdbTipo
        Aplicar-ResultadoTmdb $item
        $ui.panResultadosTmdb.Children.Clear()
        $catNombre = "$($ui.upCategoria.SelectedItem.Content)"
        Set-Estado "TMDB $idTxt aplicado: $($item.Titulo). Categoría, IDs, keywords y logos actualizados ($catNombre)." "ok"
        return $true
    } catch {
        Set-Estado "No se pudo aplicar el ID de TMDB ${idTxt}: $($_.Exception.Message)" "warn"
        return $false
    } finally {
        $script:aplicandoTmdb = $false
    }
}

# Construye las miniaturas de capturas. CLIC en la miniatura = seleccionar/deseleccionar (la casilla
# manda lo que va en la descripción); la miniatura se resalta si está marcada y se atenúa si no. Para
# VERLA EN GRANDE, botón 🔍 en la esquina (y también la casilla de texto de debajo). Así el clic normal
# es la acción frecuente (marcar) y ver a tamaño completo es un gesto aparte, visible e intuitivo.
$script:capPreviewCache=@{}
$script:capPreviewSync=$null
function Construir-Capturas($rutas,$estados=$null) {
    # Reconstruir miniaturas no debe perder URLs ni la selección ya realizada.
    if($null -eq $estados){$estados=@($script:capRows | ForEach-Object {@{Ruta=$_.Ruta;Marcada=[bool]$_.Check.IsChecked;Subida=$_.Subida}})}
    $estadosPorRuta=@{}
    foreach($estado in @($estados)){if($estado.Ruta){$estadosPorRuta["$($estado.Ruta)"]=$estado}}
    $ui.panCapturas.Children.Clear()
    $script:capRows = @()
    $rutas=@($rutas | Where-Object {$_})
    if($rutas.Count){
        $script:capPreviewSync=[hashtable]::Synchronized(@{Done=0;Total=$rutas.Count})
        $previewTimer=[Windows.Threading.DispatcherTimer]::new()
        $previewTimer.Interval=[TimeSpan]::FromMilliseconds(250)
        $previewTimer.Add_Tick({Actualizar-PanelTareasAux})
        try {
            $previewTimer.Start()
            $script:capPreviewCache=Invoke-HdzBackground {
                param($a)
                . $a.Module
                Get-HdzCapturePreviews -Paths $a.Paths -Cache $a.Cache -Sync $a.Sync
            } @{Module=(Join-Path $PSScriptRoot 'HDZ-Async.ps1');Paths=$rutas;Cache=$script:capPreviewCache;Sync=$script:capPreviewSync}
        } finally {$previewTimer.Stop();$script:capPreviewSync=$null;Actualizar-PanelTareasAux}
    } else {$script:capPreviewCache=@{}}
    foreach ($rc in $rutas) {
        $cont = New-Object System.Windows.Controls.StackPanel
        $cont.Width = 380
        $cont.Margin = [System.Windows.Thickness]::new(0, 0, 12, 12)
        $bordeImg = New-Object System.Windows.Controls.Border
        $bordeImg.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $bordeImg.Background = Brocha "#14141E"
        $bordeImg.Height = 214                 # 380×214 ≈ 16:9, miniatura grande para ver el detalle
        $bordeImg.Cursor = [System.Windows.Input.Cursors]::Hand
        $bordeImg.ClipToBounds = $true
        $bordeImg.BorderThickness = [System.Windows.Thickness]::new(3)
        $bordeImg.ToolTip = "Clic para marcar/desmarcar · 🔍 para verla a tamaño completo"
        # Grid dentro del borde: la imagen ocupa todo y el botón 🔍 va encima, arriba a la derecha.
        $gridImg = New-Object System.Windows.Controls.Grid
        try {
            $bmp = $script:capPreviewCache[$rc].Bitmap
            $img = New-Object System.Windows.Controls.Image
            $img.Source = $bmp; $img.Stretch = "UniformToFill"
            [void]$gridImg.Children.Add($img)
        } catch {}
        $rutaCap = $rc
        # Botón 🔍 para abrir a tamaño completo (esquina superior derecha, sobre la miniatura).
        $btnZoom = New-Object System.Windows.Controls.Button
        $btnZoom.Content = "🔍"; $btnZoom.FontSize = 14
        $btnZoom.Width = 30; $btnZoom.Height = 30
        $btnZoom.HorizontalAlignment = "Right"; $btnZoom.VerticalAlignment = "Top"
        $btnZoom.Margin = [System.Windows.Thickness]::new(0, 7, 7, 0)
        $btnZoom.Cursor = [System.Windows.Input.Cursors]::Hand
        $btnZoom.Foreground = $win.Resources["TextBrush"]
        $btnZoom.Background = Brocha "#CC0C0C0F"
        $btnZoom.BorderBrush = $win.Resources["CardBorderBrush"]
        $btnZoom.BorderThickness = [System.Windows.Thickness]::new(1)
        $btnZoom.ToolTip = "Ver a tamaño completo"
        $btnZoom.Add_Click({ try { Start-Process $rutaCap } catch {} }.GetNewClosure())
        [void]$gridImg.Children.Add($btnZoom)
        $bordeImg.Child = $gridImg
        [void]$cont.Children.Add($bordeImg)
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $win.Resources["Check"]
        $anterior=$estadosPorRuta["$rc"]
        $cb.IsChecked = if($anterior){[bool]$anterior.Marcada}else{$true}
        $cb.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
        $tbn = New-Object System.Windows.Controls.TextBlock
        $tbn.Text = Split-Path $rc -Leaf
        $tbn.FontSize = 10.5; $tbn.Foreground = $win.Resources["SubBrush"]
        $tbn.TextTrimming = "CharacterEllipsis"; $tbn.MaxWidth = 350
        $cb.Content = $tbn
        # Refleja el estado de selección en la miniatura: marcada = borde de acento y opaca;
        # desmarcada = sin borde y atenuada. Así se ve de un vistazo qué capturas entran.
        $refImg = $bordeImg
        $pintar = {
            if ($cb.IsChecked) { $refImg.BorderBrush = $win.Resources["AccentBrush"]; $refImg.Opacity = 1.0 }
            else               { $refImg.BorderBrush = $win.Resources["CardBorderBrush"]; $refImg.Opacity = 0.45 }
        }.GetNewClosure()
        & $pintar
        # Clic en la miniatura = marcar/desmarcar (no abrir). La casilla dispara el resto.
        $bordeImg.Add_MouseLeftButtonUp({ $cb.IsChecked = -not $cb.IsChecked }.GetNewClosure())
        # Marcar/desmarcar: repinta la miniatura y rehace el bloque de capturas de la descripción.
        $cb.Add_Checked({ & $pintar; Rehacer-CapturasDescripcion }.GetNewClosure())
        $cb.Add_Unchecked({ & $pintar; Rehacer-CapturasDescripcion }.GetNewClosure())
        [void]$cont.Children.Add($cb)
        [void]$ui.panCapturas.Children.Add($cont)
        $script:capRows += [PSCustomObject]@{ Ruta = $rc; Check = $cb; Subida = $(if($anterior){$anterior.Subida}else{$null}) }
    }
    Actualizar-ContadorCapturas
}

# Quita SOLO una extensión conocida (.torrent/.mkv/.mp4/…) del final del nombre. A diferencia de
# [IO.Path]::GetFileNameWithoutExtension, NO recorta desde el último punto: así un nombre interno
# de PACK como «Friends (1994) S02 … H.265-HDZ» (sin extensión real) conserva el «.265-HDZ» en
# lugar de quedarse en «… H». Era la causa de que el título llegara cortado al tracker.
function Quitar-ExtConocida([string]$n) {
    return ("$n" -replace '(?i)\.(torrent|mkv|mp4|m4v|avi|mov|ts|m2ts|wmv|mpg|mpeg)$', '')
}

# --- MEMORIA de torrents pendientes ------------------------------------------------------------
# Para retomar un trabajo a medias (torrent creado pero no subido) tras cerrar el programa: por cada
# .torrent guardamos dónde quedaron el VÍDEO y las CAPTURAS (rutas exactas) y la carpeta de origen.
# Al volver a seleccionar ese torrent, se recuperan. Es el único dato de proyecto que se persiste
# (aparte de las claves); va en su propio fichero (HDZ-GUI.torrents.json), no en los ajustes.
function Leer-MemoriasTorrent {
    if (-not (Test-Path -LiteralPath $rutaMemTorrents)) { return @() }
    try { return @(Get-Content -LiteralPath $rutaMemTorrents -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return @() }
}
function Guardar-MemoriaTorrent($torrent, $video, $capturas, $origen) {
    if ($script:modoTest) { return }
    $torrent = "$torrent".Trim()
    if ([string]::IsNullOrWhiteSpace($torrent)) { return }
    $caps = @(@($capturas) | Where-Object { $_ } | ForEach-Object { "$_" } | Select-Object -Unique)
    $vid = "$video".Trim()
    if ([string]::IsNullOrWhiteSpace($vid) -and $caps.Count -eq 0) { return }   # nada útil que recordar
    try {
        $otras = @(Leer-MemoriasTorrent | Where-Object { "$($_.TorrentRuta)" -ne $torrent })
        $entrada = [ordered]@{
            TorrentRuta = $torrent
            Nombre      = [System.IO.Path]::GetFileNameWithoutExtension($torrent)
            Video       = $vid
            Capturas    = $caps
            Origen      = "$origen".Trim()
            Fecha       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
        # La entrada nueva va primera; conservamos solo los 10 torrents más recientes.
        $lista = @(@($entrada) + @($otras) | Select-Object -First 10)
        $lista | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $rutaMemTorrents -Encoding UTF8
    } catch {}
}
function Recordar-Torrent($torrent, $nombreInterno = "") {
    $lista = @(Leer-MemoriasTorrent)
    if ($lista.Count -eq 0) { return $null }
    $t = "$torrent".Trim()
    $e = @($lista | Where-Object { "$($_.TorrentRuta)" -eq $t }) | Select-Object -First 1
    if (-not $e) {
        $nom = if ($nombreInterno) { "$nombreInterno" } else { [System.IO.Path]::GetFileNameWithoutExtension($t) }
        $e = @($lista | Where-Object { "$($_.Nombre)" -eq "$nom" }) | Select-Object -First 1
    }
    return $e
}

# Carga un .torrent: localiza vídeo, mediainfo, specs, capturas, prerellena campos
function Cargar-TorrentParaSubir($rutaTorrent, $videoHint = $null, $origenHint = "", $capturasHint = @(), $videosPackHint = @(), $conservarPanel = $false) {
    # $conservarPanel = torrent RECIÉN creado cuyo panel ya trabajaste EN PARALELO mientras se hasheaba
    # (capturas seleccionadas/subidas y descripción montada). En ese caso NO reseteamos la descripción
    # ni reconstruimos la rejilla de capturas (perdería tu selección y las que ya subiste); el resto
    # (título, IDs, specs, MediaInfo, TMDB, logos) sí se rellena, que no toca tu trabajo.
    $ui.txtTorrentSubir.Text = $rutaTorrent
    $script:videosPackSubir = @()   # se rellena abajo si el torrent es un PACK (temporada)
    # Torrent recién cargado (aún sin subir): no hay página web todavía → ocultar «Ver en la web».
    $script:urlTorrentWeb = ""
    $script:rutaTorrentTracker = ""
    $script:torrentRemotoId = 0
    $script:torrentRemotoNombre = ""
    if ($ui.btnVerWeb) { $ui.btnVerWeb.Visibility = "Collapsed" }
    if ($ui.btnAbrirTorrent) { $ui.btnAbrirTorrent.Visibility = "Collapsed" }
    $nombre = Get-NombreTorrent $rutaTorrent
    if (-not $nombre) {
        $ui.lblTorrentInfo.Text = "No se pudo leer el nombre interno del .torrent."
        $ui.lblTorrentInfo.Visibility = "Visible"
        return
    }
    $ui.lblTorrentInfo.Visibility = "Collapsed"
    # MEMORIA: si no nos pasaron pistas (carga manual: «Examinar» / «Último creado»), recuperamos de
    # la memoria persistente dónde quedaron el vídeo y las capturas de este torrent. Clave porque,
    # con la carpeta de «procesados/capturas» aparte, la búsqueda por carpeta podría no encontrarlas.
    if ((-not $videoHint) -and (@($capturasHint).Count -eq 0)) {
        $mem = Recordar-Torrent $rutaTorrent $nombre
        if ($mem) {
            if ("$($mem.Video)" -and (Test-Path -LiteralPath "$($mem.Video)")) { $videoHint = "$($mem.Video)" }
            $capturasHint = @(@($mem.Capturas) | Where-Object { $_ -and (Test-Path -LiteralPath "$_") })
            if ([string]::IsNullOrWhiteSpace("$origenHint")) { $origenHint = "$($mem.Origen)" }
            if ($videoHint -or @($capturasHint).Count -gt 0) {
                Set-Estado "Recuperado de la memoria: $(if ($videoHint){'vídeo'}) $(if ($videoHint -and @($capturasHint).Count){'y '})$(if (@($capturasHint).Count){"$(@($capturasHint).Count) captura(s)"}) de un trabajo anterior."
            }
        }
    }
    # Cada torrent arranca con descripción centrada limpia y sin logos del anterior. Pero si conservamos
    # el panel (torrent recién creado ya trabajado en paralelo), NO tocamos la descripción ni los logos.
    if (-not $conservarPanel) {
        Reset-Descripcion
        Construir-Logos @()
    }
    # Título: nombre interno sin la extensión (solo si es una conocida; no recortar en «H.265»).
    # En $conservarPanel ya se puso al crear el torrent (y pudiste editarlo): no lo pisamos.
    if (-not $conservarPanel) { $ui.upTitulo.Text = Quitar-ExtConocida $nombre }

    # Si nos dan el vídeo (al crear el torrent ya sabemos cuál es), lo usamos; si no, lo localizamos.
    $video = if ($videoHint -and (Test-Path -LiteralPath $videoHint)) { $videoHint } else { Resolve-VideoDeTorrent $rutaTorrent $nombre }
    $script:videoSubir = $video
    if (-not $video) {
        if (-not $conservarPanel) {
            $ui.lblTorrentInfo.Text = "Torrent cargado, pero no encontré el vídeo junto al .torrent. El MediaInfo y las specs habrá que ponerlos a mano."
            $ui.lblTorrentInfo.Visibility = "Visible"
        }
    } elseif (-not $conservarPanel) {
        # En $conservarPanel el MediaInfo y las specs ya se extrajeron al crear el torrent.
        Set-Estado "Extrayendo MediaInfo y specs de $(Split-Path $video -Leaf)…"
        $ui.upMediainfo.Text = Get-MediaInfoTexto $video
        $specs = Get-SpecsVideo $video
        if ($specs.Resolucion) { Set-ComboValor $ui.upResolucion $specs.Resolucion }
        $ui.upDV.IsChecked = $specs.DV
        $ui.upHDR10P.IsChecked = $specs.HDR10P
        $ui.upHDR10.IsChecked = $specs.HDR10
    }

    # Categoría/Tipo/temporada por el nombre. $esSerie/$esPackTorrent se calculan SIEMPRE (el pack los
    # necesita abajo); las combos solo se tocan si NO conservamos el panel (ya se pusieron al crear).
    $esSerie = ($nombre -match "(?i)\bS\d{1,3}(E\d{1,4})?\b")
    $esPackTorrent = $false
    if ($esSerie -and $nombre -match "(?i)\bS(\d{1,3})(?:E(\d{1,4}))?") { $esPackTorrent = -not $Matches[2] }
    if (-not $conservarPanel) {
        Set-ComboValor $ui.upCategoria $(if ($esSerie) { 2 } else { 1 })
        if ($nombre -match "(?i)WEB-?DL")      { Set-ComboValor $ui.upTipo 6 }
        elseif ($nombre -match "(?i)WEB-?Rip") { Set-ComboValor $ui.upTipo 6 }
        elseif ($nombre -match "(?i)Remux")    { Set-ComboValor $ui.upTipo $(if ($nombre -match "(?i)UHD|2160") {5} else {2}) }
        elseif ($nombre -match "(?i)BDRip|BRRip") { Set-ComboValor $ui.upTipo 7 }
        Actualizar-TipoCategoria
        if ($esSerie -and $nombre -match "(?i)\bS(\d{1,3})(?:E(\d{1,4}))?") {
            $ui.upTemporada.Text = [int]$Matches[1]
            $ui.upEpisodio.Text = if ($Matches[2]) { "$([int]$Matches[2])" } else { "0" }   # sin episodio = pack
        }
    }

    # PACK (temporada): reunimos TODOS los episodios para poder sacar capturas de cada uno. Si el
    # creador del torrent nos pasó la lista exacta, la usamos; si no, listamos los vídeos de la carpeta
    # del pack (junto al vídeo principal). Con <2 vídeos no es un pack real -> se trata como archivo suelto.
    if ($esPackTorrent) {
        $lista = @(@($videosPackHint) | Where-Object { $_ -and (Test-Path -LiteralPath "$_") })
        if ($lista.Count -lt 2 -and $video) {
            $dirPack = Split-Path $video -Parent
            $lista = @(Get-ChildItem -LiteralPath $dirPack -File -ErrorAction SilentlyContinue |
                       Where-Object { $_.Extension -match "(?i)^\.(mkv|mp4)$" } | Sort-Object Name | ForEach-Object { $_.FullName })
        }
        if ($lista.Count -ge 2) { $script:videosPackSubir = @($lista | Select-Object -Unique) }
    }

    # Capturas: las _cap_*.png de este título. El montaje las deja en la CARPETA DE ORIGEN (no se
    # mueven aunque el MKV vaya a otra carpeta de salida).
    $baseT = Quitar-ExtConocida $nombre
    $baseEsc = [regex]::Escape($baseT)
    # 0) Si el motor nos dio las rutas EXACTAS de las capturas (al procesar), las usamos tal cual.
    #    Es lo más fiable: funciona aunque el MKV se haya movido, tras reabrir el programa, y en
    #    packs donde la captura lleva el nombre del episodio y no el del pack.
    $caps = @(@($capturasHint) | Where-Object { $_ -and (Test-Path -LiteralPath "$_") } | Select-Object -Unique)
    # 1) Si no, buscamos por título exacto en todas las carpetas candidatas (incluida la de origen
    #    que reporta el motor y la carpeta de trabajo/salida de la interfaz).
    if ($caps.Count -eq 0) {
        $dirs = @(
            "$origenHint".Trim(),
            $(if ($video) { Split-Path $video -Parent }),
            $(Split-Path $rutaTorrent -Parent),
            "$($ui.txtCarpeta.Text)".Trim(),
            "$($ui.txtSalidaArchivo.Text)".Trim()
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
        $caps = @($dirs | ForEach-Object {
            Get-ChildItem -LiteralPath $_ -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match "(?i)^\.(jpg|jpeg|png)$" -and $_.BaseName -match "(?i)^$baseEsc.*_cap_\d+$" }
        } | Sort-Object FullName -Unique | ForEach-Object { $_.FullName })
    }
    # 2) Respaldo: cualquier _cap_ (solo en la carpeta del vídeo/torrent, para no mezclar títulos).
    if ($caps.Count -eq 0) {
        $dirPrinc = if ($video) { Split-Path $video -Parent } else { Split-Path $rutaTorrent -Parent }
        $caps = @(Get-ChildItem -LiteralPath $dirPrinc -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Extension -match "(?i)^\.(jpg|jpeg|png)$" -and $_.BaseName -match "(?i)_cap_\d+$" } |
                  Sort-Object Name | ForEach-Object { $_.FullName })
    }
    if ($conservarPanel) {
        # Conservamos la rejilla tal cual la dejaste (selección + las que ya subiste); solo tomamos
        # sus rutas para la memoria. NO reconstruimos (eso las volvería a marcar todas y perdería
        # las URLs subidas).
        $caps = @($script:capRows | ForEach-Object { $_.Ruta } | Where-Object { $_ })
    } else {
        Construir-Capturas $caps
    }

    # MEMORIA: recordamos para este .torrent las rutas EXACTAS del vídeo y las capturas resueltas,
    # para poder retomar el trabajo si se cierra el programa sin haber subido.
    $origenMem = if ($origenHint) { $origenHint } elseif ($video) { Split-Path $video -Parent } else { "" }
    Guardar-MemoriaTorrent $rutaTorrent $script:videoSubir $caps $origenMem

    # Búsqueda TMDB automática (puede fallar o no acertar; el usuario lo revisa a mano). En
    # $conservarPanel ya se buscó al crear el torrent (y pudiste corregir la coincidencia/IDs): NO se
    # repite, para no pisar tu ajuste.
    if ($conservarPanel) {
        Set-Estado "✓  Torrent creado y listo. Tu selección de capturas y la descripción se han conservado." "ok"
    } elseif (-not [string]::IsNullOrWhiteSpace($ui.cfgTmdbKey.Text)) {
        try {
            $ta = Get-TituloAnioLimpio $baseT
            Set-Estado "Buscando «$($ta.Titulo)» en TMDB…"
            $res = Search-Tmdb $ta.Titulo $ta.Anio $script:tmdbTipo
            if ($res -and @($res).Count -gt 0) {
                Aplicar-ResultadoTmdb $res[0]
                Set-Estado "Torrent cargado. TMDB: $($res[0].Titulo) ($($res[0].Fecha)) — revisa que sea correcto."
            } else {
                Set-Estado "Torrent cargado. TMDB no encontró coincidencia automática; busca a mano."
            }
        } catch {
            Set-Estado "Torrent cargado. La búsqueda automática TMDB falló: $($_.Exception.Message)"
        }
    } else {
        Set-Estado "Torrent cargado: $($ui.upTitulo.Text). (Añade tu clave TMDB en Ajustes para autocompletar IDs.)"
    }
    if (Get-Command Construir-TabBar -ErrorAction SilentlyContinue) { Construir-TabBar }   # refrescar la etiqueta de la pestaña
}

# =========================================================================
# SUBIDAS MÚLTIPLES — cada pestaña es una subida con su propio estado completo.
# Reutilizamos los mismos controles: al cambiar de pestaña hacemos snapshot del
# estado actual y restauramos el de la pestaña destino.
# =========================================================================
$script:tabs = @()
$script:tabActual = -1
$script:subidaTabId = ''
$script:logosActuales = @()
$script:urlTorrentWeb = ""
$script:rutaTorrentTracker = ""
$script:torrentRemotoId = 0
$script:torrentRemotoNombre = ""

function Nuevo-EstadoSubida {
    @{
        Id=[guid]::NewGuid().ToString('N')
        TorrentRuta=""; Video=$null; Titulo=""; Keywords=""; Tmdb=""; TmdbAplicado=""; Imdb=""; Tvdb=""; Mal=""
        Temporada=""; Episodio=""; Categoria=0; Tipo=0; Resolucion=0
        Mediainfo=""; Nfo=""; Descripcion=$script:descVacia
        Anon=$false; Personal=$false; AudioEd=$false; Proper=$false; DV=$false; HDR10P=$false; HDR10=$false; ModQueue=$false
        Firma=$null; Logos=@(); LogoSel=$null; Caps=@(); UrlWeb=""; VideosPack=@()
        TorrentTrackerRuta=""; TorrentRemotoId=0; TorrentRemotoNombre=""
    }
}
function Snapshot-Subida {
    @{
        Id=$script:subidaTabId
        TorrentRuta="$($ui.txtTorrentSubir.Text)"; Video=$script:videoSubir
        Titulo="$($ui.upTitulo.Text)"; Keywords="$($ui.upKeywords.Text)"
        Tmdb="$($ui.upTmdb.Text)"; TmdbAplicado="$script:ultimoTmdbAplicado"; Imdb="$($ui.upImdb.Text)"; Tvdb="$($ui.upTvdb.Text)"; Mal="$($ui.upMal.Text)"
        Temporada="$($ui.upTemporada.Text)"; Episodio="$($ui.upEpisodio.Text)"
        Categoria=$ui.upCategoria.SelectedIndex; Tipo=$ui.upTipo.SelectedIndex; Resolucion=$ui.upResolucion.SelectedIndex
        Mediainfo="$($ui.upMediainfo.Text)"; Nfo="$($ui.upNfo.Text)"; Descripcion="$($ui.upDescripcion.Text)"
        Anon=[bool]$ui.upAnon.IsChecked; Personal=[bool]$ui.upPersonal.IsChecked; AudioEd=[bool]$ui.upAudioEd.IsChecked
        Proper=[bool]$ui.upProper.IsChecked; DV=[bool]$ui.upDV.IsChecked; HDR10P=[bool]$ui.upHDR10P.IsChecked
        HDR10=[bool]$ui.upHDR10.IsChecked; ModQueue=[bool]$ui.upModQueue.IsChecked
        Firma=$script:firmaSel; Logos=$script:logosActuales; LogoSel=$script:logoSel
        Caps=@($script:capRows | ForEach-Object { @{ Ruta=$_.Ruta; Marcada=[bool]$_.Check.IsChecked; Subida=$_.Subida } })
        UrlWeb="$($script:urlTorrentWeb)"; VideosPack=@($script:videosPackSubir)
        TorrentTrackerRuta="$($script:rutaTorrentTracker)"; TorrentRemotoId=[string]$script:torrentRemotoId; TorrentRemotoNombre="$($script:torrentRemotoNombre)"
    }
}
function Restore-Subida($s) {
    if(-not $s.Id){$s.Id=[guid]::NewGuid().ToString('N')}
    $script:subidaTabId="$($s.Id)"
    $ui.txtTorrentSubir.Text="$($s.TorrentRuta)"; $script:videoSubir=$s.Video; $script:videosPackSubir=@($s.VideosPack)
    $ui.upTitulo.Text="$($s.Titulo)"; $ui.upKeywords.Text="$($s.Keywords)"
    $ui.upTmdb.Text="$($s.Tmdb)"; $ui.upImdb.Text="$($s.Imdb)"; $ui.upTvdb.Text="$($s.Tvdb)"; $ui.upMal.Text="$($s.Mal)"
    $tieneTmdbAplicado = if ($s -is [System.Collections.IDictionary]) { $s.Contains('TmdbAplicado') } else { $null -ne $s.PSObject.Properties['TmdbAplicado'] }
    $script:ultimoTmdbAplicado = if ($tieneTmdbAplicado) { "$($s.TmdbAplicado)" } else { "$($s.Tmdb)" }
    $ui.upTemporada.Text="$($s.Temporada)"; $ui.upEpisodio.Text="$($s.Episodio)"
    if ([int]$s.Categoria -ge 0)  { $ui.upCategoria.SelectedIndex=[int]$s.Categoria }
    if ([int]$s.Tipo -ge 0)       { $ui.upTipo.SelectedIndex=[int]$s.Tipo }
    if ([int]$s.Resolucion -ge 0) { $ui.upResolucion.SelectedIndex=[int]$s.Resolucion }
    $ui.upMediainfo.Text="$($s.Mediainfo)"; $ui.upNfo.Text="$($s.Nfo)"
    $ui.upDescripcion.Text=$(if ([string]::IsNullOrEmpty("$($s.Descripcion)")) { $script:descVacia } else { "$($s.Descripcion)" })
    $ui.upAnon.IsChecked=[bool]$s.Anon; $ui.upPersonal.IsChecked=[bool]$s.Personal; $ui.upAudioEd.IsChecked=[bool]$s.AudioEd
    $ui.upProper.IsChecked=[bool]$s.Proper; $ui.upDV.IsChecked=[bool]$s.DV; $ui.upHDR10P.IsChecked=[bool]$s.HDR10P
    $ui.upHDR10.IsChecked=[bool]$s.HDR10; $ui.upModQueue.IsChecked=[bool]$s.ModQueue
    Actualizar-TipoCategoria
    $script:firmaSel=$s.Firma; Refresh-FirmaSel
    Construir-Logos @($s.Logos); $script:logoSel=$s.LogoSel; Refresh-LogoSel
    $supAnterior=$script:suprimirRehacerCaps;$script:suprimirRehacerCaps=$true
    try { Construir-Capturas @(@($s.Caps) | ForEach-Object { $_.Ruta }) @($s.Caps) }
    finally {$script:suprimirRehacerCaps=$supAnterior}
    $ui.panResultadosTmdb.Children.Clear()
    $ui.lblTorrentInfo.Visibility="Collapsed"
    # Página web del torrent de esta pestaña (botón «Ver en la web»).
    $script:urlTorrentWeb = "$($s.UrlWeb)"
    $script:rutaTorrentTracker = "$($s.TorrentTrackerRuta)"
    $script:torrentRemotoId = if ($s.TorrentRemotoId) { [string]$s.TorrentRemotoId } else { '' }
    $script:torrentRemotoNombre = "$($s.TorrentRemotoNombre)"
    if ($ui.btnVerWeb) { $ui.btnVerWeb.Visibility = if ($script:urlTorrentWeb) { "Visible" } else { "Collapsed" } }
    if ($ui.btnAbrirTorrent) { $ui.btnAbrirTorrent.Visibility = if ($script:rutaTorrentTracker -and (Test-Path -LiteralPath $script:rutaTorrentTracker)) { "Visible" } else { "Collapsed" } }
    # volver a modo Escribir en la descripción al cambiar de pestaña
    if ($ui.tabEscribir) { $ui.tabEscribir.IsChecked=$true }
}
function Construir-TabBar {
    if (-not $ui.panTabsSubida) { return }
    $ui.panTabsSubida.Children.Clear()
    for ($i=0; $i -lt @($script:tabs).Count; $i++) {
        $idx = $i
        # Título COMPLETO (sin truncar): las pestañas son tipo MKVToolNix, con scroll horizontal+flechas.
        $titulo = if ($i -eq $script:tabActual) { "$($ui.upTitulo.Text)" } else { "$($script:tabs[$i].Titulo)" }
        if ([string]::IsNullOrWhiteSpace($titulo)) { $titulo = "Subida $($i+1)" }

        $cont = New-Object System.Windows.Controls.Border
        $cont.CornerRadius=[System.Windows.CornerRadius]::new(7,7,0,0)   # forma de pestaña (esquinas arriba)
        $cont.Cursor=[System.Windows.Input.Cursors]::Hand
        if ($i -eq $script:tabActual) {
            # Activa: mismo color que el cuerpo + línea roja arriba; solapa el borde del cuerpo (-1 abajo) → se funde.
            $cont.Background=(Brocha "#0E0E11")
            $cont.BorderBrush=$win.Resources["AccentBrush"]; $cont.BorderThickness=[System.Windows.Thickness]::new(0,2,0,0)
            $cont.Margin=[System.Windows.Thickness]::new(0,0,3,-1)
            $cont.Padding=[System.Windows.Thickness]::new(13,7,8,8)
        } else {
            $cont.Background=(Brocha "#17171C"); $cont.BorderBrush=$win.Resources["CardBorderBrush"]
            $cont.BorderThickness=[System.Windows.Thickness]::new(1)
            $cont.Margin=[System.Windows.Thickness]::new(0,4,3,0)
            $cont.Padding=[System.Windows.Thickness]::new(13,5,8,6)
        }

        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation="Horizontal"
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text=$titulo; $t.VerticalAlignment="Center"; $t.FontSize=12; $t.ToolTip=$titulo
        $t.Foreground=$(if ($i -eq $script:tabActual) { [System.Windows.Media.Brushes]::White } else { $win.Resources["SubBrush"] })
        [void]$sp.Children.Add($t)
        if (@($script:tabs).Count -gt 1) {
            $x = New-Object System.Windows.Controls.TextBlock
            $x.Text=" ✕"; $x.VerticalAlignment="Center"; $x.FontSize=11; $x.Margin=[System.Windows.Thickness]::new(8,0,0,0)
            $x.Foreground=$(if ($i -eq $script:tabActual) { [System.Windows.Media.Brushes]::White } else { $win.Resources["SubBrush"] })
            $x.Cursor=[System.Windows.Input.Cursors]::Hand
            $x.Add_MouseLeftButtonUp({ param($snd,$e) $e.Handled=$true; Cerrar-Tab $idx }.GetNewClosure())
            [void]$sp.Children.Add($x)
        }
        $cont.Child=$sp
        $cont.Add_MouseLeftButtonUp({ Cambiar-Tab $idx }.GetNewClosure())
        [void]$ui.panTabsSubida.Children.Add($cont)
    }
    # Mostrar las flechas SOLO si las pestañas desbordan el ancho visible (se comprueba tras el layout).
    if ($ui.scrTabs) { $ui.scrTabs.Dispatcher.InvokeAsync({ Update-FlechasTabs }, [System.Windows.Threading.DispatcherPriority]::Loaded) | Out-Null }
}
function Update-FlechasTabs {
    if (-not $ui.scrTabs -or -not $ui.panTabsSubida) { return }
    $vp = $ui.scrTabs.ViewportWidth
    # Si el panel aún no está medido (viewport 0, p.ej. el panel está oculto), no mostramos flechas:
    # ya se recalcula cuando el panel se muestra (SizeChanged + al entrar en «Torrent y subida»).
    if ($vp -le 1) {
        $ui.btnTabIzq.Visibility = "Collapsed"; $ui.btnTabDer.Visibility = "Collapsed"; return
    }
    # ExtentWidth = ancho real del contenido desplazable (las pestañas); si supera el viewport, desbordan.
    $vis = if ($ui.scrTabs.ExtentWidth -gt ($vp + 1)) { "Visible" } else { "Collapsed" }
    $ui.btnTabIzq.Visibility = $vis
    $ui.btnTabDer.Visibility = $vis
}
function Cambiar-Tab($idx) {
    $script:tmdbSearchResults = @()
    if ($idx -eq $script:tabActual -or $idx -lt 0 -or $idx -ge @($script:tabs).Count) { return }
    Log-DiagSubida "CAMBIAR-TAB de [$($script:tabActual)] a [$idx] | antes: $(Ctx-SubidaActiva)"
    if ($script:tabActual -ge 0 -and $script:tabActual -lt @($script:tabs).Count) { $script:tabs[$script:tabActual] = Snapshot-Subida }
    $script:tabActual = $idx
    Restore-Subida $script:tabs[$idx]
    Construir-TabBar
    Log-DiagSubida "CAMBIAR-TAB hecho | ahora: $(Ctx-SubidaActiva)"
}
function Nueva-Tab {
    if ($script:tabActual -ge 0 -and $script:tabActual -lt @($script:tabs).Count) { $script:tabs[$script:tabActual] = Snapshot-Subida }
    $script:tabs += (Nuevo-EstadoSubida)
    $script:tabActual = @($script:tabs).Count - 1
    Restore-Subida $script:tabs[$script:tabActual]
    Construir-TabBar
    if ($ui.scrTabs) { $ui.scrTabs.Dispatcher.InvokeAsync({ $ui.scrTabs.ScrollToRightEnd() }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null }
    Set-Estado "Nueva subida añadida. Carga o crea su torrent."
}
function Cerrar-Tab($idx) {
    if (@($script:tabs).Count -le 1) { Set-Estado "Debe quedar al menos una subida."; return }
    if ($idx -ne $script:tabActual -and $script:tabActual -ge 0) { $script:tabs[$script:tabActual] = Snapshot-Subida }
    $nueva=@(); for ($i=0;$i -lt @($script:tabs).Count;$i++){ if ($i -ne $idx){ $nueva += $script:tabs[$i] } }
    $script:tabs = $nueva
    if ($script:tabActual -gt $idx) { $script:tabActual-- }
    elseif ($script:tabActual -eq $idx -and $script:tabActual -ge @($script:tabs).Count) { $script:tabActual = @($script:tabs).Count - 1 }
    Restore-Subida $script:tabs[$script:tabActual]
    Construir-TabBar
}
function Init-Tabs {
    $script:tabs = @(Nuevo-EstadoSubida)
    $script:tabActual = 0
    $script:subidaTabId=$script:tabs[0].Id
    Construir-TabBar
}
# Añade una subida automáticamente (al ir terminando el montaje cada vídeo): usa la pestaña actual
# si está vacía, si no crea una nueva, y carga el torrent recién creado con su vídeo y capturas.
# $traerAlFrente:
#   $true  (carga MANUAL: «Último creado», «Examinar», «Cargar .torrent») -> cambia a esa pestaña.
#   $false (auto-añadido del MONTAJE) -> crea la pestaña en 2º plano y TE DEJA en la que estabas, para
#          NO robarte la vista mientras trabajas/subes otra (antes, al terminar una peli, la pestaña
#          que mirabas «se transformaba» en la recién añadida).
function Anadir-SubidaAuto($torrent, $video, $origen = "", $capturas = @(), $traerAlFrente = $true) {
    $torNorm = "$torrent".Trim()
    $volverA = $script:tabActual   # pestaña del usuario, para no robarle la vista en el auto-añadido
    Log-DiagSubida "ANADIR-SUBIDA torrent='$(Split-Path $torrent -Leaf)' traerAlFrente=$traerAlFrente | $(Ctx-SubidaActiva)"
    # Guardamos el estado de la pestaña activa para que la búsqueda vea su torrent actual.
    if ($script:tabActual -ge 0 -and $script:tabActual -lt @($script:tabs).Count) { $script:tabs[$script:tabActual] = Snapshot-Subida }
    # DEDUPE: si YA existe una pestaña para este mismo .torrent, no creamos otra ni pisamos ninguna.
    for ($i = 0; $i -lt @($script:tabs).Count; $i++) {
        if ("$($script:tabs[$i].TorrentRuta)".Trim() -eq $torNorm) {
            Log-DiagSubida "  -> DEDUPE: ya existe en pestaña [$i] (traerAlFrente=$traerAlFrente)"
            if ($traerAlFrente) { Cambiar-Tab $i; Construir-TabBar; Set-Estado "Esa subida ya estaba abierta: $(Split-Path $torrent -Leaf)." "ok" }
            else { Construir-TabBar }
            return
        }
    }
    # Reutilizar la pestaña activa SOLO si está vacía Y es la única (arranque); si no, pestaña nueva.
    $vacia = [string]::IsNullOrWhiteSpace($ui.txtTorrentSubir.Text) -and [string]::IsNullOrWhiteSpace($ui.upTitulo.Text)
    $reutiliza = $vacia -and (@($script:tabs).Count -le 1)
    if (-not $reutiliza) { Nueva-Tab }
    Cargar-TorrentParaSubir $torrent $(if ($video -and (Test-Path -LiteralPath $video)) { $video } else { $null }) $origen @($capturas)
    if ($script:tabActual -ge 0 -and $script:tabActual -lt @($script:tabs).Count) { $script:tabs[$script:tabActual] = Snapshot-Subida }
    # Auto-añadido: volver a la pestaña donde estaba el usuario (no robar la vista).
    if (-not $traerAlFrente -and $volverA -ge 0 -and $volverA -lt @($script:tabs).Count -and $volverA -ne $script:tabActual) {
        $script:tabActual = $volverA
        Restore-Subida $script:tabs[$volverA]
    }
    Construir-TabBar
    if ($traerAlFrente) { Set-Estado "Subida añadida: $(Split-Path $torrent -Leaf). Está en «Torrent y subida»." "ok" }
    else { Set-Estado "Nueva subida lista en «Torrent y subida»: $(Split-Path $torrent -Leaf)." "ok" }
}
$ui.btnNuevaSubida.Add_Click({ Nueva-Tab })
$ui.btnTabIzq.Add_Click({ $ui.scrTabs.ScrollToHorizontalOffset([Math]::Max(0, $ui.scrTabs.HorizontalOffset - 240)) })
$ui.btnTabDer.Add_Click({ $ui.scrTabs.ScrollToHorizontalOffset($ui.scrTabs.HorizontalOffset + 240) })
$ui.scrTabs.Add_SizeChanged({ Update-FlechasTabs })
$ui.panTabsSubida.Add_SizeChanged({ Update-FlechasTabs })
# Flechas de las pestañas de PROYECTO/AUDIO/SUBS (modo heterogéneo) — las 3 barras
$ui.btnTabProyIzq.Add_Click({ $ui.scrTabsProy.ScrollToHorizontalOffset([Math]::Max(0, $ui.scrTabsProy.HorizontalOffset - 240)) })
$ui.btnTabProyDer.Add_Click({ $ui.scrTabsProy.ScrollToHorizontalOffset($ui.scrTabsProy.HorizontalOffset + 240) })
$ui.btnTabProyAIzq.Add_Click({ $ui.scrTabsProyA.ScrollToHorizontalOffset([Math]::Max(0, $ui.scrTabsProyA.HorizontalOffset - 240)) })
$ui.btnTabProyADer.Add_Click({ $ui.scrTabsProyA.ScrollToHorizontalOffset($ui.scrTabsProyA.HorizontalOffset + 240) })
$ui.btnTabProySIzq.Add_Click({ $ui.scrTabsProyS.ScrollToHorizontalOffset([Math]::Max(0, $ui.scrTabsProyS.HorizontalOffset - 240)) })
$ui.btnTabProySDer.Add_Click({ $ui.scrTabsProyS.ScrollToHorizontalOffset($ui.scrTabsProyS.HorizontalOffset + 240) })
foreach ($scr in @($ui.scrTabsProy, $ui.scrTabsProyA, $ui.scrTabsProyS)) { $scr.Add_SizeChanged({ Update-FlechasTabsProy }) }
foreach ($pan in @($ui.panTabsGenInner, $ui.panTabsProy, $ui.panTabsProyA, $ui.panTabsProyS)) { $pan.Add_SizeChanged({ Update-FlechasTabsProy }) }
# Asas de redimensión de los campos de texto (arrastrar la esquina cambia el alto).
# Acumulamos sobre el Height actual (no ActualHeight) para que el arrastre sea estable.
$ui.gripDesc.Add_DragDelta({ param($s, $e)
    $h = if ([double]::IsNaN($ui.gridDesc.Height)) { $ui.gridDesc.ActualHeight } else { $ui.gridDesc.Height }
    $n = $h + $e.VerticalChange
    if ($n -ge 120 -and $n -le 1600) { $ui.gridDesc.Height = $n }
})
$ui.gripMedia.Add_DragDelta({ param($s, $e)
    $h = if ([double]::IsNaN($ui.gridMediaInfo.Height)) { $ui.gridMediaInfo.ActualHeight } else { $ui.gridMediaInfo.Height }
    $n = $h + $e.VerticalChange
    if ($n -ge 80 -and $n -le 1600) { $ui.gridMediaInfo.Height = $n }
})
$ui.gripListado.Add_DragDelta({ param($s, $e)
    $h = if ([double]::IsNaN($ui.gridListado.Height)) { $ui.gridListado.ActualHeight } else { $ui.gridListado.Height }
    $n = $h + $e.VerticalChange
    if ($n -ge 120 -and $n -le 2000) { $ui.gridListado.Height = $n }
})

# =========================================================================
# SUBIR AL TRACKER — eventos
# =========================================================================
$ui.upCategoria.Add_SelectionChanged({ Actualizar-TipoCategoria })
$ui.upTmdb.Add_LostKeyboardFocus({
    if (-not $script:aplicandoTmdb) { [void](Invoke-AplicarTmdbManual) }
})
$ui.upTmdb.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Enter -or $e.Key -eq [System.Windows.Input.Key]::Return) {
        [void](Invoke-AplicarTmdbManual)
        $e.Handled = $true
    }
})

$ui.btnTorrentExaminar.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Torrents (*.torrent)|*.torrent"
    if ($ui.txtCarpeta.Text -and (Test-Path -LiteralPath $ui.txtCarpeta.Text)) { $dlg.InitialDirectory = $ui.txtCarpeta.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Anadir-SubidaAuto $dlg.FileName }
})
function Open-HdzLatestTorrent {
    $carpetas=@("$($ui.cfgCarpetaTorrent.Text)","$($ui.txtSalidaTorrent.Text)","$($ui.txtSalidaArchivo.Text)","$($ui.txtCarpeta.Text)","$($ui.cfgCarpetaProcesados.Text)")+@($script:carpetasTemporadas)
    Set-Estado 'Buscando el último torrent creado…'
    try {
        $ultimo=Invoke-HdzBackground {
            param($a)
            . $a.Module
            Get-HdzLatestCreatedTorrent -Folders $a.Folders
        } @{Module=(Join-Path $PSScriptRoot 'HDZ-History.ps1');Folders=$carpetas}
        if(-not $ultimo){Set-Estado 'No se encontró ningún torrent disponible en el historial ni en las carpetas configuradas. Puedes seleccionarlo con «Examinar».' 'error';return}
        Anadir-SubidaAuto ([string]$ultimo)
    } catch {Set-Estado "No se pudo localizar o abrir el último torrent: $($_.Exception.Message)" 'error'}
}
$ui.btnTorrentUltimo.Add_Click({ Open-HdzLatestTorrent })
# --- Crear el .torrent de algo ya procesado (archivo o carpeta/pack), en segundo plano ---
# El worker dot-sourcea el módulo compartido y crea el torrent reportando progreso por $sync.
$torrentWorker = {
    param($modulo, $tipo, $ruta, $announce, $carpeta, $sync)
    try {
        . $modulo
        $cb = { param($p) $sync.Pct = $p }
        # NO se pone 'source': el torrent que crea el programa es SOLO para subir. Al registrar, el
        # tracker le añade un campo 'entropy' ALEATORIO (nonce único) + 'source' al 'info', cambiando el
        # info-hash. Por eso el creado NUNCA puede coincidir con el registrado: el único sembrable es el
        # que se descarga del tracker tras subir. No tocamos el creado (lo pidió el usuario).
        if ($tipo -eq "pack") { $sync.Resultado = New-TorrentPack $ruta $announce "" $carpeta $cb }
        else                  { $sync.Resultado = New-TorrentArchivo $ruta $announce "" $carpeta $cb }
    } catch { $sync.Error = $_.Exception.Message }
    $sync.Fin = $true
}
$script:torTimer = $null; $script:torSync = $null; $script:torPS = $null; $script:torAsync = $null; $script:torVideoHint = $null; $script:torVideosPack = @()
# Incluye el tramo previo al hasheo (MediaInfo/TMDB). Sin esta bandera parecía que no ocurría nada
# mientras se preparaba el torrent, sobre todo si se lanzaba desde el móvil.
$script:torPreparando = $false
function Start-CrearTorrentAsync($tipo, $ruta) {
    if ($script:torPreparando -or ($script:torAsync -and -not $script:torAsync.IsCompleted)) { throw 'Ya se está creando un torrent. Espera a que termine.' }
    $announce = "$($ui.txtAnnounce.Text)".Trim()
    $carpeta  = "$($ui.txtSalidaTorrent.Text)".Trim()
    # Si no hay carpeta de salida en la sesión, usamos la carpeta por defecto de .torrent (Ajustes).
    if ([string]::IsNullOrWhiteSpace($carpeta)) { $carpeta = "$($ui.cfgCarpetaTorrent.Text)".Trim() }
    $script:torPreparando = $true
    $ui.panTorrentProgreso.Visibility = "Visible"
    $ui.barTorrentProgreso.Value = 0; $ui.lblTorrentProgresoPct.Text = "0%"
    $ui.lblTorrentProgreso.Text = "Preparando torrent de $(Split-Path $ruta -Leaf)…"
    Actualizar-PanelTareasAux
    # Pista del vídeo para luego cargar specs/capturas (el .torrent puede acabar en otra carpeta).
    # En un PACK guardamos además la lista de TODOS los episodios (para capturas por episodio).
    $script:torVideosPack = @()
    $script:torVideoHint = if ($tipo -eq "pack") {
        $script:torVideosPack = @(Get-ChildItem -LiteralPath $ruta -File -Recurse -ErrorAction SilentlyContinue |
          Where-Object { $_.Extension -match "(?i)^\.(mkv|mp4)$" } | Sort-Object FullName | ForEach-Object { $_.FullName })
        @($script:torVideosPack | Select-Object -First 1)
    } else { $ruta }
    # El vídeo ya se conoce AHORA, así que se puede generar capturas EN PARALELO mientras se crea el
    # torrent (que solo hashea, no necesita el vídeo para nada). Asociamos ya el vídeo (y, en pack,
    # todos los episodios) y detectamos su HDR para que el tonemap de las capturas sea correcto sin
    # esperar a que termine el torrent. Al terminar, Cargar-TorrentParaSubir refresca specs y capturas.
    $primerVideo = if ($tipo -eq "pack") { @($script:torVideosPack | Select-Object -First 1)[0] } else { $ruta }
    $script:videoSubir = $primerVideo
    $script:videosPackSubir = @($script:torVideosPack)
    # Contexto NUEVO: panel en blanco para este torrent (capturas, descripción y logos del anterior).
    # Si no, al trabajar en paralelo se mezclaba con lo del torrent previo (p. ej. seguías viendo las
    # capturas de la S07 al crear la S08, o montabas la descripción sobre la anterior). Al terminar,
    # Cargar-TorrentParaSubir se llama con $conservarPanel para NO pisar lo que hayas hecho.
    Construir-Capturas @()
    Reset-Descripcion
    Construir-Logos @()
    if ($primerVideo -and (Test-Path -LiteralPath $primerVideo)) {
        try {
            $specs0 = Get-SpecsVideo $primerVideo
            if ($specs0.Resolucion) { Set-ComboValor $ui.upResolucion $specs0.Resolucion }
            $ui.upDV.IsChecked = [bool]$specs0.DV
            $ui.upHDR10P.IsChecked = [bool]$specs0.HDR10P
            $ui.upHDR10.IsChecked = [bool]$specs0.HDR10
        } catch {}
        # MediaInfo del vídeo YA: no hay que esperar a que termine el torrent.
        try { $ui.upMediainfo.Text = Get-MediaInfoTexto $primerVideo } catch {}
    }
    # Título, categoría/tipo/temporada y TMDB (logos + IDs) YA, en paralelo, para que aparezcan mientras
    # se hashea (antes solo salían al terminar). Al terminar, Cargar-TorrentParaSubir se llama con
    # $conservarPanel y NO los vuelve a tocar (ni re-busca en TMDB), así respeta lo que hayas ajustado.
    try {
        $nombreFuente = if ($tipo -eq "pack") { Split-Path $ruta -Leaf } else { [System.IO.Path]::GetFileNameWithoutExtension($ruta) }
        $baseTit = Quitar-ExtConocida $nombreFuente
        $ui.upTitulo.Text = $baseTit
        $esSerieF = ($nombreFuente -match "(?i)\bS\d{1,3}(E\d{1,4})?\b")
        Set-ComboValor $ui.upCategoria $(if ($esSerieF) { 2 } else { 1 })
        if ($nombreFuente -match "(?i)WEB-?DL|WEB-?Rip") { Set-ComboValor $ui.upTipo 6 }
        elseif ($nombreFuente -match "(?i)Remux")        { Set-ComboValor $ui.upTipo $(if ($nombreFuente -match "(?i)UHD|2160") {5} else {2}) }
        elseif ($nombreFuente -match "(?i)BDRip|BRRip")  { Set-ComboValor $ui.upTipo 7 }
        Actualizar-TipoCategoria
        if ($esSerieF -and $nombreFuente -match "(?i)\bS(\d{1,3})(?:E(\d{1,4}))?") {
            $ui.upTemporada.Text = [int]$Matches[1]
            $ui.upEpisodio.Text = if ($Matches[2]) { "$([int]$Matches[2])" } else { "0" }
        }
        if (-not [string]::IsNullOrWhiteSpace($ui.cfgTmdbKey.Text)) {
            $taF = Get-TituloAnioLimpio $baseTit
            $resF = Search-Tmdb $taF.Titulo $taF.Anio $script:tmdbTipo
            if ($resF -and @($resF).Count -gt 0) { Aplicar-ResultadoTmdb $resF[0] }
        }
    } catch {}
    $sync = [hashtable]::Synchronized(@{ Pct = 0; Resultado = $null; Error = $null; Fin = $false })
    $script:torSync = $sync
    foreach ($b in @($ui.btnCrearTorrentArchivo, $ui.btnCrearTorrentCarpeta, $ui.btnTorrentExaminar, $ui.btnTorrentUltimo)) { $b.IsEnabled = $false }
    $ui.lblTorrentInfo.Visibility = "Collapsed"
    $ui.panTorrentProgreso.Visibility = "Visible"
    $ui.barTorrentProgreso.Value = 0; $ui.lblTorrentProgresoPct.Text = "0%"
    $ui.lblTorrentProgreso.Text = "Creando torrent de $(Split-Path $ruta -Leaf)…"
    Actualizar-PanelTareasAux

    $ps = [powershell]::Create()
    [void]$ps.AddScript($torrentWorker.ToString()).AddArgument($rutaTorrentMod).AddArgument($tipo).AddArgument($ruta).AddArgument($announce).AddArgument($carpeta).AddArgument($sync)
    $script:torPS = $ps
    $script:torAsync = $ps.BeginInvoke()

    if (-not $script:torTimer) {
        $script:torTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:torTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:torTimer.Add_Tick({
            $s = $script:torSync
            if (-not $s) { $script:torTimer.Stop(); return }
            $ui.barTorrentProgreso.Value = [int]$s.Pct; $ui.lblTorrentProgresoPct.Text = "$([int]$s.Pct)%"
            Actualizar-PanelTareasAux
            if ($s.Fin) {
                $script:torTimer.Stop()
                try { $script:torPS.EndInvoke($script:torAsync) } catch {}
                try { $script:torPS.Dispose() } catch {}
                $script:torPS = $null; $script:torAsync = $null; $script:torPreparando = $false
                $ui.panTorrentProgreso.Visibility = "Collapsed"
                foreach ($b in @($ui.btnCrearTorrentArchivo, $ui.btnCrearTorrentCarpeta, $ui.btnTorrentExaminar, $ui.btnTorrentUltimo)) { $b.IsEnabled = $true }
                $res = $s.Resultado; $err = $s.Error; $script:torSync = $null
                Actualizar-PanelTareasAux
                if ($err) {
                    Set-Estado "No se pudo crear el torrent: $err" "error"
                    try { Log-Sec "TORRENT · error"; Log-Linea "$err" } catch {}
                }
                elseif ($res) {
                    try { [void](Add-HdzHistory @{kind='torrent';status='Creado';video="$($script:torVideoHint)";torrent="$res";sources=@($script:torVideosPack)}) } catch { Set-Estado "Torrent creado, pero no se pudo guardar el historial: $($_.Exception.Message)" 'warn' }
                    Set-Estado "✓  Torrent creado: $(Split-Path $res -Leaf)" "ok"
                    try {
                        if ($script:torVideoHint) { Iniciar-LogProyecto (Split-Path $script:torVideoHint -Parent) }
                        Log-Sec "TORRENT · creado"
                        Log-Linea "Archivo: $(Split-Path $res -Leaf)"
                        Log-Linea "Ruta: $res"
                    } catch {}
                    # Capturas que el usuario ya generó EN PARALELO mientras se creaba el torrent:
                    # se pasan como pista para que la recarga no las pierda al rehacer la rejilla.
                    $capsYa = @($script:capRows | ForEach-Object { $_.Ruta } | Where-Object { $_ -and (Test-Path -LiteralPath "$_") })
                    # $conservarPanel = $true: NO resetea la descripción ni la selección/subida de
                    # capturas que hiciste mientras se hasheaba.
                    Cargar-TorrentParaSubir $res $script:torVideoHint "" @($capsYa) @($script:torVideosPack) $true
                }
            }
        })
    }
    $script:torTimer.Start()
}
$ui.btnCrearTorrentArchivo.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Vídeos (*.mkv;*.mp4)|*.mkv;*.mp4|Todos|*.*"
    if ($ui.txtCarpeta.Text -and (Test-Path -LiteralPath $ui.txtCarpeta.Text)) { $dlg.InitialDirectory = $ui.txtCarpeta.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Start-CrearTorrentAsync "archivo" $dlg.FileName }
})
$ui.btnCrearTorrentCarpeta.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Carpeta del pack (con los MKV finales) para crear su .torrent"
    if ($ui.txtCarpeta.Text -and (Test-Path -LiteralPath $ui.txtCarpeta.Text)) { $dlg.SelectedPath = $ui.txtCarpeta.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Start-CrearTorrentAsync "pack" $dlg.SelectedPath }
})
$ui.btnNfoExaminar.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "NFO (*.nfo;*.txt)|*.nfo;*.txt|Todos|*.*"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ui.upNfo.Text = $dlg.FileName }
})
$ui.btnMediaRefrescar.Add_Click({
    if ($script:videoSubir -and (Test-Path -LiteralPath $script:videoSubir)) {
        $ui.upMediainfo.Text = Get-MediaInfoTexto $script:videoSubir
    } else { Set-Estado "No hay vídeo asociado para regenerar el MediaInfo." "error" }
})
$ui.btnCapGenerar.Add_Click({ Start-CapturasAsync })
# Colapsar/expandir la rejilla de miniaturas (con muchas capturas el scroll se hace muy largo).
# Solo oculta las miniaturas: la insignia con el recuento y los botones siguen visibles.
$ui.btnCapColapsar.Add_Click({
    if ($ui.panCapturas.Visibility -eq "Visible") {
        $ui.panCapturas.Visibility = "Collapsed"; $ui.btnCapColapsar.Content = "▸ Mostrar"
    } else {
        $ui.panCapturas.Visibility = "Visible";   $ui.btnCapColapsar.Content = "▾ Ocultar"
    }
})
$ui.btnCapTodas.Add_Click({ $script:suprimirRehacerCaps = $true; foreach ($r in $script:capRows) { $r.Check.IsChecked = $true }; $script:suprimirRehacerCaps = $false; Rehacer-CapturasDescripcion })
$ui.btnCapNinguna.Add_Click({ $script:suprimirRehacerCaps = $true; foreach ($r in $script:capRows) { $r.Check.IsChecked = $false }; $script:suprimirRehacerCaps = $false; Rehacer-CapturasDescripcion })
$ui.btnCapAnadir.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Imágenes (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png"
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $actuales = @($script:capRows | ForEach-Object { $_.Ruta })
        Construir-Capturas (@($actuales) + @($dlg.FileNames))
    }
})
function Get-HdzUploadTab([string]$TabId) {
    if(-not $TabId){throw 'No se identificó la pestaña de origen.'}
    if($TabId -eq $script:subidaTabId){return Snapshot-Subida}
    $found=@($script:tabs | Where-Object {$_.Id -eq $TabId})
    if($found.Count -ne 1){throw 'La pestaña de origen se ha cerrado. Los enlaces subidos siguen en la caché para recuperarlos, sin mezclarlos con otra película.'}
    return $found[0]
}
function Save-HdzUploadTab($state) {
    $idx=-1
    for($i=0;$i -lt @($script:tabs).Count;$i++){if($script:tabs[$i].Id -eq $state.Id){$idx=$i;break}}
    if($idx -lt 0){throw 'La pestaña de origen ya no existe.'}
    if($state.Id -eq $script:subidaTabId){
        $byPath=@{};foreach($cap in @($state.Caps)){$byPath["$($cap.Ruta)"]=$cap}
        foreach($row in @($script:capRows)){if($byPath.ContainsKey("$($row.Ruta)")){$row.Subida=$byPath["$($row.Ruta)"].Subida}}
        $ui.upDescripcion.Text="$($state.Descripcion)"
        Actualizar-ContadorCapturas
    }
    $script:tabs[$idx]=$state
}
function Complete-HdzCaptureInsertion([string]$TabId,$Paths,$Urls) {
    $Paths=@($Paths);$Urls=@($Urls)
    if($Paths.Count -ne $Urls.Count){throw 'El servidor no devolvió todos los enlaces esperados; no se anunciará una inserción completa.'}
    $byPath=@{}
    for($i=0;$i -lt $Paths.Count;$i++){[void](Get-CapturaBbcode $Urls[$i]);$byPath["$($Paths[$i])"]="$($Urls[$i])"}
    $state=Get-HdzUploadTab $TabId
    $state.Caps=@($state.Caps | ForEach-Object {
        @{Ruta=$_.Ruta;Marcada=[bool]$_.Marcada;Subida=$(if($byPath.ContainsKey("$($_.Ruta)")){$byPath["$($_.Ruta)"]}else{$_.Subida})}
    })
    $state.Descripcion=Get-HdzCaptureDescription "$($state.Descripcion)" @($state.Caps)
    $selected=@($state.Caps | Where-Object {$_.Marcada -and $_.Subida} | ForEach-Object {$_.Subida} | Select-Object -Unique)
    foreach($url in $selected){if(-not $state.Descripcion.Contains((Get-CapturaBbcode $url))){throw 'No se pudo verificar la inserción de las capturas.'}}
    Save-HdzUploadTab $state
    Set-Estado "$($selected.Count) captura(s) añadida(s) a la descripción de «$($state.Titulo)»$(if($TabId -ne $script:subidaTabId){' (en su pestaña)'})." 'ok'
}
function Complete-HdzDescriptionImages([string]$TabId,$Urls) {
    $state=Get-HdzUploadTab $TabId
    $state.Descripcion=Add-HdzImageTags "$($state.Descripcion)" $Urls
    Save-HdzUploadTab $state
    Set-Estado "$(@($Urls).Count) imagen(es) añadida(s) a la descripción de «$($state.Titulo)»." 'ok'
}
function Insertar-CapturasSeleccionadas {
    $marcadas = @($script:capRows | Where-Object { $_.Check.IsChecked })
    if ($marcadas.Count -eq 0) { Set-Estado "Marca al menos una captura." "error"; return }
    # Solo subimos las que aún no tienen URL (cache de sesión); el resto ya está subido.
    $pend = @($marcadas | Where-Object { -not $_.Subida })
    $paths=@($pend | ForEach-Object {$_.Ruta})
    $ownerId=$script:subidaTabId
    $onDone = {
        param($urls)
        Complete-HdzCaptureInsertion $ownerId $paths @($urls)
    }.GetNewClosure()
    if ($pend.Count -eq 0) { & $onDone @() }
    else { Start-SubidaAsync $paths $onDone @($ui.btnCapInsertar) }
}
$ui.btnCapInsertar.Add_Click({try {Insertar-CapturasSeleccionadas} catch {Set-Estado $_.Exception.Message 'error'}})

# --- Toolbar BBCode de la descripción (iconos como en la web) ---
# Crea un botón-icono. $deco: bold|italic|underline|strike para las letras B/I/U/S;
# $glifo=$true usa la fuente de iconos Segoe MDL2 Assets.
function New-BbBtn($contenido, $tooltip, [scriptblock]$accion, $glifo = $false, $deco = "") {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $win.Resources["IconBtn"]
    $b.ToolTip = $tooltip
    $b.Margin = [System.Windows.Thickness]::new(0, 0, 4, 4)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $contenido
    if ($glifo) { $tb.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe MDL2 Assets"); $tb.FontSize = 15 }
    else { $tb.FontSize = 15.5; $tb.FontWeight = "SemiBold" }
    switch ($deco) {
        "bold"      { $tb.FontWeight = "Bold" }
        "italic"    { $tb.FontStyle = "Italic" }
        "underline" { $tb.TextDecorations = [System.Windows.TextDecorations]::Underline }
        "strike"    { $tb.TextDecorations = [System.Windows.TextDecorations]::Strikethrough }
    }
    $b.Content = $tb
    $b.Add_Click($accion)
    return $b
}
function Add-BbSep {
    $s = New-Object System.Windows.Controls.Border
    $s.Width = 1; $s.Height = 20; $s.Background = Brocha "#33333A"
    $s.Margin = [System.Windows.Thickness]::new(4, 0, 7, 4); $s.VerticalAlignment = "Center"
    [void]$ui.panBbToolbar.Children.Add($s)
}

# Inserta texto literal en el cursor (sin etiquetas), conservando la posición
function Insert-Texto($texto) {
    $tb = $ui.upDescripcion
    $s = $tb.SelectionStart; $l = $tb.SelectionLength
    if ($s -lt 0) { $s = $tb.Text.Length; $l = 0 }
    $tb.Text = $tb.Text.Remove($s, $l).Insert($s, $texto)
    $tb.SelectionStart = $s + $texto.Length
    $tb.SelectionLength = 0
    $tb.Focus()
}

# Crea el botón Emoji con un popup selector claro (rejilla de emojis por categorías)
function New-EmojiBtn {
    $btn = New-BbBtn ([char]0xE76E) "Emoji" { } $true

    $pop = New-Object System.Windows.Controls.Primitives.Popup
    $pop.PlacementTarget = $btn
    $pop.Placement = "Bottom"
    $pop.StaysOpen = $false
    $pop.AllowsTransparency = $true
    $pop.PopupAnimation = "Fade"

    $marco = New-Object System.Windows.Controls.Border
    $marco.Background = Brocha "#26262C"
    $marco.BorderBrush = Brocha "#3A3A42"
    $marco.BorderThickness = [System.Windows.Thickness]::new(1)
    $marco.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $marco.Padding = [System.Windows.Thickness]::new(8)
    $marco.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    $efx = New-Object System.Windows.Media.Effects.DropShadowEffect
    $efx.BlurRadius = 14; $efx.ShadowDepth = 3; $efx.Opacity = 0.5; $efx.Color = [System.Windows.Media.Colors]::Black
    $marco.Effect = $efx

    $cats = [ordered]@{
        "Caras"     = "😀 😃 😄 😁 😆 😅 😂 🤣 😊 🙂 😉 😍 🥰 😘 😎 🤩 🤔 🤨 😐 😴 😢 😭 😡 🤯 😱 🥳 🤗 🤫 🙄 😏"
        "Gestos"    = "👍 👎 👌 ✌️ 🤞 🤟 🤙 👏 🙌 🙏 💪 👀 🫡 🤝 ✋ 👋 ☝️ 👇 👉 👈"
        "Símbolos"  = "❤️ 🧡 💛 💚 💙 💜 🖤 ⭐ 🌟 ✨ 🔥 💯 ✅ ❌ ⚠️ ❓ ❗ 💩 🎉 🎬 🍿 📺 🎵 🏆 👑 💎 ⚡ 💥 🚀 🎯"
    }

    $stack = New-Object System.Windows.Controls.StackPanel
    foreach ($cat in $cats.Keys) {
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $cat
        $lbl.Foreground = Brocha "#9A9AA6"
        $lbl.FontSize = 10; $lbl.FontWeight = "SemiBold"
        $lbl.Margin = [System.Windows.Thickness]::new(2, 4, 0, 3)
        [void]$stack.Children.Add($lbl)

        $wrap = New-Object System.Windows.Controls.WrapPanel
        $wrap.Width = 300
        foreach ($e in ($cats[$cat] -split ' ')) {
            $emoji = $e
            $eb = New-Object System.Windows.Controls.Button
            $eb.Content = $emoji
            $eb.FontSize = 17
            $eb.Width = 30; $eb.Height = 30
            $eb.Margin = [System.Windows.Thickness]::new(1)
            $eb.Background = [System.Windows.Media.Brushes]::Transparent
            $eb.BorderThickness = [System.Windows.Thickness]::new(0)
            $eb.Cursor = "Hand"
            $eb.ToolTip = $emoji
            $eb.Add_Click({ Insert-Texto $emoji; $pop.IsOpen = $false }.GetNewClosure())
            [void]$wrap.Children.Add($eb)
        }
        [void]$stack.Children.Add($wrap)
    }

    $marco.Child = $stack
    $pop.Child = $marco
    $btn.Add_Click({ $pop.IsOpen = -not $pop.IsOpen }.GetNewClosure())
    return $btn
}
$tp = $ui.panBbToolbar
[void]$tp.Children.Add((New-BbBtn "B" "Negrita"        { Insert-Bb "[b]" "[/b]" } $false "bold"))
[void]$tp.Children.Add((New-BbBtn "I" "Cursiva"        { Insert-Bb "[i]" "[/i]" } $false "italic"))
[void]$tp.Children.Add((New-BbBtn "U" "Subrayado"      { Insert-Bb "[u]" "[/u]" } $false "underline"))
[void]$tp.Children.Add((New-BbBtn "S" "Tachado"        { Insert-Bb "[s]" "[/s]" } $false "strike"))
Add-BbSep
[void]$tp.Children.Add((New-BbBtn ([char]0xEB9F) "Imagen"   { Insert-Bb "[img=350]" "[/img]" } $true))
[void]$tp.Children.Add((New-BbBtn ([char]0xE714) "YouTube"  { Insert-Bb "[youtube]" "[/youtube]" } $true))
[void]$tp.Children.Add((New-BbBtn ([char]0xE71B) "Enlace"   { Insert-Bb "[url=]" "[/url]" } $true))
Add-BbSep
[void]$tp.Children.Add((New-BbBtn ([char]0xE8FD) "Lista"          { Insert-Bb "[list]`n[*]" "`n[/list]" } $true))
[void]$tp.Children.Add((New-BbBtn ([char]0xE292) "Lista numerada" { Insert-Bb "[list=1]`n[*]" "`n[/list]" } $true))
Add-BbSep
[void]$tp.Children.Add((New-BbBtn ([char]0xE790) "Color"          { Insert-Bb "[color=#ff0000]" "[/color]" } $true))
[void]$tp.Children.Add((New-BbBtn ([char]0xE8E9) "Tamaño de letra" { Insert-Bb "[size=24]" "[/size]" } $true))
[void]$tp.Children.Add((New-BbBtn ([char]0xE8D2) "Tipo de letra"  { Insert-Bb "[font=Arial]" "[/font]" } $true))
Add-BbSep
[void]$tp.Children.Add((New-BbBtn ([char]0xE8E4) "Alinear izquierda" { Insert-Bb "[left]" "[/left]" } $true))
[void]$tp.Children.Add((New-BbBtn ([char]0xE8E3) "Centrar"            { Insert-Bb "[center]" "[/center]" } $true))
[void]$tp.Children.Add((New-BbBtn ([char]0xE8E2) "Alinear derecha"    { Insert-Bb "[right]" "[/right]" } $true))
Add-BbSep
[void]$tp.Children.Add((New-BbBtn ([char]0xE134) "Cita"     { Insert-Bb "[quote]" "[/quote]" } $true))
[void]$tp.Children.Add((New-BbBtn ([char]0xE943) "Código"   { Insert-Bb "[code]" "[/code]" } $true))
[void]$tp.Children.Add((New-BbBtn ([char]0xED1A) "Spoiler"  { Insert-Bb "[spoiler]" "[/spoiler]" } $true))
[void]$tp.Children.Add((New-BbBtn ([char]0xE891) "Nota"     { Insert-Bb "[note]" "[/note]" } $true))
[void]$tp.Children.Add((New-BbBtn ([char]0xE7BA) "Alerta"   { Insert-Bb "[alert]" "[/alert]" } $true))
[void]$tp.Children.Add((New-BbBtn ([char]0xE80A) "Tabla"    { Insert-Bb "[table]`n[tr][td]" "[/td][/tr]`n[/table]" } $true))
[void]$tp.Children.Add((New-EmojiBtn))

$ui.btnDescSubir.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Imágenes (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png"
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $ownerId=$script:subidaTabId
    $onDone={
        param($urls)
        Complete-HdzDescriptionImages $ownerId @($urls)
    }.GetNewClosure()
    Start-SubidaAsync @($dlg.FileNames) $onDone @($ui.btnDescSubir)
})

# --- Vista previa de la descripción en WPF puro (FlowDocument): sin control nativo, así recorta y
#     hace scroll correctamente dentro de la tarjeta (el WebBrowser tenía bug de "airspace"). ---
function Build-PreviewDoc($bb) {
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
    $doc.FontSize = 14
    $doc.PagePadding = [System.Windows.Thickness]::new(12)
    $doc.Foreground = (Brocha "#E8E8EE")

    $align = "Left"; $bold = $false; $ital = $false; $under = $false; $strike = $false; $color = $null; $size = $null
    $nuevoPara = {
        $p = New-Object System.Windows.Documents.Paragraph
        $p.TextAlignment = $align
        $p.Margin = [System.Windows.Thickness]::new(0, 0, 0, 2)
        $p.LineHeight = 22
        [void]$doc.Blocks.Add($p)
        $p
    }
    $para = & $nuevoPara
    $addRun = {
        param($t)
        $r = New-Object System.Windows.Documents.Run($t)
        if ($bold) { $r.FontWeight = "Bold" }
        if ($ital) { $r.FontStyle = "Italic" }
        if ($under -or $strike) {
            $tc = New-Object System.Windows.TextDecorationCollection
            if ($under)  { foreach ($d in [System.Windows.TextDecorations]::Underline)     { [void]$tc.Add($d) } }
            if ($strike) { foreach ($d in [System.Windows.TextDecorations]::Strikethrough) { [void]$tc.Add($d) } }
            $r.TextDecorations = $tc
        }
        if ($color) { try { $r.Foreground = (Brocha $color) } catch {} }
        if ($size)  { try { $r.FontSize = [double]$size } catch {} }
        $para.Inlines.Add($r)
    }
    $addImg = {
        param($url, $w)
        try {
            $img = New-Object System.Windows.Controls.Image
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.UriSource = [Uri]$url
            if ($w -gt 0) { $bmp.DecodePixelWidth = [int]$w }
            # OnLoad = decodifica de golpe, así la relacion de aspecto ya se conoce al medir
            # el InlineUIContainer (si no, el logo sale ancho y aplastado en la vista previa).
            # Las imagenes ya se mostraron antes como miniaturas -> estan en cache, no bloquea.
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.EndInit()
            $img.Source = $bmp; $img.Stretch = "Uniform"
            # MaxWidth (no Width fijo): con Stretch=Uniform mantiene el aspecto y ademas encaja
            # dentro del ancho del panel de vista previa aunque el [img=700] sea mas ancho.
            if ($w -gt 0) { $img.MaxWidth = [double]$w } else { $img.MaxWidth = 760 }
            $img.Margin = [System.Windows.Thickness]::new(2)
            $para.Inlines.Add((New-Object System.Windows.Documents.InlineUIContainer($img)))
        } catch {}
    }

    $imgMode = $false; $imgW = 0
    $rx = [regex]'(?s)(\[/?[a-zA-Z*][^\]]*\])|([^\[]+)'
    foreach ($m in $rx.Matches("$bb")) {
        if ($m.Groups[1].Success) {
            $tl = $m.Groups[1].Value.ToLower()
            switch -regex ($tl) {
                '^\[img(=\d+)?\]$' { $imgMode = $true; $imgW = $(if ($tl -match '=(\d+)') { [int]$Matches[1] } else { 0 }) }
                '^\[/img\]$'       { $imgMode = $false }
                '^\[b\]$'          { $bold = $true }
                '^\[/b\]$'         { $bold = $false }
                '^\[i\]$'          { $ital = $true }
                '^\[/i\]$'         { $ital = $false }
                '^\[u\]$'          { $under = $true }
                '^\[/u\]$'         { $under = $false }
                '^\[s\]$'          { $strike = $true }
                '^\[/s\]$'         { $strike = $false }
                '^\[color=.+\]$'   { $color = ($tl -replace '^\[color=(.+)\]$', '$1') }
                '^\[/color\]$'     { $color = $null }
                '^\[size=\d+\]$'   { $size = ($tl -replace '\D', '') }
                '^\[/size\]$'      { $size = $null }
                '^\[center\]$'     { $align = "Center"; $para = & $nuevoPara }
                '^\[/center\]$'    { $align = "Left";   $para = & $nuevoPara }
                '^\[right\]$'      { $align = "Right";  $para = & $nuevoPara }
                '^\[/right\]$'     { $align = "Left";   $para = & $nuevoPara }
                '^\[left\]$'       { $align = "Left";   $para = & $nuevoPara }
                '^\[/left\]$'      { $align = "Left";   $para = & $nuevoPara }
                '^\[\*\]$'         { $para.Inlines.Add((New-Object System.Windows.Documents.LineBreak)); & $addRun "• " }
                default            { }   # cualquier otra etiqueta: se ignora (se ve el texto interior)
            }
        } else {
            $txt = $m.Groups[2].Value
            if ($imgMode) {
                $u = $txt.Trim(); if ($u) { & $addImg $u $imgW }
            } else {
                $partes = $txt -replace "`r", "" -split "`n", -1
                for ($i = 0; $i -lt $partes.Count; $i++) {
                    if ($i -gt 0) { $para.Inlines.Add((New-Object System.Windows.Documents.LineBreak)) }
                    if ($partes[$i] -ne "") { & $addRun $partes[$i] }
                }
            }
        }
    }
    return $doc
}
# Alterna el campo de descripción entre edición (TextBox) y vista previa (FlowDocument WPF),
# en el mismo sitio, como las pestañas del tracker.
function Mostrar-ModoDescripcion($preview) {
    if ($preview) {
        try { $ui.fdPreview.Document = Build-PreviewDoc $ui.upDescripcion.Text } catch {}
        $ui.panEdicionTools.Visibility = "Collapsed"
        $ui.upDescripcion.Visibility = "Collapsed"
        $ui.panPreview.Visibility = "Visible"
    } else {
        $ui.panPreview.Visibility = "Collapsed"
        $ui.upDescripcion.Visibility = "Visible"
        $ui.panEdicionTools.Visibility = "Visible"
    }
}
$ui.tabEscribir.Add_Checked({ Mostrar-ModoDescripcion $false })
$ui.tabPrevia.Add_Checked({ Mostrar-ModoDescripcion $true })

$ui.btnBuscarTmdb.Add_Click({
    $ui.panResultadosTmdb.Children.Clear()
    $script:tmdbSearchResults = @()
    $ta = Get-TituloAnioLimpio $ui.upTitulo.Text
    try {
        $res = Search-Tmdb $ta.Titulo $ta.Anio $script:tmdbTipo
        $script:tmdbSearchResults = @($res)
        if (-not $res -or @($res).Count -eq 0) {
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = "Sin resultados para «$($ta.Titulo)»$(if ($ta.Anio) { " ($($ta.Anio))" }). Prueba a ajustar el título."
            $t.Foreground = $win.Resources["WarnBrush"]; $t.FontSize = 12; $t.TextWrapping = "Wrap"
            [void]$ui.panResultadosTmdb.Children.Add($t)
            return
        }
        foreach ($item in $res) {
            $b = New-Object System.Windows.Controls.Button
            $b.Style = $win.Resources["GhostMini"]
            $b.HorizontalAlignment = "Left"
            $b.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
            $marcaGenero = if (@($item.Generos) -contains 99) { "  · 🎥 documental" } elseif (@($item.Generos) -contains 16) { "  · 🎨 animación" } else { "" }
            $b.Content = "$($item.Titulo)  ·  $($item.Fecha)  ·  TMDB $($item.Id)$marcaGenero"
            $itemCap = $item
            $b.Add_Click({
                Set-Estado "Aplicando TMDB $($itemCap.Id) (IDs, keywords, logos)…"
                Aplicar-ResultadoTmdb $itemCap
                Set-Estado "Datos rellenados desde TMDB: $($itemCap.Titulo)."
            }.GetNewClosure())
            [void]$ui.panResultadosTmdb.Children.Add($b)
        }
    } catch {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = "Error en la búsqueda TMDB: $($_.Exception.Message)"
        $t.Foreground = $win.Resources["ErrBrush"]; $t.FontSize = 12; $t.TextWrapping = "Wrap"
        [void]$ui.panResultadosTmdb.Children.Add($t)
    }
})

# El estado de la subida se muestra en la barra inferior (junto al botón «Subir a HDZERO»).
function Set-SubidaEstado($texto, $tipo = "info") {
    $ui.lblEstado.Text = $texto
    $ui.lblEstado.Foreground = switch ($tipo) {
        "ok" { $win.Resources["OkBrush"] } "error" { $win.Resources["ErrBrush"] }
        "warn" { $win.Resources["WarnBrush"] } default { $win.Resources["SubBrush"] }
    }
}

# Construye la subida completa: sube capturas seleccionadas, monta el BBCode y hace el POST a la API.
function Invoke-SubidaTracker {
    # --- Validaciones ---
    $rutaTorrent = "$($ui.txtTorrentSubir.Text)"
    if ([string]::IsNullOrWhiteSpace($rutaTorrent) -or -not (Test-Path -LiteralPath $rutaTorrent)) {
        Set-SubidaEstado "Elige primero un archivo .torrent." "error"; return
    }
    $token = "$($ui.cfgTrackerToken.Text)".Trim()
    $baseUrl = "$($ui.cfgTrackerUrl.Text)".Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($baseUrl)) {
        Set-SubidaEstado "Falta la URL del tracker o el token de API (pestaña Ajustes / claves)." "error"; return
    }
    if ([string]::IsNullOrWhiteSpace($ui.upTitulo.Text)) { Set-SubidaEstado "El título no puede estar vacío." "error"; return }
    if ([string]::IsNullOrWhiteSpace($ui.upMediainfo.Text)) { Set-SubidaEstado "El MediaInfo está vacío." "error"; return }
    # Última barrera: si se escribió un TMDB manual y todavía no se validó (por ejemplo, desde
    # el móvil justo antes de pulsar Subir), no permitimos enviar una categoría de la ficha antigua.
    $tmdbActual = "$($ui.upTmdb.Text)".Trim()
    if ($tmdbActual -and -not [string]::IsNullOrWhiteSpace($ui.cfgTmdbKey.Text)) {
        if (-not (Invoke-AplicarTmdbManual $tmdbActual)) {
            Set-SubidaEstado "No se puede subir: revisa el ID de TMDB y su categoría." "error"
            return
        }
    }
    $catId = Get-ComboValor $ui.upCategoria
    $tipoId = Get-ComboValor $ui.upTipo
    $resId = Get-ComboValor $ui.upResolucion
    if (-not $catId -or -not $tipoId -or -not $resId) { Set-SubidaEstado "Elige categoría, tipo y resolución." "error"; return }
    $esTv = ($script:tmdbTipo -eq "tv")
    if ($esTv -and ([string]::IsNullOrWhiteSpace($ui.upTemporada.Text) -or [string]::IsNullOrWhiteSpace($ui.upEpisodio.Text))) {
        Set-SubidaEstado "Para series, indica número de temporada y episodio (0 = pack)." "error"; $ui.navSubida.IsChecked = $true; return
    }

    $ui.btnSubir.IsEnabled = $false
    try {
        # --- 1. Capturas marcadas que aún NO estén en la descripción: subir e insertar.
        #        (Si ya las insertaste con «Subir y añadir», no se duplican.) ---
        $marcadas = @($script:capRows | Where-Object { $_.Check.IsChecked })
        $pendientes=@($marcadas | Where-Object {-not $_.Subida})
        if($pendientes.Count){
            Set-SubidaEstado "Subiendo $($pendientes.Count) captura(s) con respaldo automático…"
            try {
                $subidas=Send-Imagenes @($pendientes | ForEach-Object {$_.Ruta})
                foreach($item in $subidas.Items){
                    if($item.Full){foreach($r in $pendientes){if($r.Ruta -eq $item.Ruta){$r.Subida=$item.Full}}}
                }
                Rehacer-CapturasDescripcion
                if($subidas.Error){throw $subidas.Error}
            } catch {
                Set-SubidaEstado "Error subiendo capturas: $($_.Exception.Message)" 'error'
                $ui.btnSubir.IsEnabled=$true;return
            }
        }
        # La descripción se rehace para reflejar EXACTAMENTE las capturas marcadas: las que hayas
        # desmarcado (aunque ya estuvieran subidas) NO se incluyen; las marcadas, sí.
        Rehacer-CapturasDescripcion

        # --- 2. Descripción: siempre centrada ---
        # No recortar: los saltos de línea que el usuario escribió son parte del BBCode.
        # El parser del tracker transforma los EOL normales a <br> al renderizar.
        $desc = "$($ui.upDescripcion.Text)"
        if ([string]::IsNullOrWhiteSpace($desc)) { $desc = $script:descVacia }
        if ($desc -notmatch '(?i)\[center\]') { $desc = "[center]`n$desc`n[/center]" }

        # --- 2b. Firma elegida: subir y añadir antes del último [/center] ---
        if ($script:firmaSel -and (Test-Path -LiteralPath $script:firmaSel)) {
            Set-SubidaEstado "Subiendo firma…"
            try {
                if (-not $script:firmaCacheUrl[$script:firmaSel]) { $script:firmaCacheUrl[$script:firmaSel] = Send-Imagen $script:firmaSel }
                $urlFirma = $script:firmaCacheUrl[$script:firmaSel]
                if ($urlFirma -and "$desc" -notlike "*$urlFirma*") {
                    $tagFirma = "[img=350]$urlFirma" + "[/img]"
                    $idx = $desc.LastIndexOf("[/center]")
                    if ($idx -ge 0) {
                        $antesFirma = $desc.Substring(0, $idx)
                        if ($antesFirma -notmatch "(?:\r?\n)$") { $antesFirma += "`n" }
                        $desc = $antesFirma + $tagFirma + "`n" + $desc.Substring($idx)
                    } else {
                        $antesFirma = $desc
                        if ($antesFirma -and $antesFirma -notmatch "(?:\r?\n)$") { $antesFirma += "`n" }
                        $desc = $antesFirma + $tagFirma
                    }
                }
            } catch {
                Set-SubidaEstado "No se pudo subir la firma: $($_.Exception.Message)" "error"; $ui.btnSubir.IsEnabled = $true; return
            }
        }

        # --- 3. Construir el multipart de la API ---
        Set-SubidaEstado "Enviando a HDZERO…"
        # PowerShell 7.6 codifica los nombres de fichero NO-ASCII como «encoded-word» RFC 2047
        # (filename="=?utf-8?B?...?=") en el multipart. PHP no lo decodifica, ve un nombre que NO
        # acaba en «.torrent» y el tracker responde «You Must Provide A Valid Torrent File». Para
        # evitarlo subimos una COPIA con nombre ASCII (el tracker usa el 'info.name' interno, no el
        # nombre del fichero subido, así que no cambia nada del resultado). [Antes fallaban solo los
        # títulos con acentos, p.ej. «El Gato con Botas El Último Deseo».]
        $torrentUpload = $rutaTorrent
        $torrentTmpAscii = $null
        if ($rutaTorrent -match '[^ -]') {
            try {
                $torrentTmpAscii = Join-Path $env:TEMP ("hdz_upload_" + [guid]::NewGuid().ToString('N') + ".torrent")
                Copy-Item -LiteralPath $rutaTorrent -Destination $torrentTmpAscii -Force
                $torrentUpload = $torrentTmpAscii
            } catch { $torrentUpload = $rutaTorrent }
        }
        $imdbVal = ("$($ui.upImdb.Text)" -replace "(?i)tt", "").Trim()
        $form = [ordered]@{
            name             = "$($ui.upTitulo.Text)".Trim()
            description      = $desc
            mediainfo        = "$($ui.upMediainfo.Text)"
            category_id      = "$catId"
            type_id          = "$tipoId"
            resolution_id    = "$resId"
            tmdb             = $(if ("$($ui.upTmdb.Text)".Trim()) { "$($ui.upTmdb.Text)".Trim() } else { "0" })
            imdb             = $(if ($imdbVal) { $imdbVal } else { "0" })
            tvdb             = $(if ("$($ui.upTvdb.Text)".Trim()) { "$($ui.upTvdb.Text)".Trim() } else { "0" })
            mal              = $(if ("$($ui.upMal.Text)".Trim()) { "$($ui.upMal.Text)".Trim() } else { "0" })
            keywords         = "$($ui.upKeywords.Text)".Trim()
            anonymous        = $(if ($ui.upAnon.IsChecked) { "1" } else { "0" })
            personal_release = $(if ($ui.upPersonal.IsChecked) { "1" } else { "0" })
            mod_queue_opt_in = $(if ($ui.upModQueue.IsChecked) { "1" } else { "0" })
            # Campos personalizados de HDZERO (se ignoran si la API no los lee)
            audio_editado    = $(if ($ui.upAudioEd.IsChecked) { "1" } else { "0" })
            dolby_vision     = $(if ($ui.upDV.IsChecked) { "1" } else { "0" })
            hdr10plus        = $(if ($ui.upHDR10P.IsChecked) { "1" } else { "0" })
            hdr              = $(if ($ui.upHDR10.IsChecked) { "1" } else { "0" })
            is_proper        = $(if ($ui.upProper.IsChecked) { "1" } else { "0" })
            torrent          = Get-Item -LiteralPath $torrentUpload
        }
        # SALVAGUARDA anti-cruce: el 'name' debe corresponder al .torrent que se sube. Si el título del
        # panel es de OTRA película (p.ej. por reutilizar/mezclar pestañas de subida), el tracker lo
        # rechazaría como duplicado o subiría con nombre equivocado. Comparamos con el nombre INTERNO
        # del torrent (su release real): si la película/año no coinciden, usamos el nombre del torrent.
        Log-DiagSubida "SUBIR pulsado | name-enviado='$($form.name)' | torrent-subido='$(Split-Path $rutaTorrent -Leaf)' | $(Ctx-SubidaActiva)"
        try {
            $nombreTorrentInterno = Get-NombreTorrent $rutaTorrent
            if ($nombreTorrentInterno) {
                $nameTorrent = Quitar-ExtConocida $nombreTorrentInterno
                $bA = Get-TituloAnioLimpio "$($form.name)"
                $bT = Get-TituloAnioLimpio $nameTorrent
                $claveA = ("$($bA.Titulo) $($bA.Anio)").Trim().ToLower()
                $claveT = ("$($bT.Titulo) $($bT.Anio)").Trim().ToLower()
                if ($claveA -ne $claveT -and $nameTorrent.Trim()) {
                    Set-SubidaEstado "⚠  El título no coincidía con el torrent; se corrige a «$nameTorrent»." "warn"
                    try { Log-Linea "AVISO anti-cruce: name del panel='$($form.name)' NO corresponde al torrent; se usa el nombre real del torrent='$nameTorrent'." } catch {}
                    Log-DiagSubida "ANTI-CRUCE DISPARADO: name del panel='$($form.name)' (clave '$claveA') NO coincide con el torrent='$nameTorrent' (clave '$claveT'). Corregido al del torrent."
                    $form.name = $nameTorrent
                    $ui.upTitulo.Text = $nameTorrent
                }
            }
        } catch {}
        if ($esTv) {
            $form.season_number = "$($ui.upTemporada.Text)".Trim()
            $form.episode_number = "$($ui.upEpisodio.Text)".Trim()
        }
        $nfoTmpAscii = $null
        if (-not [string]::IsNullOrWhiteSpace($ui.upNfo.Text) -and (Test-Path -LiteralPath $ui.upNfo.Text)) {
            $nfoRuta = "$($ui.upNfo.Text)"
            if ($nfoRuta -match '[^ -]') {
                try { $nfoTmpAscii = Join-Path $env:TEMP ("hdz_upload_" + [guid]::NewGuid().ToString('N') + ".nfo"); Copy-Item -LiteralPath $nfoRuta -Destination $nfoTmpAscii -Force; $nfoRuta = $nfoTmpAscii } catch {}
            }
            $form.nfo = Get-Item -LiteralPath $nfoRuta
        }

        # LOG de proyecto: punto SUBIDA AL TRACKER (campos enviados, sin binarios ni secretos).
        try {
            if ($script:videoSubir) { Iniciar-LogProyecto (Split-Path $script:videoSubir -Parent) }
            elseif ($rutaTorrent) { Iniciar-LogProyecto (Split-Path $rutaTorrent -Parent) }
            Log-Sec "SUBIDA AL TRACKER · petición"
            Log-Linea "Destino: $baseUrl/api/torrents/upload"
            Log-Linea "Torrent: $(Split-Path $rutaTorrent -Leaf)"
            $camposLog = foreach ($k in $form.Keys) { if ($k -notin @('torrent', 'nfo')) { "$k = $($form[$k])" } }
            Log-Bloque "Campos enviados" ($camposLog -join "`r`n")
        } catch {}

        $uri = "$baseUrl/api/torrents/upload?api_token=$token"
        $resp = Invoke-HdzRestMethod -Uri $uri -Method Post -Form $form -Headers @{ "Accept" = "application/json" } -TimeoutSec 300

        $msg = "$($resp.message)$($resp.data)"
        try { Log-Sec "SUBIDA AL TRACKER · respuesta"; Log-Linea "success=$($resp.success) | message=$($resp.message) | data=$($resp.data)" } catch {}
        if ("$($resp.success)" -ieq 'true') {
            Set-SubidaEstado "✓  Subido correctamente. $($resp.message)" "ok"
            # El resultado anterior de esta pestaña deja de ser el vigente desde que el tracker
            # acepta una nueva subida. Se rellenan de nuevo al descargar/publicar el torrent actual.
            $script:rutaTorrentTracker = ""
            $script:torrentRemotoId = 0
            $script:torrentRemotoNombre = ""
            if ($ui.btnAbrirTorrent) { $ui.btnAbrirTorrent.Visibility = "Collapsed" }
            # Página web del torrent: la URL de descarga ($resp.data) es del tipo
            # https://host/torrent/download/<id>.<rsskey>; la página es https://host/torrents/<id>.
            $script:urlTorrentWeb = ""
            if ("$($resp.data)" -match "^(https?://[^/]+)/torrent/download/(\d+)") {
                $script:urlTorrentWeb = "$($Matches[1])/torrents/$($Matches[2])"
                $ui.btnVerWeb.Visibility = "Visible"
                try { Log-Linea "Página del torrent: $($script:urlTorrentWeb)" } catch {}
            }
            # El torrent que hay que poner a SEMBRAR es el que DEVUELVE el tracker (con tu passkey),
            # no el que subiste. La URL de descarga viene en $resp.data: lo bajamos, lo dejamos
            # disponible en la web remota y mostramos acciones NO modales en el PC.
            $urlDesc = "$($resp.data)".Trim()
            if ($urlDesc -match "^https?://") {
                Set-SubidaEstado "Descargando el .torrent del tracker (el que debes sembrar)…"
                # Destino: la carpeta por defecto de .torrent (Ajustes) si está puesta; si no, junto al
                # .torrent subido; y como último recurso, Documentos.
                $carpTorDef = "$($ui.cfgCarpetaTorrent.Text)".Trim()
                $dirDest  = if ($carpTorDef) { $carpTorDef } elseif ($rutaTorrent) { Split-Path $rutaTorrent -Parent } else { [Environment]::GetFolderPath('MyDocuments') }
                # Nombre de reserva por si el servidor no manda Content-Disposition (raro).
                $baseDest = if ($rutaTorrent) { [System.IO.Path]::GetFileNameWithoutExtension($rutaTorrent) } else { "$($ui.upTitulo.Text)".Trim() }
                foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) { $baseDest = $baseDest.Replace("$ch", "") }
                if ([string]::IsNullOrWhiteSpace($baseDest)) { $baseDest = "torrent" }
                $bajado = Descargar-TorrentTracker $urlDesc $token $dirDest $baseDest
                try { Log-Linea "Torrent del tracker para sembrar: $(if ($bajado) { $bajado } else { 'NO se pudo descargar' })" } catch {}
                if ($bajado) {
                    $script:rutaTorrentTracker = "$bajado"
                    if ($ui.btnAbrirTorrent) { $ui.btnAbrirTorrent.Visibility = "Visible" }
                    $pubRemota = Publicar-TorrentAgente $bajado
                    try { [void](Add-HdzHistory @{kind='tracker';status='Subido; seed no comprobado';video="$($script:videoSubir)";torrent="$bajado";torrentId=$(if($pubRemota){"$($pubRemota.id)"}else{''});captures=@($script:capRows | ForEach-Object { $_.Ruta })}) } catch { Log-Linea "No se pudo guardar el historial: $($_.Exception.Message)" }
                    if ($pubRemota) {
                        $script:torrentRemotoId = [string]$pubRemota.id
                        $script:torrentRemotoNombre = "$($pubRemota.name)"
                        Set-SubidaEstado "✓  Subido. Torrent para sembrar disponible en el PC y en la web remota: $(Split-Path $bajado -Leaf)" "ok"
                    } else {
                        Set-SubidaEstado "✓  Subido. Torrent para sembrar guardado en el PC: $(Split-Path $bajado -Leaf). No se pudo enviar a la web remota." "warn"
                    }
                    if ($script:agSync) { $script:agSync.PushNow = $true }
                } else {
                    Set-SubidaEstado "✓  Subido, pero no pude descargar el .torrent del tracker. Descárgalo a mano desde la web del torrent." "warn"
                }
            }
        } else {
            Set-SubidaEstado "Respuesta del tracker: $msg" "warn"
        }
    } catch {
        $detalle = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detalle = $_.ErrorDetails.Message }
        Set-SubidaEstado "Error en la subida: $detalle" "error"
        try { Log-Sec "SUBIDA AL TRACKER · error"; Log-Linea "$detalle" } catch {}
    } finally {
        $ui.btnSubir.IsEnabled = $true
        # Copias temporales de nombre ASCII usadas para el multipart (ver arriba): a la papelera.
        if ($torrentTmpAscii) { Remove-Item -LiteralPath $torrentTmpAscii -Force -ErrorAction SilentlyContinue }
        if ($nfoTmpAscii)     { Remove-Item -LiteralPath $nfoTmpAscii -Force -ErrorAction SilentlyContinue }
    }
}

# Descarga el .torrent que devuelve el tracker (el que se siembra, con tu passkey) EXACTAMENTE como
# lo haría el navegador: guarda con el nombre que envía el servidor (cabecera Content-Disposition),
# así coincide con el que bajarías a mano desde la web. El enlace de UNIT3D ya lleva la rsskey en la
# ruta; si aun así fallara, se reintenta con el api_token. Valida que sea un .torrent real (bencode).
# $dirDest = carpeta destino; $nombreFallback = nombre si el servidor no manda Content-Disposition.
function Descargar-TorrentTracker($url, $token, $dirDest, $nombreFallback) {
    $url = "$url".Trim()
    if ($url -notmatch "^https?://") { return $null }
    try { [void][System.IO.Directory]::CreateDirectory($dirDest) } catch {}
    $intentos = @($url)
    if ($token) { $intentos += ($url + $(if ($url -match '\?') { '&' } else { '?' }) + "api_token=$token") }
    foreach ($u in $intentos) {
        try {
            $resp = Invoke-HdzWebRequest -Uri $u -TimeoutSec 120 -ErrorAction Stop
            # Bytes del .torrent (binario).
            $bytes = if ($resp.RawContentStream) { $resp.RawContentStream.ToArray() } elseif ($resp.Content -is [byte[]]) { $resp.Content } else { $null }
            if (-not $bytes -or $bytes.Length -lt 1) { continue }
            if ($bytes[0] -ne [byte][char]'d') { continue }   # no es bencode válido
            # Nombre del fichero tal cual lo nombra el servidor (igual que el navegador).
            $cdVal = "$($resp.Headers['Content-Disposition'])"
            $nombre = $null
            if ($cdVal) {
                if ($cdVal -match "filename\*\s*=\s*[^']*''([^;]+)") { $nombre = [Uri]::UnescapeDataString($Matches[1].Trim().Trim('"')) }
                elseif ($cdVal -match 'filename\s*=\s*"([^"]+)"') { $nombre = $Matches[1] }
                elseif ($cdVal -match 'filename\s*=\s*([^;]+)')   { $nombre = $Matches[1].Trim().Trim('"') }
            }
            if ([string]::IsNullOrWhiteSpace($nombre)) { $nombre = "$nombreFallback" }
            if ([string]::IsNullOrWhiteSpace($nombre)) { $nombre = "torrent" }
            if ($nombre -notmatch "(?i)\.torrent$") { $nombre = "$nombre.torrent" }
            foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) { $nombre = $nombre.Replace("$ch", "") }
            $destino = Join-Path $dirDest $nombre
            $bse = [System.IO.Path]::GetFileNameWithoutExtension($nombre); $ext = [System.IO.Path]::GetExtension($nombre); $k = 1
            while (Test-Path -LiteralPath $destino) { $destino = Join-Path $dirDest "$bse ($k)$ext"; $k++ }
            [System.IO.File]::WriteAllBytes($destino, $bytes)
            return $destino
        } catch {}
    }
    return $null
}

# Envía al relay el fichero YA descargado desde el tracker. Nunca se envía al navegador la URL
# original (contiene la rsskey/passkey); el panel recibe únicamente un id opaco y el nombre.
function Publicar-TorrentAgente($ruta) {
    if (-not $ruta -or -not (Test-Path -LiteralPath $ruta)) { return $null }
    $baseAgente = "$script:agentUrl".Trim()
    if ($baseAgente -notmatch '(?i)/agent/sync/?(?:\?.*)?$') { return $null }
    $endpoint = [regex]::Replace($baseAgente, '(?i)/agent/sync/?(?:\?.*)?$', '/agent/torrent')
    try {
        $form = @{ torrent = Get-Item -LiteralPath $ruta }
        $r = Invoke-HdzRestMethod -Uri $endpoint -Method Post -Form $form `
            -Headers @{ "X-HDZ-Key" = "$script:soporteKey"; "Accept" = "application/json" } -TimeoutSec 30
        if ("$($r.ok)" -eq "True" -and "$($r.id)" -match '^[0-9a-f]{64}$') {
            try { Log-Linea "Torrent publicado para descarga remota: id=$($r.id), nombre=$($r.name)" } catch {}
            return $r
        }
    } catch {
        try { Log-Linea "No se pudo publicar el torrent en la web remota: $(Redacta-Log $_.Exception.Message)" } catch {}
    }
    return $null
}

$ui.btnVerWeb.Add_Click({ if ($script:urlTorrentWeb) { try { Start-Process $script:urlTorrentWeb } catch { Set-SubidaEstado "No se pudo abrir el navegador: $($_.Exception.Message)" "warn" } } })
$ui.btnAbrirTorrent.Add_Click({
    if ($script:rutaTorrentTracker -and (Test-Path -LiteralPath $script:rutaTorrentTracker)) {
        try { Start-Process -FilePath $script:rutaTorrentTracker }
        catch { Set-SubidaEstado "No pude abrir el torrent: $($_.Exception.Message)" "warn" }
    }
})

$ui.btnSubir.Add_Click({ Invoke-SubidaTracker })
if ($ui.btnEnviarLog) { $ui.btnEnviarLog.Add_Click({ Enviar-LogSoporte }) }

# =========================================================================
# PERSISTENCIA DE AJUSTES
# =========================================================================
function ChipPersist($nombre) { $v = Get-ChipValor $nombre; if ($null -eq $v) { "ASK" } else { "$v" } }
function ComboPersist($cmb)   { $v = Get-ComboValor $cmb;   if ($null -eq $v) { "ASK" } else { "$v" } }

function Guardar-Ajustes {
    # Defensa 1: en modo test (renders headless) NUNCA tocamos los ajustes del usuario.
    if ($script:modoTest) { return }
    try {
        # Defensa 2: leemos lo ya guardado para NO pisar credenciales con campos vacíos.
        # Si un campo sensible está vacío pero antes tenía valor, conservamos el anterior
        # (un arranque que no recargó bien las claves no podrá borrarlas al cerrar).
        $prev = $null
        if (Test-Path -LiteralPath $rutaAjustes) {
            try { $prev = Get-Content -LiteralPath $rutaAjustes -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        }
        $keep = {
            param($uiVal, $prevName)
            $u = "$uiVal"
            if (-not [string]::IsNullOrWhiteSpace($u)) { return $u }
            if ($prev -and -not [string]::IsNullOrWhiteSpace("$($prev.$prevName)")) { return "$($prev.$prevName)" }
            return $u
        }
        # Solo se PERSISTE la configuración de la pestaña «Ajustes / claves» (credenciales, host de
        # imágenes, firma) más el marcador interno de versión descartada. Los datos del PROYECTO
        # (carpeta, título, año, opciones de procesado, carpetas de salida…) NO se guardan: al
        # reabrir el programa todo arranca en blanco, sin memoria del proyecto anterior.
        $aj = [ordered]@{
            Version        = 2
            TrackerUrl     = & $keep $ui.cfgTrackerUrl.Text   "TrackerUrl"
            TrackerToken   = & $keep $ui.cfgTrackerToken.Text "TrackerToken"
            HostImg        = ChipPersist "hostImg"
            ImgbbKey       = & $keep $ui.cfgImgbbKey.Text "ImgbbKey"
            ImgboxUser     = & $keep $ui.cfgImgboxUser.Text "ImgboxUser"
            ImgboxPass     = $(
                                $pw = "$($ui.cfgImgboxPass.Password)"
                                if ($pw.Length -gt 0) { Protect-Texto $pw }
                                elseif ($prev -and "$($prev.ImgboxPass)".Length -gt 0) { "$($prev.ImgboxPass)" }
                                else { "" }
                              )
            TmdbKey        = & $keep $ui.cfgTmdbKey.Text  "TmdbKey"
            UsuarioSoporte = "$($ui.cfgUsuarioSoporte.Text)".Trim()
            CarpetaProcesados = "$($ui.cfgCarpetaProcesados.Text)".Trim()
            CarpetaTorrent = "$($ui.cfgCarpetaTorrent.Text)".Trim()
            Firma          = $(if ($script:firmaSel) { Split-Path $script:firmaSel -Leaf } else { "" })
            Announce       = & $keep $ui.txtAnnounce.Text "Announce"
            UltimaVersionDescartada = $script:ajusteVerDescartada
            BienvenidaVista = [bool]$script:bienvenidaVista
        }
        # Defensa 3: escritura ATÓMICA con respaldo. Escribimos a un temporal, guardamos el
        # fichero actual como .bak (red de recuperación) y luego reemplazamos. Si algo falla a
        # mitad, el .json queda intacto y siempre hay un .bak con el estado anterior.
        $tmp = "$rutaAjustes.tmp"
        $aj | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $tmp -Encoding UTF8
        if (Test-Path -LiteralPath $rutaAjustes) { Copy-Item -LiteralPath $rutaAjustes -Destination "$rutaAjustes.bak" -Force }
        Move-Item -LiteralPath $tmp -Destination $rutaAjustes -Force
    } catch {}
}

function Restaurar-Ajustes {
    if (-not (Test-Path -LiteralPath $rutaAjustes)) { return }
    try {
        $aj = Get-Content -LiteralPath $rutaAjustes -Raw -Encoding UTF8 | ConvertFrom-Json
        if ("$($aj.Version)" -ne "2") { return }
        if ($aj.UltimaVersionDescartada) { $script:ajusteVerDescartada = "$($aj.UltimaVersionDescartada)" }
        if ($null -ne $aj.BienvenidaVista) { $script:bienvenidaVista = [bool]$aj.BienvenidaVista }
        # Recuperación: si una clave sensible está vacía en el fichero principal pero el respaldo
        # .bak (versión anterior) sí la tiene, la rescatamos de ahí. Así un borrado accidental se
        # auto-repara en el siguiente arranque en vez de quedarse perdido.
        $bak = $null
        if (Test-Path -LiteralPath "$rutaAjustes.bak") {
            try { $bak = Get-Content -LiteralPath "$rutaAjustes.bak" -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        }
        $rescatar = {
            param($name)
            $v = "$($aj.$name)"
            if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
            if ($bak -and "$($bak.Version)" -eq "2" -and -not [string]::IsNullOrWhiteSpace("$($bak.$name)")) { return "$($bak.$name)" }
            return $v
        }
        $chip = { param($n, $v) if ("$v" -eq "ASK") { Set-ChipValor $n $null } elseif ($null -ne $v) { Set-ChipValor $n $v } }
        # Solo se RESTAURA la configuración de «Ajustes / claves» (credenciales, host de imágenes,
        # firma). Los datos del PROYECTO no se restauran: cada apertura empieza en blanco.
        $vTrackerUrl   = & $rescatar "TrackerUrl";   if ($vTrackerUrl)   { $ui.cfgTrackerUrl.Text   = $vTrackerUrl }
        $vTrackerToken = & $rescatar "TrackerToken"; if ($vTrackerToken) { $ui.cfgTrackerToken.Text = $vTrackerToken }
        $vImgbbKey     = & $rescatar "ImgbbKey";     if ($vImgbbKey)     { $ui.cfgImgbbKey.Text     = $vImgbbKey }
        $vImgboxUser   = & $rescatar "ImgboxUser";   if ($vImgboxUser)   { $ui.cfgImgboxUser.Text   = $vImgboxUser }
        $vImgboxPass   = & $rescatar "ImgboxPass";   if ($vImgboxPass -and $ui.cfgImgboxPass) { $ui.cfgImgboxPass.Password = (Unprotect-Texto $vImgboxPass) }
        $vTmdbKey      = & $rescatar "TmdbKey";      if ($vTmdbKey)      { $ui.cfgTmdbKey.Text      = $vTmdbKey }
        if ($aj.UsuarioSoporte) { $ui.cfgUsuarioSoporte.Text = "$($aj.UsuarioSoporte)" }
        if ($aj.CarpetaProcesados) { $ui.cfgCarpetaProcesados.Text = "$($aj.CarpetaProcesados)" }
        if ($aj.CarpetaTorrent) { $ui.cfgCarpetaTorrent.Text = "$($aj.CarpetaTorrent)" }
        if ($aj.Firma)        { $script:firmaSel = Join-Path $rutaFirmas "$($aj.Firma)" }
        & $chip "hostImg" $aj.HostImg
        $vAnnounce = & $rescatar "Announce"; if ($vAnnounce) { $ui.txtAnnounce.Text = $vAnnounce }
        $ui.swProyecto.IsChecked = $true       # los datos de proyecto van siempre (sin prompts en consola)
        $ui.swAplicarTodos.IsChecked = $true   # aplicar a todos en heterogéneo (sin preguntar por archivo)
    } catch {}
}

# =========================================================================
# LANZAMIENTO DEL SCRIPT
# =========================================================================
# Arranca de verdad un job de montaje ya preparado (config + launcher escritos). Se llama tanto al
# pulsar «Iniciar» (si no hay nada corriendo) como al DESENCOLAR el siguiente cuando termina uno.
# Fija aquí todos los efectos por-trabajo (log, bandera de consola, rutas de progreso) para que el
# job encolado use SUS propios ficheros y su propio log al llegarle el turno.
function Arrancar-JobMontaje($job) {
    if ($script:modoTest) {
        if (-not $script:testJobsMontaje) { $script:testJobsMontaje = @() }
        $script:testJobsMontaje = @($script:testJobsMontaje) + $job
        Write-Host "TEST_JOB: carpeta='$($job.Carpeta)' archivos='$($job.Nombres)'"
        return
    }
    try {
        Iniciar-LogProyecto $job.Carpeta
        $script:montajeInicio = Get-Date
        $script:ultimaFaseLog = ""   # reinicia el seguimiento de fases para el log en vivo
        Log-Sec "MONTAJE · lanzado"
        if ($job.Nombres) { Log-Linea "Archivos seleccionados: $($job.Nombres)" }
        Log-Bloque "Decisiones enviadas al motor (configuración)" $job.CfgJson
    } catch {}

    # Progreso limpio + bandera de consola oculta ("0") para ESTE trabajo.
    Remove-Item -LiteralPath $job.ProgPath, $job.ResPath, $job.ErrPath -ErrorAction SilentlyContinue
    "0" | Set-Content -LiteralPath $job.FlagPath -Encoding ASCII
    $script:rutaProgreso   = $job.ProgPath
    $script:rutaFlagCons   = $job.FlagPath
    $script:rutaResultados = $job.ResPath
    $script:rutaErrorMontaje = $job.ErrPath
    $script:resultadosLeidos = 0
    $script:consolaVisible = $false

    try {
        $script:procMontaje = Start-Process pwsh -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', "-ExecutionPolicy", "Bypass", "-File", ('"' + $job.LauncherPath + '"'))
        $script:montajeLifetime = Protect-HdzChildProcess $script:procMontaje
    } catch {
        if ($script:procMontaje -and -not $script:procMontaje.HasExited) { $script:procMontaje.Kill($true) }
        Set-Estado "Error al lanzar: $($_.Exception.Message)" "error"
        return
    }

    # UI de progreso: mostrar barra, habilitar el botón de consola, arrancar el sondeo.
    $ui.btnConsola.IsEnabled = $true
    Set-ContenidoConsola $false
    $ui.panProgreso.Visibility = "Visible"
    $ui.panProgreso2.Visibility = "Collapsed"
    $ui.barProgreso.Value = 0
    $ui.lblProgreso.Text = "Preparando montaje…"
    $ui.lblProgresoPct.Text = "0%"
    Iniciar-SondeoProgreso

    $nCola = @($script:colaMontaje).Count
    $sufCola = if ($nCola -gt 0) { "  ($nCola en cola)" } else { "" }
    Set-Estado "✓  Montaje lanzado en segundo plano.$sufCola Pulsa «Mostrar consola» si el script pide algo." "ok"
}

# Lanza el montaje según el ÁMBITO ($scope):
#   'unico'  -> homogéneo / lote único: un solo trabajo con la selección actual (comportamiento de siempre).
#   'actual' -> heterogéneo: SOLO la película de la pestaña activa (su grupo de archivos).
#   'todos'  -> heterogéneo: cada película que aún NO se haya lanzado, como trabajo propio, en cola.
# Cada película lanzada se anota en $script:gruposLanzados para no encolarla dos veces.
function Iniciar-Montaje($scope) {
    if ($script:timerIdiomasManuales.IsEnabled) { Actualizar-IdiomasManuales }
    if (-not (Test-Path -LiteralPath $rutaScript)) {
        Set-Estado "No se encuentra HDZnew.ps1 junto a esta interfaz ($rutaScript)." "error"
        return
    }
    $carpetasEntrada = @(Get-CarpetasEntrada)
    $carpeta = if ($carpetasEntrada.Count -gt 0) { $carpetasEntrada[0] } else { $ui.txtCarpeta.Text }
    # En MODO REMEZCLA la carpeta de trabajo es la que aporta el VÍDEO (la pre-fase del motor combina
    # las demás). Validamos las carpetas de remezcla en vez de la carpeta única.
    $remezclaOn = [bool]$ui.swRemezcla.IsChecked
    if ($remezclaOn) {
        $rzCarpetas = Leer-RemezclaCarpetas
        $rzVideo = @($rzCarpetas | Where-Object { $_.Video }) | Select-Object -First 1
        if (@($rzCarpetas).Count -lt 2) { Set-Estado "Remezcla: añade al menos 2 vídeos." "error"; return }
        if (-not $rzVideo) { Set-Estado "Remezcla: marca qué vídeo aporta la imagen." "error"; return }
        if (-not (@($rzCarpetas | Where-Object { -not $_.Video -and ($_.Audio -or $_.Subs) }))) { Set-Estado "Remezcla: marca Audio o Subs en al menos otro vídeo." "error"; return }
        if (Es-RemezclaSeriePorEpisodio $rzCarpetas) {
            $pruebaSerieMontaje = Test-RemezclaSeriePorEpisodio $rzCarpetas
            if (-not $pruebaSerieMontaje.Ok) { Set-Estado "Remezcla de serie: $($pruebaSerieMontaje.Mensaje)" "error"; return }
        } elseif (@($rzCarpetas | Where-Object { -not "$($_.Archivo)".Trim() }).Count -gt 0) {
            Set-Estado "Remezcla: usa todos archivos individuales o todas carpetas de serie; no los mezcles." "error"; return
        }
        $carpeta = $rzVideo.Ruta   # la carpeta de vídeo hace de carpeta de trabajo para el lanzador
        $carpetasEntrada = @($carpeta)
    }
    if ([string]::IsNullOrWhiteSpace($carpeta) -or -not (Test-Path -LiteralPath $carpeta)) {
        Set-Estado "Selecciona una carpeta válida con los vídeos." "error"
        return
    }
    $multiTemporada = (-not $remezclaOn) -and ($carpetasEntrada.Count -gt 1)
    if ($script:modoTest -and $env:HDZ_GUI_TEST_TEMPORADAS) {
        Write-Host "TEST_TEMPORADAS_INICIO: entradas=$($carpetasEntrada.Count) remezcla=$remezclaOn multi=$multiTemporada modo=$(Get-ChipValor 'modoLote')"
    }
    if ($multiTemporada -and (Get-ChipValor "modoLote") -ne "HOMOGENEO") {
        Set-Estado "Varias temporadas se procesan como «Mismo proyecto (temporada)». Cambia a ese modo para mantener cada carpeta como un pack independiente." "error"
        return
    }
    if ((Get-ChipValor "modoLote") -eq "HETEROGENEO" -and @($script:tabsProy).Count -gt 0) {
        # En modo por archivo, cada pestaña (película) necesita su título. Validamos todas.
        if ($script:tabProyActual -ge 0 -and $script:tabProyActual -lt @($script:tabsProy).Count) {
            $script:tabsProy[$script:tabProyActual].Estado = Snapshot-Proyecto
            $script:tabsProy[$script:tabProyActual].Decisiones = Snapshot-DecisionesTab
        }
        for ($i = 0; $i -lt @($script:tabsProy).Count; $i++) {
            if ([string]::IsNullOrWhiteSpace("$($script:tabsProy[$i].Estado.Titulo)")) {
                $ui.navProyecto.IsChecked = $true
                Cambiar-TabProy $i
                Set-Estado "La película «$($script:tabsProy[$i].Principal)» no tiene título. Rellénalo en su pestaña." "error"
                return
            }
            $dAud = $script:tabsProy[$i].Decisiones
            if ($dAud -and @($dAud.AudioLangsTodos).Count -gt 0 -and @($dAud.AudioLangs).Count -eq 0) {
                $ui.navProyecto.IsChecked = $true
                Cambiar-TabProy $i
                Set-Estado "La película «$($script:tabsProy[$i].Principal)» no tiene ningún idioma de audio marcado." "error"
                return
            }
        }
    } elseif ([bool]$ui.swProyecto.IsChecked -and [string]::IsNullOrWhiteSpace($ui.txtTitulo.Text)) {
        Set-Estado "Has activado los datos del proyecto: el título no puede estar vacío." "error"
        $ui.navProyecto.IsChecked = $true
        return
    }
    $filtroVal = Get-ChipValor "filtro"
    $idiomasMarcados = @($script:chipsIdiomas | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
    $audiosDisponibles = @($script:chipsIdiomasAudio | ForEach-Object { "$($_.Tag)" })
    $audiosMarcados = @($script:chipsIdiomasAudio | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
    if ($audiosDisponibles.Count -gt 0 -and $audiosMarcados.Count -eq 0) {
        Set-Estado "Marca al menos un idioma de audio para conservar." "error"
        $ui.navProyecto.IsChecked = $true
        return
    }
    if ($filtroVal -eq "PERSONALIZADA" -and $idiomasMarcados.Count -eq 0) {
        Set-Estado "Filtro personalizado de subtítulos: marca al menos un idioma." "error"
        $ui.navProyecto.IsChecked = $true
        return
    }
    # Selección de archivos del análisis
    $todosNombresScan = @($script:ultimoScan | ForEach-Object { $_.Nombre })
    $marcadosSel = @($todosNombresScan | Where-Object { $script:seleccion[$_] -ne $false })
    if ($todosNombresScan.Count -gt 0 -and $marcadosSel.Count -eq 0) {
        Set-Estado "No hay ningún archivo seleccionado para procesar." "error"
        $ui.navProyecto.IsChecked = $true
        return
    }

    $cfg = [ordered]@{}
    $excluded=@(Get-HdzExcludedAudioTracks)
    if($excluded.Count){$cfg.PistasAudioExcluidas=$excluded}
    # Si se ha deseleccionado algún archivo, el script procesará SOLO los marcados
    if (-not $remezclaOn -and $todosNombresScan.Count -gt 0 -and ($marcadosSel.Count -lt $todosNombresScan.Count -or @($script:videosElegidos).Count -gt 0)) {
        $cfg.ArchivosSeleccionados = @($marcadosSel)
    }
    # Plan de remezcla: el motor combina las carpetas (vídeo de una + audios/subs de otras) antes de montar.
    if ($remezclaOn) {
        $rzPlan = @(Leer-RemezclaCarpetas)
        $cfg.Remezcla = @{ Modo = $(if (Es-RemezclaSeriePorEpisodio $rzPlan) { "SERIE_EPISODIOS" } else { "MANUAL" }); Carpetas = @($rzPlan | ForEach-Object { @{ Ruta = $_.Ruta; Archivo = $_.Archivo; Video = [bool]$_.Video; Audio = [bool]$_.Audio; Subs = [bool]$_.Subs } }) }
    }
    $v = Get-ChipValor "modoLote";     if ($null -ne $v) { $cfg.ModoLote = $v }
    $v = Get-ChipValor "capturasProy"; if ($null -ne $v) { $cfg.NumCapturas = [int]$v }
    $v = Get-ChipValor "originales";   if ($null -ne $v) { $cfg.AccionOriginales = "$v"; $cfg.BorrarOriginales = ("$v" -eq "BORRAR") }
    $v = Get-ChipValor "sufijo";       if ($null -ne $v) { $cfg.SufijoHDZ = $v }
    $v = Get-ChipValor "torrent";      if ($null -ne $v) { $cfg.ModoTorrent = $v }
    # La URL de anuncio y el nombre del pack se envían siempre que estén rellenos.
    if (-not [string]::IsNullOrWhiteSpace($ui.txtAnnounce.Text))   { $cfg.TorrentAnnounce   = $ui.txtAnnounce.Text.Trim() }
    # Nombre del pack: SOLO se envía si lo editaste a mano. Si sigue con el valor automático (que es
    # una previsualización), NO se envía, para que el motor nombre el pack a partir del archivo YA
    # PROCESADO (mismo naming que los episodios), no del nombre del vídeo original.
    $packTxt = "$($ui.txtPackNombre.Text)".Trim()
    if (-not $multiTemporada -and $packTxt -and ($packTxt -ne "$($script:packNombreAutoVal)".Trim())) {
        $cfg.TorrentPackNombre = $packTxt
    }
    if (-not [string]::IsNullOrWhiteSpace($ui.txtSalidaArchivo.Text)) { $cfg.CarpetaSalida  = $ui.txtSalidaArchivo.Text.Trim() }
    # Carpeta para archivar los originales .procesado + capturas (ajuste): el motor crea dentro una
    # subcarpeta por proyecto. No afecta al MKV resultado.
    if (-not [string]::IsNullOrWhiteSpace($ui.cfgCarpetaProcesados.Text)) { $cfg.CarpetaProcesados = $ui.cfgCarpetaProcesados.Text.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($ui.txtSalidaTorrent.Text)) { $cfg.CarpetaTorrent = $ui.txtSalidaTorrent.Text.Trim() }
    # Conversor de audio manual (sustituye a ModoConversionDTS). Lista global; en heterogéneo
    # se añade además ConversionesPorArchivo (por película) más abajo, que tiene prioridad.
    $convGlobal = @(Leer-ConversionesActuales)
    if ($convGlobal.Count -gt 0) { $cfg.ConversionesAudioManual = $convGlobal }
    $v = Get-ChipValor "defAudio";     if ($null -ne $v) { $cfg.DefaultPreferidoAudio = $v }
    # En temporadas homogéneas la selección es global. Si todos siguen marcados, se omite el filtro
    # y el motor conserva exactamente su comportamiento histórico.
    if (-not $remezclaOn -and (Get-ChipValor "modoLote") -ne "HETEROGENEO" -and
        $audiosDisponibles.Count -gt 0 -and $audiosMarcados.Count -lt $audiosDisponibles.Count) {
        $cfg.IdiomasAudioMantener = @($audiosMarcados)
    }
    # Subs únicos: decisión POR sub (idioma+formato), una por cada sección de la GUI.
    $mapaSubs = [ordered]@{}
    foreach ($r in @($script:subsUnicosRows)) {
        $mapaSubs["$($r.Cod)|$($r.Fmt)"] = $(if ($r.RbForzado.IsChecked) { "Forzado" } else { "Completo" })
    }
    if ($mapaSubs.Count -gt 0) { $cfg.SubsUnicosPorIdioma = $mapaSubs }

    # Idiomas por pista para las pistas 'und'. Todas tienen un valor (idioma o "und"),
    # así que todas se envían y el script nunca pregunta por consola.
    $undSeleccion = @()
    foreach ($r in $script:undRows) {
        $vU = Get-ComboValor $r.Combo
        if ($null -ne $vU -and $vU -ne 'AUTO') {
            $undSeleccion += [ordered]@{ Archivo = $r.Archivo; Id = $r.Id; Tipo = $r.Tipo; Idioma = $vU }
        }
    }
    $cfg.IdiomasPistasExactos = $true
    if ($undSeleccion.Count -gt 0) { $cfg.IdiomasUndPistas = @($undSeleccion) }
    $v = Get-ChipValor "extraerPGS";   if ($null -ne $v) { $cfg.ExtraerPGS = $v }
    $v = Get-ChipValor "conservarPGS"; if ($null -ne $v) { $cfg.DecisionConservarPGS = $v }

    if ($filtroVal -eq "PERSONALIZADA") { $cfg.IdiomasSubsMantener = @($idiomasMarcados) }
    elseif ($null -ne $filtroVal)       { $cfg.IdiomasSubsMantener = $filtroVal }
    # REMEZCLA: la selección de idiomas de la tarjeta MANDA sobre el filtro de subs del panel Subs.
    # Audios: filtro propio (IdiomasAudioMantener). Si están TODOS marcados, no se filtra ese tipo.
    if ($remezclaOn) {
        $audSel = @(@($script:remezclaChipsAudio) | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
        if (@($script:remezclaChipsAudio).Count -gt 0 -and $audSel.Count -lt @($script:remezclaChipsAudio).Count) { $cfg.IdiomasAudioMantener = @($audSel) }
        $subSel = @(@($script:remezclaChipsSub) | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
        if (@($script:remezclaChipsSub).Count -gt 0) {
            if ($subSel.Count -lt @($script:remezclaChipsSub).Count) { $cfg.IdiomasSubsMantener = @($subSel) }
            else { $cfg.IdiomasSubsMantener = "TODOS" }
        }
    }

    if ([bool]$ui.swProyecto.IsChecked) {
        $esWeb = ((Get-ChipValor "origen") -ne "FISICO")
        $plat = if ($esWeb) {
            if (-not [string]::IsNullOrWhiteSpace($ui.txtPlataformaOtra.Text)) { $ui.txtPlataformaOtra.Text.Trim() }
            else { Get-CodigoPlataforma $ui.cmbPlataforma.SelectedItem }
        } else {
            if (-not [string]::IsNullOrWhiteSpace($ui.txtFormatoOtro.Text)) { $ui.txtFormatoOtro.Text.Trim() }
            else { "$($ui.cmbFormato.SelectedItem)" }
        }
        $cfg.Proyecto = [ordered]@{
            Titulo            = $ui.txtTitulo.Text.Trim()
            Ano               = $ui.txtAno.Text.Trim()
            EsSerie           = [bool]$ui.swSerie.IsChecked
            TipoOrigen        = (Get-ChipValor "origen")
            WebTipo           = (Get-ChipValor "webTipo")
            PlataformaFormato = $plat
            EtiquetasExtra    = if ($esWeb) { "" } else { $ui.txtEtiquetas.Text.Trim() }
            AplicarATodos     = [bool]$ui.swAplicarTodos.IsChecked
        }
    }

    # Episodios POR ARCHIVO (series): tag de episodio de cada vídeo, con posible rango multi-capítulo
    # (S01E01-E02). Se envía el valor editado en la lista o, si está vacío, el autodetectado. El motor
    # lo usa en vez de detectar del nombre, y así nunca pregunta el capítulo por consola.
    if ([bool]$ui.swSerie.IsChecked) {
        $mapaEp = [ordered]@{}
        foreach ($f in @($script:ultimoScan)) {
            if ($script:seleccion["$($f.Nombre)"] -eq $false) { continue }
            $tag = if ($script:episodiosMap.ContainsKey($f.Nombre) -and "$($script:episodiosMap[$f.Nombre])".Trim()) {
                "$($script:episodiosMap[$f.Nombre])".Trim()
            } else { Detectar-EpisodioGui $f.Nombre }
            if ($tag) { $mapaEp["$($f.Nombre)"] = $tag }
        }
        if ($mapaEp.Count -gt 0) { $cfg.EpisodiosPorArchivo = $mapaEp }
    }

    # Carpeta de salida del MKV POR ARCHIVO (opcional): cada vídeo puede ir a una carpeta distinta.
    # Solo se envían los que tengan carpeta propia; el resto usa la global / junto al origen.
    if ($script:salidaMap -and $script:salidaMap.Count -gt 0) {
        $mapaSal = [ordered]@{}
        foreach ($f in @($script:ultimoScan)) {
            if ($script:seleccion["$($f.Nombre)"] -eq $false) { continue }
            if ($script:salidaMap.ContainsKey($f.Nombre) -and "$($script:salidaMap[$f.Nombre])".Trim()) {
                $mapaSal["$($f.Nombre)"] = "$($script:salidaMap[$f.Nombre])".Trim()
            }
        }
        if ($mapaSal.Count -gt 0) { $cfg.CarpetaSalidaPorArchivo = $mapaSal }
    }

    # Identidad POR ARCHIVO (modo «Cada archivo distinto»): mapa nombreArchivo -> datos de proyecto.
    # El motor (Get-DatosProyecto) lo consulta por nombre de archivo y aplica la identidad de cada peli.
    if ((Get-ChipValor "modoLote") -eq "HETEROGENEO" -and @($script:tabsProy).Count -gt 0) {
        if ($script:tabProyActual -ge 0 -and $script:tabProyActual -lt @($script:tabsProy).Count) {
            $script:tabsProy[$script:tabProyActual].Estado = Snapshot-Proyecto
            $script:tabsProy[$script:tabProyActual].Decisiones = Snapshot-DecisionesTab
        }
        $mapaProy = [ordered]@{}
        $mapaGen  = [ordered]@{}   # Originales/Sufijo/Torrent POR PELÍCULA (pestañas de General)
        foreach ($tb in @($script:tabsProy)) {
            $e = $tb.Estado
            $esWebE = ("$($e.Origen)" -ne "FISICO")
            $platE = if ($esWebE) {
                if (-not [string]::IsNullOrWhiteSpace($e.PlatOtra)) { "$($e.PlatOtra)".Trim() }
                elseif ([int]$e.PlatIdx -ge 0 -and [int]$e.PlatIdx -lt $ui.cmbPlataforma.Items.Count) { Get-CodigoPlataforma $ui.cmbPlataforma.Items[[int]$e.PlatIdx] }
                else { "" }
            } else {
                if (-not [string]::IsNullOrWhiteSpace($e.FmtOtro)) { "$($e.FmtOtro)".Trim() }
                elseif ([int]$e.FmtIdx -ge 0 -and [int]$e.FmtIdx -lt $ui.cmbFormato.Items.Count) { "$($ui.cmbFormato.Items[[int]$e.FmtIdx])" }
                else { "" }
            }
            $datos = [ordered]@{
                Titulo            = "$($e.Titulo)".Trim()
                Ano               = "$($e.Ano)".Trim()
                EsSerie           = [bool]$e.EsSerie
                TipoOrigen        = "$($e.Origen)"
                WebTipo           = "$($e.WebTipo)"
                PlataformaFormato = $platE
                EtiquetasExtra    = if ($esWebE) { "" } else { "$($e.Etiquetas)".Trim() }
                NumCapturas       = $(if ($null -ne $e.Capturas) { [int]$e.Capturas } else { -1 })
            }
            foreach ($arch in @($tb.Archivos)) { 
                $nombre = if ($arch.Name) { $arch.Name } else { Split-Path $arch -Leaf }
                $mapaProy[$nombre] = $datos 
            }
            # Ajustes de General propios de esta película (originales, sufijo, torrent).
            $gen = [ordered]@{}
            if ($null -ne $e.Originales) { $gen.AccionOriginales = "$($e.Originales)"; $gen.BorrarOriginales = ("$($e.Originales)" -eq "BORRAR") }
            if ($null -ne $e.Sufijo)     { $gen.SufijoHDZ = $e.Sufijo }
            if ($null -ne $e.Torrent)    { $gen.ModoTorrent = "$($e.Torrent)" }
            if ($gen.Count -gt 0) { 
                foreach ($arch in @($tb.Archivos)) { 
                    $nombre = if ($arch.Name) { $arch.Name } else { Split-Path $arch -Leaf }
                    $mapaGen[$nombre] = $gen 
                } 
            }
        }
        if ($mapaProy.Count -gt 0) { $cfg.ProyectoPorArchivo = $mapaProy }
        if ($mapaGen.Count -gt 0)  { $cfg.GeneralPorArchivo = $mapaGen }

        # Decisiones de audio/subtítulos POR ARCHIVO (audio por defecto, filtro, PGS) + conversiones
        # de audio por película + pistas und (de TODAS las pestañas) + subs únicos. Reemplazan a las globales.
        $mapaDec = [ordered]@{}; $undTodos = @(); $mapaSU = [ordered]@{}; $mapaConv = [ordered]@{}
        foreach ($tb in @($script:tabsProy)) {
            $d = $tb.Decisiones
            if (-not $d) { continue }
            $filtroEf = if ($d.Filtro -eq "PERSONALIZADA") { @($d.FiltroLangs) } else { $d.Filtro }
            $dec = [ordered]@{
                DefAudio = $d.DefAudio; Filtro = $filtroEf
                AudioLangs = @($d.AudioLangs)
                ExtraerPGS = [bool]$d.ExtraerPGS; ConservarPGS = $d.ConservarPGS
            }
            foreach ($arch in @($tb.Archivos)) { 
                $nombre = if ($arch.Name) { $arch.Name } else { Split-Path $arch -Leaf }
                $mapaDec[$nombre] = $dec 
            }
            # Conversiones de audio de esta película (formato motor, sin el campo GUI 'Dest').
            $convPeli = @(@($d.Conv) | Where-Object { $_ })
            if ($convPeli.Count -gt 0) { 
                foreach ($arch in @($tb.Archivos)) { 
                    $nombre = if ($arch.Name) { $arch.Name } else { Split-Path $arch -Leaf }
                    $mapaConv[$nombre] = $convPeli 
                } 
            }
            if ($d.Und) {
                foreach ($k in $d.Und.Keys) {
                    if ($null -eq $d.Und[$k] -or $d.Und[$k] -eq 'AUTO') { continue }
                    $p = "$k" -split "\|"
                    if ($p.Count -ge 3) { $undTodos += [ordered]@{ Archivo = $p[0]; Id = $p[1]; Tipo = $p[2]; Idioma = $d.Und[$k] } }
                }
            }
            if ($d.SubsUnicos -and $d.SubsUnicos.Count -gt 0) {
                $perArch = [ordered]@{}
                foreach ($kk in $d.SubsUnicos.Keys) { $perArch["$kk"] = $d.SubsUnicos[$kk] }
                foreach ($arch in @($tb.Archivos)) { 
                    $nombre = if ($arch.Name) { $arch.Name } else { Split-Path $arch -Leaf }
                    $mapaSU[$nombre] = $perArch 
                }
            }
        }
        if ($mapaDec.Count -gt 0) { $cfg.DecisionesPorArchivo = $mapaDec }
        if ($mapaConv.Count -gt 0) { $cfg.ConversionesPorArchivo = $mapaConv }       # conversiones por película
        if ($undTodos.Count -gt 0) { $cfg.IdiomasUndPistas = @($undTodos) }          # reemplaza al global
        if ($mapaSU.Count -gt 0)  { $cfg.SubsUnicosPorArchivo = $mapaSU }
    }

    # ¿Qué películas (grupos) hay que lanzar, según el ámbito? Cada grupo = 1 trabajo independiente.
    $het = (("$(Get-ChipValor 'modoLote')") -eq "HETEROGENEO") -and (@($script:tabsProy).Count -gt 0)
    $gruposLanzar = @()
    if ($het -and $scope -eq 'todos') {
        foreach ($tb in @($script:tabsProy)) {
            $k = "$($tb.Principal)"
            if ($script:gruposLanzados.ContainsKey($k)) { continue }   # ya lanzada/en cola: no repetir
            $gruposLanzar += @{ Key = $k; Archivos = @($tb.Archivos) }
        }
        if ($gruposLanzar.Count -eq 0) { Set-Estado "Todas las películas ya están lanzadas o en cola." "warn"; return }
    } elseif ($het -and $scope -eq 'actual') {
        if ($script:tabProyActual -lt 0 -or $script:tabProyActual -ge @($script:tabsProy).Count) { return }
        $tb = $script:tabsProy[$script:tabProyActual]; $k = "$($tb.Principal)"
        if ($script:gruposLanzados.ContainsKey($k)) { Set-Estado "«$k» ya está lanzada o en cola." "warn"; return }
        $gruposLanzar += @{ Key = $k; Archivos = @($tb.Archivos) }
    } elseif ($multiTemporada) {
        # Un trabajo homogéneo POR CARPETA. Las decisiones son comunes, pero el motor ve una sola
        # temporada cada vez y por tanto crea su carpeta/pack/torrent sin mezclar S01 con S02.
        foreach ($cp in $carpetasEntrada) {
            $cpNorm = "$cp".TrimEnd('\')
            $archCp = @($script:ultimoScan | Where-Object {
                "$((Split-Path $_.Ruta -Parent))".TrimEnd('\').Equals($cpNorm, [StringComparison]::OrdinalIgnoreCase) -and
                $script:seleccion[$_.Nombre] -ne $false
            } | ForEach-Object { $_.Nombre })
            if ($archCp.Count -gt 0) {
                $gruposLanzar += @{ Key = $cpNorm; Carpeta = $cpNorm; Archivos = @($archCp) }
            }
        }
        if ($gruposLanzar.Count -eq 0) {
            Set-Estado "No hay temporadas con archivos seleccionados para procesar." "error"
            return
        }
        if ($script:modoTest) { Write-Host "TEST_TEMPORADAS_GRUPOS: $($gruposLanzar.Count) [$(@($gruposLanzar | ForEach-Object { Split-Path $_.Carpeta -Leaf }) -join ', ')]" }
    } else {
        # Homogéneo / lote único: un único trabajo con la selección actual (sin trocear por película).
        $gruposLanzar += @{ Key = $null; Archivos = $null }
    }

    try {
        Guardar-Ajustes
        $baseMarca = Get-Date -Format "yyyyMMdd_HHmmss"
        $gi = 0
        foreach ($grp in $gruposLanzar) {
        # Config de ESTE grupo: copia de $cfg con ArchivosSeleccionados = archivos de la película. El
        # motor solo procesa esos; los mapas por-archivo comparten claves de sobra sin estorbar.
        $cfgG = $cfg
        if ($grp.Archivos) {
            $cfgG = [ordered]@{}
            foreach ($kk in $cfg.Keys) { $cfgG[$kk] = $cfg[$kk] }
            $cfgG.ArchivosSeleccionados = @($grp.Archivos)
        }
        $marca = "${baseMarca}_$gi"; $gi++
        $cfgPath = Join-Path $env:TEMP "hdz_gui_config_$marca.json"
        $cfgJson = $cfgG | ConvertTo-Json -Depth 6
        $cfgJson | Set-Content -LiteralPath $cfgPath -Encoding UTF8
        $selG = @($cfgG.ArchivosSeleccionados)
        $selNombres = if ($selG.Count -gt 0) { $selG -join ", " } else { "(todos los seleccionados)" }
        $carpetaJob = if ($grp.Carpeta) { "$($grp.Carpeta)" } else { $carpeta }

        # Rutas de progreso/consola/resultados de ESTE trabajo. Aquí solo se CALCULAN (van embebidas
        # en el launcher). Los efectos (borrar progreso, escribir la bandera, fijar $script:ruta*, el
        # log de «MONTAJE lanzado») ocurren cuando el job ARRANCA de verdad — en Arrancar-JobMontaje —
        # que puede ser ahora mismo o más tarde, al desencolarlo tras terminar el montaje anterior.
        $progPath = Join-Path $env:TEMP "hdz_gui_progreso_$marca.json"
        $flagPath = Join-Path $env:TEMP "hdz_gui_consola_$marca.flag"
        $resPath  = Join-Path $env:TEMP "hdz_gui_resultados_$marca.jsonl"
        $errPath  = Join-Path $env:TEMP "hdz_gui_error_$marca.txt"

        $esc = { param($s) "$s" -replace "'", "''" }
        $launcherPath = Join-Path $env:TEMP "hdz_gui_launcher_$marca.ps1"
        # El launcher captura su PROPIA ventana de consola (GetConsoleWindow es fiable para el
        # proceso actual) y, mediante un tipo C# (Add-Type), lanza un HILO NATIVO que la
        # muestra/oculta según el fichero-bandera. Todo el bucle vigía vive en C# para que no
        # dependa de un runspace de PowerShell (un scriptblock en un Thread crudo no lo tiene).
        # Como la consola arranca con -WindowStyle Hidden, no hay parpadeo inicial.
        $plantilla = @'
$ErrorActionPreference = 'Stop'
$hdzErrorPath = '@@ERR@@'
try {
Add-Type -Namespace HdzCons -Name Win -UsingNamespace System.Threading,System.IO -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
public static void Start(string flagPath) {
    IntPtr hwnd = GetConsoleWindow();
    Thread t = new Thread(delegate() {
        int last = -1;
        while (true) {
            int want = 1;
            try { if (File.ReadAllText(flagPath).Trim() == "0") want = 0; } catch {}
            if (want != last) { ShowWindow(hwnd, want == 0 ? 0 : 5); last = want; }
            Thread.Sleep(200);
        }
    });
    t.IsBackground = true;
    t.Start();
}
"@
[HdzCons.Win]::Start('@@FLAG@@')
Set-Location -LiteralPath '@@CARPETA@@'
$env:HDZ_CONFIG = '@@CFG@@'
$env:HDZ_PROGRESS = '@@PROG@@'
$env:HDZ_RESULTS = '@@RES@@'
$env:HDZ_CONSOLE_FLAG = '@@FLAG@@'
& '@@SCRIPT@@'
# El motor terminó su ruta normal (sin 'exit' propio). Salimos aquí para que HasExited pase a true.
# CÓDIGO DE SALIDA para que la GUI distinga CÓMO acabó (antes SIEMPRE era 0 y todo parecía correcto,
# aunque hubieran fallado archivos): 0 = limpio · 2 = terminó pero con incidencias (algún archivo
# fallo) · 1 = el motor PETÓ (throw sin capturar). El motor acumula los fallos en $global:incidencias,
# que sigue accesible aquí tras el '& $script'. Si el motor peta con un throw, esta línea NO se
# ejecuta y el proceso sale con 1 por su cuenta -> la GUI lo trata como fallo.
$codFin = 0
try { if ($global:incidencias -and $global:incidencias.Count -gt 0) { $codFin = 2 } } catch {}
exit $codFin
} catch {
    $detalle = "Mensaje: $($_.Exception.Message)`r`nTipo: $($_.Exception.GetType().FullName)`r`nPosición: $($_.InvocationInfo.PositionMessage)`r`nPila: $($_.ScriptStackTrace)"
    try { [System.IO.File]::WriteAllText($hdzErrorPath, $detalle, [System.Text.UTF8Encoding]::new($false)) } catch {}
    exit 1
}
'@
        $launcher = $plantilla `
            -replace '@@FLAG@@',    (& $esc $flagPath) `
            -replace '@@CARPETA@@', (& $esc $carpetaJob) `
            -replace '@@CFG@@',     (& $esc $cfgPath) `
            -replace '@@PROG@@',    (& $esc $progPath) `
            -replace '@@RES@@',     (& $esc $resPath) `
            -replace '@@ERR@@',     (& $esc $errPath) `
            -replace '@@SCRIPT@@',  (& $esc $rutaScript)
        Set-Content -LiteralPath $launcherPath -Value $launcher -Encoding UTF8

        # SIN -NoExit: con -NoExit el proceso NO obedece al 'exit' del launcher y se queda vivo tras
        # terminar el motor (HasExited nunca pasa a true) → la barra se queda colgada al 100% y el
        # reset no la oculta. Sin -NoExit, al terminar el motor el proceso sale y la GUI lo detecta.
        # (La consola oculta se muestra/oculta por su hilo C#; los Read-Host bloquean y mantienen vivo
        # el proceso mientras esperan respuesta, así que no hace falta -NoExit para las preguntas.)
        # Job listo (config + launcher ya escritos en disco). Se arranca ahora o se encola.
        $job = [ordered]@{
            Carpeta = $carpetaJob; CfgPath = $cfgPath; CfgJson = $cfgJson; LauncherPath = $launcherPath
            ProgPath = $progPath; FlagPath = $flagPath; ResPath = $resPath; ErrPath = $errPath; Nombres = $selNombres
        }
        Guardar-Ajustes

        if ($script:procMontaje -and -not $script:procMontaje.HasExited) {
            # Ya hay un montaje EN MARCHA: no arrancamos otro en paralelo (colisionarían en los
            # temporales de la fusión DV y en los .mkv/torrent de salida). Lo ENCOLAMOS: arrancará
            # solo al terminar el actual. Puedes seguir pulsando para añadir más a la cola.
            $script:colaMontaje = @($script:colaMontaje) + $job
            Set-Estado "➕  En cola ($(@($script:colaMontaje).Count)). Se lanzará al terminar el montaje en curso." "ok"
        } else {
            Arrancar-JobMontaje $job
        }
        if ($grp.Key) { $script:gruposLanzados["$($grp.Key)"] = $true }   # peli marcada: no repetir
        }
        Actualizar-BotonesIniciar
    } catch {
        Set-Estado "Error al lanzar: $($_.Exception.Message)" "error"
    }
}

# «Iniciar»: en heterogéneo lanza SOLO la película activa; en homogéneo/lote, todo (como siempre).
$ui.btnIniciar.Add_Click({
    if ((("$(Get-ChipValor 'modoLote')") -eq "HETEROGENEO") -and (@($script:tabsProy).Count -gt 0)) { Iniciar-Montaje 'actual' }
    else { Iniciar-Montaje 'unico' }
})
# «Todas»: en heterogéneo encola cada película pendiente (una tras otra). Fuera de heterogéneo hace
# lo mismo que «Iniciar» (un único trabajo con todo lo seleccionado).
$ui.btnIniciarTodos.Add_Click({
    if ((("$(Get-ChipValor 'modoLote')") -eq "HETEROGENEO") -and (@($script:tabsProy).Count -gt 0)) { Iniciar-Montaje 'todos' }
    else { Iniciar-Montaje 'unico' }
})

# Ajusta etiquetas/visibilidad/estado de los dos botones de inicio según el modo y qué películas ya
# se han lanzado. En heterogéneo: «Iniciar» = película activa (se deshabilita si ya está lanzada),
# «Todas» visible (se deshabilita si no queda ninguna). Fuera de heterogéneo: un único «Iniciar».
function Actualizar-BotonesIniciar {
    if (-not $ui.btnIniciar) { return }
    if ("$($ui.btnIniciar.Visibility)" -ne "Visible") { return }   # en «Subida» el botón está oculto: no tocar
    $het = (("$(Get-ChipValor 'modoLote')") -eq "HETEROGENEO") -and (@($script:tabsProy).Count -gt 0)
    if ($het) {
        $ui.btnIniciar.Content = "▶   Procesar este trabajo"
        if ($ui.btnIniciarTodos) { $ui.btnIniciarTodos.Visibility = "Visible" }
        $curLanzada = $false
        if ($script:tabProyActual -ge 0 -and $script:tabProyActual -lt @($script:tabsProy).Count) {
            $curLanzada = $script:gruposLanzados.ContainsKey("$($script:tabsProy[$script:tabProyActual].Principal)")
        }
        $ui.btnIniciar.IsEnabled = -not $curLanzada
        $quedan = @(@($script:tabsProy) | Where-Object { -not $script:gruposLanzados.ContainsKey("$($_.Principal)") }).Count
        if ($ui.btnIniciarTodos) { $ui.btnIniciarTodos.IsEnabled = ($quedan -gt 0) }
    } else {
        $ui.btnIniciar.Content = "▶   Procesar este trabajo"
        $ui.btnIniciar.IsEnabled = $true
        if ($ui.btnIniciarTodos) { $ui.btnIniciarTodos.Visibility = "Collapsed" }
    }
}

# Sondeo del fichero de progreso que escribe HDZnew.ps1 (~3/s) + detección de fin de proceso.
function Iniciar-SondeoProgreso {
    if ($script:timerProgreso) { $script:timerProgreso.Stop() }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(350)
    $t.Add_Tick({
        # ¿El motor abrió la consola por su cuenta (porque necesita una respuesta)? La bandera
        # pasa a "1" sin que el usuario tocara el botón → reflejarlo en la UI para no desincronizar.
        if ($script:rutaFlagCons -and -not $script:consolaVisible -and (Test-Path -LiteralPath $script:rutaFlagCons)) {
            try {
                if ((Get-Content -LiteralPath $script:rutaFlagCons -Raw -ErrorAction Stop).Trim() -eq "1") {
                    $script:consolaVisible = $true
                    Set-ContenidoConsola $true
                    Set-Estado "⚠  El montaje pide una respuesta: la consola se ha abierto. Contéstale para continuar." "warn"
                }
            } catch {}
        }
        # Leer progreso
        if ($script:rutaProgreso -and (Test-Path -LiteralPath $script:rutaProgreso)) {
            try {
                $p = Get-Content -LiteralPath $script:rutaProgreso -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $p) {
                    $pct = [int]$p.pct
                    if ($pct -lt 0) { $pct = 0 } elseif ($pct -gt 100) { $pct = 100 }
                    $ui.barProgreso.Value = $pct
                    $ui.lblProgresoPct.Text = "$pct%"
                    $txt = "$($p.fase)"
                    if (-not [string]::IsNullOrWhiteSpace($p.archivo)) { $txt += ": $($p.archivo)" }
                    $ui.lblProgreso.Text = $txt
                    # LOG EN VIVO: cada vez que cambia la fase del motor, se anota en el log del
                    # proyecto con su hora. Así, si el proceso se cuelga (p.ej. hasheando el
                    # torrent), el log refleja en todo momento por dónde iba y no se pierde nada.
                    if (-not [string]::IsNullOrWhiteSpace($txt) -and "$txt" -ne "$($script:ultimaFaseLog)") {
                        $script:ultimaFaseLog = "$txt"
                        try { Log-Linea "▸ $txt" } catch {}
                    }
                    # 2ª barra (detalle de la tarea en curso): pct2 = -1 (o ausente) → oculta.
                    $pct2 = if ($null -ne $p.pct2) { [int]$p.pct2 } else { -1 }
                    if ($pct2 -ge 0) {
                        if ($pct2 -gt 100) { $pct2 = 100 }
                        $ui.panProgreso2.Visibility = "Visible"
                        $ui.barProgreso2.Value = $pct2
                        $ui.lblProgreso2Pct.Text = "$pct2%"
                        if (-not [string]::IsNullOrWhiteSpace($p.fase2)) { $ui.lblProgreso2.Text = "$($p.fase2)" }
                    } else {
                        $ui.panProgreso2.Visibility = "Collapsed"
                    }
                }
            } catch {}
        }
        # Resultados nuevos (torrents creados) → crear una pestaña de subida por cada uno.
        # Procesamos UNO por tick para no bloquear la UI (cada carga hace MediaInfo + TMDB).
        if ($script:rutaResultados -and (Test-Path -LiteralPath $script:rutaResultados)) {
            try {
                $lineas = @(Get-Content -LiteralPath $script:rutaResultados -Encoding UTF8 -ErrorAction Stop)
                if ($lineas.Count -gt $script:resultadosLeidos) {
                    $linea = $lineas[$script:resultadosLeidos]
                    $script:resultadosLeidos++
                    $r = $linea | ConvertFrom-Json
                    if ($r -and $r.torrent -and (Test-Path -LiteralPath $r.torrent)) {
                        Anadir-SubidaAuto $r.torrent "$($r.video)" "$($r.origen)" @($r.capturas) $false
                    }
                }
            } catch {}
        }
        # ¿Terminó el proceso de consola?
        if ($script:procMontaje -and $script:procMontaje.HasExited) {
            $script:timerProgreso.Stop()
            # Al parar el timer no habrá más ticks: drenamos los resultados que pudieran quedar sin leer
            # (torrents creados en los últimos instantes) para no perder ninguna pestaña de subida.
            if ($script:rutaResultados -and (Test-Path -LiteralPath $script:rutaResultados)) {
                try {
                    $lineasFin = @(Get-Content -LiteralPath $script:rutaResultados -Encoding UTF8 -ErrorAction Stop)
                    while ($script:resultadosLeidos -lt $lineasFin.Count) {
                        $lf = $lineasFin[$script:resultadosLeidos]; $script:resultadosLeidos++
                        try { $rf = $lf | ConvertFrom-Json; if ($rf -and $rf.torrent -and (Test-Path -LiteralPath $rf.torrent)) { Anadir-SubidaAuto $rf.torrent "$($rf.video)" "$($rf.origen)" @($rf.capturas) $false } } catch {}
                    }
                } catch {}
            }
            $ui.btnConsola.IsEnabled = $false
            $script:consolaVisible = $false
            Set-ContenidoConsola $false
            $codigo = $script:procMontaje.ExitCode
            $ui.barProgreso.Value = 100
            $ui.lblProgresoPct.Text = "100%"
            $ui.panProgreso2.Visibility = "Collapsed"
            # ¿CÓMO acabó el motor? El launcher devuelve 0 = limpio, 2 = terminó con incidencias,
            # otro (1) = petó. La cuenta EXACTA viene en la última fase del motor ("Terminado con N
            # incidencia(s)"): la releemos del fichero de progreso por si el último tick no llegó a
            # capturarla antes de que el proceso saliera. Antes esto se ignoraba y SIEMPRE salía el
            # ✓ verde de éxito, aunque hubieran fallado archivos y no se hubiera creado el pack.
            $faseFin = "$($script:ultimaFaseLog)"
            try {
                if ($script:rutaProgreso -and (Test-Path -LiteralPath $script:rutaProgreso)) {
                    $pf = Get-Content -LiteralPath $script:rutaProgreso -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($pf -and -not [string]::IsNullOrWhiteSpace($pf.fase)) { $faseFin = "$($pf.fase)" }
                }
            } catch {}
            $nInc = 0
            if ($faseFin -match '(\d+)\s+incidencia') { $nInc = [int]$Matches[1] }
            $peto = ($codigo -ne 0 -and $codigo -ne 2 -and $nInc -eq 0)
            $detalleError = ""; $resumenError = ""
            try {
                if ($script:rutaErrorMontaje -and (Test-Path -LiteralPath $script:rutaErrorMontaje)) {
                    $detalleError = Get-Content -LiteralPath $script:rutaErrorMontaje -Raw -Encoding UTF8
                    $resumenError = @($detalleError -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)[0]
                    $resumenError = ("$resumenError" -replace '^Mensaje:\s*', '').Trim()
                    if ($resumenError.Length -gt 180) { $resumenError = $resumenError.Substring(0, 177) + "..." }
                }
            } catch {}
            if ($codigo -eq 0 -and $nInc -eq 0) {
                $ui.lblProgreso.Text = "Proceso finalizado."
                $msgFin = "✓  El montaje ha finalizado. Revisa la carpeta y el log."; $tipoFin = "ok"
            } elseif ($peto) {
                if ($resumenError) {
                    $ui.lblProgreso.Text = "El montaje falló: $resumenError"
                    $msgFin = "✖  El montaje FALLÓ: $resumenError  Revisa el log."; $tipoFin = "error"
                } else {
                    $ui.lblProgreso.Text = "El montaje falló (código $codigo)."
                    $msgFin = "✖  El montaje FALLÓ (código $codigo) y se cortó antes de terminar. Revisa el log."; $tipoFin = "error"
                }
            } else {
                $txtInc = if ($nInc -gt 0) { "$nInc incidencia(s)" } else { "incidencias" }
                $ui.lblProgreso.Text = "Terminado con $txtInc — revisa el log."
                $msgFin = "⚠  Terminó con ${txtInc}: algún archivo falló y puede que NO se haya creado el pack/torrent. Revisa el log."; $tipoFin = "warn"
            }
            try {
                Log-Sec "MONTAJE · finalizado"
                Log-Linea "Código de salida del motor: $codigo | incidencias: $nInc | fase final: $faseFin"
                if ($detalleError) { Log-Bloque "ERROR FATAL DEL MOTOR" $detalleError }
                Anexar-LogMontaje $script:logCarpeta
            } catch {}
            $script:procMontaje = $null
            if ($script:montajeLifetime) { $script:montajeLifetime.Dispose(); $script:montajeLifetime=$null }
            # ¿Quedan trabajos en cola? Arrancar el SIGUIENTE automáticamente (uno tras otro, nunca
            # en paralelo). Así se cumple lo pedido: lanzar varios y que se vayan encolando.
            if (@($script:colaMontaje).Count -gt 0) {
                $sig = @($script:colaMontaje)[0]
                $script:colaMontaje = @(@($script:colaMontaje) | Select-Object -Skip 1)
                Set-Estado "$msgFin  Lanzando el siguiente de la cola (quedan $(@($script:colaMontaje).Count) después)…" $tipoFin
                Arrancar-JobMontaje $sig
            } else {
                Set-Estado $msgFin $tipoFin
            }
        }
    })
    $script:timerProgreso = $t
    $t.Start()
}

# Contenido del botón de consola con iconos de "campo de contraseña": ojo (E7B3) para mostrar,
# ojo tachado (ED1A) para ocultar. Fuente Segoe Fluent Icons (Win11) para el glifo tachado nítido.
function Set-ContenidoConsola($consolaVisible) {
    if (-not $ui.btnConsola) { return }
    $glifo = if ($consolaVisible) { [char]0xED1A } else { [char]0xE7B3 }
    $rotulo = if ($consolaVisible) { "  Ocultar consola" } else { "  Mostrar consola" }
    $tb = New-Object System.Windows.Controls.TextBlock
    $rg = New-Object System.Windows.Documents.Run ([string]$glifo)
    $rg.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets")
    $rt = New-Object System.Windows.Documents.Run $rotulo
    [void]$tb.Inlines.Add($rg); [void]$tb.Inlines.Add($rt)
    $ui.btnConsola.Content = $tb
}
# Mostrar/ocultar la ventana de consola del montaje en curso (vía fichero-bandera).
$ui.btnConsola.Add_Click({
    if (-not $script:rutaFlagCons) { return }
    $script:consolaVisible = -not $script:consolaVisible
    $txt = if ($script:consolaVisible) { "1" } else { "0" }
    try { Set-Content -LiteralPath $script:rutaFlagCons -Value $txt -Encoding ASCII } catch {}
    Set-ContenidoConsola $script:consolaVisible
})

# Dejar el programa en blanco: borra carpeta, análisis y todas las opciones marcadas,
# como recién abierto. No toca un montaje en curso ni las credenciales de Ajustes.
function Actualizar-HistorialVisible {
    $script:historialVisible = @(Get-HdzHistory 30)
    $script:panHistorial.Children.Clear()
    foreach ($entry in $script:historialVisible) {
        $row = [Windows.Controls.StackPanel]::new(); $row.Margin='0,8,0,8'
        $text = [Windows.Controls.TextBox]::new(); $text.IsReadOnly=$true; $text.TextWrapping='Wrap'; $text.Background='#17171C'; $text.Foreground='White'; $text.BorderThickness=0
        $text.Text = "$($entry.date) · $($entry.status)`n$($entry.video)`n$($entry.torrent)"
        [void]$row.Children.Add($text)
        $path = if ($entry.video) { "$($entry.video)" } else { "$($entry.torrent)" }
        if ($path) {
            $open = [Windows.Controls.Button]::new(); $open.Content='Abrir carpeta del resultado'; $open.Tag=$path
            $open.Add_Click({ param($sender) if (Test-Path -LiteralPath $sender.Tag) { Start-Process explorer.exe -ArgumentList ('/select,"' + $sender.Tag + '"') } else { Set-Estado 'El resultado ya no está en su ruta guardada.' 'warn' } })
            [void]$row.Children.Add($open)
        }
        [void]$script:panHistorial.Children.Add($row)
    }
    if ($script:historialVisible.Count -eq 0) { $empty=[Windows.Controls.TextBlock]::new(); $empty.Text='Todavía no hay trabajos guardados.'; $empty.Foreground='White'; [void]$script:panHistorial.Children.Add($empty) }
}
$script:historialVisible = @()
$script:panHistorial = [Windows.Controls.StackPanel]::new()
$script:expHistorial = [Windows.Controls.Expander]::new(); $script:expHistorial.Header='Historial de resultados · ver rutas guardadas'; $script:expHistorial.Foreground='White'; $script:expHistorial.Margin='0,16,0,8'; $script:expHistorial.Content=$script:panHistorial
$script:expHistorial.Add_Expanded({ Actualizar-HistorialVisible })
[void]$ui.panGeneral.Children.Add($script:expHistorial)
function Reset-Todo {
    if ($script:networkBusy) { throw 'Espera a que termine la petición de red antes de reiniciar; no se duplica ni interrumpe una subida incierta.' }
    $script:timerIdiomasManuales.Stop()
    $script:idiomasManuales = @{}
    $script:remixPresentationKey = $null
    $script:remixPresentation = @()
    if ($script:remixPairsPanel) { $script:remixPairsPanel.Children.Clear() }
    Remove-HdzJobConfig $script:colaMontaje
    # Detener el lector antes de cancelar: un resultado antiguo no puede resucitar el lote.
    if ($script:timerProgreso) { $script:timerProgreso.Stop() }
    if ($script:procMontaje -and -not $script:procMontaje.HasExited) {
        $script:colaMontaje = @()
        $script:procMontaje.Kill($true)
        if (-not $script:procMontaje.WaitForExit(5000)) { throw 'El montaje aún se está deteniendo. No se ha vaciado su estado.' }
        $script:procMontaje = $null
    }
    $script:procMontaje = $null
    if ($script:montajeLifetime) { $script:montajeLifetime.Dispose(); $script:montajeLifetime=$null }
    $script:rutaProgreso = $null; $script:rutaResultados = $null; $script:rutaFlagCons = $null
    $script:rutaErrorMontaje = $null; $script:resultadosLeidos = 0; $script:ultimaFaseLog = ''
    $script:consolaVisible = $false
    Set-ContenidoConsola $false
    $script:historialVisible = @(); $script:panHistorial.Children.Clear(); $script:expHistorial.IsExpanded=$false
    # Detener trabajos de ANÁLISIS pendientes: el resultado de un escaneo antiguo no puede volver a
    # rellenar la interfaz después de haber pulsado «Empezar de Zero».
    $script:scanGen++
    try { $script:debounceTimer.Stop() } catch {}
    try { $script:pollTimer.Stop() } catch {}
    try { if ($script:scanPS -and $script:scanAsync -and -not $script:scanAsync.IsCompleted) { $script:scanPS.Stop() } } catch {}
    try { if ($script:scanPS) { $script:scanPS.Dispose() } } catch {}
    $script:scanPS = $null; $script:scanAsync = $null

    # También se cancelan las tareas auxiliares de la ficha (capturas, subida de imágenes y
    # creación del torrent). Si se dejan vivas, pueden terminar más tarde y rellenar de nuevo
    # una subida que el usuario ya había borrado con este reinicio.
    try { $script:subTimer.Stop() } catch {}
    try { if ($script:subPS -and $script:subAsync -and -not $script:subAsync.IsCompleted) { $script:subPS.Stop() } } catch {}
    try { if ($script:subPS) { $script:subPS.Dispose() } } catch {}
    $script:subPS = $null; $script:subAsync = $null; $script:subSync = $null; $script:subOnComplete = $null; $script:subBotones = @()
    try { $script:capTimer.Stop() } catch {}
    try { if ($script:capPS -and $script:capAsync -and -not $script:capAsync.IsCompleted) { $script:capPS.Stop() } } catch {}
    try { if ($script:capPS) { $script:capPS.Dispose() } } catch {}
    $script:capPS = $null; $script:capAsync = $null; $script:capSync = $null; $script:capTabInicio = $null
    try { $script:torTimer.Stop() } catch {}
    try { if ($script:torPS -and $script:torAsync -and -not $script:torAsync.IsCompleted) { $script:torPS.Stop() } } catch {}
    try { if ($script:torPS) { $script:torPS.Dispose() } } catch {}
    $script:torPS = $null; $script:torAsync = $null; $script:torSync = $null; $script:torVideoHint = $null; $script:torPreparando = $false

    # General / carpeta / análisis
    $script:carpetasTemporadas = @()
    $script:cambioCarpetaInterno = $true
    try { $ui.txtCarpeta.Text = "" } finally { $script:cambioCarpetaInterno = $false }
    Actualizar-DescripcionCarpetas
    $script:ultimoScan = @()
    $script:audioTracksExcluded=@{};$script:audioTrackRows=@();if($ui.panAudioTracks){$ui.panAudioTracks.Children.Clear();$ui.cardAudioTracks.Visibility='Collapsed'}
    $script:seleccion = @{}
    $script:carpetaScan = $null
    $script:restringirSeleccion = $null
    $script:gruposLote = @(); $script:gruposRender = $null; $script:clavesHibRender = @()
    $script:videosElegidos = @()
    $script:gruposProy = @(); $script:tabsProy = @(); $script:tabProyActual = -1
    $script:gruposLanzados = @{}; $script:episodiosMap = @{}; $script:salidaMap = @{}
    $script:epTextboxes = @{}; $script:salidaBtns = @{}
    $ui.panListado.Children.Clear()
    $ui.lblResumen.Text = ""
    Reset-Adaptacion

    # Remezcla: filas, roles, resumen y chips de pistas. Antes se conservaban estas filas ocultas
    # y reaparecían al volver a activar el interruptor.
    $script:remezclaCarpetas = @(); $script:remixScanActivo = $false; $script:remixScanCrudo = @(); $script:remixScanFolders = @()
    $script:remezclaChipsAudio = @(); $script:remezclaChipsSub = @()
    $ui.panRemezclaCarpetas.Children.Clear(); $ui.panRemezclaInfo.Children.Clear()
    $ui.panRemezclaAudios.Children.Clear(); $ui.panRemezclaSubs.Children.Clear(); $ui.panRemezclaPistas.Visibility = "Collapsed"
    $ui.lblRemezclaInfo.Text = ""; $ui.swRemezcla.IsChecked = $false
    # El cambio del interruptor puede haber programado un refresco automático; no debe resucitar
    # un análisis anterior cuando el usuario ha pedido empezar completamente de cero.
    try { $script:debounceTimer.Stop() } catch {}

    # Todos los grupos de chips de procesamiento a su opción por defecto (índice 0).
    # Se excluye "hostImg" porque es configuración (pestaña Ajustes), no una selección.
    foreach ($nombre in @($script:gruposChips.Keys)) {
        if ($nombre -eq "hostImg") { continue }
        $lista = $script:gruposChips[$nombre]
        if (@($lista).Count -gt 0) { $lista[0].Radio.IsChecked = $true }
    }

    # Datos del proyecto (siempre activos: la GUI los define y los envía, sin prompts en consola)
    $ui.swProyecto.IsChecked = $true
    $ui.swSerie.IsChecked = $false
    $ui.swAplicarTodos.IsChecked = $true
    $ui.txtTitulo.Text = ""; $ui.txtAno.Text = ""
    $script:tituloAutoVal = ""; $script:anoAutoVal = ""; $script:serieAutoVal = $null; $script:carpetaIdentificada = ""
    $ui.txtPlataformaOtra.Text = ""; $ui.txtFormatoOtro.Text = ""; $ui.txtEtiquetas.Text = ""
    $ui.txtTemporadaEp.Text = ""; $ui.txtPrimerEp.Text = ""
    if ($ui.cmbPlataforma.Items.Count -gt 0) { $ui.cmbPlataforma.SelectedIndex = 0 }
    if ($ui.cmbFormato.Items.Count -gt 0) { $ui.cmbFormato.SelectedIndex = 0 }
    Set-ComboValor $ui.cmbNumCapturas 6
    Set-ComboValor $ui.cmbEpsPorVideo 1

    # Torrent (la URL de anuncio NO se borra: es configuración persistente de Ajustes)
    $ui.txtPackNombre.Text = ""
    $ui.txtLogoPersonalizado.Text = ""
    $ui.txtSalidaArchivo.Text = ""; $ui.txtSalidaTorrent.Text = ""

    # Subida al tracker
    $ui.txtTorrentSubir.Text = ""
    $ui.lblTorrentInfo.Text = ""
    $script:videoSubir = $null; $script:videosPackSubir = @()
    $script:urlTorrentWeb = ""; $script:rutaTorrentTracker = ""
    $script:torrentRemotoId = 0; $script:torrentRemotoNombre = ""
    if ($ui.btnVerWeb) { $ui.btnVerWeb.Visibility = "Collapsed" }
    if ($ui.btnAbrirTorrent) { $ui.btnAbrirTorrent.Visibility = "Collapsed" }
    $ui.upTitulo.Text = ""; $ui.upKeywords.Text = ""
    $ui.upTmdb.Text = ""; $ui.upImdb.Text = ""; $ui.upTvdb.Text = ""; $ui.upMal.Text = ""
    $ui.upTemporada.Text = ""; $ui.upEpisodio.Text = ""
    $ui.upMediainfo.Text = ""; $ui.upNfo.Text = ""
    $script:tmdbTipo = "movie"; $script:ultimoTmdbAplicado = ""; $ui.panTV.Visibility = "Collapsed"
    if ($ui.upCategoria.Items.Count -gt 0) { $ui.upCategoria.SelectedIndex = 0 }
    if ($ui.upTipo.Items.Count -gt 0) { $ui.upTipo.SelectedIndex = 0 }
    if ($ui.upResolucion.Items.Count -gt 0) { $ui.upResolucion.SelectedIndex = 0 }
    foreach ($cb in @("upAnon","upPersonal","upAudioEd","upProper","upDV","upHDR10P","upHDR10","upModQueue")) {
        if ($ui[$cb]) { $ui[$cb].IsChecked = $false }
    }
    $ui.panResultadosTmdb.Children.Clear()
    $script:capRows = @(); $script:logosActuales = @(); $script:logoSel = $null
    $ui.panLogos.Children.Clear()
    $ui.cardLogos.Visibility = "Visible"
    $ui.panCapturas.Children.Clear()
    $script:firmaSel = $null
    Refresh-FirmaSel
    Reset-Descripcion
    if (Get-Command Init-Tabs -ErrorAction SilentlyContinue) { Init-Tabs }   # una sola subida en blanco
    if (Get-Command Construir-TabBarProy -ErrorAction SilentlyContinue) { Construir-TabBarProy }
    $script:agBrowse = $null; $script:agCapThumbs = @{}
    $script:capPreviewCache=@{};$script:capPreviewSync=$null
    $script:tmdbSearchResults = @()
    # Lo que aún no había arrancado deja de ser una intención del usuario tras un reinicio total.
    $script:colaMontaje = @()

    # Refrescos de visibilidad dependientes
    Actualizar-Proyecto
    Actualizar-Filtro
    Actualizar-Torrent
    Actualizar-TipoCategoria
    Actualizar-PanelHost

    # Barras y botones de tareas auxiliares: su trabajo ya se ha cancelado arriba.
    $ui.panTorrentProgreso.Visibility = "Collapsed"; $ui.barTorrentProgreso.Value = 0
    $ui.lblTorrentProgreso.Text = ""; $ui.lblTorrentProgresoPct.Text = "0%"
    $ui.panSubProgreso.Visibility = "Collapsed"; $ui.barSubProgreso.Value = 0
    $ui.lblSubProgreso.Text = ""; $ui.lblSubProgresoPct.Text = "0%"
    foreach ($b in @($ui.btnCrearTorrentArchivo, $ui.btnCrearTorrentCarpeta, $ui.btnTorrentExaminar, $ui.btnTorrentUltimo, $ui.btnCapGenerar, $ui.btnCapInsertar, $ui.btnCapAnadir)) { if ($b) { $b.IsEnabled = $true } }
    Actualizar-PanelTareasAux

    # Si no hay montaje en curso, ocultar la barra de progreso
    if (-not ($script:procMontaje -and -not $script:procMontaje.HasExited)) {
        $ui.panProgreso.Visibility = "Collapsed"
        $ui.panProgreso2.Visibility = "Collapsed"
        $ui.barProgreso.Value = 0; $ui.barProgreso2.Value = 0
        $ui.lblProgreso.Text = ""; $ui.lblProgreso2.Text = ""
        $ui.lblProgresoPct.Text = "0%"; $ui.lblProgreso2Pct.Text = "0%"
        $ui.btnConsola.IsEnabled = $false
    }

    if ($script:workspaceReady) { Set-HdzWorkspaceStage 'general' }
    Set-Estado "Programa reiniciado. Elige una carpeta de vídeos para empezar."
}

# =========================================================================
# DIÁLOGO MODAL CON EL ESTILO DE LA GUI (sustituye a los MessageBox nativos)
# =========================================================================
# Devuelve $true si el usuario confirma (Sí / botón principal), $false si cancela.
# Si -BotonNo queda vacío, se muestra un único botón (modo "aceptar").
function Show-DialogoHDZ {
    param(
        [string]$Titulo,
        [string]$Mensaje,
        [string]$Icono   = "",
        [string]$BotonSi = "Sí",
        [string]$BotonNo = "No",
        [System.Windows.Window]$Owner = $null
    )
    $soloOk = [string]::IsNullOrEmpty($BotonNo)
    $xamlDlg = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        SizeToContent="Height" Width="470" ResizeMode="NoResize" ShowInTaskbar="False"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>
    <Style x:Key="P" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="#D92B2B" CornerRadius="9" Padding="22,10">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#EF4444"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#A81E1E"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="G" TargetType="Button">
      <Setter Property="Foreground" Value="#C8C8CE"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="#1A1A1F" BorderBrush="#2E2E35" BorderThickness="1" CornerRadius="9" Padding="20,10">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#D92B2B"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Background="#131316" BorderBrush="#2E2E35" BorderThickness="1" CornerRadius="14" Margin="16">
    <Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="7" Opacity="0.55" Color="#000000"/></Border.Effect>
    <StackPanel Margin="28,24,28,22">
      <DockPanel x:Name="barra" LastChildFill="True" Margin="0,0,0,16">
        <TextBlock x:Name="lblIcono" FontSize="22" VerticalAlignment="Center" Margin="0,0,12,0" DockPanel.Dock="Left"/>
        <TextBlock x:Name="lblTitulo" Foreground="#EDEDEF" FontSize="16.5" FontWeight="SemiBold" VerticalAlignment="Center" TextWrapping="Wrap"/>
      </DockPanel>
      <ScrollViewer MaxHeight="360" VerticalScrollBarVisibility="Auto" Margin="0,0,0,24">
        <TextBlock x:Name="lblCuerpo" Foreground="#9C9CA8" FontSize="13.5" TextWrapping="Wrap" LineHeight="21" Margin="0,0,8,0"/>
      </ScrollViewer>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="btnNo" Style="{StaticResource G}" Margin="0,0,10,0"/>
        <Button x:Name="btnSi" Style="{StaticResource P}"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Parse($xamlDlg)
    $g = @{}
    foreach ($n in @("barra","lblIcono","lblTitulo","lblCuerpo","btnSi","btnNo")) { $g[$n] = $dlg.FindName($n) }
    $g.lblIcono.Text  = $Icono
    if (-not $Icono) { $g.lblIcono.Visibility = "Collapsed" }
    $g.lblTitulo.Text = $Titulo
    $g.lblCuerpo.Text = $Mensaje
    $g.btnSi.Content  = $BotonSi
    $g.btnSi.IsDefault = $true
    if ($soloOk) {
        $g.btnNo.Visibility = "Collapsed"
    } else {
        $g.btnNo.Content = $BotonNo
        $g.btnNo.IsCancel = $true
        $g.btnNo.Add_Click({ $dlg.DialogResult = $false }.GetNewClosure())
    }
    $g.btnSi.Add_Click({ $dlg.DialogResult = $true }.GetNewClosure())
    # Permitir arrastrar la ventana sin barra de título (clic sobre la cabecera).
    $g.barra.Add_MouseLeftButtonDown({ try { $dlg.DragMove() } catch {} }.GetNewClosure())
    if ($Owner) {
        $dlg.Owner = $Owner
        $dlg.WindowStartupLocation = "CenterOwner"
    } else {
        $dlg.WindowStartupLocation = "CenterScreen"
    }
    $res = $dlg.ShowDialog()
    return [bool]$res
}

# =========================================================================
# Ventana de BIENVENIDA (primer arranque): pide las credenciales del usuario.
# Las claves se guardan SOLO en %APPDATA% (nunca viajan con el programa). Se
# muestra una vez, cuando aún no hay token de tracker configurado.
# =========================================================================
function Show-Bienvenida {
    param([System.Windows.Window]$Owner = $null)
    $xamlB = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        SizeToContent="Height" Width="580" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>
    <Style x:Key="In" TargetType="TextBox">
      <Setter Property="Background" Value="#0E0E11"/>
      <Setter Property="Foreground" Value="#EDEDEF"/>
      <Setter Property="CaretBrush" Value="#EDEDEF"/>
      <Setter Property="BorderBrush" Value="#242429"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#D92B2B"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="P" TargetType="Button">
      <Setter Property="Foreground" Value="White"/><Setter Property="FontSize" Value="13.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="bd" Background="#D92B2B" CornerRadius="9" Padding="22,10"><ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/></Border>
          <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#EF4444"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="G" TargetType="Button">
      <Setter Property="Foreground" Value="#C8C8CE"/><Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="bd" Background="#1A1A1F" BorderBrush="#2E2E35" BorderThickness="1" CornerRadius="9" Padding="20,10"><ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/></Border>
          <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#D92B2B"/><Setter Property="Foreground" Value="White"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Lb" TargetType="TextBlock"><Setter Property="Foreground" Value="#EDEDEF"/><Setter Property="FontSize" Value="12.5"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="2,0,0,5"/></Style>
    <Style x:Key="Hn" TargetType="TextBlock"><Setter Property="Foreground" Value="#9C9CA8"/><Setter Property="FontSize" Value="11.5"/><Setter Property="Margin" Value="2,4,0,14"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
  </Window.Resources>
  <Border Background="#131316" BorderBrush="#2E2E35" BorderThickness="1" CornerRadius="14" Margin="16">
    <Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="7" Opacity="0.55" Color="#000000"/></Border.Effect>
    <StackPanel Margin="30,26,30,24">
      <StackPanel x:Name="barra" Margin="0,0,0,4">
        <TextBlock Text="Bienvenido a HD ZERO Studio" Foreground="#EDEDEF" FontSize="18" FontWeight="SemiBold"/>
        <TextBlock Text="Configura tus credenciales para empezar." Foreground="#9C9CA8" FontSize="13" Margin="0,2,0,0"/>
      </StackPanel>
      <Border Background="#101013" BorderBrush="#242429" BorderThickness="1" CornerRadius="9" Padding="12,9" Margin="0,14,0,18">
        <TextBlock Foreground="#9C9CA8" FontSize="12" TextWrapping="Wrap"
          Text="🔒  Se guardan SOLO en tu equipo (%APPDATA%). Nunca se comparten ni viajan con el programa. Podrás cambiarlas cuando quieras en «Ajustes / claves»."/>
      </Border>

      <TextBlock Style="{StaticResource Lb}" Text="URL del tracker"/>
      <TextBox x:Name="bUrl" Style="{StaticResource In}"/>
      <TextBlock Style="{StaticResource Hn}" Text="Por defecto: https://hdzero.org"/>

      <TextBlock Style="{StaticResource Lb}" Text="Token de la API (api_token)"/>
      <TextBox x:Name="bTok" Style="{StaticResource In}"/>
      <TextBlock Style="{StaticResource Hn}" Text="En HDZERO → tu perfil → Configuración → Seguridad."/>

      <TextBlock Style="{StaticResource Lb}" Text="URL de anuncio (announce, con tu passkey)"/>
      <TextBox x:Name="bAnn" Style="{StaticResource In}"/>
      <TextBlock Style="{StaticResource Hn}" Text="La que usas para subir torrents (incluye tu passkey personal)."/>

      <TextBlock Style="{StaticResource Lb}" Text="Clave o token de TMDB (opcional)"/>
      <TextBox x:Name="bTmdb" Style="{StaticResource In}"/>
      <TextBlock Style="{StaticResource Hn}" Text="Para la búsqueda automática. themoviedb.org → Ajustes → API. Puedes dejarlo vacío."/>

      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,6,0,0">
        <Button x:Name="bSkip" Style="{StaticResource G}" Content="Ahora no" Margin="0,0,10,0"/>
        <Button x:Name="bSave" Style="{StaticResource P}" Content="Guardar y empezar"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    $b = [Windows.Markup.XamlReader]::Parse($xamlB)
    $g = @{}
    foreach ($n in @("barra","bUrl","bTok","bAnn","bTmdb","bSkip","bSave")) { $g[$n] = $b.FindName($n) }
    # Prefijar con lo que ya hubiera (normalmente vacío en un PC nuevo).
    $g.bUrl.Text  = if (-not [string]::IsNullOrWhiteSpace($ui.cfgTrackerUrl.Text)) { $ui.cfgTrackerUrl.Text } else { "https://hdzero.org" }
    $g.bTok.Text  = "$($ui.cfgTrackerToken.Text)"
    $g.bAnn.Text  = "$($ui.txtAnnounce.Text)"
    $g.bTmdb.Text = "$($ui.cfgTmdbKey.Text)"
    $g.barra.Add_MouseLeftButtonDown({ try { $b.DragMove() } catch {} }.GetNewClosure())
    $g.bSave.IsDefault = $true
    $g.bSave.Add_Click({
        $ui.cfgTrackerUrl.Text   = "$($g.bUrl.Text)".Trim()
        $ui.cfgTrackerToken.Text = "$($g.bTok.Text)".Trim()
        $ui.txtAnnounce.Text     = "$($g.bAnn.Text)".Trim()
        $ui.cfgTmdbKey.Text      = "$($g.bTmdb.Text)".Trim()
        $script:bienvenidaVista = $true
        Guardar-Ajustes
        $b.DialogResult = $true
    }.GetNewClosure())
    $g.bSkip.IsCancel = $true
    $g.bSkip.Add_Click({
        $script:bienvenidaVista = $true   # no volver a molestar; se configura en Ajustes
        Guardar-Ajustes
        $b.DialogResult = $false
    }.GetNewClosure())
    if ($Owner) { $b.Owner = $Owner; $b.WindowStartupLocation = "CenterOwner" }
    [void]$b.ShowDialog()
}

# Pop-up OBLIGATORIO de nombre de usuario: no se puede cerrar ni saltar; sin un nombre, no se
# puede usar el programa. Se muestra al arrancar mientras no haya un usuario establecido.
function Show-UsuarioObligatorio {
    param([System.Windows.Window]$Owner = $null)
    $xamlU = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        SizeToContent="Height" Width="520" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>
    <Style x:Key="In" TargetType="TextBox">
      <Setter Property="Background" Value="#0E0E11"/><Setter Property="Foreground" Value="#EDEDEF"/>
      <Setter Property="CaretBrush" Value="#EDEDEF"/><Setter Property="BorderBrush" Value="#242429"/>
      <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="10,8"/><Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
          </Border>
          <ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#D92B2B"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="P" TargetType="Button">
      <Setter Property="Foreground" Value="White"/><Setter Property="FontSize" Value="13.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="bd" Background="#D92B2B" CornerRadius="9" Padding="26,10"><ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/></Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#EF4444"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Background" Value="#3A2326"/><Setter Property="Foreground" Value="#8A8A92"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Lb" TargetType="TextBlock"><Setter Property="Foreground" Value="#EDEDEF"/><Setter Property="FontSize" Value="12.5"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="2,0,0,5"/></Style>
  </Window.Resources>
  <Border Background="#131316" BorderBrush="#2E2E35" BorderThickness="1" CornerRadius="14" Margin="16">
    <Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="7" Opacity="0.55" Color="#000000"/></Border.Effect>
    <StackPanel Margin="30,26,30,24">
      <StackPanel x:Name="barra">
        <TextBlock Text="Antes de empezar" Foreground="#EDEDEF" FontSize="18" FontWeight="SemiBold"/>
        <TextBlock Text="Establece un nombre de usuario para poder usar el programa." Foreground="#9C9CA8" FontSize="13" Margin="0,2,0,0" TextWrapping="Wrap"/>
      </StackPanel>
      <Border Background="#101013" BorderBrush="#242429" BorderThickness="1" CornerRadius="9" Padding="12,9" Margin="0,14,0,16">
        <TextBlock Foreground="#9C9CA8" FontSize="12" TextWrapping="Wrap"
          Text="👤  Preferiblemente, usa tu usuario de Telegram o el del tracker. Así el soporte podrá identificarte si pides ayuda o envías un log."/>
      </Border>
      <TextBlock Style="{StaticResource Lb}" Text="Nombre de usuario"/>
      <TextBox x:Name="uNom" Style="{StaticResource In}"/>
      <TextBlock x:Name="uErr" Foreground="#E0A422" FontSize="11.5" Margin="2,7,0,0" TextWrapping="Wrap" Text=""/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
        <Button x:Name="uSave" Style="{StaticResource P}" Content="Continuar"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    $w = [Windows.Markup.XamlReader]::Parse($xamlU)
    $g = @{}
    foreach ($n in @("barra","uNom","uSave","uErr")) { $g[$n] = $w.FindName($n) }
    $g.uNom.Text = "$($ui.cfgUsuarioSoporte.Text)"
    $g.barra.Add_MouseLeftButtonDown({ try { $w.DragMove() } catch {} }.GetNewClosure())
    # El botón "Continuar" solo se habilita cuando hay un nombre escrito.
    $refrescar = { $g.uSave.IsEnabled = -not [string]::IsNullOrWhiteSpace($g.uNom.Text) }.GetNewClosure()
    & $refrescar
    $g.uNom.Add_TextChanged($refrescar)
    $g.uSave.IsDefault = $true
    $g.uSave.Add_Click({
        $val = "$($g.uNom.Text)".Trim()
        if ([string]::IsNullOrWhiteSpace($val)) { $g.uErr.Text = "Escribe un nombre de usuario para poder continuar."; return }
        $ui.cfgUsuarioSoporte.Text = $val
        Guardar-Ajustes
        $w.Tag = "ok"     # marca en el PROPIO objeto ventana (evita la trampa de $script: con GetNewClosure)
        $w.Close()
    }.GetNewClosure())
    # No se puede cerrar sin nombre: se cancela cualquier intento de cierre (X no hay; Alt+F4 se anula).
    # El handler lee la marca del 'sender' (la ventana), no de $script:, para que el cierre funcione.
    $w.Add_Closing({ param($s, $e) if ("$($s.Tag)" -ne "ok") { $e.Cancel = $true } })
    # ESC no cierra.
    $w.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $e.Handled = $true } })
    if ($Owner) { $w.Owner = $Owner; $w.WindowStartupLocation = "CenterOwner" }
    [void]$g.uNom.Focus()
    [void]$w.ShowDialog()
}

$ui.btnReset.Add_Click({
    $ok = Show-DialogoHDZ -Owner $win -Icono "🗑" -Titulo "Empezar de Zero" `
        -Mensaje "Se borrará la carpeta seleccionada y todas las opciones marcadas, dejando el programa como recién abierto.`n`nNo se borra ningún archivo del disco ni tus credenciales de Ajustes.`n`n¿Continuar?" `
        -BotonSi "Sí, empezar de Zero" -BotonNo "Cancelar"
    if ($ok) { Reset-Todo }
})

# =========================================================================
# ARRANQUE
# =========================================================================
Add-Type -Namespace HdzNative -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
'@
# API para fijar el icono NATIVO de la ventana (WM_SETICON) con los frames reales del .ico.
# Es más fiable que Window.Icon (que escalaba un frame pequeño → icono diminuto en la barra).
Add-Type -Namespace HdzNative -Name IconApi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr LoadImage(System.IntPtr hinst, string lpszName, uint uType, int cx, int cy, uint fuLoad);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, int Msg, System.IntPtr wParam, System.IntPtr lParam);
'@
# Fija el icono NATIVO (WM_SETICON) en el HWND ACTUAL de la ventana. Hay que poder reaplicarlo:
# cambiar ShowInTaskbar recrea el HWND y se pierde el icono puesto en el anterior (la barra de
# tareas se quedaba sin icono, p. ej. durante el pop-up de usuario al arrancar).
function Set-IconoNativo($w) {
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($w)).Handle
        if ($h -eq [IntPtr]::Zero) { return }
        $rutaIco = Join-Path $PSScriptRoot "HDZ.ico"
        if (-not (Test-Path -LiteralPath $rutaIco)) { return }
        $IMAGE_ICON = 1; $LR_LOADFROMFILE = 0x10; $WM_SETICON = 0x80
        $hBig   = [HdzNative.IconApi]::LoadImage([IntPtr]::Zero, $rutaIco, $IMAGE_ICON, 64, 64, $LR_LOADFROMFILE)
        $hSmall = [HdzNative.IconApi]::LoadImage([IntPtr]::Zero, $rutaIco, $IMAGE_ICON, 16, 16, $LR_LOADFROMFILE)
        if ($hBig   -ne [IntPtr]::Zero) { [void][HdzNative.IconApi]::SendMessage($h, $WM_SETICON, [IntPtr]1, $hBig) }
        if ($hSmall -ne [IntPtr]::Zero) { [void][HdzNative.IconApi]::SendMessage($h, $WM_SETICON, [IntPtr]0, $hSmall) }
    } catch {}
}
# Estado del proceso de montaje en curso y de su consola (oculta por defecto).
$script:procMontaje   = $null
$script:rutaFlagCons  = $null   # fichero-bandera: "1" visible / "0" oculta
$script:rutaProgreso  = $null   # JSON de progreso que escribe HDZnew.ps1
$script:rutaErrorMontaje = $null # detalle de un error fatal del launcher/motor
$script:consolaVisible = $false
$script:timerProgreso = $null

$win.Add_SourceInitialized({
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        $oscuro = 1
        [void][HdzNative.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$oscuro, 4)
        [void][HdzNative.Dwm]::DwmSetWindowAttribute($h, 19, [ref]$oscuro, 4)
        # Icono nativo desde HDZ.ico (frames reales 64/16 → nítido en barra de tareas y título).
        Set-IconoNativo $win
    } catch {}
})
# Al cargar: como el proceso arranca oculto (vía .vbs), el botón de la barra de tareas a veces no
# se registra hasta que la ventana cambia de estado. Forzamos el registro y traemos la ventana al
# frente recreando el botón (ShowInTaskbar off→on) y activándola.
# --- Comprobación de actualizaciones (GitHub) — no bloqueante ---
function Get-VersionLocal {
    return $script:HDZVersion
}
if ($ui.lblVersion) { $ui.lblVersion.Text = "v$(Get-VersionLocal)" }
$script:updTimer = $null; $script:updSync = $null; $script:updPS = $null; $script:updAsync = $null
$script:updVersion=''; $script:updRequested=$false; $script:updCommandId=''
$script:updPollTimer=$null; $script:updRequestTimer=$null; $script:updLastCheck=[datetime]::MinValue
function Test-HdzUpdateBusy {
    return [bool]($script:networkBusy -or ($script:procMontaje -and -not $script:procMontaje.HasExited) -or
        @($script:colaMontaje).Count -gt 0 -or ($script:scanAsync -and -not $script:scanAsync.IsCompleted) -or
        @(Get-TareasAuxiliares).Count -gt 0)
}
function Get-HdzUpdateState {
    $local=$null; $remote=$null
    $available=[version]::TryParse((Get-VersionLocal),[ref]$local) -and
        [version]::TryParse($script:updVersion,[ref]$remote) -and $remote -gt $local
    return @{available=[bool]$available;version=$script:updVersion;
        canInstall=[bool]($available -and -not $script:updRequested -and -not (Test-HdzUpdateBusy));
        requested=[bool]$script:updRequested}
}
function Update-HdzUpdateButton {
    $state=Get-HdzUpdateState
    $ui.btnActualizar.Visibility=if($state.available){'Visible'}else{'Collapsed'}
    $ui.btnActualizar.IsEnabled=$state.canInstall
    $ui.btnActualizar.ToolTip=if($state.canInstall){"Actualizar a $($state.version)"}elseif($script:updRequested){'Actualización solicitada…'}else{'Espera a que terminen los trabajos activos para actualizar'}
}
function Set-HdzUpdateVersion($manifest) {
    $version=$null
    $script:updVersion=if($manifest -and [version]::TryParse("$($manifest.version)",[ref]$version)){"$version"}else{''}
    Update-HdzUpdateButton
}
function Start-HdzUpdateInstaller {
    if($script:modoTest){throw 'El instalador real está deshabilitado en las pruebas.'}
    $upd=Join-Path $PSScriptRoot 'instalacion\Actualizar-HDZStudio.ps1'
    if(-not (Test-Path -LiteralPath $upd)){throw 'No encuentro el actualizador instalado.'}
    $necesitaAdmin=$false
    try {
        $probe=Join-Path $PSScriptRoot ('.hdz_wtest_'+[guid]::NewGuid().ToString('N')+'.tmp')
        [IO.File]::WriteAllText($probe,'x');Remove-Item -LiteralPath $probe -Force
    }catch{$necesitaAdmin=$true}
    $argsUpd=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$upd+'"'),'-WaitForProcessId',"$PID")
    $start=@{FilePath='powershell.exe';ArgumentList=$argsUpd;WindowStyle='Hidden';ErrorAction='Stop'}
    if($necesitaAdmin){throw 'Esta instalación está en una carpeta protegida. Usa la instalación por usuario para actualizar sin intervenir en el PC.'}
    Start-Process @start
}
function Close-HdzForUpdate { $win.Close() }
function Complete-HdzUpdateRequest {
    if(-not $script:updRequested){return}
    # La orden remota debe quedar confirmada en el relay ANTES de cerrar el agente.
    if($script:updCommandId -and $script:updCommandId -notin @($script:agSync.LastAckIds)){
        if(([datetime]::UtcNow-$script:updRequestedAt).TotalSeconds -lt 30){return}
        $script:updRequested=$false;$script:updRequestTimer.Stop();$win.IsEnabled=$true
        Set-Estado 'No se confirmó la orden de actualización en la web. No se ha cerrado el programa; inténtalo de nuevo.' 'warn'
        Update-HdzUpdateButton;return
    }
    $script:updRequestTimer.Stop()
    try {
        if(Test-HdzUpdateBusy){throw 'Hay un trabajo activo. Espera a que termine antes de actualizar.'}
        Guardar-Ajustes
        Start-HdzUpdateInstaller
        Close-HdzForUpdate
    }catch{
        $script:updRequested=$false;$win.IsEnabled=$true
        Set-Estado "No se pudo iniciar la actualización: $($_.Exception.Message)" 'warn'
        Update-HdzUpdateButton
    }
}
function Request-HdzUpdate([string]$CommandId='') {
    $state=Get-HdzUpdateState
    if(-not $state.available){throw 'No hay una actualización nueva confirmada.'}
    if($script:updRequested){throw 'La actualización ya está solicitada.'}
    if(-not $state.canInstall){throw 'Espera a que terminen los trabajos activos antes de actualizar.'}
    $script:updRequested=$true;$script:updCommandId=$CommandId;$script:updRequestedAt=[datetime]::UtcNow
    Set-Estado "Actualización a $($state.version) solicitada. El programa se actualizará y reabrirá automáticamente."
    $win.IsEnabled=$false;Update-HdzUpdateButton
    $script:updRequestTimer=[Windows.Threading.DispatcherTimer]::new()
    $script:updRequestTimer.Interval=[TimeSpan]::FromSeconds(2)
    $script:updRequestTimer.Add_Tick({Complete-HdzUpdateRequest})
    if(-not $script:modoTest){$script:updRequestTimer.Start()}
}
$ui.btnActualizar.Add_Click({
    try {
        if(Show-DialogoHDZ -Owner $win -Icono '↑' -Titulo 'Actualizar HDZ Studio' -Mensaje 'Se guardarán los ajustes y se cerrará el proyecto actual. El programa se actualizará y se reabrirá automáticamente. ¿Continuar?' -BotonSi 'Actualizar' -BotonNo 'Cancelar'){
            Request-HdzUpdate
        }
    }catch{Set-Estado $_.Exception.Message 'warn'}
})
function Iniciar-ChequeoActualizacion {
    if ($script:modoTest) { return }
    if($script:updSync -or $script:updRequested){return}
    $script:updLastCheck=[datetime]::UtcNow
    if(-not $script:updPollTimer){
        $script:updPollTimer=[Windows.Threading.DispatcherTimer]::new()
        $script:updPollTimer.Interval=[TimeSpan]::FromSeconds(2)
        $script:updPollTimer.Add_Tick({
            Update-HdzUpdateButton
            if(([datetime]::UtcNow-$script:updLastCheck).TotalMinutes -ge 5){Iniciar-ChequeoActualizacion}
        })
        $script:updPollTimer.Start()
    }
    $url = $null
    try {
        $cfgPath = Join-Path $PSScriptRoot "HDZ-update.config.json"
        if (-not (Test-Path -LiteralPath $cfgPath)) { return }
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        # Fuente de actualización: si hay "baseUrl" (servidor propio) se usa esa; si no, GitHub raw.
        $baseCfg = "$($cfg.baseUrl)".Trim()
        if ($baseCfg) {
            $url = ($baseCfg.TrimEnd('/')) + "/version.json"
        } else {
            $repo = "$($cfg.repo)"; $rama = "$($cfg.rama)"; if (-not $rama) { $rama = "main" }
            if ([string]::IsNullOrWhiteSpace($repo) -or $repo -like "*USUARIO/REPO*") { return }   # sin configurar → no se busca
            $url = "https://raw.githubusercontent.com/$repo/$rama/version.json"
        }
        $urls = @($url)
        foreach ($fallback in @($cfg.fallbackUrls)) {
            if ("$fallback" -notmatch '^https://') { throw 'La conexión alternativa requiere HTTPS.' }
            $urls += "$fallback".TrimEnd('/') + '/version.json'
        }
    } catch { Set-HdzUpdateVersion $null; return }

    $sync = [hashtable]::Synchronized(@{ Hecho = $false; Json = $null; Error = $null })
    $script:updSync = $sync
    $worker = {
        param($urls, $sync)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            foreach ($address in @($urls | Select-Object -Unique)) {
                for ($attempt=1; $attempt -le 2; $attempt++) {
                    try {
                        $json = Invoke-RestMethod -Uri $address -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop
                        $parsedVersion=$null
                        if (-not [version]::TryParse("$($json.version)",[ref]$parsedVersion)) { throw 'Respuesta de actualización no válida.' }
                        $sync.Json = $json
                        return
                    } catch { }
                }
            }
            $sync.Error = 'No se pudo comprobar si hay actualizaciones. Se volverá a intentar automáticamente.'
        } catch { $sync.Error = 'No se pudo comprobar si hay actualizaciones.' }
        finally { $sync.Hecho = $true }
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($worker.ToString()).AddArgument($urls).AddArgument($sync)
    $script:updPS = $ps; $script:updAsync = $ps.BeginInvoke()

    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(500)
    $t.Add_Tick({
        $s = $script:updSync
        if (-not $s -or -not $s.Hecho) { return }
        $script:updTimer.Stop()
        try { $script:updPS.EndInvoke($script:updAsync) } catch {}
        try { $script:updPS.Dispose() } catch {}
        $j = $s.Json; $script:updSync = $null
        # Sin ventanas modales al detectar una versión: el botón es el aviso.
        Set-HdzUpdateVersion $(if($s.Error){$null}else{$j})
    })
    $script:updTimer = $t; $t.Start()
}

$win.Add_Loaded({
    try {
        $win.ShowInTaskbar = $false
        $win.ShowInTaskbar = $true
        Set-IconoNativo $win   # el toggle recreó el HWND → reaplicar el icono nativo
        if ($win.WindowState -eq [System.Windows.WindowState]::Minimized) { $win.WindowState = [System.Windows.WindowState]::Normal }
        [void]$win.Activate()
        $win.Topmost = $true; $win.Topmost = $false
    } catch {}
    # Reaplicar el icono VARIAS veces desde muy pronto: en cuanto la barra de tareas crea su botón
    # (unos cientos de ms), este reenvío de WM_SETICON lo pinta. Reintentar cada 150 ms y parar al
    # cabo de ~1,5 s evita el retraso de un único tick tardío (visible sobre todo con el pop-up,
    # que bloquea Add_Loaded; el timer sí dispara en el bucle modal del diálogo).
    try {
        $script:iconoTicks = 0
        $script:tIcono = New-Object System.Windows.Threading.DispatcherTimer
        $script:tIcono.Interval = [TimeSpan]::FromMilliseconds(150)
        $script:tIcono.Add_Tick({
            $script:iconoTicks++
            try { Set-IconoNativo $win } catch {}
            if ($script:iconoTicks -ge 10) { $script:tIcono.Stop() }
        })
        $script:tIcono.Start()
    } catch {}
    # Buscar actualizaciones EN PRIMER LUGAR (red de seguridad: aunque luego se muestre un diálogo
    # modal, durante su bucle de mensajes este chequeo puede correr y ofrecer la actualización).
    try { $win.Dispatcher.InvokeAsync([action]{ Iniciar-ChequeoActualizacion }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null } catch {}
    # OBLIGATORIO antes de nada: nombre de usuario. El pop-up no se puede cerrar ni saltar; sin un
    # nombre, el programa no se puede usar. Solo aparece mientras no haya un usuario establecido.
    if (-not $script:modoTest -and [string]::IsNullOrWhiteSpace($ui.cfgUsuarioSoporte.Text)) {
        try { Show-UsuarioObligatorio -Owner $win } catch {}
    }
    # Primer arranque: si aún no hay token de tracker y no se mostró antes, guiamos al usuario con
    # la ventana de bienvenida para que ponga SUS credenciales (se guardan solo en su %APPDATA%).
    if (-not $script:modoTest -and -not $script:bienvenidaVista -and [string]::IsNullOrWhiteSpace($ui.cfgTrackerToken.Text)) {
        try { Show-Bienvenida -Owner $win } catch {}
    }
    try { Set-IconoNativo $win } catch {}   # reaplicar tras los diálogos de arranque
    if (-not $script:modoTest) {
        try {
            $updateResultPath=Join-Path $PSScriptRoot 'instalacion\ultimo-resultado.json'
            if(Test-Path -LiteralPath $updateResultPath){
                $updateResult=Get-Content -LiteralPath $updateResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                Set-Estado "$($updateResult.message)" $(if($updateResult.ok){'ok'}else{'warn'})
                Remove-Item -LiteralPath $updateResultPath -Force
            }
        } catch {}
    }
})
$win.Add_Closing({ param($sender, $eventArgs)
    if ($script:networkBusy -or ($script:procMontaje -and -not $script:procMontaje.HasExited)) {
        $eventArgs.Cancel = $true
        Set-Estado 'Hay un trabajo activo. Espera a que termine o usa «Empezar de Zero» para detenerlo conservando los archivos.' 'warn'
        return
    }
    Guardar-Ajustes
    try { Detener-Agente } catch {}
    foreach($timer in @($script:updPollTimer,$script:updTimer,$script:updRequestTimer)){if($timer){$timer.Stop()}}
    try {
        if ($script:mutexInstancia) {
            $script:mutexInstancia.ReleaseMutex()
            $script:mutexInstancia.Dispose()
            $script:mutexInstancia = $null
        }
    } catch {}
})

# =========================================================================
# AGENTE DE CONTROL REMOTO (Fase 2) — OPT-IN: solo si soporte.cfg trae "agent".
# Empuja el estado del programa al relay (/agent/sync) y aplica los comandos que
# manda el panel web. El HTTP va en un runspace aparte para no bloquear la UI; el
# estado se COMPONE en el hilo de UI y los comandos se APLICAN en el hilo de UI.
# =========================================================================
$script:agSync = $null; $script:agPS = $null; $script:agTimer = $null; $script:agBrowse = $null
$agenteWorker = {
    param($url, $key, $sync, $dbg)
    function _agl($m) { try { "[$(Get-Date -f 'HH:mm:ss')] $m" | Out-File $dbg -Append -Encoding UTF8 } catch {} }
    _agl "worker ARRANCADO url=$url keyLen=$($key.Length)"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $last = [datetime]::MinValue; $n = 0
    while (-not $sync.Stop) {
        $now = [datetime]::UtcNow
        # Empuja cada ~1,8 s O de inmediato si PushNow (tras aplicar un comando: navegar carpetas, etc.).
        if ($sync.PushNow -or ($now - $last).TotalMilliseconds -ge 1800) {
            $sync.PushNow = $false; $last = $now
            try {
                $snapshot = $sync.Estado
                if ($null -ne $snapshot) {
                    # El DTO solo contiene valores; serializar aquí deja libre el Dispatcher WPF.
                    $body = if ($snapshot -is [string]) { $snapshot } else { ConvertTo-Json -InputObject $snapshot -Depth 8 -Compress }
                    $r = Invoke-RestMethod -Uri $url -Method Post -Body $body `
                         -Headers @{ "X-HDZ-Key" = $key } -ContentType "application/json; charset=utf-8" -TimeoutSec 10
                    $sync.Online = $true
                    try { $sync.LastAckIds=@($(if($snapshot -is [string]){($body | ConvertFrom-Json)._acks}else{$snapshot._acks}) | ForEach-Object {$_.id}) } catch {}
                    if ($n -lt 2) { _agl "push OK (len=$($body.Length))" }; $n++
                    if ($r.cmds) { foreach ($c in @($r.cmds)) { [void]$sync.Cmds.Enqueue($c) } }
                } else { if ($n -lt 6) { _agl "estado VACIO, no envio" }; $n++ }
            } catch { $sync.Online = $false; _agl "push ERROR: $($_.Exception.Message)" }
        }
        Start-Sleep -Milliseconds 200
    }
}
# Lista carpetas/vídeos de una ruta del PC para el explorador del panel. Ruta vacía = unidades.
function Listar-CarpetaAgente($p, $filtro = "video") {
    $definition = 'function ReadFolder {' + (Get-Command Listar-CarpetaAgenteCore).ScriptBlock.ToString() + '}; ReadFolder $parameters.Path $parameters.Filter'
    Invoke-HdzBackground { param($parameters) & ([scriptblock]::Create($parameters.Definition)) } @{Definition=$definition;Path=$p;Filter=$filtro}
}
function Listar-CarpetaAgenteCore($p, $filtro = "video") {
    # $filtro decide que FICHEROS se listan (ademas de las subcarpetas): video (por defecto),
    # torrent, nfo o imagen. Cada fichero se devuelve como { name; path } para poder elegirlo.
    $rx = switch ("$filtro") {
        "torrent" { "(?i)^\.torrent$" }
        "nfo"     { "(?i)^\.(nfo|txt)$" }
        "imagen"  { "(?i)^\.(png|jpg|jpeg)$" }
        default   { "(?i)^\.(mkv|mp4|ts)$" }
    }
    try {
        if ([string]::IsNullOrWhiteSpace($p)) {
            $dr = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object { @{ name = "$($_.Name)"; path = "$($_.Name)" } })
            return [ordered]@{ path = ""; up = $null; dirs = $dr; files = @(); filtro = "$filtro" }
        }
        $dirs = @(Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { @{ name = "$($_.Name)"; path = "$($_.FullName)" } })
        $files = @(Get-ChildItem -LiteralPath $p -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match $rx } | Sort-Object Name | ForEach-Object { @{ name = "$($_.Name)"; path = "$($_.FullName)" } })
        $up = Split-Path $p -Parent
        return [ordered]@{ path = "$p"; up = "$up"; dirs = $dirs; files = $files; filtro = "$filtro" }
    } catch { return [ordered]@{ path = "$p"; up = ""; dirs = @(); files = @(); filtro = "$filtro"; error = "$($_.Exception.Message)" } }
}
$script:agGruposChip = @('modoLote','originales','sufijo','torrent','origen','webTipo','capturasProy','defAudio','filtro','extraerPGS','conservarPGS','hostImg')
function _agMapSwitch { @{ remezcla=$ui.swRemezcla; proyecto=$ui.swProyecto; serie=$ui.swSerie; aplicarTodos=$ui.swAplicarTodos } }
function _agMapCombo  { @{ plataforma=$ui.cmbPlataforma; formato=$ui.cmbFormato; upCategoria=$ui.upCategoria; upTipo=$ui.upTipo; upResolucion=$ui.upResolucion; numCapturas=$ui.cmbNumCapturas; epsPorVideo=$ui.cmbEpsPorVideo } }
$script:agFlags = @('upAnon','upPersonal','upAudioEd','upProper','upDV','upHDR10P','upHDR10','upModQueue')
# Inputs de texto NO secretos que se empujan al panel (los secretos van aparte y NO se envían).
function _agMapInput {
    [ordered]@{
        carpeta=$ui.txtCarpeta; titulo=$ui.txtTitulo; ano=$ui.txtAno; plataformaOtra=$ui.txtPlataformaOtra; formatoOtro=$ui.txtFormatoOtro; etiquetas=$ui.txtEtiquetas;
        salidaArchivo=$ui.txtSalidaArchivo; salidaTorrent=$ui.txtSalidaTorrent; packNombre=$ui.txtPackNombre;
        upTitulo=$ui.upTitulo; upKeywords=$ui.upKeywords; upTmdb=$ui.upTmdb; upImdb=$ui.upImdb; upTvdb=$ui.upTvdb; upMal=$ui.upMal; upTemporada=$ui.upTemporada; upEpisodio=$ui.upEpisodio; upMediainfo=$ui.upMediainfo; upDescripcion=$ui.upDescripcion; upNfo=$ui.upNfo;
        cfgTrackerUrl=$ui.cfgTrackerUrl; cfgImgboxUser=$ui.cfgImgboxUser; cfgCarpetaProcesados=$ui.cfgCarpetaProcesados; cfgCarpetaTorrent=$ui.cfgCarpetaTorrent; cfgUsuarioSoporte=$ui.cfgUsuarioSoporte;
        temporadaEp=$ui.txtTemporadaEp; primerEp=$ui.txtPrimerEp;
    }
}
function Get-CapturaThumbB64($ruta) {
    # Las capturas visibles ya se prepararon fuera del hilo UI. No volver a leer
    # sus PNG de varios MB en cada publicación del estado remoto.
    if($script:capPreviewCache -and $script:capPreviewCache.ContainsKey($ruta)){return "$($script:capPreviewCache[$ruta].Thumb)"}
    # Miniatura JPEG pequeña en base64 para enviar al panel web (las capturas son ficheros locales
    # que el movil no puede leer). Se CACHEA, pero la clave incluye la FECHA DE MODIFICACION: si un
    # fichero se sobrescribe con el mismo nombre (p.ej. reprocesar), la clave cambia y se recodifica —
    # asi la web no muestra una miniatura vieja de otra captura que tuvo ese nombre.
    if (-not $script:agCapThumbs) { $script:agCapThumbs = @{} }
    $clave = $ruta
    try { $clave = "$ruta|$((Get-Item -LiteralPath $ruta -ErrorAction Stop).LastWriteTimeUtc.Ticks)" } catch {}
    if ($script:agCapThumbs.ContainsKey($clave)) { return $script:agCapThumbs[$clave] }
    $b64 = ""
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $imageStream=[IO.MemoryStream]::new([IO.File]::ReadAllBytes($ruta),$false)
        $bmp.BeginInit()
        $bmp.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
        $bmp.StreamSource = $imageStream; $bmp.DecodePixelWidth = 384
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $bmp.EndInit()
        $enc = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder
        $enc.QualityLevel = 68
        [void]$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $ms = New-Object System.IO.MemoryStream
        $enc.Save($ms)
        $b64 = "data:image/jpeg;base64," + [Convert]::ToBase64String($ms.ToArray())
        $ms.Dispose()
    } catch {} finally {if($imageStream){$imageStream.Dispose()}}
    $script:agCapThumbs[$clave] = $b64
    return $b64
}
function Es-PrincipalGrupo($nombre) {
    # Principal = primer archivo de su grupo (una pareja híbrida es un grupo). Sin grupos aún, todos.
    if (-not $script:gruposLote -or @($script:gruposLote).Count -eq 0) { return $true }
    foreach ($g in @($script:gruposLote)) { if ("$($g.Principal)" -eq $nombre) { return $true } }
    return $false
}
function Miembros-GrupoDe($nombre) {
    foreach ($g in @($script:gruposLote)) { if (@($g.Miembros) -contains $nombre) { return @($g.Miembros) } }
    return @($nombre)
}
function Get-TareasAuxiliares {
    $tareas = @()
    if($script:capPreviewSync){
        $done=[int]$script:capPreviewSync.Done;$total=[int]$script:capPreviewSync.Total
        $tareas+=@{tipo='miniaturas';titulo='Cargando capturas';fase="Preparando miniaturas $done/$total";pct=$(if($total){[int](100*$done/$total)}else{0});detalle="$done/$total"}
    }
    $torActiva = [bool]$script:torPreparando -or [bool]($script:torSync -and -not [bool]$script:torSync.Fin)
    if ($torActiva) {
        $pct = if ($script:torSync) { [int]$script:torSync.Pct } else { 0 }
        $fase = "$($ui.lblTorrentProgreso.Text)"; if ([string]::IsNullOrWhiteSpace($fase)) { $fase = "Preparando torrent…" }
        $tareas += [PSCustomObject]@{ tipo = "torrent"; titulo = "Creando torrent"; pct = $pct; fase = $fase; detalle = "$pct%" }
    }
    $capActiva = [bool]($script:capSync -and -not [bool]$script:capSync.Fin)
    if ($capActiva) {
        $total = [int]$script:capSync.Total; $hechas = [int]$script:capSync.Done
        $pct = if ($total -gt 0) { [int](100 * $hechas / $total) } else { 0 }
        $fase = "$($ui.lblSubProgreso.Text)"; if ([string]::IsNullOrWhiteSpace($fase)) { $fase = "Generando capturas…" }
        $tareas += [PSCustomObject]@{ tipo = "capturas"; titulo = "Generando capturas"; pct = $pct; fase = $fase; detalle = "$hechas/$total" }
    }
    $subActiva = [bool]($script:subSync -and -not [bool]$script:subSync.Fin)
    if ($subActiva) {
        $total = [int]$script:subSync.Total; $hechas = [int]$script:subSync.Done
        $pct = if ($total -gt 0) { [int](100 * $hechas / $total) } else { 0 }
        $fase = "$($ui.lblSubProgreso.Text)"; if ([string]::IsNullOrWhiteSpace($fase)) { $fase = "Subiendo imágenes…" }
        $tareas += [PSCustomObject]@{ tipo = "imagenes"; titulo = "Subiendo imágenes"; pct = $pct; fase = $fase; detalle = "$hechas/$total" }
    }
    return @($tareas)
}
function Actualizar-PanelTareasAux {
    if (-not $ui.panTareasAux) { return }
    $tareas = @(Get-TareasAuxiliares)
    while ($ui.panTareasAux.Children.Count -gt $tareas.Count) { $ui.panTareasAux.Children.RemoveAt($ui.panTareasAux.Children.Count-1) }
    $taskIndex=0
    foreach ($t in $tareas) {
        $kind="$($t.tipo)|$($t.titulo)"
        $existing=if($taskIndex -lt $ui.panTareasAux.Children.Count){$ui.panTareasAux.Children[$taskIndex]}else{$null}
        if ($existing -and $existing.Tag.Kind -eq $kind) {
            $existing.Tag.Title.Text="$($t.titulo) · $($t.fase)"
            $existing.Tag.Detail.Text="$($t.detalle)"
            $existing.Tag.Bar.Value=[Math]::Clamp([double]$t.pct,0,100)
            $taskIndex++
            continue
        }
        $bd = New-Object System.Windows.Controls.Border
        $bd.Background = $win.Resources["ChipBrush"]; $bd.BorderBrush = $win.Resources["ChipBorderBrush"]
        $bd.BorderThickness = [System.Windows.Thickness]::new(1); $bd.CornerRadius = [System.Windows.CornerRadius]::new(8)
        $bd.Padding = [System.Windows.Thickness]::new(12, 8, 12, 9); $bd.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
        $sp = New-Object System.Windows.Controls.StackPanel
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
        [void]$g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        $auto = New-Object System.Windows.Controls.ColumnDefinition; $auto.Width = [System.Windows.GridLength]::Auto; [void]$g.ColumnDefinitions.Add($auto)
        $lt = New-Object System.Windows.Controls.TextBlock; $lt.Text = "$($t.titulo) · $($t.fase)"; $lt.Foreground = $win.Resources["TextBrush"]; $lt.FontSize = 11.5; $lt.FontWeight = "SemiBold"; $lt.TextTrimming = "CharacterEllipsis"
        $rt = New-Object System.Windows.Controls.TextBlock; $rt.Text = "$($t.detalle)"; $rt.Foreground = $win.Resources["SubBrush"]; $rt.FontSize = 11.5; $rt.FontWeight = "SemiBold"
        [System.Windows.Controls.Grid]::SetColumn($rt, 1); [void]$g.Children.Add($lt); [void]$g.Children.Add($rt)
        $bar = New-Object System.Windows.Controls.ProgressBar; $bar.Height = 5; $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = [double]$t.pct; $bar.Background = "#26262C"; $bar.BorderThickness = [System.Windows.Thickness]::new(0); $bar.Foreground = $win.Resources["AccentBrush"]
        [void]$sp.Children.Add($g); [void]$sp.Children.Add($bar); $bd.Child = $sp
        $bd.Tag=@{Kind=$kind;Title=$lt;Detail=$rt;Bar=$bar}
        if($existing){$ui.panTareasAux.Children.RemoveAt($taskIndex)}
        $ui.panTareasAux.Children.Insert($taskIndex,$bd);$taskIndex++
    }
    $ui.panTareasAux.Visibility = if ($tareas.Count -gt 0) { "Visible" } else { "Collapsed" }
}
function Componer-EstadoAgente {
    param([switch]$Snapshot)
    # El análisis es inmutable entre escaneos. Invalidar solo al cambiar fuentes
    # o correcciones de idioma, en vez de recalcular miles de pistas por segundo.
    $languageKey=ConvertTo-Json -InputObject $script:idiomasManuales -Compress
    if (-not [object]::ReferenceEquals($script:agCachedScan,$script:ultimoScan) -or
        -not [object]::ReferenceEquals($script:agCachedRemix,$script:remixScanCrudo) -or
        $script:agCachedLanguages -ne $languageKey -or -not $script:agMediaCache) {
        $script:agMediaCache=@{};$script:agCachedScan=$script:ultimoScan
        $script:agCachedRemix=$script:remixScanCrudo;$script:agCachedLanguages=$languageKey
    }
    $principalNames=@{};$hybridNames=@{}
    foreach($group in $script:gruposLote){
        $principalNames["$($group.Principal)"]=$true
        if(@($group.Miembros).Count -gt 1){foreach($name in $group.Miembros){$hybridNames["$name"]=$true}}
    }
    $op = [ordered]@{}
    foreach ($g in $script:agGruposChip) { $v = Get-ChipValor $g; if ($v -is [bool]) { $v = "$v".ToLower() }; $op[$g] = "$v" }
    $sw = [ordered]@{}; $ms = _agMapSwitch; foreach ($k in $ms.Keys) { $sw[$k] = [bool]$ms[$k].IsChecked }
    $fl = [ordered]@{}; foreach ($n in $script:agFlags) { if ($ui[$n]) { $fl[$n] = [bool]$ui[$n].IsChecked } }
    $cs = [ordered]@{}; $mc = _agMapCombo; foreach ($k in $mc.Keys) { $cs[$k] = "$(Get-ComboValor $mc[$k])" }
    $cd = [ordered]@{}; foreach ($k in $mc.Keys) { $cd[$k] = @(@($mc[$k].Tag) | ForEach-Object { @{ t = "$($_.T)"; v = "$($_.V)" } }) }
    $inp = [ordered]@{}; $mi = _agMapInput; foreach ($k in $mi.Keys) { $inp[$k] = "$($mi[$k].Text)" }
    # Controles dinámicos: estas decisiones se crean tras analizar los vídeos, por lo que el
    # panel móvil necesita una descripción explícita (no basta con los controles fijos de arriba).
    if(-not $script:agConvDestinations){$script:agConvDestinations=@{}}
    $convTracksAg = @($script:convTrackOpts | ForEach-Object {
        $can = [int]$_.Channels
        if(-not $script:agConvDestinations.ContainsKey($can)){$script:agConvDestinations[$can]=@((Get-OpcionesDestino $can) | ForEach-Object {@{t="$($_.T)";v="$($_.V)"}})}
        [ordered]@{ v = "$($_.V)"; t = "$($_.T)"; canales = $can
                    destinos = $script:agConvDestinations[$can] }
    })
    $convRowsAg = @()
    foreach ($r in @($script:convRows)) {
        if ($ui.panConvFilas -and -not $ui.panConvFilas.Children.Contains($r.Grid)) { continue }
        $convRowsAg += [ordered]@{ Index = "$(Get-ComboValor $r.CmbOrigen)"; Dest = "$(Get-ComboValor $r.CmbDestino)"; MantenerOriginal = [bool]$r.SwMant.IsChecked }
    }
    $undAg = @()
    if(-not $script:agUndOptions){$script:agUndOptions=@($opcionesIdiomaUnd|ForEach-Object {@{t="$($_.T)";v="$($_.V)"}})}
    foreach ($r in @($script:undRows)) {
        if(-not $r){continue}
        $undAg += [ordered]@{ archivo = "$($r.Archivo)"; id = "$($r.Id)"; tipo = "$($r.Tipo)"
                               etiqueta = "$($r.Etiqueta)"
                               valor = "$(Get-ComboValor $r.Combo)" }
    }
    $subIdiomasAg = @($script:chipsIdiomas | ForEach-Object { [ordered]@{ v = "$($_.Tag)"; t = "$($_.Content)"; sel = [bool]$_.IsChecked } })
    $remezclaFuentesAg = @((Leer-RemezclaCarpetas) | ForEach-Object { [ordered]@{ ruta = "$($_.Ruta)"; archivo = "$($_.Archivo)"; video = [bool]$_.Video; audio = [bool]$_.Audio; subs = [bool]$_.Subs } })
    $remezclaAudioAg = @($script:remezclaChipsAudio | ForEach-Object { [ordered]@{ v = "$($_.Tag)"; t = "$($_.Content)"; sel = [bool]$_.IsChecked } })
    $remezclaSubsAg = @($script:remezclaChipsSub | ForEach-Object { [ordered]@{ v = "$($_.Tag)"; t = "$($_.Content)"; sel = [bool]$_.IsChecked } })
    $subsUnicosAg = @(); $subUniN = 0
    foreach ($r in @($script:subsUnicosRows)) {
        $subUniN++
        $subsUnicosAg += [ordered]@{ i = $subUniN; etiqueta = "$(NombreIdioma $r.Cod) · $($r.Fmt)"; forzado = [bool]$r.RbForzado.IsChecked }
    }
    # En «Cada archivo distinto», la lista de vídeos del móvil muestra SOLO la película de la pestaña
    # activa (igual que el programa). $loteFiltro = archivos de esa película; $null = sin filtrar (homogéneo).
    $loteFiltro = $null
    if ((Get-ChipValor "modoLote") -eq "HETEROGENEO" -and $script:tabProyActual -ge 0 -and $script:tabProyActual -lt @($script:tabsProy).Count) {
        $loteFiltro = @($script:tabsProy[$script:tabProyActual].Archivos)
    }
    # La remezcla produce UN único MKV final, pero el análisis debe enseñar TODAS las fuentes
    # elegidas: ocultar las de audio/subs aquí daba la falsa impresión de que no participarían.
    $loteRemezclaAg = [bool]$script:remixScanActivo -and @($script:remixScanCrudo).Count -gt 0
    $rolesRemezclaPorArchivo = @{}
    $loteAnalisisAg = @($script:ultimoScan)
    if ($loteRemezclaAg) {
        foreach ($cfgRz in @(Leer-RemezclaCarpetas)) {
            if (-not $cfgRz.Video -and -not $cfgRz.Audio -and -not $cfgRz.Subs) { continue }
            if ("$($cfgRz.Archivo)") { $rolesRemezclaPorArchivo["$($cfgRz.Archivo)"] = $cfgRz }
            else { foreach($source in @($script:remixScanCrudo | Where-Object { (Split-Path $_.Ruta -Parent).TrimEnd('\') -eq "$($cfgRz.Ruta)".TrimEnd('\') })) { $rolesRemezclaPorArchivo["$($source.Ruta)"]=$cfgRz } }
        }
        $loteAnalisisAg = @($script:remixScanCrudo | Where-Object { $rolesRemezclaPorArchivo.ContainsKey("$($_.Ruta)") })
        $loteFiltro=$null
    }
    # Tareas auxiliares fuera del montaje: se comparten con la barra global del programa y el móvil.
    $tareasAg = @(Get-TareasAuxiliares)
    $est = [ordered]@{
        interfaz = Get-HdzInterfaceState
        torrentRuta = "$($ui.txtTorrentSubir.Text)"
        v = Get-VersionLocal; equipo = "$env:COMPUTERNAME"; carpeta = "$($ui.txtCarpeta.Text)"
        # Cambia solo cuando el Dispatcher WPF está vivo. El worker puede seguir haciendo sync con
        # un estado viejo si un diálogo modal bloquea la interfaz; el panel detecta así ese caso.
        uiTs = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        # Página de la subida ACTIVA, nunca la URL privada de descarga con passkey.
        # La web abre este enlace en su propio navegador, no en el PC del agente.
        torrentWebUrl = "$script:urlTorrentWeb"
        selectVideos = $true
        update = Get-HdzUpdateState
        torrentDescarga = [ordered]@{
            disponible = [bool]("$script:torrentRemotoId" -match '^[0-9a-f]{64}$' -and -not [string]::IsNullOrWhiteSpace("$script:torrentRemotoNombre"))
            id = [string]$script:torrentRemotoId
            nombre = "$script:torrentRemotoNombre"
        }
        opciones = $op; switches = $sw; flags = $fl; combos_sel = $cs; combos = $cd; inputs = $inp
        remezclaVisible = ("$($ui.panRemezcla.Visibility)" -eq "Visible")
        remezclaFuentes = $remezclaFuentesAg; remezclaAudio = $remezclaAudioAg; remezclaSubs = $remezclaSubsAg
        audioIdiomas = @($script:chipsIdiomasAudio | ForEach-Object {
            [ordered]@{ v = "$($_.Tag)"; t = "$($_.Content)"; sel = [bool]$_.IsChecked }
        })
        audioIdiomasVisible = ("$($ui.cardFiltroAudio.Visibility)" -eq "Visible")
        audioTracksSupported = $true
        audioTracks = @($script:audioTrackRows | ForEach-Object {@{archivo=$_.Archivo;id=$_.Id;index=$_.Index;etiqueta=$_.Etiqueta;sel=[bool]$_.Choice.IsChecked}})
        conversionesAudioVisible = ("$($ui.cardConvAudio.Visibility)" -eq "Visible")
        defAudioVisible = ("$($ui.cardDefAudio.Visibility)" -eq "Visible")
        undAudioVisible = ("$($ui.cardUndAudio.Visibility)" -eq "Visible")
        conversionesAudio = $convRowsAg; pistasConversionAudio = $convTracksAg
        pgsVisible = ("$($ui.cardPGS.Visibility)" -eq "Visible")
        idiomasSubs = $subIdiomasAg
        idiomasSubsPersonalizadosVisible = (("$($ui.cardFiltro.Visibility)" -eq "Visible") -and ((Get-ChipValor "filtro") -eq "PERSONALIZADA"))
        subsUnicosVisible = ("$($ui.cardSubsUnicos.Visibility)" -eq "Visible")
        subsUnicos = $subsUnicosAg
        undAudioSubs = $undAg
        idiomasPistaOpciones = $script:agUndOptions
        undSubsVisible = ("$($ui.cardUndSub.Visibility)" -eq "Visible")
        browse = $script:agBrowse
        montaje = [ordered]@{
            activo  = [bool]($script:procMontaje -and -not $script:procMontaje.HasExited)
            pct     = [int]$ui.barProgreso.Value
            fase    = "$($ui.lblProgreso.Text)"
            visible = ("$($ui.panProgreso.Visibility)" -eq "Visible")
            enCola  = @($script:colaMontaje).Count
            # 2ª barra (detalle de la tarea en curso: ensamblado, hasheo, copia entre discos…).
            # Sin esto, desde el móvil se veía la barra principal clavada y parecía colgado.
            pct2    = $(if ("$($ui.panProgreso2.Visibility)" -eq "Visible") { [int]$ui.barProgreso2.Value } else { -1 })
            fase2   = "$($ui.lblProgreso2.Text)"
        }
        tareas = $tareasAg
        loteRemezcla = $loteRemezclaAg
        lote = @(@($loteAnalisisAg) | Where-Object { (-not $loteFiltro) -or ($loteFiltro -contains "$($_.Nombre)") } | ForEach-Object {
            $f = $_
            $nm = "$($f.Nombre)"
            $cfgRz = if ($loteRemezclaAg -and $rolesRemezclaPorArchivo.ContainsKey("$($f.Ruta)")) { $rolesRemezclaPorArchivo["$($f.Ruta)"] } else { $null }
            $mediaKey="$($f.Ruta)|$nm"
            $entry=$script:agMediaCache[$mediaKey]
            if(-not $entry -or -not [object]::ReferenceEquals($entry.Source,$f)){
                $entry=@{Source=$f;Episode=(Detectar-EpisodioGui $nm);BadgeKey=$null;Badges=@()};$script:agMediaCache[$mediaKey]=$entry
            }
            $epv = if ($script:episodiosMap.ContainsKey($nm)) { "$($script:episodiosMap[$nm])" } else { $entry.Episode }
            $sal = if ($cfgRz -and -not $cfgRz.Video) { "" } elseif ($script:salidaMap.ContainsKey($nm)) { "$($script:salidaMap[$nm])" } else { "" }
            # Badges del vídeo (misma info y estilos que la lista del programa: New-Pill).
            $badgeKey="$($cfgRz.Video)|$($cfgRz.Audio)|$($cfgRz.Subs)|$($hybridNames.ContainsKey($nm))"
            if($entry.BadgeKey -eq $badgeKey){$bdg=$entry.Badges}else{
            $bdg = @()
            if ($f.Error) { $bdg += @{ t = "error al analizar: $($f.Error)"; s = "warn" } }
            else {
                if ($cfgRz) {
                    $rolesRz = @(); if ($cfgRz.Video) { $rolesRz += "VÍDEO FINAL" }; if ($cfgRz.Audio) { $rolesRz += "AUDIO" }; if ($cfgRz.Subs) { $rolesRz += "SUBS" }
                    $bdg += @{ t = "REMEZCLA · $($rolesRz -join ' + ')"; s = "accent" }
                }
                if ($f.Video) {
                    $resB = Get-HdzVideoResolution $f.Video; if (-not $resB) { $resB = '?' }
                    $bdg += @{ t = $resB; s = "accent" }
                    $codB = switch -Regex ("$($f.Video.Codec)") { "hevc" { "HEVC" } "h264" { "H.264" } "av1" { "AV1" } default { "$($f.Video.Codec)".ToUpper() } }
                    $bdg += @{ t = $codB; s = "gris" }
                    if ($f.Video.EsDV)  { $bdg += @{ t = "Dolby Vision"; s = "hdr" } }
                    if ($f.Video.EsHDR) { $bdg += @{ t = "HDR"; s = "hdr" } }
                }
                $resAud = @()
                foreach ($a in @($f.Audios)) {
                    $cA = switch -Regex ("$($a.Codec)") {
                        "^eac3$" { "DD+" } "^ac3$" { "DD" } "^truehd$" { "TrueHD" }
                        "^dts$"  { if ("$($a.Profile)" -match "MA") { "DTS-HD MA" } else { "DTS" } }
                        default  { "$($a.Codec)".ToUpper() }
                    }
        $lA = Get-IdiomaPistaGui $a 'Audio'
                    $resAud += "$cA $(if ($lA -eq 'und') { '¿?' } else { $lA })"
                }
                if ($resAud.Count -gt 0) { $bdg += @{ t = ("♪ " + (($resAud | Select-Object -First 4) -join " · ") + $(if ($resAud.Count -gt 4) { " +$($resAud.Count-4)" } else { "" })); s = "gris" } }
                $nPgsB = @($f.Subs | Where-Object { $_.EsPGS }).Count
                $nTxtB = @($f.Subs | Where-Object { -not $_.EsPGS }).Count
                if (@($f.Subs).Count -gt 0) { $bdg += @{ t = "💬 $nTxtB texto · $nPgsB PGS"; s = "gris" } }
                if ($hybridNames.ContainsKey($nm)) { $bdg += @{ t = "PAREJA HÍBRIDA DV+HDR10"; s = "warn" } }
                $undsB = @($f.Audios | Where-Object { (Get-IdiomaPistaGui $_ 'Audio') -eq "und" }).Count + @($f.Subs | Where-Object { (Get-IdiomaPistaGui $_ 'Sub') -eq "und" }).Count
                if ($undsB -gt 0) { $bdg += @{ t = "$undsB pista(s) sin idioma"; s = "warn" } }
            }
            $entry.BadgeKey=$badgeKey;$entry.Badges=$bdg
            }
            [ordered]@{ nombre = $nm; sel = $(if ($loteRemezclaAg) { $true } else { $script:seleccion[$nm] -ne $false }); ep = "$epv"; salida = "$sal"; principal = $(if ($cfgRz) { [bool]$cfgRz.Video } else { -not $script:gruposLote -or $principalNames.ContainsKey($nm) }); fijo = $loteRemezclaAg; badges = $bdg }
        })
        resumen = $(if ($loteRemezclaAg) { "$(@($loteAnalisisAg).Count) archivos fuente · $(@($script:ultimoScan).Count) archivo(s) final(es)" } else { "$($ui.lblResumen.Text)" })
        estado  = "$($ui.lblEstado.Text)"
    }
    # Capturas: miniatura base64 + estado de seleccion (la casilla decide que va en la descripcion).
    $caps = @()
    $ci = 0
    foreach ($cr in @($script:capRows)) {
        $caps += [ordered]@{ i = $ci; nombre = (Split-Path "$($cr.Ruta)" -Leaf); sel = [bool]$cr.Check.IsChecked; thumb = (Get-CapturaThumbB64 "$($cr.Ruta)"); subida = "$($cr.Subida)" }
        $ci++
    }
    $est.capturas = $caps
    $est.capturasVisible = ($caps.Count -gt 0)
    # Pestañas de SUBIDA (cada release en «Torrent y subida»: su propio torrent, capturas, descripción,
    # IDs). El montaje crea una por película. La web las muestra y cambia entre ellas (comando
    # set_subida_tab -> Cambiar-Tab), igual que en el programa. Sin esto, la web solo veía la activa y
    # parecía que «todas las pestañas» tenían las mismas capturas.
    $tabsSub = @()
    for ($ts = 0; $ts -lt @($script:tabs).Count; $ts++) {
        $tit = if ($ts -eq $script:tabActual) { "$($ui.upTitulo.Text)".Trim() } else { "$($script:tabs[$ts].Titulo)".Trim() }
        if (-not $tit) { $tit = "Subida $($ts + 1)" }
        $tabsSub += [ordered]@{ i = $ts; titulo = "$tit"; activa = ($ts -eq $script:tabActual) }
    }
    $est.tabsSubida = $tabsSub
    $est.tabSubidaActual = [int]$script:tabActual
    # Pestañas por película (solo en «Cada archivo distinto»): el móvil las muestra y cambia de
    # película igual que el programa. El título de la activa se lee en vivo del campo; el de las
    # demás, de su Estado guardado. Cambiar de pestaña en el móvil llama a Cambiar-TabProy (comando
    # set_tab), que vuelca la identidad/audio/subs de esa película en los controles compartidos.
    $tabsA = @()
    if ((Get-ChipValor "modoLote") -eq "HETEROGENEO") {
        for ($ti = 0; $ti -lt @($script:tabsProy).Count; $ti++) {
            $tbp = $script:tabsProy[$ti]
            $tit = if ($ti -eq $script:tabProyActual) { "$($ui.txtTitulo.Text)".Trim() } else { "$($tbp.Estado.Titulo)".Trim() }
            if (-not $tit) { $tit = [System.IO.Path]::GetFileNameWithoutExtension("$($tbp.Principal)") }
            $tabsA += [ordered]@{ i = $ti; titulo = "$tit"; activa = ($ti -eq $script:tabProyActual) }
        }
    }
    $est.tabsProy = $tabsA
    $est.tabProyActual = [int]$script:tabProyActual
    # Logos de TMDB: URLs publicas (image.tmdb.org); el movil las carga directamente.
    $lgs = @()
    foreach ($lg in @($script:logosActuales)) {
        $lgs += [ordered]@{ url = "$($lg.Url)"; w = "$($lg.Width)"; h = "$($lg.Height)"; lang = "$($lg.Lang)"; sel = ("$($lg.Url)" -eq "$($script:logoSel)") }
    }
    $est.logos = $lgs
    $est.logoRefresh = $true
    $est.customLogo = $true
    $est.protocol = 2
    $est.tmdbResults = @(for($i=0;$i -lt @($script:tmdbSearchResults).Count;$i++){
        $result=@($script:tmdbSearchResults)[$i]
        if($result -and "$($result.Id)" -match '^[1-9][0-9]*$' -and "$($result.Titulo)".Trim()){
            @{i=$i;id="$($result.Id)";titulo="$($result.Titulo)";fecha="$($result.Fecha)"}
        }
    })
    $est.carpetas = @(Get-CarpetasEntrada)
    $est.firmas = @($script:firmaBordes | ForEach-Object { @{ruta="$($_.Ruta)";nombre=(Split-Path $_.Ruta -Leaf);sel=($_.Ruta -eq $script:firmaSel);thumb=(Get-CapturaThumbB64 $_.Ruta)} })
    if ($script:networkBusy) { $est.tareas = @($est.tareas) + @(@{titulo='Red';fase='Esperando respuesta del servicio';pct=0;detalle='En curso'}) }
    $est.session = $script:agSession
    $est.busy = [bool]$script:networkBusy
    $est.history = @($script:historialVisible)
    $est._acks = @($script:agCompleted.Values)
    if($Snapshot){return $est}
    return ($est | ConvertTo-Json -Depth 8 -Compress)
}
function _agClick($btn) {
    if (-not $btn -or -not $btn.IsEnabled) { throw 'Esta acción no está disponible mientras hay otra tarea en curso.' }
    $btn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}
function Aplicar-ComandoAgente($c) {
    $commandId = "$($c._id)"
    if ($commandId -and $script:agCompleted.Contains($commandId)) { return }
    $commandOk = $false; $commandMessage = ''
    try {
        if ($commandId -and "$($c.session)" -ne $script:agSession) { throw 'La sesión de esa orden ya terminó. Revisa el estado actual.' }
        if ($script:networkBusy -and "$($c.type)" -ne 'ping') { throw 'Hay una petición de red en curso. Espera su resultado.' }
        if ($script:updRequested -and "$($c.type)" -ne 'ping') { throw 'Hay una actualización solicitada. Espera a que el programa se reabra.' }
        if ($null -ne $c.subidaTab -and [int]$c.subidaTab -ne $script:tabActual) { throw 'La pestaña de subida cambió; la orden no se ha aplicado a otra ficha.' }
        if ($null -ne $c.projectTab -and [int]$c.projectTab -ne $script:tabProyActual) { throw 'El proyecto activo cambió; revisa la selección.' }
        # DIAGNÓSTICO: registra los comandos del control web que tocan campos o pestañas de subida
        # (con el valor y el contexto de la pestaña activa). Si una pestaña se cruza, aquí quedará
        # EXACTAMENTE qué comando lo provocó (p.ej. un set_input de 'upTitulo' con un valor de otra peli).
        $tipoC = "$($c.type)"
        if ($tipoC -in @("set_input","set_subida_tab","cerrar_subida","subir","cargar_torrent","crear_torrent","reset") -or ("$($c.name)" -like "up*") -or ("$($c.name)" -like "btn*")) {
            $val = if ($null -ne $c.value) { "$($c.value)" } else { "" }
            if ("$($c.name)" -match '(?i)key|token|pass|announce') { $val = '[CENSURADO]' }
            elseif ($val.Length -gt 60) { $val = $val.Substring(0, 60) + "…" }
            $pathLeaf = if ("$($c.path)".Trim()) { Split-Path "$($c.path)" -Leaf } else { "" }
            Log-DiagSubida "CMD-WEB tipo=$tipoC name='$($c.name)' idx='$($c.idx)' value='$val' path='$pathLeaf' | $(Ctx-SubidaActiva)"
        }
        switch ("$($c.type)") {
            "history_view" { Actualizar-HistorialVisible }
            "history_torrent" {
                $originalTorrent = Get-HdzHistoryTorrent "$($c.id)"
                $published = Publicar-TorrentAgente $originalTorrent
                if (-not $published) { throw 'No se pudo enviar el torrent original a la web. El archivo local sigue intacto.' }
                $script:torrentRemotoId = [string]$published.id; $script:torrentRemotoNombre = [string]$published.name
                Set-Estado 'Torrent original disponible en el botón de descarga de la web.' 'ok'
            }
            "ping"        { }
            "send_log" { if (-not $c.confirmed) { throw 'Confirma el envío del registro desde la web.' }; Enviar-LogSoporte -ConfirmadoRemoto }
            "actualizar"  { Request-HdzUpdate $commandId }
            "reset"       { Reset-Todo }
            "iniciar"     { _agClick $ui.btnIniciar }
            "iniciar_todos" { _agClick $ui.btnIniciarTodos }
            "subir"       { _agClick $ui.btnSubir }
            "ver_web"     { _agClick $ui.btnVerWeb }
            "set_carpeta" { $ui.txtCarpeta.Text = "$($c.value)" }
            "set_videos" { Set-VideosElegidos @($c.paths | ForEach-Object { "$_" }) }
            "add_carpeta" { Set-CarpetasTemporadas (@(Get-CarpetasEntrada) + @("$($c.path)")) }
            "remove_carpeta" { Set-CarpetasTemporadas @(Get-CarpetasEntrada | Where-Object { $_ -ne "$($c.path)" }) }
            "sel_tmdb" {
                $index = [int]$c.idx
                if (-not $script:tmdbSearchResults -or $index -lt 0 -or $index -ge @($script:tmdbSearchResults).Count -or -not $script:tmdbSearchResults[$index].Id) { throw 'El resultado TMDB ya no está disponible. Vuelve a buscar.' }
                Aplicar-ResultadoTmdb $script:tmdbSearchResults[$index]
                Set-Estado 'Ficha TMDB aplicada.' 'ok'
            }
            "sel_firma" {
                if ("$($c.path)" -and "$($c.path)" -notin @($script:firmaBordes.Ruta)) { throw 'Firma no disponible.' }
                $script:firmaSel = "$($c.path)"; Refresh-FirmaSel
            }
            "add_captura" {
                if ([IO.Path]::GetExtension("$($c.path)") -notin @('.png','.jpg','.jpeg') -or -not (Test-Path -LiteralPath "$($c.path)" -PathType Leaf)) { throw 'Selecciona una imagen PNG o JPEG existente.' }
                Construir-Capturas (@($script:capRows | ForEach-Object { $_.Ruta }) + @("$($c.path)"))
            }
            "description_image" {
                if ([IO.Path]::GetExtension("$($c.path)") -notin @('.png','.jpg','.jpeg') -or -not (Test-Path -LiteralPath "$($c.path)" -PathType Leaf)) { throw 'Selecciona una imagen PNG o JPEG existente.' }
                $ownerId=$script:subidaTabId
                $onDone={param($urls) Complete-HdzDescriptionImages $ownerId @($urls)}.GetNewClosure()
                Start-SubidaAsync @("$($c.path)") $onDone @($ui.btnDescSubir)
            }
            "set_chip"    { if ($c.grupo) { Set-ChipValor "$($c.grupo)" $c.value } }
            "set_audio_track" {
                foreach($row in @($script:audioTrackRows)){if($row.Archivo -eq "$($c.archivo)" -and "$($row.Id)" -eq "$($c.id)"){$row.Choice.IsChecked=[bool]$c.value;if($row.Choice.IsChecked){$script:audioTracksExcluded.Remove($row.Key)}else{$script:audioTracksExcluded[$row.Key]=@{Archivo=$row.Archivo;Id=$row.Id;Index=$row.Index}};break}}
            }
            "set_audio_lang" {
                $cod = "$($c.code)"
                foreach ($tbAud in @($script:chipsIdiomasAudio)) {
                    if ("$($tbAud.Tag)" -eq $cod) {
                        $script:idiomasAudioSeleccionUsuario = $true
                        $tbAud.IsChecked = [bool]$c.value
                        break
                    }
                }
            }
            "set_sub_lang" {
                $cod = "$($c.code)"
                foreach ($tbSub in @($script:chipsIdiomas)) {
                    if ("$($tbSub.Tag)" -eq $cod) { $tbSub.IsChecked = [bool]$c.value; break }
                }
            }
            "set_sub_unico" {
                $i = [int]$c.idx
                if ($i -gt 0 -and $i -le @($script:subsUnicosRows).Count) {
                    $script:subsUnicosRows[$i - 1].RbForzado.IsChecked = [bool]$c.forzado
                }
            }
            "set_und" {
                $archivo = "$($c.archivo)"; $id = "$($c.id)"; $tipoUnd = "$($c.tipo)"
                foreach ($rUnd in @($script:undRows)) {
                    if ("$($rUnd.Archivo)" -eq $archivo -and "$($rUnd.Id)" -eq $id -and "$($rUnd.Tipo)" -eq $tipoUnd) {
                        Set-ComboValor $rUnd.Combo $c.value; break
                    }
                }
            }
            "set_conv" {
                $estados = @()
                foreach ($cr in @($c.rows)) {
                    $idx = "$($cr.Index)"; $dst = "$($cr.Dest)"
                    $origen = @($script:convTrackOpts | Where-Object { "$($_.V)" -eq $idx } | Select-Object -First 1)
                    if (-not $origen) { continue }
                    $destinos = @(Get-OpcionesDestino ([int]$origen.Channels))
                    if (@($destinos | Where-Object { "$($_.V)" -eq $dst }).Count -eq 0) { $dst = "$($destinos[0].V)" }
                    $estados += [ordered]@{ Index = $idx; Dest = $dst; MantenerOriginal = [bool]$cr.MantenerOriginal }
                }
                Reconstruir-FilasConv $estados
            }
            "set_remezcla" {
                $filas = @($c.fuentes | Where-Object { $_ -and "$($_.ruta)".Trim() -and (Test-Path -LiteralPath "$($_.ruta)") })
                $ui.panRemezclaCarpetas.Children.Clear(); $script:remezclaCarpetas = @()
                foreach ($fr in $filas) { Add-FilaRemezcla "$($fr.ruta)" "$($fr.archivo)" }
                for ($ri = 0; $ri -lt [Math]::Min($filas.Count, $script:remezclaCarpetas.Count); $ri++) {
                    $dest = $script:remezclaCarpetas[$ri]; $src = $filas[$ri]
                    $dest.Video.IsChecked = [bool]$src.video; $dest.Audio.IsChecked = [bool]$src.audio; $dest.Subs.IsChecked = [bool]$src.subs
                }
                Actualizar-PreviewRemezcla
            }
            "set_remezcla_lang" {
                $tipoRz = "$($c.tipo)"; $codRz = "$($c.code)"
                $coleccion = if ($tipoRz -eq "audio") { @($script:remezclaChipsAudio) } else { @($script:remezclaChipsSub) }
                foreach ($chipRz in $coleccion) { if ("$($chipRz.Tag)" -eq $codRz) { $chipRz.IsChecked = [bool]$c.value; break } }
            }
            "set_switch"  { $m = _agMapSwitch; if ($m.ContainsKey("$($c.name)")) { $m["$($c.name)"].IsChecked = [bool]$c.value } }
            "set_check"   { if ($ui["$($c.name)"]) { $ui["$($c.name)"].IsChecked = [bool]$c.value } }
            "set_combo"   { $m = _agMapCombo; if ($m.ContainsKey("$($c.name)")) { Set-ComboValor $m["$($c.name)"] $c.value } }
            "set_input"   {
                $n = "$($c.name)"; $val = "$($c.value)"
                if     ($n -eq "cfgImgboxPass")  { if ($val.Trim()) { $ui.cfgImgboxPass.Password = $val } }
                elseif ($n -eq "cfgTrackerToken"){ if ($val.Trim()) { $ui.cfgTrackerToken.Text = $val } }
                elseif ($n -eq "cfgTmdbKey")     { if ($val.Trim()) { $ui.cfgTmdbKey.Text = $val } }
                elseif ($n -eq "cfgImgbbKey")    { if ($val.Trim()) { $ui.cfgImgbbKey.Text = $val } }
                elseif ($n -eq "announce")       { if ($val.Trim()) { $ui.txtAnnounce.Text = $val } }
                else {
                    $m = _agMapInput
                    if ($m.Contains($n)) {
                        $m[$n].Text = $val
                        # En la web el campo pierde el foco en el móvil, pero el TextBox WPF no;
                        # aplicamos aquí explícitamente la misma validación que en escritorio.
                        if ($n -eq "upTmdb") { [void](Invoke-AplicarTmdbManual $val) }
                    }
                }
            }
            "sel"         { if ($null -ne $c.nombre) { $script:seleccion["$($c.nombre)"] = [bool]$c.value; Refrescar-Adaptacion } }
            "sel_todos"   { foreach ($f in @($script:ultimoScan)) { $script:seleccion["$($f.Nombre)"] = [bool]$c.value }; Refrescar-Adaptacion }
            "browse"      { if ($c.close) { $script:agBrowse = $null } else { $script:agBrowse = Listar-CarpetaAgente "$($c.path)" "$($c.filtro)" } }
            "sel_captura" { $i = [int]$c.idx; if ($i -ge 0 -and $i -lt @($script:capRows).Count) { $script:capRows[$i].Check.IsChecked = [bool]$c.value } }
            "cap_todas"   { foreach ($cr in @($script:capRows)) { $cr.Check.IsChecked = [bool]$c.value } }
            "sel_logo"    { $u = "$($c.url)"; if ($u) { $script:logoSel = $u; Insert-LogoEnDescripcion $u; Refresh-LogoSel } }
            "set_custom_logo" { Usar-LogoPersonalizado "$($c.url)" }
            "click"       {
                # Solo botones que NO abren dialogos nativos (esos no sirven en remoto). Lista blanca.
                if ("$($c.name)" -eq 'btnActualizarLogos') { Update-HdzTmdbLogos; break }
                $safe = @('btnTorrentUltimo','btnCapGenerar','btnCapInsertar','btnBuscarTmdb','btnMediaRefrescar','btnNuevaSubida','btnAplicarEp')
                $n = "$($c.name)"; if (($safe -contains $n) -and $ui[$n]) { _agClick $ui[$n] }
            }
            "set_tab"      { $i = [int]$c.idx; if ($i -ge 0 -and $i -lt @($script:tabsProy).Count) { Cambiar-TabProy $i } }
            "set_subida_tab" { $i = [int]$c.idx; if ($i -ge 0 -and $i -lt @($script:tabs).Count) { Cambiar-Tab $i } }
            "cerrar_subida"  { $i = [int]$c.idx; if ($i -ge 0 -and $i -lt @($script:tabs).Count) { Cerrar-Tab $i } }
            "set_episodio" { $nm = "$($c.nombre)"; if ($nm) { $v = "$($c.value)".Trim(); foreach ($m in Miembros-GrupoDe $nm) { $script:episodiosMap[$m] = $v; if ($script:epTextboxes.ContainsKey($m)) { $script:epTextboxes[$m].Text = $v } } } }
            "set_salida"   { $nm = "$($c.nombre)"; if ($nm) { $v = "$($c.value)".Trim(); foreach ($m in Miembros-GrupoDe $nm) { if ($v) { $script:salidaMap[$m] = $v } else { [void]$script:salidaMap.Remove($m) }; if ($script:salidaBtns.ContainsKey($m)) { $script:salidaBtns[$m].Content = Etiqueta-SalidaArchivo $m } } } }
            "crear_torrent" { $modo = if ("$($c.modo)" -eq "pack") { "pack" } else { "archivo" }; if ("$($c.path)") { Start-CrearTorrentAsync $modo "$($c.path)" } }
            "cargar_torrent"{ if ("$($c.path)") { Anadir-SubidaAuto "$($c.path)" } }
            default       { throw 'Orden remota no reconocida.' }
        }
        $commandOk = $true
    } catch {
        $commandMessage = Redacta-Log $_.Exception.Message
        Set-Estado $commandMessage 'error'
    } finally {
        if ($commandId) {
            $script:agCompleted[$commandId] = @{id=$commandId;ok=$commandOk;message=$commandMessage}
            while ($script:agCompleted.Count -gt 100) { $script:agCompleted.Remove(@($script:agCompleted.Keys)[0]) }
        }
    }
}
function Resolver-AgentUrl {
    # Lectura A PRUEBA DE BALAS de la URL del agente. NO depende de Get-Content ni de ConvertFrom-Json
    # (que en el proceso GUI, por algun motivo de entorno, devolvian 'agent' vacio pese a estar en el
    # fichero). Usa [System.IO.File]::ReadAllText (puro .NET) + regex sobre el texto crudo.
    $dbg = Join-Path $env:TEMP "hdz_agente.log"
    # Varias rutas y varias FORMAS de calcularlas: si $env:APPDATA se resolviera raro en este proceso,
    # el equivalente via $env:USERPROFILE lo cubre.
    $roamUP = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE "AppData\Roaming" } else { $null }
    $cands = @(
        (Join-Path $env:APPDATA "HDZ-agente.url"),
        $(if ($roamUP) { Join-Path $roamUP "HDZ-agente.url" }),
        (Join-Path $PSScriptRoot "agente.url"),
        (Join-Path $env:APPDATA "HDZ-soporte.cfg"),
        $(if ($roamUP) { Join-Path $roamUP "HDZ-soporte.cfg" }),
        (Join-Path $PSScriptRoot "soporte.cfg")
    ) | Where-Object { $_ } | Select-Object -Unique
    foreach ($f in $cands) {
        try {
            if (-not [System.IO.File]::Exists($f)) { continue }
            $txt = [System.IO.File]::ReadAllText($f)
            $tlen = if ($txt) { $txt.Length } else { 0 }
            $hasAgent = if ($txt) { $txt.Contains('agent') } else { $false }
            if ([string]::IsNullOrWhiteSpace($txt)) {
                try { "  [resolver] '$f' len=$tlen (vacio)" | Out-File $dbg -Append -Encoding UTF8 } catch {}
                continue
            }
            $val = ""
            if ($f -like "*.url") {
                $u = $txt.Trim()
                if ($u -match '(?i)^https?://') { $val = $u }
            } else {
                try { $j = $txt | ConvertFrom-Json; if ($j.agent) { $val = "$($j.agent)".Trim() } } catch {}
                if (-not $val) {
                    $m = [regex]::Match($txt, '"agent"\s*:\s*"([^"]+)"')
                    if ($m.Success) { $val = $m.Groups[1].Value.Trim() }
                }
            }
            try { "  [resolver] '$f' len=$tlen hasAgent=$hasAgent -> '$val'" | Out-File $dbg -Append -Encoding UTF8 } catch {}
            if ($val) { return $val }
        } catch {
            try { "  [resolver] '$f' ERROR: $($_.Exception.Message)" | Out-File $dbg -Append -Encoding UTF8 } catch {}
        }
    }
    return ""
}
function Update-HdzAgentState {
    param([switch]$Force)
    if(-not $script:agSync){return}
    $now=[datetime]::UtcNow
    if(-not $Force -and $script:agSnapshotAt -and ($now-$script:agSnapshotAt).TotalMilliseconds -lt 600){return}
    try {$script:agSync.Estado=Componer-EstadoAgente -Snapshot;$script:agSnapshotAt=[datetime]::UtcNow} catch {return}
    $script:agSync.PushNow=$true
}
function Start-HdzAgentStateTimer {
    if($script:agStateTimer){$script:agStateTimer.Stop()}
    $script:agStateTimer=[Windows.Threading.DispatcherTimer]::new()
    $script:agStateTimer.Interval=[TimeSpan]::FromMilliseconds(700)
    $script:agStateTimer.Add_Tick({Update-HdzAgentState})
    $script:agStateTimer.Start()
}
function Iniciar-Agente {
    $script:agDbg = Join-Path $env:TEMP "hdz_agente.log"
    try { "[$(Get-Date -f 'HH:mm:ss')] Iniciar-Agente: modoTest=$($script:modoTest) agentUrl='$($script:agentUrl)' keyLen=$($script:soporteKey.Length)" | Out-File $script:agDbg -Append -Encoding UTF8 } catch {}
    if ($script:modoTest) { return }
    # Respaldo a prueba de balas: reresolvemos SIEMPRE con lectura .NET+regex (independiente de
    # Get-Content/ConvertFrom-Json, que en el proceso GUI daban 'agent' vacio). Si el cfg cargado
    # temprano no trajo la URL, esto la recupera del texto crudo del propio cfg o del .url dedicado.
    if ([string]::IsNullOrWhiteSpace($script:agentUrl)) {
        $r = Resolver-AgentUrl
        if ($r) { $script:agentUrl = $r }
    }
    try { "  APPDATA=$env:APPDATA  agentUrl(final)='$($script:agentUrl)'" | Out-File $script:agDbg -Append -Encoding UTF8 } catch {}
    if ([string]::IsNullOrWhiteSpace($script:agentUrl)) {
        try { "  -> agentUrl vacia; programo reintento" | Out-File $script:agDbg -Append -Encoding UTF8 } catch {}
        # Reintento autorreparable: quizas el fichero aun no estaba listo. Reintenta unas cuantas veces.
        if (-not $script:agReintentos) { $script:agReintentos = 0 }
        if ($script:agReintentos -lt 8) {
            $script:agReintentos++
            $tr = New-Object System.Windows.Threading.DispatcherTimer
            $tr.Interval = [TimeSpan]::FromSeconds(4)
            $tr.Add_Tick({ $this.Stop(); try { Iniciar-Agente } catch {} })
            $tr.Start()
        }
        return
    }
    $script:agSync = [hashtable]::Synchronized(@{
        Estado = $null; Online = $false; Stop = $false; PushNow = $false
        Cmds   = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    })
    $ps = [powershell]::Create()
    [void]$ps.AddScript($agenteWorker.ToString()).AddArgument($script:agentUrl).AddArgument($script:soporteKey).AddArgument($script:agSync).AddArgument($script:agDbg)
    [void]$ps.BeginInvoke(); $script:agPS = $ps
    $script:agTickLog = $false
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(700)
    $t.Add_Tick({
        if (-not $script:agSync) { return }
        # Aplica comandos PRIMERO, luego recompón el estado (así refleja el comando recién aplicado)
        # y pide empuje inmediato para que el panel vea el cambio sin esperar al ciclo normal.
        $q = $script:agSync.Cmds; $aplicado = $false
        $budget=[Diagnostics.Stopwatch]::StartNew();$processed=0
        while ($q.Count -gt 0 -and $processed -lt 4 -and ($processed -eq 0 -or $budget.ElapsedMilliseconds -lt 40)) { $c = $q.Dequeue(); Aplicar-ComandoAgente $c; $aplicado = $true; $processed++ }
        $err = $null
        try { if($aplicado){Update-HdzAgentState -Force}else{Update-HdzAgentState} } catch { $err = "$($_.Exception.Message)" }
        if (-not $script:agTickLog) { $script:agTickLog = $true; try { "[$(Get-Date -f 'HH:mm:ss')] UI tick #1: EstadoLen=$("$($script:agSync.Estado)".Length) ComponerErr=$err" | Out-File $script:agDbg -Append -Encoding UTF8 } catch {} }
        if ($aplicado) { $script:agSync.PushNow = $true }
    })
    $t.Start(); $script:agTimer = $t
    # Un Tick que está ejecutando una orden no vuelve a entrar mientras espera.
    # Otro temporizador publica el progreso durante esas esperas asíncronas.
    Start-HdzAgentStateTimer
    try { Set-Estado "🌐 Control remoto activo (panel web)." } catch {}
}
function Detener-Agente {
    try { if ($script:agSync) { $script:agSync.Stop = $true } } catch {}
    try { if ($script:agTimer) { $script:agTimer.Stop() } } catch {}
    try { if ($script:agStateTimer) { $script:agStateTimer.Stop() } } catch {}
}

# Logo del tracker (junto a la GUI); si no existe, texto de respaldo «HDZERO».
# Acepta el logo nuevo (incluye «STUDIO») o el antiguo como reserva.
$rutaLogo = @(
    (Join-Path $PSScriptRoot "HDZero New logo.png"),
    (Join-Path $PSScriptRoot "hdz_logo_r.png")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($rutaLogo) {
    try {
        $bmpLogo = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmpLogo.BeginInit()
        $bmpLogo.UriSource = New-Object System.Uri($rutaLogo)
        # SIN DecodePixelHeight y SIN BitmapScalingMode a propósito: la imagen se mantiene a
        # resolución nativa y se muestra lo más pura posible (escalado por defecto de WPF, sin
        # reducciones encadenadas ni suavizado extra que restaban definición).
        $bmpLogo.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmpLogo.EndInit()
        $ui.imgLogo.Source = $bmpLogo
        $ui.imgLogo.Visibility = "Visible"
        $ui.panLogoTexto.Visibility = "Collapsed"
        $script:logoCargado = $true
    } catch {}
}

# Icono de la ventana (y de la barra de tareas) = HDZ.ico cuadrado de marca.
# OJO: NO usar BitmapImage(UriSource=.ico): coge el frame de 16 px (¡el más pequeño!) y la barra
# de tareas lo escala → icono diminuto. Hay que abrir el decodificador y usar el frame MAYOR (256).
$rutaIco = Join-Path $PSScriptRoot "HDZ.ico"
if (Test-Path -LiteralPath $rutaIco) {
    try {
        $decIco = [System.Windows.Media.Imaging.BitmapDecoder]::Create([Uri]$rutaIco,
                  [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
                  [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $win.Icon = ($decIco.Frames | Sort-Object PixelWidth -Descending)[0]
    } catch {}
}

Restaurar-Ajustes
# La carpeta de salida del .torrent es dato de PROYECTO (arranca en blanco), pero si hay una carpeta
# por defecto en Ajustes, la usamos para prerrellenarla (así el montaje deja ahí el .torrent).
if ([string]::IsNullOrWhiteSpace($ui.txtSalidaTorrent.Text) -and -not [string]::IsNullOrWhiteSpace($ui.cfgCarpetaTorrent.Text)) {
    $ui.txtSalidaTorrent.Text = "$($ui.cfgCarpetaTorrent.Text)".Trim()
}
if ([string]::IsNullOrWhiteSpace($ui.txtCarpeta.Text)) { $ui.txtCarpeta.Text = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($ui.cfgTrackerUrl.Text)) { $ui.cfgTrackerUrl.Text = "https://hdzero.org" }
Actualizar-Proyecto
Actualizar-Filtro
Actualizar-Torrent
Actualizar-ModoLote
Actualizar-TipoCategoria
Construir-Firmas
if ([string]::IsNullOrWhiteSpace($ui.upDescripcion.Text)) { Reset-Descripcion }
. (Join-Path $PSScriptRoot 'HDZ-Interface.ps1')
Initialize-HdzInterface
Initialize-HdzAudioTracks
. (Join-Path $PSScriptRoot 'HDZ-Design.ps1')
Initialize-HdzDesign
Init-Tabs
Actualizar-PanelHost
Set-Estado "Elige la carpeta de los vídeos: las opciones se adaptarán a lo que se detecte."

if ($script:modoTest) {
    # Modo test: carpeta opcional por variable de entorno, escaneo síncrono y
    # renderizado de cada sección a PNG (sin mostrar la ventana).
    if ($env:HDZ_GUI_TEST_TEMPORADAS) {
        Set-CarpetasTemporadas @($env:HDZ_GUI_TEST_TEMPORADAS -split ';' | Where-Object { $_ })
    } elseif ($env:HDZ_GUI_TEST_DIR) {
        $ui.txtCarpeta.Text = $env:HDZ_GUI_TEST_DIR
    }
    Lanzar-Escaneo
    if ($env:HDZ_GUI_TEST_AUDIO_LANGS) {
        $langsTest = @("$($env:HDZ_GUI_TEST_AUDIO_LANGS)".ToLowerInvariant() -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        foreach ($chipAud in @($script:chipsIdiomasAudio)) { $chipAud.IsChecked = ($langsTest -contains "$($chipAud.Tag)") }
        $dispAud = @($script:chipsIdiomasAudio | ForEach-Object { "$($_.Tag)" })
        $selAud = @($script:chipsIdiomasAudio | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
        Write-Host "TEST_AUDIO_LANGS: disponibles=[$($dispAud -join ',')] seleccionados=[$($selAud -join ',')] visible=$($ui.cardFiltroAudio.Visibility)"
    }
    if ($env:HDZ_GUI_TEST_EPEDIT) {
        $primeraCaja = @($script:epTextboxes.GetEnumerator() | Select-Object -First 1)
        if ($primeraCaja.Count -gt 0) {
            $cajaEp = $primeraCaja[0].Value
            $cajaEp.Text = "$($env:HDZ_GUI_TEST_EPEDIT)"
            $miembrosEp = @("$($cajaEp.Tag)" -split '\|' | Where-Object { $_ })
            $guardadosEp = @($miembrosEp | ForEach-Object { "$_=$($script:episodiosMap[$_])" })
            Write-Host "TEST_EPEDIT: texto='$($cajaEp.Text)' guardados=[$($guardadosEp -join ' | ')]"
        } else {
            Write-Host "TEST_EPEDIT: ERROR no se encontró ningún editor de episodio."
        }
    }
    if ($env:HDZ_GUI_TEST_SERIE) {
        $epMuestra = @($script:ultimoScan | Select-Object -First 3 | ForEach-Object {
            "$($_.Nombre) => $(Detectar-EpisodioGui $_.Nombre)"
        })
        Write-Host "TEST_SERIE: activa=$([bool]$ui.swSerie.IsChecked) titulo='$($ui.txtTitulo.Text)' episodios=[$($epMuestra -join ' | ')]"
    }
    if ($env:HDZ_GUI_TEST_TEMPORADAS) {
        $csTest = @(Get-CarpetasEntrada)
        Write-Host "TEST_TEMPORADAS: carpetas=$($csTest.Count) videos=$(@($script:ultimoScan).Count) desc='$($ui.lblCarpetaDesc.Text)'"
        if ($env:HDZ_GUI_TEST_LANZAR -eq "1") {
            Iniciar-Montaje 'unico'
            Write-Host "TEST_TEMPORADAS_JOBS: $(@($script:testJobsMontaje).Count)"
        }
    }
    # Gancho de test: simular la deselección de un archivo (nombre exacto)
    if ($env:HDZ_GUI_TEST_DESELECT) {
        $script:seleccion["$($env:HDZ_GUI_TEST_DESELECT)"] = $false
        Refrescar-Adaptacion
    }
    # Gancho de test: simular «Elegir vídeos…» restringiendo a una lista (nombres separados por «;»)
    if ($env:HDZ_GUI_TEST_RESTRINGIR) {
        $script:restringirSeleccion = @($env:HDZ_GUI_TEST_RESTRINGIR -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        Refrescar-Adaptacion
        $marcados = @($script:seleccion.GetEnumerator() | Where-Object { $_.Value -ne $false } | ForEach-Object { $_.Key })
        Write-Host "TEST_RESTRINGIR: marcados = [$($marcados -join ', ')] ; restriccionLimpiada = $($null -eq $script:restringirSeleccion)"
    }
    # Gancho de test: simular clic en la primera firma y reportar la selección + resaltado
    if ($env:HDZ_GUI_TEST_FIRMA -and @($script:firmaBordes).Count -gt 0) {
        $bf = $script:firmaBordes[0].Borde
        $ev = New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
        $ev.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent
        $bf.RaiseEvent($ev)
        Write-Host "TEST_FIRMA: firmaSel = '$($script:firmaSel)' ; grosorBorde = $($script:firmaBordes[0].Borde.BorderThickness.Left)"
    }
    # Gancho de test: seleccionar torrent en modo PACK y comprobar el autorrelleno del nombre
    if ($env:HDZ_GUI_TEST_PACK) {
        Set-ChipValor "torrent" "PACK"
        Write-Host "TEST_PACK: nombrePack = '$($ui.txtPackNombre.Text)'"
    }
    # Gancho de test: poner descripción de ejemplo y activar la pestaña de vista previa
    if ($env:HDZ_GUI_TEST_PREVIEW) {
        $ui.upDescripcion.Text = "[center]`n[img=700]https://image.tmdb.org/t/p/original/logo.png[/img]`n[b]Friends[/b] — Temporada 1`n[/center]"
        $ui.tabPrevia.IsChecked = $true
        Write-Host "TEST_PREVIEW: panPreview visible = $($ui.panPreview.Visibility) ; tools = $($ui.panEdicionTools.Visibility) ; textbox = $($ui.upDescripcion.Visibility)"
    }
    # Gancho de test: flechas con UNA sola pestaña (deben quedar OCULTAS)
    if ($env:HDZ_GUI_TEST_FLECHAS1) {
        $ui.navSubida.IsChecked = $true
        $rt = $win.Content; $rt.Measure([System.Windows.Size]::new(1100,760)); $rt.Arrange([System.Windows.Rect]::new(0,0,1100,760)); $rt.UpdateLayout()
        Update-FlechasTabs
        Write-Host "TEST_FLECHAS1(1 tab): viewport=$([int]$ui.scrTabs.ViewportWidth) extent=$([int]$ui.scrTabs.ExtentWidth) flechas=$($ui.btnTabIzq.Visibility)"
    }
    # Gancho de test: menú lateral colapsado (solo iconos)
    if ($env:HDZ_GUI_TEST_COLAPSAR) {
        $script:sidebarColapsado = $true; Aplicar-Sidebar
        Write-Host "TEST_COLAPSAR: ancho sidebar=$($ui.sidebar.Width) navProyecto.Content='$($ui.navProyecto.Content)' lblSec=$($ui.lblSecMontaje.Visibility)"
    }
    # Gancho de test: varias pestañas con títulos largos (estilo MKVToolNix) para ver scroll/flechas
    if ($env:HDZ_GUI_TEST_TABSLONG) {
        $ui.upTitulo.Text = "Cómo Conocí a Vuestra Madre (2005) S01 1080p AMZN WEB-DL DD+ 5.1 H.264-HDZ"
        foreach ($tt in @("Friends (1994) S01 2160p HMAX WEB-DL DV HDR10-HDZ", "La Leyenda de Korra (2012) S01 1080p NF WEB-DL-HDZ")) {
            Nueva-Tab; $ui.upTitulo.Text = $tt
        }
        Construir-TabBar
        Write-Host "TEST_TABSLONG: $(@($script:tabs).Count) pestañas"
        # Comprobar flechas con estas 3 pestañas largas (deben SALIR por desbordamiento)
        $ui.navSubida.IsChecked = $true
        $rt = $win.Content; $rt.Measure([System.Windows.Size]::new(1100,760)); $rt.Arrange([System.Windows.Rect]::new(0,0,1100,760)); $rt.UpdateLayout()
        Update-FlechasTabs
        Write-Host "TEST_FLECHAS(3 tabs): viewport=$([int]$ui.scrTabs.ViewportWidth) extent=$([int]$ui.scrTabs.ExtentWidth) flechas=$($ui.btnTabIzq.Visibility)"
        # Simular arrastre del asa de la descripción (+150 px) y comprobar el alto
        $h0 = $ui.gridDesc.Height
        $ev = New-Object System.Windows.Controls.Primitives.DragDeltaEventArgs(0, 150)
        $ev.RoutedEvent = [System.Windows.Controls.Primitives.Thumb]::DragDeltaEvent
        $ui.gripDesc.RaiseEvent($ev)
        Write-Host "TEST_RESIZE: gridDesc alto inicial=$h0 -> tras +150 = $($ui.gridDesc.Height) (esperado 450)"
    }
    # Gancho de test: secciones por sub único ambiguo + mapa que se enviaría
    if ($env:HDZ_GUI_TEST_SUBSEC) {
        Construir-FilasSubsUnicos @(
            [PSCustomObject]@{ Cod="eng"; Fmt="Text"; Label="Inglés · Texto" },
            [PSCustomObject]@{ Cod="es";  Fmt="Text"; Label="Castellano · Texto" }
        )
        # Marcar el 2º como Forzado
        $script:subsUnicosRows[1].RbForzado.IsChecked = $true
        $mapa = [ordered]@{}
        foreach ($r in @($script:subsUnicosRows)) { $mapa["$($r.Cod)|$($r.Fmt)"] = $(if ($r.RbForzado.IsChecked) { "Forzado" } else { "Completo" }) }
        Write-Host "TEST_SUBSEC: filas=$(@($script:subsUnicosRows).Count) mapa=$(($mapa.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
    }
    # Gancho de test: pestañas de subida (snapshot/restore de estado independiente)
    if ($env:HDZ_GUI_TEST_PROG) {
        $ui.panProgreso.Visibility = "Visible"; $ui.barProgreso.Value = 42; $ui.lblProgresoPct.Text = "42%"; $ui.lblProgreso.Text = "Procesando 2/24: Friends S02E02"
        $ui.panProgreso2.Visibility = "Visible"; $ui.barProgreso2.Value = 73; $ui.lblProgreso2Pct.Text = "73%"; $ui.lblProgreso2.Text = "Ensamblando Friends S02E02"
        Set-ContenidoConsola $true   # estado "ocultar" → glifo de ojo tachado
        Write-Host "TEST_PROG: dos barras visibles + boton consola en modo ocultar"
    }
    # Las tareas de torrent/capturas no son montaje: deben viajar también al panel remoto.
    if ($env:HDZ_GUI_TEST_AUXPROG) {
        $script:torPreparando = $false
        $script:torSync = [hashtable]::Synchronized(@{ Pct = 63; Fin = $false })
        $script:capSync = [hashtable]::Synchronized(@{ Done = 4; Total = 9; Fin = $false })
        $ui.lblTorrentProgreso.Text = "Creando torrent de película de prueba…"
        $ui.lblSubProgreso.Text = "Generando capturas · tonemap HDR…"
        Actualizar-PanelTareasAux
        $auxTest = @((Componer-EstadoAgente | ConvertFrom-Json).tareas | ForEach-Object { "$($_.tipo):$($_.pct):$($_.detalle)" })
        Write-Host "TEST_AUXPROG: [$($auxTest -join ' | ')] panel=$($ui.panTareasAux.Visibility)"
        $script:torSync = $null; $script:capSync = $null
        Actualizar-PanelTareasAux
    }
    if ($env:HDZ_GUI_TEST_TABS) {
        $ui.upTitulo.Text = "Pelicula A"; $ui.upTmdb.Text = "111"
        Nueva-Tab
        $ui.upTitulo.Text = "Pelicula B"; $ui.upTmdb.Text = "222"
        $r1 = "tras crear 2 tabs: activa=$($script:tabActual) titulo='$($ui.upTitulo.Text)' tmdb='$($ui.upTmdb.Text)'"
        Cambiar-Tab 0
        $r2 = "vuelvo a tab 0: titulo='$($ui.upTitulo.Text)' tmdb='$($ui.upTmdb.Text)' (esperado Pelicula A / 111)"
        Cambiar-Tab 1
        $r3 = "voy a tab 1: titulo='$($ui.upTitulo.Text)' tmdb='$($ui.upTmdb.Text)' (esperado Pelicula B / 222)"
        Write-Host "TEST_TABS: nTabs=$(@($script:tabs).Count)`n  $r1`n  $r2`n  $r3"
        Cerrar-Tab 1
        Write-Host "TEST_TABS: tras cerrar tab1 -> nTabs=$(@($script:tabs).Count) activa=$($script:tabActual) titulo='$($ui.upTitulo.Text)'"
    }
    # Gancho de test: modo heterogéneo con dos botones (Procesar esta / Todas) y anti-duplicado.
    if ($env:HDZ_GUI_TEST_MULTIPROC) {
        Set-ChipValor "modoLote" "HETEROGENEO"
        Actualizar-ModoLote
        $nT = @($script:tabsProy).Count
        Actualizar-BotonesIniciar
        $b1 = "btnIniciar='$($ui.btnIniciar.Content)' vis=$($ui.btnIniciar.Visibility) en=$($ui.btnIniciar.IsEnabled)"
        $b2 = "btnIniciarTodos vis=$($ui.btnIniciarTodos.Visibility) en=$($ui.btnIniciarTodos.IsEnabled)"
        $b3 = "(sin tabs)"
        if ($nT -gt 0) {
            $script:gruposLanzados["$($script:tabsProy[0].Principal)"] = $true   # simula lanzar la peli activa (tab 0)
            Actualizar-BotonesIniciar
            $todasEn = if ($nT -gt 1) { "True(quedan)" } else { "False(no quedan)" }
            $b3 = "tras marcar tab0: btnIniciar.en=$($ui.btnIniciar.IsEnabled) (esperado False) ; todos.en=$($ui.btnIniciarTodos.IsEnabled) (esperado $todasEn)"
        }
        Write-Host "TEST_MULTIPROC: nTabs=$nT`n  $b1`n  $b2`n  $b3"
        # Estado del agente: ¿expone las pestañas por película para el web?
        try {
            $est = Componer-EstadoAgente | ConvertFrom-Json
            $tabsTxt = @($est.tabsProy | ForEach-Object { "[$($_.i)]$($_.titulo)$(if($_.activa){'*'})" }) -join " "
            $loteTxt = @($est.lote | ForEach-Object { "$($_.nombre)" }) -join " | "
            Write-Host "TEST_AGENTE_TABS: modo=$($est.opciones.modoLote) activa=$($est.tabProyActual) tabs={ $tabsTxt }"
            Write-Host "TEST_AGENTE_LOTE: scan=$(@($script:ultimoScan).Count) enviados=$(@($est.lote).Count) -> { $loteTxt }"
            $b0 = @($est.lote)[0]
            $bTxt = @($b0.badges | ForEach-Object { "[$($_.s)]$($_.t)" }) -join " "
            Write-Host "TEST_AGENTE_BADGES: $($b0.nombre) -> $bTxt"
            Write-Host "TEST_AGENTE_EXTRA: resumen='$($est.resumen)' estado='$($est.estado)' packIn=$([bool]($est.inputs.PSObject.Properties.Name -contains 'packNombre'))"
        } catch { Write-Host "TEST_AGENTE_TABS: ERROR $($_.Exception.Message)" }
    }
    # Gancho de test: construir miniaturas de capturas desde una carpeta con .png/.jpg
    if ($env:HDZ_GUI_TEST_CAPSDIR -and (Test-Path -LiteralPath $env:HDZ_GUI_TEST_CAPSDIR)) {
        $testCaps = @(Get-ChildItem -LiteralPath $env:HDZ_GUI_TEST_CAPSDIR -File |
            Where-Object { $_.Extension -match '(?i)^\.(png|jpe?g)$' } |
            Select-Object -First 4 -ExpandProperty FullName)
        if ($testCaps.Count -gt 0) { Construir-Capturas $testCaps; Write-Host "TEST_CAPS: $($testCaps.Count) miniatura(s)" }
    }
    # Gancho de test: modo remezcla — añadir carpetas, leer roles, preview y cfg.
    if ($env:HDZ_GUI_TEST_REMEZCLA) {
        $ui.swRemezcla.IsChecked = $true
        $archivosRzTest = @("$($env:HDZ_GUI_TEST_REMEZCLA_FILES)" -split ';' | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
        if ($archivosRzTest.Count -gt 0) {
            foreach ($af in $archivosRzTest) { Add-FilaRemezcla (Split-Path $af -Parent) $af }
        } else {
            Add-FilaRemezcla "C:\v\Pelis 4K"
            Add-FilaRemezcla "C:\v\Pelis 1080p"
            Add-FilaRemezcla "C:\v\Subs"
        }
        $cs = Leer-RemezclaCarpetas
        $resumen = @($cs | ForEach-Object { "$(Split-Path $_.Ruta -Leaf)[V=$($_.Video) A=$($_.Audio) S=$($_.Subs)]" }) -join " | "
        Write-Host "TEST_REMEZCLA: carpetas=$($cs.Count) | $resumen | panelVisible=$($ui.panRemezcla.Visibility)"
        $cfgRz = @{ Carpetas = @($cs | ForEach-Object { @{ Ruta = $_.Ruta; Archivo = $_.Archivo; Video = [bool]$_.Video; Audio = [bool]$_.Audio; Subs = [bool]$_.Subs } }) }
        Write-Host "TEST_REMEZCLA_CFG: $($cfgRz | ConvertTo-Json -Depth 6 -Compress)"
        # Idiomas: simular un análisis combinado y construir los chips.
        $script:ultimoScan = @(
            @{ Nombre="x.mkv"; Ruta="C:\v\x.mkv"; Video=@{Height=2160}
               Audios=@(@{Lang="spa";Codec="eac3";Profile="";Channels=6;Title=""}, @{Lang="spa";Codec="eac3";Profile="";Channels=6;Title="Latino"}, @{Lang="eng";Codec="eac3";Profile="";Channels=6;Title=""})
               Subs=@(@{Lang="spa";Codec="subrip";Title=""}, @{Lang="eng";Codec="subrip";Title=""}, @{Lang="cat";Codec="subrip";Title=""}, @{Lang="ger";Codec="subrip";Title=""}) }
        )
        Construir-PistasRemezcla
        $aud = @($script:remezclaChipsAudio | ForEach-Object { "$($_.Tag)" }) -join ","
        $sub = @($script:remezclaChipsSub | ForEach-Object { "$($_.Tag)" }) -join ","
        Write-Host "TEST_REMEZCLA_IDIOMAS: audios=[$aud] subs=[$sub] panelVisible=$($ui.panRemezclaPistas.Visibility)"
        # Simular desmarcar 'cat' y 'ger' en subs, y 'eng' en audio
        foreach ($c in $script:remezclaChipsSub) { if ("$($c.Tag)" -in @("cat","ger")) { $c.IsChecked=$false } }
        foreach ($c in $script:remezclaChipsAudio) { if ("$($c.Tag)" -eq "eng") { $c.IsChecked=$false } }
        $audSel = @($script:remezclaChipsAudio | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
        $subSel = @($script:remezclaChipsSub | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
        Write-Host "TEST_REMEZCLA_SEL: IdiomasAudioMantener=[$($audSel -join ',')] IdiomasSubsMantener=[$($subSel -join ',')]"
        # La remezcla nueva no empareja títulos: dos nombres distintos elegidos por el usuario se
        # convierten en UNA composición con vídeo del primero y pistas según sus interruptores.
        $mV = [PSCustomObject]@{ Ruta="C:\manual\The.Last.House.2026.mkv"; Nombre="The.Last.House.2026.mkv"; Error=$null; Video=@{Height=2160;Codec="hevc"}; Audios=@(@{Lang="eng";Codec="eac3"}); Subs=@() }
        $mP = [PSCustomObject]@{ Ruta="C:\manual\La ultima casa (2026).mkv"; Nombre="La ultima casa (2026).mkv"; Error=$null; Video=@{Height=1080;Codec="h264"}; Audios=@(@{Lang="spa";Codec="eac3"}); Subs=@(@{Lang="spa";Codec="subrip"}) }
        $mR = @([PSCustomObject]@{ Ruta="C:\manual";Archivo=$mV.Ruta;Video=$true;Audio=$false;Subs=$false }, [PSCustomObject]@{ Ruta="C:\manual";Archivo=$mP.Ruta;Video=$false;Audio=$true;Subs=$true })
        $mOut = @(Combinar-EscaneoRemezcla @($mV,$mP) $mR)
        Write-Host "TEST_REMEZCLA_MANUAL: salidas=$($mOut.Count) video=$($mOut[0].Nombre) audios=$(@($mOut[0].Audios).Count) subs=$(@($mOut[0].Subs).Count)"

        # Serie en dos versiones: los títulos no coinciden, pero SxxEyy / 1xnn sí. Deben
        # quedar dos salidas y cada una solo con las pistas de su mismo capítulo.
        $sV1 = [PSCustomObject]@{ Ruta="C:\serie\Video\Original.Show.S02E01.2160p.mkv"; Nombre="Original.Show.S02E01.2160p.mkv"; Error=$null; Video=@{Height=2160;Codec="hevc"}; Audios=@(); Subs=@() }
        $sV2 = [PSCustomObject]@{ Ruta="C:\serie\Video\Original.Show.S02E02.2160p.mkv"; Nombre="Original.Show.S02E02.2160p.mkv"; Error=$null; Video=@{Height=2160;Codec="hevc"}; Audios=@(); Subs=@() }
        $sA1 = [PSCustomObject]@{ Ruta="C:\serie\Audio\Titulo castellano 2x1 1080p.mkv"; Nombre="Titulo castellano 2x1 1080p.mkv"; Error=$null; Video=@{Height=1080;Codec="h264"}; Audios=@(@{Lang="spa";Codec="eac3"}); Subs=@(@{Lang="spa";Codec="subrip"}) }
        $sA2 = [PSCustomObject]@{ Ruta="C:\serie\Audio\Titulo castellano 2x02 1080p.mkv"; Nombre="Titulo castellano 2x02 1080p.mkv"; Error=$null; Video=@{Height=1080;Codec="h264"}; Audios=@(@{Lang="spa";Codec="eac3"}); Subs=@(@{Lang="spa";Codec="subrip"}) }
        $sCfg = @([PSCustomObject]@{ Ruta="C:\serie\Video";Archivo="";Video=$true;Audio=$false;Subs=$false }, [PSCustomObject]@{ Ruta="C:\serie\Audio";Archivo="";Video=$false;Audio=$true;Subs=$true })
        $sOut = @(Combinar-EscaneoRemezcla @($sV1,$sV2,$sA1,$sA2) $sCfg)
        $sClaves = @($sOut | ForEach-Object { Get-ClaveRemezcla ([System.IO.Path]::GetFileNameWithoutExtension("$($_.Nombre)")) }) -join ","
        $sPistasOk = (@($sOut | Where-Object { @($_.Audios).Count -eq 1 -and @($_.Subs).Count -eq 1 }).Count -eq 2)
        Write-Host "TEST_REMEZCLA_SERIE: salidas=$($sOut.Count) episodios=[$sClaves] pistasPorEpisodio=$sPistasOk"
    }
    # Gancho de test: «Empezar de Zero» debe vaciar el proyecto, remezcla, subida y cola pendiente.
    if ($env:HDZ_GUI_TEST_RESET) {
        $script:carpetasTemporadas = @("C:\prueba\Temporada 1")
        $script:ultimoScan = @([PSCustomObject]@{ Nombre="pendiente.mkv" })
        $script:seleccion = @{ "pendiente.mkv" = $true }; $script:episodiosMap = @{ "pendiente.mkv" = "S01E01" }
        $script:remezclaCarpetas = @([PSCustomObject]@{ Ruta="C:\prueba\Version A"; Archivo=""; Video=$true; Audio=$false; Subs=$false })
        $script:colaMontaje = @(@{ Nombre="pendiente" })
        $ui.txtCarpeta.Text="C:\prueba\Temporada 1"; $ui.txtTitulo.Text="Título temporal"; $ui.upTitulo.Text="Subida temporal"; $ui.swRemezcla.IsChecked=$true
        Reset-Todo
        $vacio = (@($script:carpetasTemporadas).Count -eq 0 -and @($script:ultimoScan).Count -eq 0 -and $script:seleccion.Count -eq 0 -and @($script:remezclaCarpetas).Count -eq 0 -and @($script:colaMontaje).Count -eq 0)
        $campos = ([string]::IsNullOrWhiteSpace($ui.txtCarpeta.Text) -and [string]::IsNullOrWhiteSpace($ui.txtTitulo.Text) -and [string]::IsNullOrWhiteSpace($ui.upTitulo.Text) -and -not [bool]$ui.swRemezcla.IsChecked)
        Write-Host "TEST_RESET_TOTAL: estadoVacio=$vacio camposVacios=$campos tabsProyecto=$(@($script:tabsProy).Count)"
    }
    # Gancho de test: construir logos de prueba, simular clic en el 2º y comprobar resaltado
    if ($env:HDZ_GUI_TEST_LOGO) {
        Construir-Logos @(
            [PSCustomObject]@{ Url = "https://x/logo1.png"; Width = 800; Height = 300; Lang = "es" },
            [PSCustomObject]@{ Url = "https://x/logo2.png"; Width = 600; Height = 200; Lang = "es" }
        )
        $b1 = $script:logoBordes[1].Borde
        $ev = New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
        $ev.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent
        $b1.RaiseEvent($ev)
        Write-Host "TEST_LOGO: logoSel='$($script:logoSel)' grosor[1]=$($script:logoBordes[1].Borde.BorderThickness.Left) grosor[0]=$($script:logoBordes[0].Borde.BorderThickness.Left)"
    }
    # Gancho de test: modo heterogéneo con 3 películas → pestañas de proyecto por archivo
    if ($env:HDZ_GUI_TEST_HET) {
        $nM="The.Matrix.1999.2160p.NF.WEB-DL.mkv"; $nF="Friends.S01.1994.1080p.HMAX.WEB-DL.mkv"; $nI="Interstellar.2014.1080p.AMZN.WEB-DL.mkv"
        # Análisis simulado: Matrix con DTS + sub und; Friends con audio und + PGS; Interstellar 4 idiomas de subs.
        $script:ultimoScan = @(
            @{ Nombre=$nM; Ruta="C:\v\$nM"; Error=$null; Video=@{Codec="hevc";Height=2160;EsDV=$false;EsHDR=$true}
               Audios=@(@{Index=0;Codec="dts";Profile="MA";Lang="eng";Title="";Forced=$false;Channels=6}, @{Index=1;Codec="eac3";Profile="";Lang="spa";Title="";Forced=$false;Channels=6})
               Subs=@(@{Index=2;Codec="subrip";Lang="und";Title="";Forced=$false;EsPGS=$false}) }
            @{ Nombre=$nF; Ruta="C:\v\$nF"; Error=$null; Video=@{Codec="h264";Height=1080;EsDV=$false;EsHDR=$false}
               Audios=@(@{Index=0;Codec="aac";Profile="";Lang="und";Title="";Forced=$false;Channels=2})
               Subs=@(@{Index=1;Codec="hdmv_pgs_subtitle";Lang="spa";Title="";Forced=$false;EsPGS=$true}) }
            @{ Nombre=$nI; Ruta="C:\v\$nI"; Error=$null; Video=@{Codec="hevc";Height=1080;EsDV=$false;EsHDR=$false}
               Audios=@(@{Index=0;Codec="truehd";Profile="";Lang="eng";Title="";Forced=$false;Channels=8})
               Subs=@(@{Index=1;Codec="subrip";Lang="fre";Title="";Forced=$false;EsPGS=$false}, @{Index=2;Codec="subrip";Lang="ger";Title="";Forced=$false;EsPGS=$false}, @{Index=3;Codec="subrip";Lang="ita";Title="";Forced=$false;EsPGS=$false}, @{Index=4;Codec="subrip";Lang="spa";Title="";Forced=$false;EsPGS=$false}) }
        )
        $script:gruposProy = @(
            @{ Clave="The Matrix";  Principal=$nM; Archivos=@($nM) },
            @{ Clave="Friends";     Principal=$nF; Archivos=@($nF) },
            @{ Clave="Interstellar";Principal=$nI; Archivos=@($nI) }
        )
        Set-ChipValor "modoLote" "HETEROGENEO"
        Actualizar-ModoLote
        $rA = "tab Matrix (activa): cardConvAudio=$($ui.cardConvAudio.Visibility) nOpcsOrigen=$(@($script:convTrackOpts).Count) cardUndSub=$($ui.cardUndSub.Visibility) cardPGS=$($ui.cardPGS.Visibility)"
        # Añadir una conversión en Matrix, ir a Friends (debe verse PGS), volver y comprobar que se conserva.
        [void](Add-FilaConv)
        Cambiar-TabProy 1
        $rB = "tab Friends: cardConvAudio=$($ui.cardConvAudio.Visibility) nFilasConv=$(@($script:convRows).Count) cardPGS=$($ui.cardPGS.Visibility)"
        Cambiar-TabProy 2
        $rC = "tab Interstellar: nOpcsOrigen=$(@($script:convTrackOpts).Count) nFilasConv=$(@($script:convRows).Count) cardFiltro=$($ui.cardFiltro.Visibility)"
        Cambiar-TabProy 0
        $rD = "vuelvo a Matrix: nFilasConv=$(@($script:convRows).Count) (esperado 1: la añadida; ya no hay fila por defecto)"
        # Gathering del config por archivo (replica la lógica de envío): conversiones y und por película.
        $script:tabsProy[$script:tabProyActual].Decisiones = Snapshot-DecisionesTab
        $resumen = @($script:tabsProy | ForEach-Object {
            $d = $_.Decisiones
            $nund = if ($d.Und) { @($d.Und.Keys).Count } else { 0 }
            "$($_.Principal.Substring(0,12))…: Conv=$(@($d.Conv).Count) undPistas=$nund"
        }) -join " | "
        Write-Host "TEST_HET_AV:`n  $rA`n  $rB`n  $rC`n  $rD`n  config: $resumen"
        $r0 = "tras reconstruir: nTabs=$(@($script:tabsProy).Count) activa=$($script:tabProyActual) titulo='$($ui.txtTitulo.Text)' año='$($ui.txtAno.Text)' caps=$(Get-ChipValor 'capturasProy')"
        # Editar plataforma + capturas de la peli 0, ir a la 1 (otras capturas) y volver: deben conservarse.
        $ui.txtPlataformaOtra.Text = "EDITADO-NF"; Set-ChipValor "capturasProy" 20
        Cambiar-TabProy 1
        Set-ChipValor "capturasProy" 3
        $r1 = "tab 1: titulo='$($ui.txtTitulo.Text)' platOtra='$($ui.txtPlataformaOtra.Text)' caps=$(Get-ChipValor 'capturasProy')"
        Cambiar-TabProy 0
        $r2 = "vuelvo a tab 0: titulo='$($ui.txtTitulo.Text)' platOtra='$($ui.txtPlataformaOtra.Text)' caps=$(Get-ChipValor 'capturasProy') (esperado EDITADO-NF / caps 20)"
        # Mapa ProyectoPorArchivo que se enviaría (incluye NumCapturas por archivo)
        if ($script:tabProyActual -ge 0) { $script:tabsProy[$script:tabProyActual].Estado = Snapshot-Proyecto }
        $r3 = @($script:tabsProy | ForEach-Object { "$($_.Principal.Substring(0,[Math]::Min(20,$_.Principal.Length)))…=caps:$($_.Estado.Capturas)" }) -join " | "
        Write-Host "TEST_HET:`n  $r0`n  $r1`n  $r2`n  caps por peli: $r3"
    }
    # Gancho de test: reproduce el alta automática de varias subidas (una por resultado del montaje)
    # y vuelca las capturas que queda con cada pestaña, para cazar el reparto por pestaña.
    if ($env:HDZ_GUI_TEST_SUBIDAS) {
        $files = @(Get-ChildItem $env:HDZ_GUI_TEST_SUBIDAS -ErrorAction SilentlyContinue | Sort-Object Name)
        foreach ($f in $files) {
            $r = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 | Where-Object { $_.Trim() })[0] | ConvertFrom-Json
            if ($r -and $r.torrent -and (Test-Path -LiteralPath $r.torrent)) {
                Anadir-SubidaAuto $r.torrent "$($r.video)" "$($r.origen)" @($r.capturas)
            }
        }
        # snapshot de la pestaña activa para poder inspeccionar TODAS
        if ($script:tabActual -ge 0) { $script:tabs[$script:tabActual] = Snapshot-Subida }
        Write-Host "TEST_SUBIDAS: nTabs=$(@($script:tabs).Count)"
        for ($ti = 0; $ti -lt @($script:tabs).Count; $ti++) {
            $t = $script:tabs[$ti]
            $c0 = @($t.Caps)[0]
            Write-Host ("  snapshot tab {0}: titulo='{1}'  nCaps={2}  cap0={3}" -f $ti, $t.Titulo, @($t.Caps).Count, (Split-Path "$($c0.Ruta)" -Leaf))
        }
        # Ahora exactamente lo que ve el usuario: cambiar a cada pestaña y mirar la REJILLA VIVA.
        for ($ti = 0; $ti -lt @($script:tabs).Count; $ti++) {
            Cambiar-Tab $ti
            $liveC0 = @($script:capRows)[0]
            Write-Host ("  VIVO al abrir tab {0}: activa={1}  nCapRows={2}  cap0={3}" -f $ti, $script:tabActual, @($script:capRows).Count, (Split-Path "$($liveC0.Ruta)" -Leaf))
        }
        # Lo que ve la WEB: estado del agente por cada subida (pestañas + capturas que expone).
        for ($ti = 0; $ti -lt @($script:tabs).Count; $ti++) {
            Cambiar-Tab $ti
            $est = Componer-EstadoAgente | ConvertFrom-Json
            $subs = @($est.tabsSubida | ForEach-Object { "[$($_.i)]$($_.titulo.Substring(0,[Math]::Min(14,$_.titulo.Length)))$(if($_.activa){'*'})" }) -join " "
            $c0 = (Split-Path "$(@($est.capturas)[0].nombre)" -Leaf)
            Write-Host ("  WEB con subida {0} activa: tabsSubida={{ {1} }} capturasWeb={2} cap0={3}" -f $ti, $subs, @($est.capturas).Count, $c0)
        }
        # DEDUPE: re-añadir una subida ya existente (simula reprocesar) NO debe crear pestaña nueva.
        $nAntes = @($script:tabs).Count
        $rDup = @(Get-Content -LiteralPath (@(Get-ChildItem $env:HDZ_GUI_TEST_SUBIDAS | Sort-Object Name)[-1]).FullName -Encoding UTF8 | Where-Object { $_.Trim() })[0] | ConvertFrom-Json
        Anadir-SubidaAuto $rDup.torrent "$($rDup.video)" "$($rDup.origen)" @($rDup.capturas)
        Write-Host "TEST_DEDUPE: tabs antes=$nAntes  despues de re-anadir=$(@($script:tabs).Count)  (esperado igual)"
        # CLAVE: título (name) que se ENVIARÍA en cada pestaña, comparado con su torrent.
        Write-Host "TEST_TITULOS (name vs torrent por pestaña):"
        for ($ti = 0; $ti -lt @($script:tabs).Count; $ti++) {
            Cambiar-Tab $ti
            $nameEnv = "$($ui.upTitulo.Text)"
            $torr = Split-Path "$($ui.txtTorrentSubir.Text)" -Leaf
            $ok = if ($torr -like "*$($nameEnv.Substring(0,[Math]::Min(12,$nameEnv.Length)))*") { "OK" } else { "¡CRUZADO!" }
            Write-Host ("  tab {0}: name='{1}'  torrent='{2}'  -> {3}" -f $ti, $nameEnv, $torr, $ok)
        }
    }
    try {
        $w = 1100; $h = 760
        $root = $win.Content
        if ($env:HDZ_GUI_TEST_TMDBKEY) { $ui.cfgTmdbKey.Text = $env:HDZ_GUI_TEST_TMDBKEY }
        if ($env:HDZ_GUI_TEST_TORRENT) { Cargar-TorrentParaSubir $env:HDZ_GUI_TEST_TORRENT }
        foreach ($sec in @("navProyecto", "navSubida", "navAjustes")) {
            $ui[$sec].IsChecked = $true
            $root.Measure([System.Windows.Size]::new($w, $h))
            $root.Arrange([System.Windows.Rect]::new(0, 0, $w, $h))
            $root.UpdateLayout()
            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32))
            $rtb.Render($root)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $png = Join-Path $env:TEMP "hdz_gui_$sec.png"
            $fs = [System.IO.File]::Open($png, [System.IO.FileMode]::Create)
            $enc.Save($fs); $fs.Close()
            Write-Host "Captura: $png"
        }
        # Render ALTO de un panel concreto (para ver secciones largas sin scroll)
        if ($env:HDZ_GUI_TEST_TALL) {
            $navMap = @{ navSubida="panSubida"; navAjustes="panAjustes"; navProyecto="panCrear" }
            $ui[$env:HDZ_GUI_TEST_TALL].IsChecked = $true
            $pan = $ui[$navMap[$env:HDZ_GUI_TEST_TALL]]
            $hh = 2200
            $pan.Measure([System.Windows.Size]::new(820, $hh))
            $pan.Arrange([System.Windows.Rect]::new(0, 0, 820, $hh))
            $pan.UpdateLayout()
            $realH = [int][Math]::Min(2200, [Math]::Ceiling($pan.ActualHeight) + 20)
            $rtb2 = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(820, $realH, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32))
            $rtb2.Render($pan)
            $enc2 = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc2.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb2))
            $png2 = Join-Path $env:TEMP "hdz_gui_tall_$($env:HDZ_GUI_TEST_TALL).png"
            $fs2 = [System.IO.File]::Open($png2, [System.IO.FileMode]::Create)
            $enc2.Save($fs2); $fs2.Close()
            Write-Host "Captura alta: $png2"
        }
        if ($env:HDZ_GUI_TEST_AGENTE) {
            try { $j = Componer-EstadoAgente; $o = $j | ConvertFrom-Json
                   Write-Host "AGENTE_JSON_OK len=$($j.Length) grupos=$(@($o.opciones.PSObject.Properties).Count) flags=$(@($o.flags.PSObject.Properties).Count) combos=$(@($o.combos.PSObject.Properties).Count) inputs=$(@($o.inputs.PSObject.Properties).Count)"
                   $audAg = @($o.audioIdiomas | ForEach-Object { "$($_.v)=$($_.sel)" })
                   Write-Host "AGENTE_AUDIO: visible=$($o.audioIdiomasVisible) idiomas=[$($audAg -join ',')]"
                  Write-Host "AGENTE_CONDICIONAL: defAudio=$($o.defAudioVisible) pgs=$($o.pgsVisible)"
                  if ($env:HDZ_GUI_TEST_AGENT_AUDIO_CODE) {
                      Aplicar-ComandoAgente ([PSCustomObject]@{ type = "set_audio_lang"; code = "$($env:HDZ_GUI_TEST_AGENT_AUDIO_CODE)"; value = $false })
                      $o2 = (Componer-EstadoAgente | ConvertFrom-Json)
                      $audAg2 = @($o2.audioIdiomas | ForEach-Object { "$($_.v)=$($_.sel)" })
                      Write-Host "AGENTE_AUDIO_CMD: idiomas=[$($audAg2 -join ',')]"
                  }
                  if ($env:HDZ_GUI_TEST_AGENT_DYNAMIC) {
                      $d0 = Componer-EstadoAgente | ConvertFrom-Json
                      if (@($d0.pistasConversionAudio).Count -gt 0) {
                          $p = @($d0.pistasConversionAudio)[0]; $dst = @($p.destinos)[0].v
                          Aplicar-ComandoAgente ([PSCustomObject]@{ type = "set_conv"; rows = @([PSCustomObject]@{ Index = "$($p.v)"; Dest = "$dst"; MantenerOriginal = $false }) })
                      }
                      if (@($d0.undAudioSubs).Count -gt 0) {
                          $u = @($d0.undAudioSubs)[0]; $uv = @($d0.idiomasPistaOpciones)[0].v
                          Aplicar-ComandoAgente ([PSCustomObject]@{ type = "set_und"; archivo = "$($u.archivo)"; id = "$($u.id)"; tipo = "$($u.tipo)"; value = "$uv" })
                      }
                      if (@($d0.idiomasSubs).Count -gt 0) { $sl = @($d0.idiomasSubs)[0]; Aplicar-ComandoAgente ([PSCustomObject]@{ type = "set_sub_lang"; code = "$($sl.v)"; value = $true }) }
                      if (@($d0.subsUnicos).Count -gt 0) { Aplicar-ComandoAgente ([PSCustomObject]@{ type = "set_sub_unico"; idx = 1; forzado = $true }) }
                      $d1 = Componer-EstadoAgente | ConvertFrom-Json
                      Write-Host "AGENTE_DINAMICO: conv=$(@($d1.conversionesAudio).Count) und=$(@($d1.undAudioSubs).Count) subLang=$(@($d1.idiomasSubs).Count) subUnicos=$(@($d1.subsUnicos).Count)"
                  }
            }
            catch { Write-Host "AGENTE_JSON_ERR: $($_.Exception.Message)" }
        }
        Write-Host "HDZ-GUI: ventana construida y análisis ejecutado correctamente (modo test)."
    } catch {
        Write-Host "HDZ-GUI: error en modo test: $($_.Exception.Message)"
    }
} else {
    Lanzar-Escaneo
    try { Iniciar-Agente } catch {}
    [void]$win.ShowDialog()
}
