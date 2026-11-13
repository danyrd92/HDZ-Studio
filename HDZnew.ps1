#requires -Version 7.0
# =========================================================================
# SCRIPT MAESTRO HDZ: LÍNEA DE MONTAJE AUTOMATIZADA (BATCH EDITION)
# Versión refactorizada
# =========================================================================
# NOTA: requiere PowerShell 7+ (usa ProcessStartInfo.ArgumentList, que no existe
# en Windows PowerShell 5.1). El #requires lo hace fallar limpiamente al inicio
# en lugar de reventar a mitad de proceso.

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$rutaCarpeta = (Get-Location).Path
$ErrorActionPreference = "Stop"
$script:hdzMotorMutex = [Threading.Mutex]::new($false, 'Global\HDZStudio.Motor')
try { $motorAvailable = $script:hdzMotorMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $motorAvailable = $true }
if (-not $motorAvailable) { throw 'Ya existe un montaje activo en este equipo. No se iniciará otro motor.' }

# Herramientas portables incluidas (ffmpeg, mkvmerge, mediainfo, dovi_tool…): si existe bin\ junto
# a este script, la anteponemos al PATH para usar SIEMPRE esas versiones probadas (no las del sistema).
$rutaBinHDZ = Join-Path $PSScriptRoot "bin"
if ((Test-Path -LiteralPath $rutaBinHDZ) -and ($env:PATH -notlike "*$rutaBinHDZ*")) { $env:PATH = "$rutaBinHDZ;$env:PATH" }
. (Join-Path $PSScriptRoot "HDZ-Capturas.ps1")
. (Join-Path $PSScriptRoot "HDZ-Core.ps1")
. (Join-Path $PSScriptRoot "HDZ-History.ps1")

# --- HORA EN CONSOLA ---
# Antepone [HH:mm:ss] al inicio de cada línea que escribe el motor, para ver de un vistazo si una
# tarea acaba de empezar o lleva rato parada. Interceptamos Write-Host (el motor lo usa en todo el
# flujo) y delegamos en el real, respetando color, separador y -NoNewline. El estado «estamos a
# principio de línea» se lleva en $global:hdzLineaNueva: una llamada con -NoNewline NO cierra la
# línea, así que la siguiente continúa sin volver a estampar la hora. Las líneas en blanco (solo
# espacios/saltos) no se estampan, para no ensuciar los separadores. Como Start-Transcript captura
# la salida de consola, el log del motor también queda con marcas de hora.
$global:hdzLineaNueva = $true
function Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [System.Object[]] $Object,
        [System.Object] $Separator,
        [System.ConsoleColor] $ForegroundColor,
        [System.ConsoleColor] $BackgroundColor,
        [switch] $NoNewline
    )
    $params = @{}
    if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $params['ForegroundColor'] = $ForegroundColor }
    if ($PSBoundParameters.ContainsKey('BackgroundColor')) { $params['BackgroundColor'] = $BackgroundColor }
    $sep = if ($PSBoundParameters.ContainsKey('Separator')) { "$Separator" } else { ' ' }
    $txt = if ($Object) { ($Object -join $sep) } else { '' }
    if ($global:hdzLineaNueva) {
        $pre = [regex]::Match($txt, '^[\r\n]*').Value          # respeta saltos de línea iniciales
        $cuerpo = $txt.Substring($pre.Length)
        if (-not [string]::IsNullOrWhiteSpace($cuerpo)) {
            $txt = $pre + "[$([DateTime]::Now.ToString('HH:mm:ss'))] " + $cuerpo
        }
    }
    Microsoft.PowerShell.Utility\Write-Host -Object $txt -NoNewline:$NoNewline @params
    $global:hdzLineaNueva = -not $NoNewline
}

# --- CONFIGURACIÓN EXTERNA (GUI) ---
# Si la interfaz gráfica (HDZ-GUI.ps1) lanzó este script, deja en $env:HDZ_CONFIG la ruta de
# un JSON con las respuestas pre-elegidas. Cada pregunta consulta primero esa configuración
# (Get-CfgGui) y solo pregunta por consola si la clave no está definida (null = "preguntar").
# Sin la variable de entorno, el script se comporta exactamente igual que siempre.
$global:cfgGui = $null
if ($env:HDZ_CONFIG -and (Test-Path -LiteralPath $env:HDZ_CONFIG)) {
    try {
        $global:cfgGui = Get-Content -LiteralPath $env:HDZ_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host "Configuración de la GUI cargada: $env:HDZ_CONFIG" -ForegroundColor DarkGray
        # Consumir solo el fichero temporal reconocido de esta ejecución. Incluye el announce.
        $configFull = [IO.Path]::GetFullPath($env:HDZ_CONFIG)
        if ($configFull.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $configFull -Leaf) -match '^hdz_gui_config_[A-Za-z0-9_-]+\.json$') { Remove-Item -LiteralPath $configFull -Force -ErrorAction Stop }
    } catch {
        Write-Host "Aviso: no se pudo leer la configuración de la GUI ($($_.Exception.Message)). Se preguntará todo por consola." -ForegroundColor DarkYellow
    }
}
# Cuando la GUI lanza el montaje, el proceso es 100% DESATENDIDO: la consola NUNCA debe preguntar.
# Si por cualquier desajuste faltara una decisión puntual, se aplica un valor por defecto sensato
# (y se registra en el log) en lugar de bloquear el montaje con un Read-Host que nadie verá.
$global:sinPreguntas = [bool]$global:cfgGui

# --- RED DE SEGURIDAD: si pese a todo el montaje necesitara entrada del usuario ---
# La GUI lanza este script en una consola OCULTA. Si quedara algún Read-Host sin cubrir, la GUI
# parecería colgada (el usuario no ve la pregunta). Para evitarlo, interceptamos Read-Host: antes
# de pedir nada, REVELAMOS la consola automáticamente y la traemos al frente, de modo que el
# usuario vea la pregunta y pueda responder. Solo se activa en modo GUI ($env:HDZ_CONFIG).
if ($env:HDZ_CONFIG) {
    try {
        Add-Type -Namespace HdzEng -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]   public static extern bool ShowWindow(System.IntPtr h, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")]   public static extern bool SetForegroundWindow(System.IntPtr h);
'@
    } catch {}

    function Global:Mostrar-ConsolaMontaje {
        # Canal oficial: escribir "1" en la bandera que vigila el hilo C# de la GUI (la mostrará).
        if ($env:HDZ_CONSOLE_FLAG) { try { [System.IO.File]::WriteAllText($env:HDZ_CONSOLE_FLAG, "1") } catch {} }
        # Refuerzo directo sobre nuestra propia ventana de consola (5 = SW_SHOW) + traer al frente.
        try {
            $h = [HdzEng.Win]::GetConsoleWindow()
            if ($h -ne [System.IntPtr]::Zero) {
                [void][HdzEng.Win]::ShowWindow($h, 5)
                [void][HdzEng.Win]::SetForegroundWindow($h)
            }
        } catch {}
    }

    # Intercepta TODAS las llamadas a Read-Host del script: muestra la consola y avisa antes de pedir.
    function Global:Read-Host {
        [CmdletBinding()]
        param(
            [Parameter(Position = 0)] [string]$Prompt,
            [switch]$AsSecureString
        )
        Mostrar-ConsolaMontaje
        Write-Host ""
        Write-Host "  ===================================================================" -ForegroundColor Yellow
        Write-Host "  [!] El montaje necesita tu respuesta. Esta ventana se ha abierto sola." -ForegroundColor Yellow
        Write-Host "      Contesta aquí abajo para que el proceso continúe." -ForegroundColor Yellow
        Write-Host "  ===================================================================" -ForegroundColor Yellow
        if ($AsSecureString) { return Microsoft.PowerShell.Utility\Read-Host -Prompt $Prompt -AsSecureString }
        return Microsoft.PowerShell.Utility\Read-Host -Prompt $Prompt
    }
}

# Devuelve el valor de una clave de la configuración GUI, o $null si no está definida
# (en cuyo caso el script pregunta por consola como siempre).
function Get-CfgGui($nombre) {
    if (-not $global:cfgGui) { return $null }
    if ($global:cfgGui.PSObject.Properties.Name -notcontains $nombre) { return $null }
    $v = $global:cfgGui.$nombre
      if ($null -eq $v -or ($v -is [string] -and "$v" -eq "")) { return $null }
    return $v
}
# Decisión forzado/completo de un sub único, POR idioma+formato (la GUI manda una sección por sub
# en SubsUnicosPorIdioma = mapa "<cod>|<Text|PGS>" -> "Forzado"/"Completo"). Respaldo: decisión global.
function Get-DecisionSubGui($cod, $fmt, $archivo = $null) {
    $clave = "$cod|$fmt"
    # POR ARCHIVO (modo «Cada archivo distinto»): mapa SubsUnicosPorArchivo[nombre][cod|fmt].
    if ($archivo) {
        $mapaPA = Get-CfgGui "SubsUnicosPorArchivo"
        if ($mapaPA -and ($mapaPA.PSObject.Properties.Name -contains $archivo)) {
            $sub = $mapaPA.$archivo
            if ($sub -and ($sub.PSObject.Properties.Name -contains $clave)) { return "$($sub.$clave)" }
        }
    }
    $mapa = Get-CfgGui "SubsUnicosPorIdioma"
    if ($mapa) {
        if ($mapa.PSObject.Properties.Name -contains $clave) { return "$($mapa.$clave)" }
    }
    return (Get-CfgGui "SubsUnicosDecision")
}

# --- PROGRESO PARA LA GUI ---
# Si la GUI lanzó este script, deja en $env:HDZ_PROGRESS la ruta de un JSON que vamos
# actualizando con el avance del montaje; la interfaz lo lee y mueve su barra de progreso.
# Sin la variable, estas funciones no hacen nada (ejecución directa por consola igual que siempre).
$global:rutaProgreso = $env:HDZ_PROGRESS
# Estado de progreso. La barra PRINCIPAL (pct/fase/archivo) refleja el avance global del lote.
# La barra SECUNDARIA (pct2/fase2) muestra el detalle de la tarea en curso (p.ej. el ensamblado
# del MKV con mkvmerge). pct2 = -1 oculta la segunda barra.
$global:gPct = 0; $global:gFase = ""; $global:gArchivo = ""; $global:gPct2 = -1; $global:gFase2 = ""
function Write-ProgresoGui([bool]$fin = $false) {
    if (-not $global:rutaProgreso) { return }
    try {
        ([ordered]@{ pct = $global:gPct; fase = $global:gFase; archivo = $global:gArchivo;
            pct2 = $global:gPct2; fase2 = $global:gFase2; fin = $fin } |
            ConvertTo-Json -Compress) | Set-Content -LiteralPath $global:rutaProgreso -Encoding UTF8
    } catch {}
}
function Set-ProgresoGui([int]$pct, [string]$fase, [string]$archivo = "") {
    if ($pct -lt 0) { $pct = 0 } elseif ($pct -gt 100) { $pct = 100 }
    $global:gPct = $pct; $global:gFase = $fase; $global:gArchivo = $archivo
    Write-ProgresoGui
}
# Segunda barra (detalle de la tarea actual). $pct2 = -1 para ocultarla.
function Set-ProgresoGui2([int]$pct2, [string]$fase2 = "") {
    if ($pct2 -gt 100) { $pct2 = 100 }
    $global:gPct2 = $pct2; $global:gFase2 = $fase2
    Write-ProgresoGui
}
function Set-ProgresoGuiFin([string]$fase) {
    $global:gPct = 100; $global:gFase = $fase; $global:gArchivo = ""; $global:gPct2 = -1; $global:gFase2 = ""
    Write-ProgresoGui $true
}
$global:idxGrupoGui = 0
$global:totalGruposGui = 0

# Formatea segundos como «1h 05m» / «12m 30s» / «45s» (para los tiempos restantes).
function Format-Restante([double]$seg) {
    if ($seg -lt 0 -or [double]::IsInfinity($seg) -or [double]::IsNaN($seg)) { return "?" }
    # OJO con [int] aquí: PowerShell redondea al par más cercano ([int]1.5 -> 2), así que
    # 5400 s (1h 30m) salía como «2h 30m». Hay que truncar con Floor, no redondear.
    $t = [TimeSpan]::FromSeconds([Math]::Min($seg, 359999))
    if ($t.TotalHours -ge 1) { return ("{0}h {1:00}m" -f [int][Math]::Floor($t.TotalHours), $t.Minutes) }
    if ($t.TotalMinutes -ge 1) { return ("{0}m {1:00}s" -f [int][Math]::Floor($t.TotalMinutes), $t.Seconds) }
    return ("{0}s" -f [int][Math]::Floor($t.TotalSeconds))
}

# Mueve un archivo MOSTRANDO PROGRESO REAL cuando origen y destino están en discos distintos.
#
# POR QUÉ: Move-Item entre volúmenes distintos NO es un renombrado — Windows copia el archivo
# entero byte a byte y luego borra el origen. Con un remux de 57 GB eso son DECENAS DE MINUTOS
# sin una sola señal en pantalla, y el usuario cree que el programa se ha colgado (pasó de verdad:
# carpeta de trabajo en C:\ y carpeta de procesados en L:\). Además Windows PREASIGNA el destino
# a su tamaño final, así que ni mirando el tamaño del archivo se ve avance.
#
# Mismo volumen -> Move-Item de toda la vida (renombrado instantáneo, no hay nada que mostrar).
# Distinto volumen -> copia por bloques con % + MB/s + tiempo restante en la 2ª barra, y el origen
# se borra SOLO si la copia terminó bien (si falla, no se pierde nada).
function Move-ConProgreso($origen, $destino, [string]$etiqueta = "Moviendo archivo") {
    if (Test-Path -LiteralPath $destino) { throw "El destino ya existe: $destino. No se sobrescribe." }
    $volO = ""; $volD = ""
    try { $volO = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($origen)) } catch {}
    try { $volD = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($destino)) } catch {}
    if ($volO -and $volD -and ($volO.TrimEnd('\') -ieq $volD.TrimEnd('\'))) {
        Move-Item -LiteralPath $origen -Destination $destino -ErrorAction Stop
        return
    }
    $total = (Get-Item -LiteralPath $origen).Length
    Assert-HdzFreeSpace (Split-Path $destino -Parent) ($total + 10MB)
    $gb = [math]::Round($total / 1GB, 2)
    Write-Host "   -> $etiqueta ($gb GB) entre discos distintos: hay que COPIAR, no vale renombrar. Esto tarda." -ForegroundColor DarkYellow
    Write-DiagPaso "$etiqueta : copia entre volúmenes ($volO -> $volD), $gb GB"
    # Copia nativa de Windows (CopyFileEx): medido con un NAS por SMB, 61-66 MB/s frente a 48 MB/s
    # de la copia por bloques de PowerShell (pide lecturas/escrituras en paralelo al servidor).
    # El aviso de progreso llega en el mismo hilo, así que la 2ª barra sigue funcionando.
    if (-not ('HdzCopia.Nativa' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace HdzCopia {
  public static class Nativa {
    delegate uint Rutina(long total, long hecho, long sTotal, long sHecho, uint flujo, uint motivo, IntPtr o, IntPtr d, IntPtr dato);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CopyFileExW(string origen, string destino, Rutina progreso, IntPtr dato, IntPtr cancelar, uint flags);
    // COPY_FILE_FAIL_IF_EXISTS: nunca sobrescribe un destino existente.
    public static void Copiar(string origen, string destino, Action<long, long> progreso) {
      Rutina rutina = (total, hecho, a, b, f, m, o, d, x) => { if (progreso != null) progreso(hecho, total); return 0; };
      if (!CopyFileExW(origen, destino, rutina, IntPtr.Zero, IntPtr.Zero, 1)) throw new Win32Exception(Marshal.GetLastWin32Error());
      GC.KeepAlive(rutina);
    }
  }
}
'@
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $estado = @{ UltMs = -1000L }
    $alAvanzar = [Action[long, long]]{
        param($copiado, $tot)
        # Refresco cada 500 ms: escribir el JSON de progreso en cada bloque costaría más que la copia.
        if (($sw.ElapsedMilliseconds - $estado.UltMs) -lt 500 -and $copiado -lt $tot) { return }
        $estado.UltMs = $sw.ElapsedMilliseconds
        $seg = $sw.Elapsed.TotalSeconds
        $pct = if ($tot -gt 0) { [int](100 * $copiado / $tot) } else { 0 }
        $mbs = if ($seg -gt 0) { [math]::Round(($copiado / 1MB) / $seg, 1) } else { 0 }
        $eta = if ($copiado -gt 0 -and $seg -gt 0) { Format-Restante ((($tot - $copiado) * $seg) / $copiado) } else { "?" }
        Set-ProgresoGui2 $pct "$etiqueta ($gb GB) · $mbs MB/s · quedan $eta"
    }
    try {
        [HdzCopia.Nativa]::Copiar([System.IO.Path]::GetFullPath($origen), [System.IO.Path]::GetFullPath($destino), $alAvanzar)
        if ((Get-Item -LiteralPath $destino -Force).Length -ne $total) { throw 'La copia tiene un tamaño distinto al original.' }
        Remove-Item -LiteralPath $origen -Force -ErrorAction Stop   # solo tras copiar OK
        Set-ProgresoGui2 -1
        Write-DiagPaso "$etiqueta : copia OK en $(Format-Restante $sw.Elapsed.TotalSeconds)"
    } catch {
        # Copia a medias -> se borra el destino (lo creó esta copia: CopyFileEx no sobrescribe y el
        # destino no existía al empezar); el origen se queda donde estaba.
        # Excepto si falló justo porque el destino apareció entretanto (ERROR_FILE_EXISTS/ALREADY_EXISTS).
        $yaExistia = $_.Exception.InnerException -is [System.ComponentModel.Win32Exception] -and $_.Exception.InnerException.NativeErrorCode -in @(80, 183)
        try { if (-not $yaExistia -and (Test-Path -LiteralPath $destino)) { Remove-Item -LiteralPath $destino -Force -ErrorAction SilentlyContinue } } catch {}
        Set-ProgresoGui2 -1
        throw
    }
}

# ¿La ruta está en una unidad de red (UNC o letra asignada a un recurso compartido)?
function Test-HdzRutaRed([string]$ruta) {
    try {
        $full = [System.IO.Path]::GetFullPath($ruta)
        if ($full.StartsWith('\\')) { return $true }
        return ([System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($full)).DriveType -eq 'Network')
    } catch { return $false }
}

# Mueve el MKV terminado a su carpeta de salida sin sobrescribir (sufijo « (n)» si ya existe).
function Move-HdzFinalASalida($ruta, $carpeta) {
    [void][System.IO.Directory]::CreateDirectory($carpeta)
    $leafFin = Split-Path $ruta -Leaf
    $destFin = Join-Path $carpeta $leafFin
    $kk = 1
    while (Test-Path -LiteralPath $destFin) {
        $destFin = Join-Path $carpeta ("{0} ({1}){2}" -f [IO.Path]::GetFileNameWithoutExtension($leafFin), $kk, [IO.Path]::GetExtension($leafFin)); $kk++
    }
    Move-ConProgreso $ruta $destFin "Moviendo el MKV final a su carpeta de salida"
    Write-Host "   -> Movido a la carpeta de salida: $carpeta" -ForegroundColor DarkGray
    return $destFin
}

# Acción sobre los originales (intactos / borrar / .procesado). Solo se llama cuando el MKV final
# ya está verificado en su destino definitivo.
function Invoke-AccionOriginales($fuentesOrig, $accion, $archivo) {
    if ($accion -eq "INTACTO") {
        Write-Host "   -> Originales intactos (sin cambios)." -ForegroundColor DarkGray
    } elseif ($accion -eq "BORRAR") {
        Write-Host "   -> Borrando archivos fuente originales..." -ForegroundColor DarkGray
        foreach ($fo in $fuentesOrig) {
            try { Remove-Item -LiteralPath $fo -ErrorAction Stop }
            catch { Add-Incidencia $archivo "Original conservado: $($_.Exception.Message)" }
        }
    } else {
        # PROCESADO: renombrar a «.procesado» (en su propia carpeta) y, si está configurada,
        # archivarlos en la carpeta de procesados (Ajustes), con subcarpeta por proyecto.
        Write-Host "   -> Marcando originales como procesados (.procesado)..." -ForegroundColor DarkGray
        $procesadosNuevos = @()
        foreach ($fo in $fuentesOrig) {
            $leaf = Split-Path $fo -Leaf
            try {
                $r = Rename-Item -LiteralPath $fo -NewName "$leaf.procesado" -PassThru -ErrorAction Stop
                $procesadosNuevos += $r.FullName
            } catch { Add-Incidencia $archivo "No se pudo marcar el original: $($_.Exception.Message)" }
        }
        if ($dirProcesados -and $procesadosNuevos.Count -gt 0) {
            try { [void][System.IO.Directory]::CreateDirectory($dirProcesados) } catch {}
            foreach ($pp in $procesadosNuevos) {
                try {
                    $dstPP = Join-Path $dirProcesados (Split-Path $pp -Leaf)
                    if (-not (Test-Path -LiteralPath $dstPP)) { Move-ConProgreso $pp $dstPP "Archivando original .procesado" }
                } catch { Add-Incidencia $archivo "No se pudo archivar el .procesado: $($_.Exception.Message)" }
            }
        }
    }
}

# Resultados para la GUI: por cada torrent creado, una línea JSON (tipo/torrent/vídeo) que la GUI
# lee para ir creando pestañas de subida automáticamente. Sin la variable, no hace nada.
$global:rutaResultados = $env:HDZ_RESULTS
function Add-ResultadoGui($tipo, $torrent, $video, $capturas = @(), $origen = "") {
    if (-not $global:rutaResultados) { return }
    try {
        # 'origen' = carpeta donde el motor deja las capturas (la de trabajo, aunque el MKV se
        # mueva a otra de salida). 'capturas' = rutas EXACTAS de los .png generados. Con esto la
        # GUI localiza las capturas sin depender de los campos de la interfaz (robusto tras
        # reabrir el programa, en packs con nombre distinto al del episodio, etc.).
        ([ordered]@{
            tipo = "$tipo"; torrent = "$torrent"; video = "$video"
            origen = "$origen"; capturas = @($capturas | ForEach-Object { "$_" })
        } | ConvertTo-Json -Compress) |
            Add-Content -LiteralPath $global:rutaResultados -Encoding UTF8
    } catch {}
}

# Decisiones de idioma POR PISTA tomadas en la GUI para pistas 'und' (clave
# "<ruta>|<id>|<Audio|Sub>" -> código de idioma). La GUI lista cada pista sin idioma
# por separado, así que puede haber idiomas distintos para distintas pistas.
$global:undPistasGui = @{}
$vCfgUndPistas = Get-CfgGui "IdiomasUndPistas"
if ($vCfgUndPistas) {
    foreach ($p in @($vCfgUndPistas)) {
        if ($p.Archivo -and $null -ne $p.Id -and $p.Idioma) {
            $global:undPistasGui["$($p.Archivo)|$($p.Id)|$($p.Tipo)"] = "$($p.Idioma)"
        }
    }
}

# --- LOGGING PERSISTENTE (D3) ---
# Los logs se guardan SIEMPRE en la carpeta del proyecto (logs\ junto al script), no en la
# carpeta de cada vídeo, para tenerlos todos centralizados y poder revisarlos después aunque
# el vídeo ya se haya movido/borrado. El nombre incluye la carpeta de origen para identificar
# a qué vídeo o serie pertenece cada ejecución.
$dirLogs = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path -LiteralPath $dirLogs)) {
    try { New-Item -ItemType Directory -Path $dirLogs -Force | Out-Null } catch {}
}
$origenLog = ((Split-Path $rutaCarpeta -Leaf) -replace '[^\w\.\-]', '_')
if (-not $origenLog) { $origenLog = "montaje" }
$rutaLog = Join-Path $dirLogs "hdz_montaje_${origenLog}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
# Si por permisos no se pudo crear logs\, caemos a la carpeta de trabajo (comportamiento anterior).
if (-not (Test-Path -LiteralPath $dirLogs)) {
    $rutaLog = Join-Path $rutaCarpeta "hdz_montaje_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
}
# Fichero temporal de diagnóstico: el diagnóstico extensivo se escribe aquí directamente
# (sin pasar por consola), y al terminar el script se anexa al log principal y se borra,
# de forma que el usuario acaba con UN SOLO archivo .log pero sin ver el diagnóstico en pantalla.
$global:rutaDiag = "$rutaLog.diag.tmp"
try { Start-Transcript -Path $rutaLog -Append | Out-Null } catch { Write-Host "Aviso: no se pudo iniciar transcript ($($_.Exception.Message))" -ForegroundColor DarkYellow }

# Registro global de incidencias: se acumulan los problemas encontrados durante toda la
# ejecución (fallos de mkvpropedit, archivos saltados, errores de muxeo, etc.) y se muestran
# en un resumen al final, para que ningún error pase desapercibido.
$global:incidencias = New-Object System.Collections.Generic.List[string]
function Add-Incidencia($archivo, $mensaje) {
    $linea = if ($archivo) { "[$archivo] $mensaje" } else { $mensaje }
    $global:incidencias.Add($linea)
}
function Test-HdzAudioTrackKept($archivo,$id,[switch]$FfprobeIndex) {
    return (Test-HdzPistaNoExcluida 'PistasAudioExcluidas' $archivo $id -FfprobeIndex:$FfprobeIndex)
}
# Subtítulos desmarcados a mano en la GUI (misma forma que las de audio: Archivo + Id de mkvmerge + Index de ffprobe).
function Test-HdzSubTrackKept($archivo,$id,[switch]$FfprobeIndex) {
    return (Test-HdzPistaNoExcluida 'PistasSubsExcluidas' $archivo $id -FfprobeIndex:$FfprobeIndex)
}
function Test-HdzPistaNoExcluida($claveCfg,$archivo,$id,[switch]$FfprobeIndex) {
    foreach($item in @(Get-CfgGui $claveCfg)) {
        if(-not $item -or -not $item.Archivo){continue}
        if([string]::Equals([IO.Path]::GetFullPath("$archivo"),[IO.Path]::GetFullPath("$($item.Archivo)"),[StringComparison]::OrdinalIgnoreCase)){
            $excludedId=if($FfprobeIndex){$item.Index}else{$item.Id}
            if($null -ne $excludedId -and "$excludedId" -eq "$id"){return $false}
        }
    }
    return $true
}

# Memoria global de idiomas resueltos para subtítulos 'und' (indeterminado). El usuario elige
# el idioma de una lista y se guarda aquí con clave "<archivo>|<formato>" (formato = Text/PGS).
# Build-PistasBrutas lo aplica para asignar el código correcto a la pista.
$global:decisionesIdiomaUnd = @{}

# Idioma global elegido para TODAS las pistas 'und' del lote (audio y sub por separado).
# Se rellenan en el pre-escaneo inicial. $null = no preguntado / no aplicar.
$global:idiomaUndAudioLote = $null
$global:idiomaUndSubLote = $null
# Idiomas 'und' pre-decididos desde la GUI. El valor "und" también es válido: significa
# "dejar como indeterminado sin preguntar".
$vCfgUnd = Get-CfgGui "IdiomaUndAudio"; if ($vCfgUnd) { $global:idiomaUndAudioLote = "$vCfgUnd" }
$vCfgUnd = Get-CfgGui "IdiomaUndSub";   if ($vCfgUnd) { $global:idiomaUndSubLote   = "$vCfgUnd" }

# =========================================================================
# DICCIONARIOS Y CONSTANTES
# =========================================================================
$dictIdiomas = @{
    "spa"="Castellano"; "cas"="Castellano"; "es"="Castellano"; "es-es"="Castellano";
    "es-419"="Latino"; "es-mx"="Latino"; "es-ar"="Latino"; "es-co"="Latino"; "es-cl"="Latino"; "es-pe"="Latino"; "es-ve"="Latino"; "es-la"="Latino"; "lat"="Latino";
    "eng"="Inglés"; "en"="Inglés";
    "fra"="Francés"; "fre"="Francés"; "fr"="Francés"; "ger"="Alemán"; "deu"="Alemán"; "de"="Alemán";
    "ita"="Italiano"; "it"="Italiano"; "por"="Portugués"; "pt"="Portugués"; "jpn"="Japonés"; "ja"="Japonés";
    "chi"="Chino"; "zho"="Chino"; "zh"="Chino"; "kor"="Coreano"; "ko"="Coreano"; "tha"="Tailandés"; "th"="Tailandés";
    "cat"="Catalán"; "ca"="Catalán"; "glg"="Gallego"; "gl"="Gallego"; "eus"="Euskera"; "baq"="Euskera"; "eu"="Euskera"
}
$idiomasComunes = @(
    @{Cod="es";     Nom="Castellano"},
    @{Cod="es-419"; Nom="Latino"},
    @{Cod="eng";    Nom="Inglés"},
    @{Cod="cat";    Nom="Catalán"},
    @{Cod="glg";    Nom="Gallego"},
    @{Cod="eus";    Nom="Euskera"},
    @{Cod="fra";    Nom="Francés"},
    @{Cod="ger";    Nom="Alemán"},
    @{Cod="ita";    Nom="Italiano"},
    @{Cod="por";    Nom="Portugués"},
    @{Cod="jpn";    Nom="Japonés"},
    @{Cod="chi";    Nom="Chino"},
    @{Cod="kor";    Nom="Coreano"}
)
$opcPlataformas = @(
    @{Nombre="Netflix";      Valor="NF"},
    @{Nombre="Amazon Prime"; Valor="AMZN"},
    @{Nombre="Disney+";      Valor="DSNP"},
    @{Nombre="Movistar+";    Valor="MVSTP"},
    @{Nombre="SkyShowtime";  Valor="SKST"},
    @{Nombre="Filmin";       Valor="FLMN"},
    @{Nombre="Apple TV+";    Valor="ATVP"},
    @{Nombre="iTunes";       Valor="iT"},
    @{Nombre="HBO Max";      Valor="HMAX"},
    @{Nombre="RTVE Play";    Valor="RTVP"},
    @{Nombre="Rakuten";      Valor="RKTN"}
)
$opcFormatosFisicos = @(
    @{Nombre="UHDFull";    Valor="UHDFull"},
    @{Nombre="BDFull";     Valor="BDFull"},
    @{Nombre="UHDRemux";   Valor="UHDRemux"},
    @{Nombre="BDRemux";    Valor="BDRemux"},
    @{Nombre="UHDRip";     Valor="UHDRip"},
    @{Nombre="BDRip";      Valor="BDRip"},
    @{Nombre="MicroHD";    Valor="MHD"},
    @{Nombre="Remastered"; Valor="Remastered"}
)

# Cache global de mediainfo (D5): clave = path absoluto, valor = objeto JSON parseado
$cacheMediainfo = @{}

# Cache de Resolve-Hibrido: la detección DV/HDR10 ejecuta ffprobe completo sobre cada archivo
# del grupo, y la función se llama varias veces por grupo (pre-escaneos + bucle principal).
# Clave = paths del grupo concatenados; valor = objeto info ya calculado.
$cacheHibrido = @{}

# =========================================================================
# FUNCIONES AUXILIARES (D1)
# =========================================================================
function Get-LanguageName($lang, $title = "") {
    $l = "$lang".ToLower()
    # Caso especial PRIMERO (antes del diccionario, que también contiene es/spa/cas y
    # respondería "Castellano" sin mirar el Title): idioma genérico español pero el
    # Title indica Latino.
    if ($l -in @("es", "spa", "cas") -and $title -match "(?i)latino|latinoam|latam|latin spanish|spanish.*latin|hispanoam") {
        return "Latino"
    }
    if ($dictIdiomas.ContainsKey($l)) { return $dictIdiomas[$l] }
    if ($lang -and $lang -ne "und") { return $lang } else { return "Und" }
}

# Devuelve el código de idioma "canónico" que vamos a escribir en el MKV final.
# Normaliza variantes regionales (es-ES, en-US, pt-BR, etc.) a un único código por idioma,
# preservando la distinción Castellano (es) vs Latino (es-419) que sí es semánticamente relevante.
function Get-LanguageCode($lang, $title = "") {
    $l = Convert-HdzLanguage "$lang"

    # --- ESPAÑOL ---
    # Variantes latinas → es-419 (BCP 47 estándar "Spanish, Latin America and Caribbean")
    if ($l -match "^es-(419|mx|ar|co|cl|pe|ve|la|us)$" -or $l -eq "lat") { return "es-419" }
    # Castellano (España) y código genérico → "es" a secas
    if ($l -in @("es", "spa", "cas", "es-es", "es-latn", "es-latn-es")) {
        if ($title -match "(?i)latino|latinoam|latam|latin spanish|spanish.*latin|hispanoam") {
            return "es-419"
        }
        return "es"
    }

    # --- INGLÉS ---
    if ($l -in @("en", "eng") -or $l -match "^en-(us|gb|uk|ca|au|nz|ie|za|in)$") { return "eng" }

    # --- PORTUGUÉS ---
    # Unificamos Portugal y Brasil bajo "por" (decisión del usuario)
    if ($l -in @("pt", "por") -or $l -match "^pt-(pt|br|ao|mz)$") { return "por" }

    # --- FRANCÉS ---
    if ($l -in @("fr", "fra", "fre") -or $l -match "^fr-(fr|ca|be|ch)$") { return "fre" }

    # --- ALEMÁN ---
    if ($l -in @("de", "ger", "deu") -or $l -match "^de-(de|at|ch)$") { return "ger" }

    # --- ITALIANO ---
    if ($l -in @("it", "ita") -or $l -match "^it-(it|ch)$") { return "ita" }

    # --- JAPONÉS ---
    if ($l -in @("ja", "jpn", "jp") -or $l -match "^ja-jp$") { return "jpn" }

    # --- CHINO ---
    if ($l -in @("zh", "chi", "zho", "cmn") -or $l -match "^zh-(cn|tw|hk|sg|hans|hant)$") { return "chi" }

    # --- COREANO ---
    if ($l -in @("ko", "kor") -or $l -match "^ko-kr$") { return "kor" }

    # --- TAILANDÉS ---
    # ffprobe suele devolver ISO-639-2 (tha), mientras que MediaInfo puede devolver
    # ISO-639-1 (th). Ambos deben compararse con el mismo código para no descartar la pista.
    if ($l -in @("th", "tha") -or $l -match "^th-th$") { return "tha" }

    # --- LENGUAS COOFICIALES DE ESPAÑA ---
    if ($l -in @("ca", "cat") -or $l -match "^ca-(es|ad)$") { return "cat" }
    if ($l -in @("gl", "glg") -or $l -eq "gl-es") { return "glg" }
    if ($l -in @("eu", "eus", "baq") -or $l -eq "eu-es") { return "eus" }

    # Cualquier otro idioma se devuelve tal cual (en su forma original)
    return $l
}

function Get-PesoIdioma($nombre) { 
    if ($nombre -eq "Castellano") { return 1 }
    if ($nombre -match "Latino") { return 2 }
    if ($nombre -eq "Inglés") { return 3 }
    return 4 
}

function Get-PesoFormatoSub($formato) { 
    if ($formato -match "(?i)srt|subrip|utf-8|planos") { return 1 }
    return 2 
}

function Mostrar-Menu($titulo, $opciones) {
    Write-Host "`n>> $titulo" -ForegroundColor Cyan
    for ($i = 0; $i -lt $opciones.Count; $i++) { Write-Host "  [$($i + 1)] $($opciones[$i].Nombre)" }
    Write-Host "  [0] Escribir manualmente" -ForegroundColor DarkGray
    while ($true) {
        $seleccion = Read-Host "Elige una opción (0-$($opciones.Count))"
        if ($seleccion -eq "0") { return Read-Host "-> Escribe el valor" }
        if ($seleccion -match '^\d+$') {
            $n = [int]$seleccion
            if ($n -gt 0 -and $n -le $opciones.Count) { return $opciones[$n - 1].Valor }
        }
        Write-Host "   Entrada no válida. Introduce un número entre 0 y $($opciones.Count)." -ForegroundColor Yellow
    }
}

# Pregunta al usuario el idioma de una pista cuyo idioma es 'und' (indeterminado).
# Muestra una lista numerada de idiomas comunes (incluidas cooficiales de España) y
# devuelve el código elegido. El usuario elige por nombre, no necesita saber los códigos.
function Resolve-IdiomaUnd($descripcion) {
    # DESATENDIDO (lanzado por la GUI): NUNCA abrimos la consola. La GUI ya manda el idioma de cada
    # pista 'und' en IdiomasUndPistas; si aun así se llega aquí (una pista sin decisión por el motivo
    # que sea), se deja como 'und' y se registra, en lugar de revelar la consola con un Read-Host que
    # el usuario no espera (era el «se ha abierto sola» pese a haber elegido el idioma en la interfaz).
    if ($global:sinPreguntas) {
        Write-Host "[GUI] $descripcion sin idioma definido y sin decisión aplicable en la configuración -> se deja como 'und' (no se pregunta)." -ForegroundColor DarkYellow
        try { Add-Incidencia $global:archivoEnCurso "Pista 'und': no llegó decisión de idioma desde la GUI; se deja indeterminada (revisa la asignación de idioma en la interfaz)." } catch {}
        return "und"
    }
    Write-Host "`n>> $descripcion no tiene idioma definido (und). ¿Qué idioma es?" -ForegroundColor Cyan
    for ($i = 0; $i -lt $idiomasComunes.Count; $i++) {
        Write-Host "  [$($i + 1)] $($idiomasComunes[$i].Nom)"
    }
    Write-Host "  [0] Dejar como indeterminado (und)" -ForegroundColor DarkGray
    while ($true) {
        $sel = Read-Host "Elige una opción (0-$($idiomasComunes.Count))"
        if ($sel -eq "0") { return "und" }
        if ($sel -match '^\d+$') {
            $n = [int]$sel
            if ($n -ge 1 -and $n -le $idiomasComunes.Count) { return $idiomasComunes[$n - 1].Cod }
        }
        Write-Host "   Entrada no válida." -ForegroundColor Yellow
    }
}
# Alias compatible para el subtítulo (mantiene el nombre usado en otros sitios)
function Resolve-IdiomaSubUnd($descripcion) { return Resolve-IdiomaUnd "El subtítulo $descripcion" }

# Pre-escaneo del lote: detecta pistas de AUDIO y de SUBTÍTULO con idioma 'und'. Si las hay,
# pregunta UNA vez (por tipo) a qué idioma corresponden, y guarda la decisión global para que
# Build-PistasBrutas la aplique a todas las pistas 'und' de ese tipo en el lote.
function Resolve-IdiomasUndLote($grupos) {
    # Si la GUI decidió los idiomas PISTA A PISTA, no hay pregunta de lote que hacer:
    # las decisiones ya están en las memorias y lo no decidido se preguntará por pista.
    if ($global:undPistasGui.Count -gt 0) {
        Write-Host "`n[GUI] Idiomas de pistas 'und' definidos por pista en la configuración ($($global:undPistasGui.Count) pista(s))." -ForegroundColor DarkGray
        return
    }
    # Si la GUI ya decidió ambos idiomas (o "und" = dejar como está), no hay nada que
    # preguntar ni que escanear.
    if ($global:idiomaUndAudioLote -and $global:idiomaUndSubLote) {
        Write-Host "`n[GUI] Idiomas para pistas 'und' definidos en la configuración (audio: $($global:idiomaUndAudioLote), subs: $($global:idiomaUndSubLote))." -ForegroundColor DarkGray
        return
    }
    # DESATENDIDO sin decisiones de idioma 'und': el escaneo de lote solo sirve para PREGUNTAR, y en
    # modo GUI no se pregunta (Resolve-IdiomaUnd devuelve 'und'). Nos ahorramos el mediainfo del lote
    # y dejamos rastro del estado recibido para diagnosticar por qué no llegaron las decisiones.
    if ($global:sinPreguntas) {
        Write-Host "`n[GUI] Sin idiomas 'und' predefinidos (IdiomasUndPistas=$($global:undPistasGui.Count), audioLote='$($global:idiomaUndAudioLote)', subLote='$($global:idiomaUndSubLote)'). No se pregunta por consola; las pistas 'und' sin decisión se dejan indeterminadas." -ForegroundColor DarkYellow
        return
    }
    Write-Host "`nComprobando idiomas de pistas en el lote..." -ForegroundColor DarkGray
    $hayAudioUnd = $false
    $haySubUnd = $false
    $archivosAudioUnd = New-Object System.Collections.Generic.List[string]
    $archivosSubUnd = New-Object System.Collections.Generic.List[string]
    $total = ($grupos | ForEach-Object { (Resolve-Hibrido $_).OrigenesPistas.Count } | Measure-Object -Sum).Sum
    $nProc = 0
    foreach ($g in $grupos) {
        $hi = Resolve-Hibrido $g
        foreach ($ruta in $hi.OrigenesPistas) {
            $nProc++
            $nombreArchivo = Split-Path $ruta -Leaf
            Write-Progress -Activity "Analizando pistas und en el lote" -Status "$nProc/$total : $nombreArchivo" -PercentComplete (($nProc/$total)*100)
            $mi = Get-MediainfoJson $ruta
            if (-not $mi) { continue }
            foreach ($p in $mi.media.track) {
                $tipo = "$($p.'@type')"
                if ($tipo -notin @("Audio", "Text")) { continue }
                $lang = "$($p.Language)"
                $cod = if ([string]::IsNullOrWhiteSpace($lang)) { "und" } else { Get-LanguageCode $lang "$($p.Title)" }
                if ($cod -eq "und") {
                    if ($tipo -eq "Audio") {
                        $hayAudioUnd = $true
                        if (-not $archivosAudioUnd.Contains($nombreArchivo)) { $archivosAudioUnd.Add($nombreArchivo) }
                    } else {
                        $haySubUnd = $true
                        if (-not $archivosSubUnd.Contains($nombreArchivo)) { $archivosSubUnd.Add($nombreArchivo) }
                    }
                }
            }
        }
    }
    Write-Progress -Activity "Analizando pistas und en el lote" -Completed

    if ($hayAudioUnd -and -not $global:idiomaUndAudioLote) {
        Write-Host "`n>> Pistas de AUDIO sin idioma definido (und) detectadas en $($archivosAudioUnd.Count) archivo(s):" -ForegroundColor Yellow
        foreach ($a in $archivosAudioUnd) { Write-Host "   - $a" -ForegroundColor Gray }
        $c = Resolve-IdiomaUnd "Hay pistas de AUDIO en el lote que"
        if ($c -ne "und") { $global:idiomaUndAudioLote = $c }
    }
    if ($haySubUnd -and -not $global:idiomaUndSubLote) {
        Write-Host "`n>> SUBTÍTULOS sin idioma definido (und) detectados en $($archivosSubUnd.Count) archivo(s):" -ForegroundColor Yellow
        foreach ($a in $archivosSubUnd) { Write-Host "   - $a" -ForegroundColor Gray }
        $c = Resolve-IdiomaUnd "Hay SUBTÍTULOS en el lote que"
        if ($c -ne "und") { $global:idiomaUndSubLote = $c }
    }
}

function Detectar-Episodio($nombre) {
    # Detecta el episodio (o rango de episodios) del nombre. Soporta episodios múltiples en un
    # mismo archivo (S01E02-E03, S01E02-03, S01E02E03, 1x02-1x03, E02-E03...), normalizando
    # SIEMPRE al formato "S01E02-E03-E04" (con guion y la E repetida) o "E02-E03" si no hay temporada.
    # Episodios y temporadas pueden tener más de 2 dígitos; rellenamos a mínimo 2 sin recortar.

    # Helper: a partir de la posición donde acabó el primer "Eyy", captura episodios adicionales
    # encadenados (rango múltiple). Un eslabón válido SOLO si:
    #   - empieza por guion (con espacios opcionales) seguido de número, con E/EP opcional:
    #     "-E03", "- 03", "-03"
    #   - o es "E"/"Ep" pegado directamente al anterior: "E04"
    # Deliberadamente NO aceptamos " 1080" (espacio + número suelto, que sería resolución) ni la
    # "x" como separador de extras (evita confundir codecs x264/x265 con episodios).
    $capturarExtras = {
        param($resto)
        $extras = @()
        $rx = [regex]"(?i)^(?:\s*-\s*(?:E|EP)?\s*(\d{1,4})|(?:E|EP)(\d{1,4}))"
        $pos = 0
        while ($pos -lt $resto.Length) {
            $m = $rx.Match($resto.Substring($pos))
            if (-not $m.Success) { break }
            $num = if ($m.Groups[1].Value) { $m.Groups[1].Value } else { $m.Groups[2].Value }
            $extras += $num
            $pos += $m.Length
        }
        return $extras
    }

    # 1) Formato SxxEyy (+ extras)
    if ($nombre -match "(?i)S(\d{1,4})[\.\s-]*E(\d{1,4})") {
        $temp = $Matches[1].PadLeft(2,'0')
        $ep1  = $Matches[2].PadLeft(2,'0')
        $idxFin = $nombre.IndexOf($Matches[0]) + $Matches[0].Length
        $resto = $nombre.Substring($idxFin)
        $extras = & $capturarExtras $resto
        $lista = @($ep1) + @($extras | ForEach-Object { $_.PadLeft(2,'0') })
        return "S$temp" + (($lista | ForEach-Object { "E$_" }) -join "-")
    }
    # 2) Formato NxNN (+ extras). Los extras pueden venir como "-NxNN" (repiten temporada) o
    #    como "-NN"/"-ENN". Primero normalizamos los "-NxNN" quitando la temporada repetida.
    if ($nombre -match "(?i)(\d{1,4})x(\d{1,4})") {
        $temp = $Matches[1].PadLeft(2,'0')
        $ep1  = $Matches[2].PadLeft(2,'0')
        $idxFin = $nombre.IndexOf($Matches[0]) + $Matches[0].Length
        $resto = $nombre.Substring($idxFin)
        # Convertir eslabones "-NxMM" en "-MM" para que el helper capture solo el episodio.
        $resto = [regex]::Replace($resto, "(?i)(-\s*)\d{1,4}x(\d{1,4})", '${1}${2}')
        $extras = & $capturarExtras $resto
        $lista = @($ep1) + @($extras | ForEach-Object { $_.PadLeft(2,'0') })
        return "S$temp" + (($lista | ForEach-Object { "E$_" }) -join "-")
    }
    # 3) Formato E/EP/Cap NN (+ extras), sin temporada
    if ($nombre -match "(?i)(?:^|[\s_.-])(?:E|EP|Cap)[\.\s-]*(\d{1,4})") {
        $ep1 = $Matches[1].PadLeft(2,'0')
        $idxFin = $nombre.IndexOf($Matches[0]) + $Matches[0].Length
        $resto = $nombre.Substring($idxFin)
        $extras = & $capturarExtras $resto
        $lista = @($ep1) + @($extras | ForEach-Object { $_.PadLeft(2,'0') })
        return (($lista | ForEach-Object { "E$_" }) -join "-")
    }
    # 4) Respaldo: nombres que son SOLO un número (001.mp4, 243.mp4, 198_v2.mp4, 104 Subtitulat.mkv).
    $base = [System.IO.Path]::GetFileNameWithoutExtension($nombre)
    if ($base -match "^(\d{1,4})(?:[\s_.-]|$)") { return "E$($Matches[1].PadLeft(2,'0'))" }
    return $null
}

# Cache de mediainfo (D5) - una llamada por archivo, se reutiliza
function Get-MediainfoJson($ruta) {
    if (-not $cacheMediainfo.ContainsKey($ruta)) {
        try {
            $cacheMediainfo[$ruta] = mediainfo --Output=JSON $ruta | Out-String | ConvertFrom-Json
        } catch {
            Write-Host "   [!] mediainfo falló sobre $ruta : $($_.Exception.Message)" -ForegroundColor Red
            $cacheMediainfo[$ruta] = $null
        }
    }
    return $cacheMediainfo[$ruta]
}

# Cachea el JSON de mkvmerge -J por path (igual que mediainfo).
# mkvmerge es la fuente fiable de IDs de pista para muxear (mediainfo a veces
# numera con huecos y no coincide). Lo usamos para corregir los IDs.
$cacheMkvmergeJ = @{}
function Get-MkvmergeJson($ruta) {
    if (-not $cacheMkvmergeJ.ContainsKey($ruta)) {
        try {
            $raw = & mkvmerge -J $ruta 2>$null | Out-String
            $cacheMkvmergeJ[$ruta] = $raw | ConvertFrom-Json
        } catch {
            Write-Host "   [!] mkvmerge -J falló sobre $ruta : $($_.Exception.Message)" -ForegroundColor Red
            $cacheMkvmergeJ[$ruta] = $null
        }
    }
    return $cacheMkvmergeJ[$ruta]
}

# Devuelve un hashtable que mapea "tipo+orden" -> ID real de mkvmerge.
# Ej: "Video+1" -> 0, "Audio+1" -> 1, "Audio+2" -> 2, ..., "Text+1" -> 6, "Text+2" -> 7
# Sirve para corregir los IDs que mediainfo reporta con huecos (caso real: Fight Club
# donde mediainfo numera los PGS como 7, 9, 11, 13... y mkvmerge espera 6, 7, 8, 9...).
function Get-MkvmergeTrackIdMap($ruta) {
    $map = @{}
    $json = Get-MkvmergeJson $ruta
    if (-not $json -or -not $json.tracks) { return $map }
    $contadores = @{ video = 0; audio = 0; subtitles = 0 }
    foreach ($t in $json.tracks) {
        $tipo = "$($t.type)".ToLower()
        if (-not $contadores.ContainsKey($tipo)) { continue }
        $contadores[$tipo]++
        $tipoClave = switch ($tipo) {
            "video"     { "Video" }
            "audio"     { "Audio" }
            "subtitles" { "Text" }
            default     { $tipo }
        }
        $map["${tipoClave}+$($contadores[$tipo])"] = [int]$t.id
    }
    return $map
}

# ============================================================================
# DIAGNÓSTICO EXTENSIVO AL LOG
# ============================================================================
# Estas funciones vuelcan información detallada a un fichero de diagnóstico separado
# ($global:rutaDiag). NO pasan por consola ni por Write-Verbose, así que el usuario no
# las ve en pantalla mientras el script trabaja. Al terminar, el contenido se anexa al
# log principal para que todo quede en un único archivo.

function Write-DiagRaw($texto) {
    # Escritura directa al fichero de diagnóstico. Silenciosa (no toca la consola).
    try { Add-Content -LiteralPath $global:rutaDiag -Value $texto -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

# Marca de tiempo para medir cuánto tarda cada paso. Se escribe SOLO al fichero de diagnóstico,
# nunca a la consola. Formato: "[HH:mm:ss.fff] PASO: <descripción>".
function Write-DiagPaso($descripcion) {
    try {
        $ts = (Get-Date).ToString("HH:mm:ss.fff")
        Add-Content -LiteralPath $global:rutaDiag -Value "[$ts] PASO: $descripcion" -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

function Write-DiagSeccion($titulo) {
    Write-DiagRaw ""
    Write-DiagRaw ("=" * 78)
    Write-DiagRaw "[DIAG] $titulo"
    Write-DiagRaw ("=" * 78)
}

function Write-DiagLinea($texto) {
    $ts = (Get-Date).ToString("HH:mm:ss.fff")
    Write-DiagRaw "[$ts] [DIAG] $texto"
}

function Write-DiagBloque($texto) {
    # Para bloques multilínea (JSON dumps, listas de pistas, etc.)
    foreach ($l in ($texto -split "`r?`n")) {
        Write-DiagRaw "[DIAG]   $l"
    }
}

# Vuelca al log el entorno completo del sistema (versiones de herramientas, locale, etc.).
# Útil para diagnosticar diferencias entre máquinas (caso típico: mismo script, distintos
# resultados porque la versión de mediainfo difiere entre tu PC y el de un amigo).
function Write-DiagEntorno {
    Write-DiagSeccion "ENTORNO DEL SISTEMA"
    try { Write-DiagLinea "PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))" } catch {}
    try { Write-DiagLinea "OS: $($PSVersionTable.OS)" } catch {}
    try { Write-DiagLinea "Locale: $((Get-Culture).Name) / Charset: $([Console]::OutputEncoding.WebName)" } catch {}
    try { Write-DiagLinea "Ruta carpeta: $rutaCarpeta" } catch {}
    try {
        $espacio = [System.IO.DriveInfo]::new((Split-Path $rutaCarpeta -Qualifier))
        Write-DiagLinea ("Espacio libre en unidad {0}: {1:N2} GB de {2:N2} GB" -f $espacio.Name, ($espacio.AvailableFreeSpace / 1GB), ($espacio.TotalSize / 1GB))
    } catch {}

    Write-DiagLinea "--- Versiones de herramientas externas ---"
    foreach ($cmd in @("mediainfo", "ffmpeg", "ffprobe", "mkvmerge", "mkvextract", "mkvpropedit", "dovi_tool")) {
        try {
            $cmdInfo = Get-Command $cmd -ErrorAction SilentlyContinue
            if ($cmdInfo) {
                $ruta = $cmdInfo.Source
                $verLine = ""
                try { $verLine = (& $cmd --version 2>&1 | Select-Object -First 1) -as [string] } catch {}
                Write-DiagLinea "  $cmd : $verLine [$ruta]"
            } else {
                Write-DiagLinea "  $cmd : NO ENCONTRADO en PATH"
            }
        } catch {
            Write-DiagLinea "  $cmd : error al consultar versión"
        }
    }
}

# Vuelca al log toda la información disponible sobre un archivo MKV: tamaño, output de
# mkvmerge -i, output de mkvmerge -J (resumido), output de mediainfo JSON completo,
# y output de ffprobe por streams. Es la radiografía completa del archivo de entrada.
function Write-DiagArchivoEntrada($rutaMkv, $etiqueta = "ENTRADA") {
    Write-DiagSeccion "ARCHIVO DE $etiqueta : $(Split-Path $rutaMkv -Leaf)"
    if (-not (Test-Path -LiteralPath $rutaMkv)) {
        Write-DiagLinea "  ERROR: el archivo no existe en disco"
        return
    }
    $fi = Get-Item -LiteralPath $rutaMkv
    Write-DiagLinea "Path: $rutaMkv"
    Write-DiagLinea ("Tamaño: {0:N0} bytes ({1:N2} GB)" -f $fi.Length, ($fi.Length / 1GB))
    Write-DiagLinea "Última modificación: $($fi.LastWriteTime)"

    Write-DiagLinea "--- mkvmerge -i ---"
    try {
        $mi = & mkvmerge -i $rutaMkv 2>&1 | Out-String
        Write-DiagBloque $mi
    } catch { Write-DiagLinea "  ERROR ejecutando mkvmerge -i: $($_.Exception.Message)" }

    Write-DiagLinea "--- mkvmerge -J (resumen de pistas) ---"
    $jMkv = Get-MkvmergeJson $rutaMkv
    if ($jMkv -and $jMkv.tracks) {
        foreach ($t in $jMkv.tracks) {
            $props = $t.properties | ConvertTo-Json -Compress -Depth 4 -ErrorAction SilentlyContinue
            Write-DiagLinea "  Track id=$($t.id) type=$($t.type) codec=$($t.codec)"
            if ($props) { Write-DiagLinea "    props: $props" }
        }
    } else {
        Write-DiagLinea "  (mkvmerge -J no devolvió tracks)"
    }

    Write-DiagLinea "--- Mapping ID mkvmerge por (tipo+orden) ---"
    $idMap = Get-MkvmergeTrackIdMap $rutaMkv
    foreach ($k in ($idMap.Keys | Sort-Object)) {
        Write-DiagLinea "  $k -> $($idMap[$k])"
    }

    Write-DiagLinea "--- mediainfo --Output=JSON (resumen por pista) ---"
    $jMi = Get-MediainfoJson $rutaMkv
    if ($jMi -and $jMi.media -and $jMi.media.track) {
        foreach ($pista in $jMi.media.track) {
            $tipo = "$($pista.'@type')"
            if ($tipo -in @('General','Menu')) { continue }
            $resumen = "Pista mediainfo ID=$($pista.ID) tipo=$tipo Format=$($pista.Format)"
            if ($tipo -eq "Video") {
                $resumen += " Width=$($pista.Width) Height=$($pista.Height) BitDepth=$($pista.BitDepth)"
                $resumen += " colour_primaries=$($pista.colour_primaries) transfer=$($pista.transfer_characteristics)"
                $resumen += " HDR_Format=$($pista.HDR_Format)"
                $resumen += " HDR_Format_Compatibility=$($pista.HDR_Format_Compatibility)"
                $resumen += " HDR_Format_String=$($pista.HDR_Format_String)"
            }
            if ($tipo -in @('Audio','Text')) {
                $resumen += " Lang=$($pista.Language) Title=`"$($pista.Title)`""
                $resumen += " Profile=$($pista.Format_Profile) Comm=`"$($pista.Format_Commercial_IfAny)`""
                $resumen += " Channels=$($pista.Channels) Forced=$($pista.Forced) Default=$($pista.Default)"
                $resumen += " StreamSize=$($pista.StreamSize)"
            }
            Write-DiagLinea $resumen
        }
    } else {
        Write-DiagLinea "  (mediainfo no devolvió tracks)"
    }

    Write-DiagLinea "--- ffprobe -show_streams (audio/sub) ---"
    try {
        $fp = ffprobe -v error -show_entries "stream=index,codec_name,codec_type:stream_tags=language,title" -of csv=p=1 $rutaMkv 2>&1 | Out-String
        Write-DiagBloque $fp
    } catch { Write-DiagLinea "  ERROR ejecutando ffprobe: $($_.Exception.Message)" }
}

# Vuelca al log la configuración global del proyecto seleccionada por el usuario.
function Write-DiagConfiguracion {
    Write-DiagSeccion "CONFIGURACIÓN ELEGIDA"
    try { Write-DiagLinea "modoLote: $modoLote" } catch {}
    try { Write-DiagLinea "borrarOriginales: $borrarOriginales" } catch {}
    try { Write-DiagLinea "modoConversionDTS: $modoConversionDTS" } catch {}
    try { Write-DiagLinea "numCapturas: $numCapturas" } catch {}
    try {
        if ($datosProyectoGlobal) {
            Write-DiagLinea "datosProyectoGlobal (modo homogéneo):"
            Write-DiagBloque ($datosProyectoGlobal | ConvertTo-Json -Depth 3)
        }
    } catch {}
    try {
        if ($decisionesSubUnico -and $decisionesSubUnico.Keys.Count -gt 0) {
            Write-DiagLinea "decisionesSubUnico:"
            foreach ($k in ($decisionesSubUnico.Keys | Sort-Object)) {
                Write-DiagLinea "  $k -> $($decisionesSubUnico[$k])"
            }
        }
    } catch {}
}

# Vuelca al log el contenido completo de la carpeta de trabajo. Útil para detectar
# archivos externos (SRT, AC3, SUP, etc.) que están condicionando el comportamiento.
function Write-DiagCarpeta($etiqueta = "CARPETA") {
    Write-DiagSeccion "${etiqueta}: $rutaCarpeta"
    try {
        $items = Get-ChildItem -LiteralPath $rutaCarpeta -ErrorAction SilentlyContinue | Sort-Object Name
        foreach ($it in $items) {
            $tam = if ($it.PSIsContainer) { "<DIR>" } else { "{0,15:N0}" -f $it.Length }
            Write-DiagLinea "  $tam  $($it.Name)"
        }
    } catch { Write-DiagLinea "  ERROR listando carpeta: $($_.Exception.Message)" }
}

# Vuelca al log el detalle de las pistas que el script va a muxear, después de aplicar
# resolución de idiomas, deduplicación, ordenación y detección de forzados.
function Write-DiagPistasFinal($audiosOrdenados, $subsOrdenados, $idVideo, $altoVideo, $codecVideo, $hdrVideo) {
    Write-DiagSeccion "PISTAS A MUXEAR (después de Build-PistasBrutas + Format-Audios/Subs)"
    Write-DiagLinea "Video: idVideo=$idVideo altoVideo=$altoVideo codecVideo=$codecVideo hdrVideo='$hdrVideo'"
    Write-DiagLinea "Audios ($($audiosOrdenados.Count)):"
    for ($i = 0; $i -lt $audiosOrdenados.Count; $i++) {
        $a = $audiosOrdenados[$i]
        $linea = "  #$i Origen=$($a.Origen) ID=$($a.ID) ArchivoFuente=$(if ($a.ArchivoFuenteMkv) { Split-Path $a.ArchivoFuenteMkv -Leaf } else { $a.ID })"
        $linea += " CodLang=$($a.CodLang) NomLang=$($a.NomLang) Format=$($a.Format) Profile=$($a.Profile)"
        $linea += " Comm=`"$($a.Comm)`" Chan=$($a.Chan) Pts=$($a.Pts) PesoFam=$($a.PesoFamilia) NomFinal=`"$($a.NomFinal)`""
        Write-DiagLinea $linea
    }
    Write-DiagLinea "Subs ($($subsOrdenados.Count)):"
    for ($i = 0; $i -lt $subsOrdenados.Count; $i++) {
        $s = $subsOrdenados[$i]
        $linea = "  #$i Origen=$($s.Origen) ID=$($s.ID) ArchivoFuente=$(if ($s.ArchivoFuenteMkv) { Split-Path $s.ArchivoFuenteMkv -Leaf } else { $s.ID })"
        $linea += " CodLang=$($s.CodLang) NomLang=$($s.NomLang) Format=$($s.Format) Size=$($s.Size)"
        $linea += " IsForced=$($s.IsForced) MediainfoForcedFlag=$($s.MediainfoForcedFlag) NomFinal=`"$($s.NomFinal)`""
        Write-DiagLinea $linea
    }
}

# Vuelca al log el comando completo que se va a pasar a mkvmerge.
function Write-DiagComandoMkvmerge($argsMkv) {
    Write-DiagSeccion "COMANDO MKVMERGE"
    Write-DiagLinea "mkvmerge $($argsMkv -join ' ')"
}

# Vuelca al log el resultado final tras el muxeo: lo que mediainfo dice del archivo
# resultante (para verificar que coincide con lo esperado).
function Write-DiagArchivoSalida($rutaSalida, $nombreFinal) {
    Write-DiagSeccion "ARCHIVO FINAL"
    Write-DiagLinea "Path temporal muxeado: $rutaSalida"
    Write-DiagLinea "Nombre final calculado: $nombreFinal"
    if (-not (Test-Path -LiteralPath $rutaSalida)) {
        Write-DiagLinea "  ATENCIÓN: el archivo final NO EXISTE en disco"
        return
    }
    $fi = Get-Item -LiteralPath $rutaSalida
    Write-DiagLinea ("Tamaño: {0:N0} bytes ({1:N2} GB)" -f $fi.Length, ($fi.Length / 1GB))

    # mediainfo del archivo final (invalidando cache para forzar re-lectura)
    $cacheMediainfo.Remove($rutaSalida) | Out-Null
    $jMi = Get-MediainfoJson $rutaSalida
    if ($jMi -and $jMi.media -and $jMi.media.track) {
        foreach ($pista in $jMi.media.track) {
            $tipo = "$($pista.'@type')"
            if ($tipo -in @('General','Menu')) { continue }
            $resumen = "Pista final ID=$($pista.ID) tipo=$tipo Format=$($pista.Format)"
            if ($tipo -eq "Video") {
                $resumen += " HDR_Format=$($pista.HDR_Format)"
                $resumen += " colour_primaries=$($pista.colour_primaries) transfer=$($pista.transfer_characteristics) BitDepth=$($pista.BitDepth)"
            }
            if ($tipo -in @('Audio','Text')) {
                $resumen += " Lang=$($pista.Language) Title=`"$($pista.Title)`" Forced=$($pista.Forced) Default=$($pista.Default)"
            }
            Write-DiagLinea $resumen
        }
    }
}

function Test-Dependencias($necesarias) {
    $faltan = $false
    foreach ($h in $necesarias) {
        if (-not (Get-Command $h -ErrorAction SilentlyContinue)) { 
            Write-Host "Falta: $h" -ForegroundColor Red
            $faltan = $true 
        }
    }
    return (-not $faltan)
}

# Detecta si un archivo de vídeo trae al menos una pista PGS (para preguntar solo cuando aplica)
$cacheTienePGS = @{}
function Test-TienePGS($rutaVideo) {
    # Se consulta varias veces por archivo (pre-escaneo, preguntas y extracción); cada consulta era
    # un ffprobe nuevo, lento con archivos en red. Las pistas de un origen no cambian durante el lote.
    if ($cacheTienePGS.ContainsKey("$rutaVideo")) { return $cacheTienePGS["$rutaVideo"] }
    $tiene = $false
    try {
        $resultado = ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 $rutaVideo 2>$null
        if ($resultado) { $tiene = [bool]($resultado -match "(?i)pgs|hdmv_pgs") }
    } catch {}
    $cacheTienePGS["$rutaVideo"] = $tiene
    return $tiene
}

# Detecta el fps real del vídeo (Bug 5) y devuelve la cadena tipo "24000/1001" o "25/1"
function Get-FpsReal($rutaVideo) {
    try {
        $fps = ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 $rutaVideo 2>$null
        if ($fps -and $fps -match "^\d+/\d+$") { return $fps.Trim() }
    } catch {}
    return $null
}

# Renombra evitando colisiones (Bug 10): si existe el destino, añade sufijo incremental.
function Rename-EvitarColision($pathOrigen, $nombreDeseado) {
    $dir = Split-Path $pathOrigen -Parent
    $destino = Join-Path $dir $nombreDeseado
    if (-not (Test-Path -LiteralPath $destino)) {
        Rename-Item -LiteralPath $pathOrigen -NewName $nombreDeseado
        return $destino
    }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($nombreDeseado)
    $ext = [System.IO.Path]::GetExtension($nombreDeseado)
    $i = 2
    while ($true) {
        $candidato = "$base ($i)$ext"
        $ruta = Join-Path $dir $candidato
        if (-not (Test-Path -LiteralPath $ruta)) {
            Write-Host "   [!] Ya existe '$nombreDeseado'. Renombrando a '$candidato'." -ForegroundColor Yellow
            Rename-Item -LiteralPath $pathOrigen -NewName $candidato
            return $ruta
        }
        $i++
    }
}

# Wrapper para mkvpropedit que captura errores en lugar de silenciarlos (Bug 9)
function Invoke-Mkvpropedit($argumentos, $contexto) {
    # Reintentos ante bloqueos transitorios del archivo (código 2). Causas habituales:
    # antivirus escaneando el MKV recién creado, indexador de Windows, escáneres de medios
    # (Jellyfin), o latencia al liberar el handle en unidades de red/USB.
    $maxIntentos = 4
    $esperaSeg = 2
    for ($intento = 1; $intento -le $maxIntentos; $intento++) {
        $salida = & mkvpropedit @argumentos 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }

        $textoSalida = "$($salida -join ' | ')"
        # Solo reintentamos si parece un bloqueo (no se pudo abrir para escritura / bloqueado).
        $esBloqueo = $textoSalida -match "(?i)no se pudo abrir|bloquead|locked|could not be opened|access|permiso"
        if ($intento -lt $maxIntentos -and $esBloqueo) {
            Write-Host "   [!] mkvpropedit no pudo escribir ($contexto), intento $intento/$maxIntentos. Reintentando en ${esperaSeg}s..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds $esperaSeg
            continue
        }
        # Fallo definitivo (o no es un bloqueo): reportamos y salimos.
        Write-Host "   [!] mkvpropedit falló ($contexto). Código: $LASTEXITCODE" -ForegroundColor Red
        Write-Host "       $textoSalida" -ForegroundColor DarkRed
        Add-Incidencia $global:archivoEnCurso "mkvpropedit falló ($contexto) tras $maxIntentos intento(s). La pista pudo quedar sin renombrar o sin banderas."
        return $false
    }
    return $false
}

# Extrae una pista de subtítulo interna a un fichero temporal, mide su tamaño en disco
# y borra el temporal. Se usa cuando mediainfo no reporta StreamSize y necesitamos
# distinguir forzados de completos comparando pesos reales.
# Devuelve el tamaño en bytes, o 0 si la extracción falla.
function Measure-SubEnDisco($rutaMkv, $idPistaMkvmerge) {
    # Vía rápida y sin tocar el archivo: leer 'tag_number_of_bytes' del JSON de mkvmerge -J,
    # que ya está cacheado (Get-MkvmergeJson). Esto evita extraer la pista entera, que en archivos
    # grandes en red (UHD AV1 de varios GB sobre HDD remoto) tarda varios minutos.
    # IMPORTANTE (unidades): el valor devuelto se compara contra StreamSize de mediainfo (bytes),
    # así que SIEMPRE intentamos devolver bytes (tag o extracción real). num_index_entries NO son
    # bytes y solo se usa como último recurso si todo lo demás falla; mezclarlo con bytes haría
    # absurda la heurística del 35% (forzado vs completo).
    $entradasIndice = 0
    try {
        $mj = Get-MkvmergeJson $rutaMkv
        if ($mj -and $mj.tracks) {
            foreach ($t in $mj.tracks) {
                if ($t.id -eq [int]$idPistaMkvmerge) {
                    if ($t.properties -and $t.properties.tag_number_of_bytes) {
                        return [long]$t.properties.tag_number_of_bytes
                    }
                    if ($t.properties -and $t.properties.num_index_entries) {
                        $entradasIndice = [long]$t.properties.num_index_entries
                    }
                    break
                }
            }
        }
    } catch {}

    # Sin tag de bytes: extracción real a disco (bytes de verdad). Lento en red, pero es la
    # única medida comparable con los StreamSize del resto del grupo.
    $tempPath = Join-Path $env:TEMP "hdz_subsize_$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $salida = & mkvextract tracks $rutaMkv "${idPistaMkvmerge}:$tempPath" 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempPath)) {
            & ffmpeg -i $rutaMkv -map "0:$idPistaMkvmerge" -c copy $tempPath -y -v error 2>&1 | Out-Null
        }
        if (Test-Path -LiteralPath $tempPath) {
            $tam = (Get-Item -LiteralPath $tempPath).Length
            return [long]$tam
        }
    } catch {
    } finally {
        Remove-Item -LiteralPath $tempPath -ErrorAction SilentlyContinue
    }

    # Último recurso: num_index_entries como proxy (unidad distinta, solo mejor que 0).
    if ($entradasIndice -gt 0) {
        Write-DiagLinea "Measure-SubEnDisco: usando num_index_entries=$entradasIndice como proxy (no bytes) para pista $idPistaMkvmerge de $(Split-Path $rutaMkv -Leaf)"
        return $entradasIndice
    }
    return 0
}

# Determina el tipo de pista de un archivo externo (Bug 7) con detección más fiable.
# Las extensiones de subtítulo y de audio son inequívocas, así que las usamos como fuente de verdad
# y mediainfo solo como confirmación/fallback.
function Get-TipoPistaExterno($archivo, $pistaMediainfo) {
    $ext = $archivo.Extension.ToLower().TrimStart('.')
    $extsAudioInequivoco = @("ac3", "eac3", "dts", "dtshd", "truehd", "flac", "wav", "mka", "m4a", "aac", "opus")
    $extsSubInequivoco   = @("srt", "ass", "ssa", "sup", "pgs", "idx", "sub", "vtt")
    if ($extsAudioInequivoco -contains $ext) { return "Audio" }
    if ($extsSubInequivoco   -contains $ext) { return "Sub" }
    if ($pistaMediainfo) {
        if ($pistaMediainfo.'@type' -eq "Audio") { return "Audio" }
        if ($pistaMediainfo.'@type' -eq "Text")  { return "Sub" }
    }
    return $null   # no clasificable → el caller debe ignorarlo
}

# Pre-escaneo: detecta los grupos (idioma + formato) que tienen UN ÚNICO sub interno
# en un archivo (o pareja híbrida) sin señal positiva de forzado.
# Devuelve una lista de PSCustomObject con: CodLang, NomLang, FmtSimple, Size, RutaArchivoFuente, IdPista.
# El criterio "1 solo sub tras todo lo conocido" replica exactamente la lógica de Build-PistasBrutas:
# - Si hay 2 subs del mismo (idioma+formato) y se distinguen por tamaño (un Forzado y un Completo) → no hay duda.
# - Si hay 2 subs idénticos en tamaño → se reducirán a 1 tras la deduplicación → AHÍ sí preguntamos.
# - Si solo hay 1 sub de entrada → preguntamos.
# La función toma 1 ó 2 paths (lista de archivos del par híbrido).
function Get-SubsUnicosArchivo($rutasArchivosMkv, $incluirExternos = $false, $prefijoArchivo = "") {
    $resultado = @()
    $listaArchivos = @($rutasArchivosMkv)

    # Recolectar todos los subs internos con su tamaño "real" (midiendo en disco si hace falta).
    $todosSubs = @()
    foreach ($ruta in $listaArchivos) {
        $miJson = Get-MediainfoJson $ruta
        if (-not $miJson) { continue }
        $idMapL = Get-MkvmergeTrackIdMap $ruta
        $contTextL = 0
        foreach ($pista in $miJson.media.track) {
            if ($pista.'@type' -ne "Text") { continue }
            $contTextL++
            $claveMap = "Text+$contTextL"
            $idReal = if ($idMapL.ContainsKey($claveMap)) { $idMapL[$claveMap] } else { $pista.ID - 1 }
            if (-not (Test-HdzSubTrackKept $ruta $idReal)) { continue }   # desmarcado a mano: no cuenta
            $langCode = "$($pista.Language)"
            if ([string]::IsNullOrWhiteSpace($langCode)) { $langCode = "und" }
            $tituloPista = "$($pista.Title)"
            $langCode = Get-LanguageCode $langCode $tituloPista
            # Decisión por pista de la GUI: resuelve el idioma 'und' antes de clasificar
            # el sub (así los grupos y las preguntas usan ya el idioma correcto).
            if ($global:undPistasGui.ContainsKey("$ruta|$idReal|Sub")) {
                $langCode = Get-LanguageCode $global:undPistasGui["$ruta|$idReal|Sub"] ""
            } elseif ($langCode -eq "und") {
                if ($global:undPistasGui.ContainsKey("$ruta|$idReal|Sub")) {
                    $langCode = Get-LanguageCode $global:undPistasGui["$ruta|$idReal|Sub"] ""
                } else {
                    # Id de la GUI (ffprobe) != Id del motor (mkvmerge): recuperamos por archivo+tipo.
                    $guiCod = Get-IdiomaUndGui $ruta "Sub"
                    if ($guiCod) { $langCode = Get-LanguageCode $guiCod "" }
                }
            }

            # Señal positiva de forzado: flag mediainfo o título con "forced"
            $tieneSenalForzado = $false
            if ($pista.PSObject.Properties.Name -contains "Forced" -and "$($pista.Forced)" -match "(?i)yes|1|true") { $tieneSenalForzado = $true }
            if ($tituloPista -match "(?i)(forced|forzado|forzados)") { $tieneSenalForzado = $true }

            # Señal positiva de COMPLETO: título con "completo"/"completos"/"complete"/"full".
            # Si el sub viene etiquetado explícitamente como completo, no hay ambigüedad → no preguntar.
            $tieneSenalCompleto = $false
            if ($tituloPista -match "(?i)(completos?|complete|full)") { $tieneSenalCompleto = $true }

            $tam = if ($pista.StreamSize) { [long]$pista.StreamSize } else { 0 }
            $fmtSimple = if ("$($pista.Format)" -match "(?i)srt|subrip|ass|ssa|utf-?8|text") { "Text" } else { "PGS" }

            $todosSubs += [PSCustomObject]@{
                CodLang = $langCode
                NomLang = (Get-LanguageName $langCode $tituloPista)
                FmtSimple = $fmtSimple
                Size = $tam
                IdPista = $idReal
                RutaArchivoFuente = $ruta
                EsExterno = $false
                NombreExterno = ""
                TieneSenalForzado = $tieneSenalForzado
                TieneSenalCompleto = $tieneSenalCompleto
            }
        }
    }

    # Subs EXTERNOS de la carpeta (SRT/ASS/SSA sueltos): se incluyen solo si se pide explícitamente
    # (típicamente justo antes de muxear, cuando ya pueden existir los SRT convertidos o los que
    # el usuario metió a mano). Identificamos el idioma por el nombre del archivo.
    if ($incluirExternos) {
        $subsExt = Get-ChildItem -LiteralPath $rutaCarpeta -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match "(?i)\.(srt|ass|ssa)$" }
        foreach ($ext in $subsExt) {
            # En modo lote (con prefijo), solo consideramos los externos de ESTE archivo.
            if ($prefijoArchivo) {
                $prefEsc = [regex]::Escape($prefijoArchivo)
                # SRT convertidos de PGS de este archivo, o cualquier SRT que empiece por su nombre.
                if ($ext.Name -notmatch "(?i)^$prefEsc") { continue }
            }
            # Idioma: lo buscamos en el nombre del archivo (es, spa, eng, en, fre...).
            $codNombre = "und"
            if ($ext.BaseName -match "(?i)_sub_\d+_([a-z]{2,3})$") { $codNombre = Get-LanguageCode $Matches[1] "" }
            elseif ($ext.BaseName -match "(?i)[\._\s-](es-419|lat|cas|spa|es|eng|en|fre|fr|ger|de|ita|it|por|pt|jpn|ja|chi|zh|kor|ko)(?:[\._\s-]|$)") { $codNombre = Get-LanguageCode $Matches[1] "" }
            $fmtSimple = "Text"
            # Señal de forzado en el nombre del archivo externo
            $senal = ($ext.Name -match "(?i)(forced|forzado|forzados)")
            $senalComp = ($ext.Name -match "(?i)(completos?|complete|full)")
            $todosSubs += [PSCustomObject]@{
                CodLang = $codNombre
                NomLang = (Get-LanguageName $codNombre "")
                FmtSimple = $fmtSimple
                Size = [long]$ext.Length
                IdPista = -1
                RutaArchivoFuente = $ext.FullName
                EsExterno = $true
                NombreExterno = $ext.Name
                TieneSenalForzado = $senal
                TieneSenalCompleto = $senalComp
            }
        }
    }

    if ($todosSubs.Count -eq 0) { return $resultado }

    # IMPORTANTE (rendimiento): la medición de tamaño en disco (Measure-SubEnDisco) puede caer en
    # mkvextract, que es MUY lento en archivos UHD (abre y demuxea varios GB por pista). Por eso NO
    # medimos todos los subs por adelantado: lo hacemos de forma PEREZOSA, solo en los grupos que de
    # verdad necesitan distinguir forzado/completo por tamaño (varios subs del mismo idioma/formato y
    # sin ninguna señal en el título). Los subs únicos o etiquetados ("forzado"/"completo") nunca se
    # miden. (Antes se medían TODOS → 48 extracciones sobre 4K = ~media hora por temporada.)

    # Agrupar por (idioma + formato_simplificado)
    $grupos = @{}
    foreach ($s in $todosSubs) {
        $k = "$($s.CodLang)|$($s.FmtSimple)"
        if (-not $grupos.ContainsKey($k)) { $grupos[$k] = @() }
        $grupos[$k] += $s
    }

    # Para cada grupo:
    # - Si en el grupo hay AL MENOS UN sub con señal positiva de forzado → no hay ambigüedad: nada que preguntar.
    # - Si el grupo tiene un solo sub (caso típico no-híbrido) → CANDIDATO a preguntar.
    # - Si tiene varios y se distinguen por tamaño (max > 0 y el menor ≤ 35% del max) → la heurística los separa → nada que preguntar.
    # - Si tiene varios pero TODOS pesan parecido (el menor > 35% del max, es decir, se considerarán duplicados
    #   tras la deduplicación) → CANDIDATO a preguntar, porque tras dedup queda 1 solo.
    foreach ($k in $grupos.Keys) {
        $lista = $grupos[$k]
        $haySenal = ($lista | Where-Object { $_.TieneSenalForzado }).Count -gt 0
        if ($haySenal) { continue }
        # Si TODOS los subs del grupo están explícitamente marcados como completos en el título,
        # no hay ambigüedad: ninguno es forzado → nada que preguntar.
        $todosCompletos = ($lista.Count -gt 0) -and (($lista | Where-Object { $_.TieneSenalCompleto }).Count -eq $lista.Count)
        if ($todosCompletos) { continue }
        if ($lista.Count -eq 1) {
            $resultado += $lista[0]
            continue
        }
        # Varios subs en el grupo: ver si la heurística de tamaño los distingue.
        # AQUÍ (y solo aquí) medimos en disco los que no traigan tamaño de mediainfo: es el único
        # caso en que el tamaño se usa de verdad, así evitamos extraer subs innecesariamente.
        foreach ($s in $lista) {
            if ($s.Size -le 0 -and -not $s.EsExterno) { $s.Size = Measure-SubEnDisco $s.RutaArchivoFuente $s.IdPista }
        }
        $maxS = ($lista | Measure-Object Size -Maximum).Maximum
        $minS = ($lista | Measure-Object Size -Minimum).Minimum
        if ($maxS -gt 0 -and $minS -le ($maxS * 0.35)) { continue }  # heurística los separa: no preguntar
        # Tamaños similares → tras dedup quedará 1 → CANDIDATO. Devolvemos el primero (representante del grupo).
        $resultado += $lista[0]
    }
    return $resultado
}

# Devuelve la lista de idiomas DISTINTOS de subtítulos presentes en un archivo o par híbrido.
# Cada entrada es un PSCustomObject con CodLang (código canónico) y NomLang (nombre legible).
# Castellano (es) y Latino (es-419) cuentan como distintos.
function Get-IdiomasSubsArchivo($rutasArchivosMkv) {
    $vistos = @{}
    foreach ($ruta in @($rutasArchivosMkv)) {
        $mi = Get-MediainfoJson $ruta
        if (-not $mi) { continue }
        $idMap = Get-MkvmergeTrackIdMap $ruta
        $ordinal = 0
        foreach ($p in $mi.media.track) {
            if ($p.'@type' -ne "Text") { continue }
            $ordinal++
            $lang = "$($p.Language)"; if ([string]::IsNullOrWhiteSpace($lang)) { $lang = "und" }
            $titulo = "$($p.Title)"
            $cod = Get-LanguageCode $lang $titulo
            $id = if ($idMap.ContainsKey("Text+$ordinal")) { $idMap["Text+$ordinal"] } else { $p.ID - 1 }
            if ($global:undPistasGui.ContainsKey("$ruta|$id|Sub")) { $cod = Get-LanguageCode $global:undPistasGui["$ruta|$id|Sub"] '' }
            if (-not $vistos.ContainsKey($cod)) {
                $vistos[$cod] = [PSCustomObject]@{ CodLang = $cod; NomLang = (Get-LanguageName $cod '') }
            }
        }
    }
    return @($vistos.Values)
}

# Pre-escaneo del lote (modo HOMOGÉNEO): si algún archivo tiene MÁS DE 3 idiomas distintos de
# subtítulos, pregunta qué hacer. Devuelve una decisión global que se aplicará al filtrar:
#   - $null  -> no filtrar (mantener todos)
#   - @("__CAST_ENG__")  -> mantener solo castellano (es) e inglés (eng)
#   - @("es","eng","ita",...)  -> lista explícita de códigos a mantener (selección personalizada)
function Resolve-IdiomasSubsLote($grupos) {
    # Decisión pre-elegida en la GUI: "TODOS" (sin filtro), "CAST_ENG" o lista de códigos.
    # Si está definida, se aplica SIEMPRE (la GUI lo eligió explícitamente) y se omite el escaneo.
    $cfgFiltro = Get-CfgGui "IdiomasSubsMantener"
    if ($cfgFiltro) {
        if ("$cfgFiltro" -eq "TODOS")    { Write-Host "`n[GUI] Subtítulos: mantener todos los idiomas (configuración)." -ForegroundColor DarkGray; return $null }
        if ("$cfgFiltro" -eq "CAST_ENG") { Write-Host "`n[GUI] Subtítulos: solo castellano e inglés (configuración)." -ForegroundColor DarkGray; return @("__CAST_ENG__") }
        Write-Host "`n[GUI] Subtítulos: mantener idiomas $(@($cfgFiltro) -join ', ') (configuración)." -ForegroundColor DarkGray
        return @($cfgFiltro)
    }

    # Buscar el conjunto de idiomas más amplio del lote (normalmente todos los capítulos
    # comparten los mismos; usamos el archivo con más idiomas como representante).
    $maxIdiomas = @()
    $total = $grupos.Count
    $nProc = 0
    foreach ($g in $grupos) {
        $nProc++
        $hibridoInfo = Resolve-Hibrido $g
        Write-Progress -Activity "Analizando idiomas de subtítulos en el lote" -Status "$nProc/$total : $($hibridoInfo.ArchivoPrincipal.Name)" -PercentComplete (($nProc/$total)*100)
        $idiomas = Get-IdiomasSubsArchivo $hibridoInfo.OrigenesPistas
        if ($idiomas.Count -gt $maxIdiomas.Count) { $maxIdiomas = $idiomas }
    }
    Write-Progress -Activity "Analizando idiomas de subtítulos en el lote" -Completed

    if ($maxIdiomas.Count -le 3) { return $null }   # 3 o menos: no preguntamos

    Write-Host "`n>> Se han detectado $($maxIdiomas.Count) idiomas distintos de subtítulos:" -ForegroundColor Cyan
    foreach ($idi in $maxIdiomas) { Write-Host "   - $($idi.NomLang) ($($idi.CodLang))" -ForegroundColor Gray }

    $opcion = Mostrar-Menu "¿Qué quieres hacer con los subtítulos?" @(
        @{Nombre="Mantener solo castellano e inglés"; Valor="CAST_ENG"},
        @{Nombre="Selección personalizada de idiomas"; Valor="PERSONALIZADA"},
        @{Nombre="Mantener todos"; Valor="TODOS"}
    )

    switch ($opcion) {
        "TODOS"    { return $null }
        "CAST_ENG" { return @("__CAST_ENG__") }
        "PERSONALIZADA" {
            Write-Host "`nIdiomas de subtítulos detectados:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $maxIdiomas.Count; $i++) {
                Write-Host "   [$($i+1)] $($maxIdiomas[$i].NomLang) ($($maxIdiomas[$i].CodLang))"
            }
            $seleccion = @()
            while ($seleccion.Count -eq 0) {
                $raw = Read-Host "Escribe los números a MANTENER (separados por comas)"
                $indices = $raw -split "[,\s]+" | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
                foreach ($idx in $indices) {
                    if ($idx -ge 1 -and $idx -le $maxIdiomas.Count) {
                        $seleccion += $maxIdiomas[$idx-1].CodLang
                    }
                }
                if ($seleccion.Count -eq 0) { Write-Host "   Selección no válida, inténtalo de nuevo." -ForegroundColor Yellow }
            }
            return @($seleccion | Select-Object -Unique)
        }
    }
    return $null
}

# Versión por archivo (HETEROGÉNEO): pregunta para un único archivo si tiene >3 idiomas de subs.
# Devuelve la misma estructura que Resolve-IdiomasSubsLote.
function Resolve-IdiomasSubsArchivo($rutasArchivosMkv) {
    # Decisión pre-elegida en la GUI (mismas reglas que Resolve-IdiomasSubsLote).
    $cfgFiltro = Get-CfgGui "IdiomasSubsMantener"
    if ($cfgFiltro) {
        if ("$cfgFiltro" -eq "TODOS")    { return $null }
        if ("$cfgFiltro" -eq "CAST_ENG") { return @("__CAST_ENG__") }
        return @($cfgFiltro)
    }

    $idiomas = Get-IdiomasSubsArchivo $rutasArchivosMkv
    if ($idiomas.Count -le 3) { return $null }

    Write-Host "`n>> Este archivo tiene $($idiomas.Count) idiomas distintos de subtítulos:" -ForegroundColor Cyan
    foreach ($idi in $idiomas) { Write-Host "   - $($idi.NomLang) ($($idi.CodLang))" -ForegroundColor Gray }

    $opcion = Mostrar-Menu "¿Qué quieres hacer con los subtítulos?" @(
        @{Nombre="Mantener solo castellano e inglés"; Valor="CAST_ENG"},
        @{Nombre="Selección personalizada de idiomas"; Valor="PERSONALIZADA"},
        @{Nombre="Mantener todos"; Valor="TODOS"}
    )
    switch ($opcion) {
        "TODOS"    { return $null }
        "CAST_ENG" { return @("__CAST_ENG__") }
        "PERSONALIZADA" {
            Write-Host "`nIdiomas de subtítulos detectados:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $idiomas.Count; $i++) {
                Write-Host "   [$($i+1)] $($idiomas[$i].NomLang) ($($idiomas[$i].CodLang))"
            }
            $seleccion = @()
            while ($seleccion.Count -eq 0) {
                $raw = Read-Host "Escribe los números a MANTENER (separados por comas)"
                $indices = $raw -split "[,\s]+" | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
                foreach ($idx in $indices) {
                    if ($idx -ge 1 -and $idx -le $idiomas.Count) { $seleccion += $idiomas[$idx-1].CodLang }
                }
                if ($seleccion.Count -eq 0) { Write-Host "   Selección no válida, inténtalo de nuevo." -ForegroundColor Yellow }
            }
            return @($seleccion | Select-Object -Unique)
        }
    }
    return $null
}

# Pre-escaneo del lote en modo HOMOGÉNEO: detecta los (idioma+formato) que aparecen como sub único
# sin señal en al menos un archivo, y hace UNA pregunta por combinación al usuario.
# Devuelve una hashtable con:
#   - claves "<idioma>|<formato>" para decisiones globales (aplicar a toda la serie)
#   - clave "<idioma>|<formato>|__PREGUNTAR__" cuando el usuario quiere decidir archivo por archivo
# La memoria por archivo concreto se rellenará después.
function Resolve-SubsUnicosLote($grupos, $idiomasSubsMantener = $null) {
    $decisiones = @{}

    # 1. Pre-escanear todos los archivos del lote
    Write-Host "`nPre-escaneando subtítulos del lote..." -ForegroundColor DarkGray
    $combinaciones = @{}   # "idioma|fmt" -> @{ NomLang=...; Archivos=@(path1, path2, ...) }
    $total = $grupos.Count
    $nProc = 0
    foreach ($g in $grupos) {
        $nProc++
        $hibridoInfo = Resolve-Hibrido $g
        Write-Progress -Activity "Pre-escaneando subtítulos del lote" -Status "$nProc/$total : $($hibridoInfo.ArchivoPrincipal.Name)" -PercentComplete (($nProc/$total)*100)
        Set-ProgresoGui ([int](8 + 6 * $nProc / [Math]::Max(1,$total))) "Pre-escaneando subtítulos ($nProc/$total)" $hibridoInfo.ArchivoPrincipal.Name
        $rutas = $hibridoInfo.OrigenesPistas
        $candidatos = Get-SubsUnicosArchivo $rutas
        foreach ($c in $candidatos) {
            # Respetar el filtro de idiomas: no preguntar por subs que se van a descartar.
            if ($idiomasSubsMantener) {
                $seMantiene = if ($idiomasSubsMantener -contains "__CAST_ENG__") { $c.CodLang -in @("es", "eng") } else { $c.CodLang -in $idiomasSubsMantener }
                if (-not $seMantiene) { continue }
            }
            $k = "$($c.CodLang)|$($c.FmtSimple)"
            if (-not $combinaciones.ContainsKey($k)) {
                $combinaciones[$k] = @{ NomLang = $c.NomLang; CodLang = $c.CodLang; FmtSimple = $c.FmtSimple; Archivos = @() }
            }
            # Usamos el ArchivoPrincipal como identificador (es el que verá Build-PistasBrutas)
            $combinaciones[$k].Archivos += $hibridoInfo.ArchivoPrincipal.FullName
        }
    }
    Write-Progress -Activity "Pre-escaneando subtítulos del lote" -Completed

    if ($combinaciones.Keys.Count -eq 0) {
        Write-Host "   -> No se detectaron subtítulos únicos ambiguos en el lote." -ForegroundColor DarkGray
        return $decisiones
    }

    # 2. Mostrar resumen
    Write-Host "`n>> Subtítulos individuales detectados (sin señal de forzado en mediainfo)" -ForegroundColor Cyan
    foreach ($k in $combinaciones.Keys) {
        $info = $combinaciones[$k]
        Write-Host "   - $($info.NomLang) ($($info.FmtSimple)): $($info.Archivos.Count) archivo(s) con un único sub" -ForegroundColor Gray
    }

    # 3. Preguntar por cada combinación
    foreach ($k in $combinaciones.Keys) {
        $info = $combinaciones[$k]

        # Clave bajo la que se GUARDA la decisión. Si el idioma era 'und' y se resuelve, hay que
        # guardar con el código RESUELTO: es el que tendrán las pistas tras Build-PistasBrutas y
        # el que Set-FlagForzados usará al consultar. (Antes se guardaba "...|und|..." y la
        # decisión del usuario se perdía en silencio.)
        $kDecision = $k

        # Si el idioma es indeterminado (und): el pre-escaneo Resolve-IdiomasUndLote ya preguntó
        # el idioma de los subs 'und' del lote. Lo reutilizamos sin volver a preguntar. Solo si
        # por algún motivo no se decidió antes, preguntamos aquí como respaldo.
        if ($info.CodLang -eq "und") {
            $codElegido = if ($global:idiomaUndSubLote) { $global:idiomaUndSubLote } else { Resolve-IdiomaSubUnd "$($info.NomLang) ($($info.FmtSimple))" }
            if ($codElegido -ne "und") {
                foreach ($f in $info.Archivos) { $global:decisionesIdiomaUnd["${f}|$($info.FmtSimple)"] = $codElegido }
                $info.NomLang = (Get-LanguageName $codElegido "")
                $kDecision = "$codElegido|$($info.FmtSimple)"
            }
        }

        # Decisión POR sub (idioma+formato) elegida en la GUI; respaldo: decisión global.
        # Para subs 'und' resueltos, la GUI puede haber guardado la decisión bajo el código RESUELTO,
        # así que consultamos primero por ese código y, si no, por el original ('und').
        $codResuelto = if ($info.CodLang -eq "und" -and $kDecision -ne $k) { ($kDecision -split '\|')[0] } else { $info.CodLang }
        $cfgSubUnico = Get-DecisionSubGui $codResuelto $info.FmtSimple
        if (-not $cfgSubUnico -and $codResuelto -ne $info.CodLang) { $cfgSubUnico = Get-DecisionSubGui $info.CodLang $info.FmtSimple }
        $resp = switch ("$cfgSubUnico") {
            "Forzado"   { "1" }
            "Completo"  { "2" }
            "PREGUNTAR" { "3" }
            default     { $null }
        }
        if ($resp) {
            $txtResp = switch ($resp) { "1" { "Forzado" } "2" { "Completo" } "3" { "preguntar por archivo" } }
            Write-Host "   [GUI] Sub único $($info.NomLang) ($($info.FmtSimple)) -> $txtResp (configuración)." -ForegroundColor DarkGray
        } elseif ($global:sinPreguntas) {
            # Montaje desatendido (lanzado por la GUI): NO se pregunta. Un sub único sin señal de
            # forzado se trata como Completo por defecto (lo habitual; los forzados sí llevan señal).
            $resp = "2"
            Write-Host "   [auto] Sub único $($info.NomLang) ($($info.FmtSimple)) sin decisión en la GUI -> Completo (por defecto, sin preguntar)." -ForegroundColor DarkYellow
        } else {
            Write-Host "`n   ¿El subtítulo $($info.NomLang) ($($info.FmtSimple)) es...?" -ForegroundColor Cyan
            Write-Host "     [1] Forzado en todos los archivos"
            Write-Host "     [2] Completo en todos los archivos"
            Write-Host "     [3] Preguntar para cada archivo durante el procesamiento"
            while (-not $resp) {
                $r = Read-Host "   Elige una opción (1-3)"
                if ($r -match '^[1-3]$') { $resp = $r }
                else { Write-Host "   Entrada no válida." -ForegroundColor Yellow }
            }
        }
        switch ($resp) {
            "1" { foreach ($f in $info.Archivos) { $decisiones["${f}|$kDecision"] = "Forzado" } }
            "2" { foreach ($f in $info.Archivos) { $decisiones["${f}|$kDecision"] = "Completo" } }
            "3" { foreach ($f in $info.Archivos) { $decisiones["${f}|$kDecision"] = "__PREGUNTAR__" } }
        }
    }
    return $decisiones
}

# Pregunta para UN solo archivo (modo HETEROGÉNEO o cuando la decisión homogénea fue "__PREGUNTAR__").
# Mira los subs únicos del archivo en cuestión y pregunta por cada combinación.
# Actualiza $decisiones in-place.
function Resolve-SubsUnicosArchivo($rutasArchivosMkv, $archivoPrincipal, $decisiones, $idiomasSubsMantener = $null) {
    $candidatos = Get-SubsUnicosArchivo $rutasArchivosMkv
    if (-not $candidatos -or $candidatos.Count -eq 0) { return }
    $pathRef = $archivoPrincipal.FullName

    foreach ($c in $candidatos) {
        # Respetar el filtro de idiomas: no preguntar por subs de idiomas que se van a descartar.
        if ($idiomasSubsMantener) {
            $seMantiene = if ($idiomasSubsMantener -contains "__CAST_ENG__") { $c.CodLang -in @("es", "eng") } else { $c.CodLang -in $idiomasSubsMantener }
            if (-not $seMantiene) { continue }
        }

        # Idioma indeterminado: resolverlo ANTES de construir la clave de decisión, para que esta
        # coincida con el código que tendrán las pistas (y con las decisiones del pre-escaneo del
        # lote, que también se guardan con el código resuelto). Si el lote ya decidió el idioma,
        # se reutiliza sin volver a preguntar.
        $nomMostrar = $c.NomLang
        $codEfectivo = $c.CodLang
        if ($c.CodLang -eq "und") {
            $kUnd = "${pathRef}|$($c.FmtSimple)"
            if ($global:decisionesIdiomaUnd.ContainsKey($kUnd)) {
                $codEfectivo = $global:decisionesIdiomaUnd[$kUnd]
            } elseif ($global:idiomaUndSubLote) {
                $codEfectivo = $global:idiomaUndSubLote
                $global:decisionesIdiomaUnd[$kUnd] = $codEfectivo
            } else {
                $codElegido = Resolve-IdiomaSubUnd "$($c.NomLang) ($($c.FmtSimple))"
                if ($codElegido -ne "und") {
                    $global:decisionesIdiomaUnd[$kUnd] = $codElegido
                    $codEfectivo = $codElegido
                }
            }
            if ($codEfectivo -ne "und") { $nomMostrar = (Get-LanguageName $codEfectivo "") }
        }

        $k = "$codEfectivo|$($c.FmtSimple)"
        $llave = "${pathRef}|$k"
        # Si ya hay decisión global (1/2) la respetamos. Si es __PREGUNTAR__ o no existe, preguntamos aquí.
        $decisionPrevia = $null
        if ($decisiones.ContainsKey($llave)) { $decisionPrevia = $decisiones[$llave] }
        if ($decisionPrevia -eq "Forzado" -or $decisionPrevia -eq "Completo") { continue }

        # Decisión pre-elegida en la GUI (modo heterogéneo): por sub (idioma+formato) de ESTE archivo,
        # con respaldo al mapa global y a la decisión global.
        $cfgSubUnico = Get-DecisionSubGui $c.CodLang $c.FmtSimple $archivoPrincipal.Name
        if ("$cfgSubUnico" -in @("Forzado", "Completo")) {
            $decisiones[$llave] = "$cfgSubUnico"
            Write-Host "   [GUI] Sub único $nomMostrar ($($c.FmtSimple)) -> $cfgSubUnico (configuración)." -ForegroundColor DarkGray
            continue
        }

        if ($global:sinPreguntas) {
            # Montaje desatendido: no se pregunta. Por defecto, Completo (un sub único sin señal).
            $decisiones[$llave] = "Completo"
            Write-Host "   [auto] Sub único $nomMostrar ($($c.FmtSimple)) sin decisión -> Completo (por defecto, sin preguntar)." -ForegroundColor DarkYellow
            continue
        }
        Write-Host "`n   ¿El subtítulo $nomMostrar ($($c.FmtSimple)) es...?" -ForegroundColor Cyan
        Write-Host "     [1] Forzado"
        Write-Host "     [2] Completo"
        $resp = $null
        while (-not $resp) {
            $r = Read-Host "   Elige una opción (1-2)"
            if ($r -match '^[1-2]$') { $resp = $r }
            else { Write-Host "   Entrada no válida." -ForegroundColor Yellow }
        }
        switch ($resp) {
            "1" { $decisiones[$llave] = "Forzado" }
            "2" { $decisiones[$llave] = "Completo" }
        }
    }
}

# Pregunta forzado/completo de los SUBTÍTULOS EXTERNOS únicos (SRT/ASS sueltos en la carpeta,
# o convertidos de PGS). Se llama JUSTO ANTES de muxear cada archivo (tras la pausa de Subtitle
# Edit, si la hubo), porque es cuando esos SRT ya existen en la carpeta.
# - Si el nombre del archivo externo contiene "forced"/"forzado" → se asume forzado, no se pregunta.
# - Si queda único en su grupo (idioma+formato) sin señal → se pregunta.
# La decisión se guarda en $decisiones con clave "EXT|<nombreArchivo>", que Set-FlagForzados aplica.
function Resolve-SubsExternosForzados($rutasArchivosMkv, $prefijoArchivo, $decisiones, $idiomasSubsMantener = $null) {
    $candidatos = Get-SubsUnicosArchivo $rutasArchivosMkv $true $prefijoArchivo
    if (-not $candidatos -or $candidatos.Count -eq 0) { return }

    foreach ($c in $candidatos) {
        # Solo nos interesan los EXTERNOS aquí (los internos ya se preguntaron en su momento).
        if (-not $c.EsExterno) { continue }
        # Respetar el filtro de idiomas.
        if ($idiomasSubsMantener) {
            $seMantiene = if ($idiomasSubsMantener -contains "__CAST_ENG__") { $c.CodLang -in @("es", "eng") } else { $c.CodLang -in $idiomasSubsMantener }
            if (-not $seMantiene) { continue }
        }
        # Si el nombre ya indica forzado, asumir forzado y NO preguntar.
        if ($c.TieneSenalForzado) {
            $decisiones["EXT|$($c.NombreExterno)"] = "Forzado"
            Write-Host "   [subs externos] '$($c.NombreExterno)' detectado como FORZADO por el nombre." -ForegroundColor DarkGray
            continue
        }
        $kExt = "EXT|$($c.NombreExterno)"
        if ($decisiones.ContainsKey($kExt)) { continue }   # ya decidido

        # Decisión pre-elegida en la GUI: por sub (idioma+formato), con respaldo global.
        $cfgSubUnico = Get-DecisionSubGui $c.CodLang $c.FmtSimple
        if ("$cfgSubUnico" -in @("Forzado", "Completo")) {
            $decisiones[$kExt] = "$cfgSubUnico"
            Write-Host "   [GUI] Sub externo '$($c.NombreExterno)' -> $cfgSubUnico (configuración)." -ForegroundColor DarkGray
            continue
        }

        if ($global:sinPreguntas) {
            # Montaje desatendido: no se pregunta. Por defecto, Completo.
            $decisiones[$kExt] = "Completo"
            Write-Host "   [auto] Sub externo '$($c.NombreExterno)' sin decisión -> Completo (por defecto, sin preguntar)." -ForegroundColor DarkYellow
            continue
        }
        Write-Host "`n   ¿El subtítulo externo $($c.NomLang) '$($c.NombreExterno)' es...?" -ForegroundColor Cyan
        Write-Host "     [1] Forzado"
        Write-Host "     [2] Completo"
        $resp = $null
        while (-not $resp) {
            $r = Read-Host "   Elige una opción (1-2)"
            if ($r -match '^[1-2]$') { $resp = $r }
            else { Write-Host "   Entrada no válida." -ForegroundColor Yellow }
        }
        switch ($resp) {
            "1" { $decisiones[$kExt] = "Forzado" }
            "2" { $decisiones[$kExt] = "Completo" }
        }
    }
}
# $rutaMkvOrigen: si se proporciona, cuando un grupo no tiene tamaños reportados se intentará
# extraer cada sub interno y medir su peso en disco.
# SDH (subtítulos para sordos). Señales, de más a menos fiable: flag hearing-impaired del MKV
# (mkvmerge -J / ServiceKind=HI de mediainfo), el Title o el nombre del archivo, y por último el
# contenido: un SDH describe sonidos ([música], ♪...) en muchas líneas; un completo normal, en casi ninguna.
$patronTituloSdh = '(?i)(\bSDH\b|\bCC\b|\bHoH\b|sordos|hearing|malentendant)|(?-i:\bHI\b)'   # HI en mayúsculas: "hi" es hindi
function Get-ProporcionSonidoSrt([string]$texto) {
    $bloques = @($texto -split '\r?\n\s*\r?\n' | Where-Object { $_ -match '-->' })
    if ($bloques.Count -eq 0) { return 0 }
    $conSonido = @($bloques | Where-Object {
        $lineas = (($_ -split '\r?\n') | Where-Object { $_ -notmatch '-->' -and $_ -notmatch '^\s*\d+\s*$' }) -join ' '
        $lineas -match '\[[^\]]+\]|\([^\)]{3,}\)|♪'
    }).Count
    return $conSonido / $bloques.Count
}
function Set-FlagSdh($listaSubs) {
    if (-not $listaSubs -or $listaSubs.Count -eq 0) { return }
    foreach ($s in $listaSubs) {
        $s | Add-Member -NotePropertyName "EsSDH" -NotePropertyValue ((-not $s.IsForced) -and [bool]$s.SdhFlag) -Force
    }
    # Contenido: solo en grupos (idioma, texto plano) con 2+ completos sin señal, que es donde un SDH
    # sin marcar se confunde con el completo normal. Basta con los primeros 10 minutos: ffmpeg los
    # saca de una pasada por MKV de origen y el vídeo copiado a null le marca dónde parar (sin él lee
    # el archivo entero). Si ffmpeg falla, mkvextract del sub completo.
    $candidatos = @{}
    foreach ($s in $listaSubs) {
        if ($s.IsForced -or $s.EsSDH) { continue }
        if ("$($s.Format)" -notmatch '(?i)srt|subrip|utf-?8|text') { continue }
        $k = "$($s.CodLang)"
        if (-not $candidatos.ContainsKey($k)) { $candidatos[$k] = @() }
        $candidatos[$k] += $s
    }
    $aMedir = @($candidatos.Values | Where-Object { @($_).Count -gt 1 } | ForEach-Object { $_ })
    if ($aMedir.Count -eq 0) { return }
    $temporales = @()
    try {
        foreach ($g in @($aMedir | Where-Object { $_.Origen -eq 'Interno' -and $_.ArchivoFuenteMkv } | Group-Object ArchivoFuenteMkv)) {
            $argsFf = @('-nostdin', '-y', '-v', 'error', '-i', $g.Name)
            $argsExt = @($g.Name, 'tracks')
            foreach ($s in $g.Group) {
                $tmp = Join-Path $env:TEMP "hdz_sdh_$([guid]::NewGuid().ToString('N')).srt"
                $temporales += $tmp
                $s | Add-Member -NotePropertyName "RutaTextoSdh" -NotePropertyValue $tmp -Force
                $argsFf += @('-map', "0:$($s.ID)", '-t', '600', '-c:s', 'srt', $tmp)
                $argsExt += "$($s.ID):$tmp"
            }
            $argsFf += @('-map', '0:v:0?', '-t', '600', '-c:v', 'copy', '-f', 'null', '-')
            $null = & ffmpeg @argsFf 2>&1
            $faltan = @($g.Group | Where-Object { -not (Test-Path -LiteralPath $_.RutaTextoSdh) -or (Get-Item -LiteralPath $_.RutaTextoSdh).Length -eq 0 })
            if ($LASTEXITCODE -ne 0 -or $faltan.Count) {
                Write-Host "       -> ffmpeg no sacó los 10 primeros minutos; se extraen completos con mkvextract" -ForegroundColor DarkGray
                & mkvextract @argsExt 2>&1 | Out-Null
            }
        }
        foreach ($s in $aMedir) {
            $ruta = if ($s.Origen -eq 'Interno') { $s.RutaTextoSdh } else { "$($s.ID)" }
            if (-not $ruta -or -not (Test-Path -LiteralPath $ruta)) { continue }
            $prop = Get-ProporcionSonidoSrt (Get-Content -LiteralPath $ruta -Raw -Encoding UTF8)
            if ($prop -ge 0.2) {
                $s.EsSDH = $true
                Write-Host "       -> Sub $($s.NomLang) ID=$($s.ID) marcado SDH por contenido ($([math]::Round($prop * 100))% de líneas con sonidos)" -ForegroundColor DarkGray
            }
        }
    } finally {
        foreach ($t in $temporales) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
    }
}
# Filtro de tipos (Completos / Forzados / SDH) elegido en la GUI y, después, un único sub por
# idioma + tipo + formato: si el montaje trae varios iguales se queda el PRIMERO (orden de origen).
function Select-SubsPorTipo($subs, $tiposMantener = $null) {
    $lista = @($subs)
    if ($tiposMantener -and @($tiposMantener).Count -gt 0) {
        $antes = $lista.Count
        $lista = @($lista | Where-Object { $_.TipoSub -in @($tiposMantener) })
        if ($antes -ne $lista.Count) {
            Write-Host "   [filtro tipos subs] Subs: $antes -> $($lista.Count) (se mantienen: $(@($tiposMantener) -join ', '))" -ForegroundColor DarkGray
        }
    }
    # Excepción: dos «completos» de tamaño muy distinto (el menor < 70% del mayor) pueden ser un
    # forzado grande que la heurística del 35% no separó. Se conservan los dos antes que perder el forzado.
    $vistos = @{}; $res = @()
    foreach ($s in ($lista | Sort-Object OrdenOrigen)) {
        $k = "$($s.CodLang)|$($s.TipoSub)|$($s.FmtSub)"
        if ($vistos.ContainsKey($k)) {
            $dudoso = $false
            if ($s.TipoSub -eq 'Completos' -and [long]$s.Size -gt 0) {
                foreach ($previo in $vistos[$k]) {
                    if ([long]$previo.Size -le 0) { continue }
                    $menor = [math]::Min([long]$previo.Size, [long]$s.Size); $mayor = [math]::Max([long]$previo.Size, [long]$s.Size)
                    if ($menor -lt ($mayor * 0.7)) { $dudoso = $true } else { $dudoso = $false; break }
                }
            }
            if ($dudoso) {
                Write-Host "   [duplicados subs] DUDOSO: se conservan los dos '$($s.NomFinal)' (ID=$($s.ID), $($s.Size) bytes): por tamaño uno podría ser un forzado. Revísalo." -ForegroundColor Yellow
                $vistos[$k] += $s; $res += $s
                continue
            }
            Write-Host "   [duplicados subs] Se descarta '$($s.NomFinal)' (ID=$($s.ID)): ya hay uno igual antes." -ForegroundColor DarkGray
            continue
        }
        $vistos[$k] = @($s)
        $res += $s
    }
    return ,@($res)
}

function Set-FlagForzados($listaSubs, $rutaMkvOrigen = $null, $decisionesSubUnico = $null) {
    if (-not $listaSubs -or $listaSubs.Count -eq 0) { return }

    # Agrupar por idioma + formato (lo hacemos a mano para no depender de Group-Object,
    # que en algunos casos puede crear copias o trabajar con propiedades calculadas).
    # Importante: usamos el FORMATO SIMPLIFICADO (Text vs PGS) para que variantes como
    # "UTF-8" y "SubRip" caigan en el mismo grupo: son técnicamente el mismo formato de
    # subtítulo (SubRip Text). Si los tratásemos por separado nunca podríamos distinguir
    # forzado vs completo cuando vienen como variantes distintas en el mismo MKV.
    $clavesGrupo = @{}
    for ($i = 0; $i -lt $listaSubs.Count; $i++) {
        $fmtSimple = if ($listaSubs[$i].Format -match "(?i)srt|subrip|ass|ssa|utf-?8|text") { "Text" } else { "PGS" }
        $clave = "$($listaSubs[$i].CodLang)__$fmtSimple"
        if (-not $clavesGrupo.ContainsKey($clave)) { $clavesGrupo[$clave] = @() }
        $clavesGrupo[$clave] += $i   # guardamos el índice, no el objeto
    }

    foreach ($clave in $clavesGrupo.Keys) {
        $indices = $clavesGrupo[$clave]
        Write-Host "   [debug forzados] Grupo '$clave': $($indices.Count) sub(s)" -ForegroundColor DarkGray

        # Paso 1: respetar flag explícito de mediainfo si alguno lo trae
        $algunoConFlag = $false
        foreach ($idx in $indices) {
            if ($listaSubs[$idx].MediainfoForcedFlag -eq $true) {
                $listaSubs[$idx].IsForced = $true
                $algunoConFlag = $true
                Write-Host "       -> Sub idx=$idx marcado FORZADO por flag mediainfo" -ForegroundColor DarkGray
            }
        }

        # Paso 2: si nadie tenía flag y hay más de uno, heurística por tamaño
        if (-not $algunoConFlag -and $indices.Count -gt 1) {
            $maxS = 0
            foreach ($idx in $indices) {
                if ($listaSubs[$idx].Size -gt $maxS) { $maxS = $listaSubs[$idx].Size }
            }

            # Paso 2.5: si nadie reporta tamaño y los subs son INTERNOS, extraerlos a disco
            # y medir. Cada pista interna sabe de qué MKV viene (ArchivoFuenteMkv), así que
            # extraemos del archivo correcto (importante en híbridos con merge de pistas).
            if ($maxS -eq 0) {
                $extraibles = @()
                foreach ($idx in $indices) {
                    if ($listaSubs[$idx].Origen -eq "Interno" -and $listaSubs[$idx].ArchivoFuenteMkv) { $extraibles += $idx }
                }
                if ($extraibles.Count -gt 1) {
                    Write-Host "       -> Tamaños no reportados; extrayendo subs a disco para medir..." -ForegroundColor DarkGray
                    foreach ($idx in $extraibles) {
                        $rutaSubMkv = $listaSubs[$idx].ArchivoFuenteMkv
                        $tam = Measure-SubEnDisco $rutaSubMkv $listaSubs[$idx].ID
                        $listaSubs[$idx].Size = $tam
                        Write-Host "          sub idx=$idx (ID mkv=$($listaSubs[$idx].ID), de $(Split-Path $rutaSubMkv -Leaf)) -> $tam bytes" -ForegroundColor DarkGray
                        if ($tam -gt $maxS) { $maxS = $tam }
                    }
                }
            }

            if ($maxS -gt 0) {
                foreach ($idx in $indices) {
                    if ($listaSubs[$idx].Size -gt 0 -and $listaSubs[$idx].Size -le ($maxS * 0.35)) {
                        $listaSubs[$idx].IsForced = $true
                        Write-Host "       -> Sub idx=$idx marcado FORZADO por heurística tamaño ($($listaSubs[$idx].Size) <= 35% de $maxS)" -ForegroundColor DarkGray
                    }
                }
            } else {
                Write-Host "       -> Heurística no aplicable: ningún sub del grupo reporta tamaño ni se pudo extraer" -ForegroundColor DarkYellow
            }
        }

        # Paso 3: consultar memoria de decisiones del usuario (preguntas pre-escaneo de sub único).
        # Aplica cuando el grupo, después de todo, sigue con un sub sin marca de forzado y el usuario
        # respondió "Forzado" en la pregunta inicial para este (archivo + idioma + formato).
        # Si dijo "Completo", no hacemos nada (IsForced ya es $false por defecto).
        if ($decisionesSubUnico -and $decisionesSubUnico.Count -gt 0) {
            $fmtClave = ($clave -split "__")[1]   # "es__Text" -> "Text"
            $langClave = ($clave -split "__")[0]
            foreach ($idx in $indices) {
                if ($listaSubs[$idx].IsForced -eq $true) { continue }

                if ($listaSubs[$idx].Origen -eq "Interno") {
                    # Construir las claves a probar: por ArchivoFuenteMkv (donde vive físicamente)
                    # y por ArchivoPrincipal (donde se registró la decisión del usuario).
                    $rutaSubMkv = $listaSubs[$idx].ArchivoFuenteMkv
                    $clavesAProbar = @(
                        "${rutaSubMkv}|${langClave}|${fmtClave}"
                    )
                    if ($rutaMkvOrigen -and $rutaMkvOrigen -ne $rutaSubMkv) {
                        $clavesAProbar += "${rutaMkvOrigen}|${langClave}|${fmtClave}"
                    }
                    foreach ($k in $clavesAProbar) {
                        if ($decisionesSubUnico.ContainsKey($k) -and $decisionesSubUnico[$k] -eq "Forzado") {
                            $listaSubs[$idx].IsForced = $true
                            Write-Host "       -> Sub idx=$idx marcado FORZADO por decisión del usuario (pregunta sub único)" -ForegroundColor DarkGray
                            break
                        }
                    }
                } else {
                    # Pista EXTERNA (SRT suelto / convertido de PGS): la decisión se registró con clave
                    # basada en el nombre del archivo externo ("EXT|<nombreArchivo>").
                    $nombreExt = $listaSubs[$idx].NombreExterno
                    if ($nombreExt) {
                        $kExt = "EXT|$nombreExt"
                        if ($decisionesSubUnico.ContainsKey($kExt) -and $decisionesSubUnico[$kExt] -eq "Forzado") {
                            $listaSubs[$idx].IsForced = $true
                            Write-Host "       -> Sub externo idx=$idx ($nombreExt) marcado FORZADO por decisión del usuario" -ForegroundColor DarkGray
                        }
                    }
                }
            }
        }
    }
}

# Recoge los datos de proyecto (título, año, serie, origen, plataforma, etiquetas).
# Se usa una vez en modo homogéneo, o una vez por archivo en modo heterogéneo.
# El parámetro $contexto se imprime como cabecera para que en heterogéneo se vea
# de qué archivo se están preguntando los datos.
function Get-DatosProyecto($contexto) {
    # Identidad POR ARCHIVO (modo «Cada archivo distinto»): la GUI manda un mapa nombreArchivo ->
    # datos de proyecto (una pestaña por película). Si existe entrada para este archivo, se usa.
    $cfgPorArchivo = Get-CfgGui "ProyectoPorArchivo"
    if ($contexto -and $cfgPorArchivo -and ($cfgPorArchivo.PSObject.Properties.Name -contains $contexto)) {
        $pf = $cfgPorArchivo.$contexto
        Write-Host "`n[GUI] Datos de proyecto POR ARCHIVO para: $contexto" -ForegroundColor DarkGray
        $origenPF  = if ("$($pf.TipoOrigen)" -eq "FISICO") { "FISICO" } else { "WEB" }
        $webTipoPF = if ("$($pf.WebTipo)" -in @("WEB-DL", "WEBRip")) { "$($pf.WebTipo)" } else { "WEB-DL" }
        return [PSCustomObject]@{
            Titulo            = "$($pf.Titulo)"
            Ano               = "$($pf.Ano)"
            EsSerie           = [bool]$pf.EsSerie
            TipoOrigen        = $origenPF
            WebTipo           = $webTipoPF
            PlataformaFormato = "$($pf.PlataformaFormato)"
            EtiquetasExtra    = "$($pf.EtiquetasExtra)"
        }
    }

    # Datos pre-rellenados desde la GUI. En modo heterogéneo (con $contexto) solo se usan si
    # el usuario marcó "aplicar a todos los archivos"; si no, se pregunta por consola por cada uno.
    $cfgProy = Get-CfgGui "Proyecto"
    if ($cfgProy -and "$($cfgProy.Titulo)" -ne "" -and (-not $contexto -or $cfgProy.AplicarATodos)) {
        if ($contexto) { Write-Host "`n[GUI] Usando datos de proyecto de la configuración para: $contexto" -ForegroundColor DarkGray }
        else           { Write-Host "`n[GUI] Usando datos de proyecto de la configuración." -ForegroundColor DarkGray }
        $origenCfg  = if ("$($cfgProy.TipoOrigen)" -eq "FISICO") { "FISICO" } else { "WEB" }
        $webTipoCfg = if ("$($cfgProy.WebTipo)" -in @("WEB-DL", "WEBRip")) { "$($cfgProy.WebTipo)" } else { "WEB-DL" }
        return [PSCustomObject]@{
            Titulo            = "$($cfgProy.Titulo)"
            Ano               = "$($cfgProy.Ano)"
            EsSerie           = [bool]$cfgProy.EsSerie
            TipoOrigen        = $origenCfg
            WebTipo           = $webTipoCfg
            PlataformaFormato = "$($cfgProy.PlataformaFormato)"
            EtiquetasExtra    = "$($cfgProy.EtiquetasExtra)"
        }
    }

    if ($contexto) {
        Write-Host "`n--- DATOS PARA: $contexto ---" -ForegroundColor Yellow
    } else {
        Write-Host "`n--- CONFIGURACIÓN GLOBAL DEL PROYECTO ---" -ForegroundColor Yellow
    }

    $titulo = Read-Host "1. Título limpio"
    $ano    = Read-Host "2. Año"
    $serie  = ((Read-Host "3. ¿Es una serie? (S/N)") -match "^[sS]")

    $origen = Mostrar-Menu "4. Origen" @(@{Nombre="WEB-DL"; Valor="WEB"}, @{Nombre="Físico (Remux, Full...)"; Valor="FISICO"})
    # Dentro de WEB hay dos variantes que cambian la etiqueta del nombre: WEB-DL y WEBRip.
    $webTipo = "WEB-DL"
    if ($origen -eq "WEB") {
        $webTipo = Mostrar-Menu "Tipo de WEB" @(@{Nombre="WEB-DL"; Valor="WEB-DL"}, @{Nombre="WEBRip"; Valor="WEBRip"})
    }
    $plat   = if ($origen -eq "WEB") { Mostrar-Menu "Plataforma" $opcPlataformas } else { Mostrar-Menu "Formato Físico" $opcFormatosFisicos }
    $etiq   = if ($origen -eq "FISICO") { Read-Host "   -> Etiquetas Extra (opcional)" } else { "" }

    return [PSCustomObject]@{
        Titulo            = $titulo
        Ano               = $ano
        EsSerie           = $serie
        TipoOrigen        = $origen
        WebTipo           = $webTipo    # "WEB-DL" o "WEBRip" (solo relevante si TipoOrigen=WEB)
        PlataformaFormato = $plat
        EtiquetasExtra    = $etiq
    }
}

# =========================================================================
# FUNCIONES DE FASE (D1)
# =========================================================================

# Detecta si un grupo es híbrido DV+HDR10 y devuelve un objeto con la información.
# Cacheado: se llama varias veces por grupo (pre-escaneos de und/idiomas/subs/DTS/PGS y el
# bucle principal) y cada llamada ejecutaba ffprobe completo sobre todos los archivos.
function Resolve-Hibrido($grupo) {
    $claveCache = (@($grupo.Group | ForEach-Object { $_.FullName }) -join "||")
    if ($cacheHibrido.ContainsKey($claveCache)) { return $cacheHibrido[$claveCache] }

    $info = [PSCustomObject]@{
        EsHibrido = $false; ArchivoDV = $null; ArchivoHDR10 = $null
        ArchivoPrincipal = $grupo.Group[0]
        OrigenPistas = $grupo.Group[0].FullName    # compat: 1er archivo
        OrigenesPistas = @($grupo.Group[0].FullName)  # nueva: lista de archivos para mergear pistas
    }

    # REMEZCLA: el vídeo viene de este archivo; añadimos los archivos de audio/subs emparejados de
    # otras carpetas a OrigenesPistas (Build-PistasBrutas tomará vídeo de aquí y audio/subs según rol).
    if ($global:remixActivo) {
        if ($global:remixManual) {
            $extras = @($global:remixFuentesManual | Where-Object { Test-Path -LiteralPath $_ })
            if ($extras.Count -gt 0) { $info.OrigenesPistas = @($info.ArchivoPrincipal.FullName) + $extras }
        } else {
            $k = Get-ClaveRemezcla $info.ArchivoPrincipal.BaseName
            $matchingKeys = @($global:remixFuentes.Keys | Where-Object { Test-HdzEpisodeMatch $_ $k })
            if ($matchingKeys.Count -ge 1) {
                $extras = @(foreach ($matchKey in $matchingKeys) { $global:remixFuentes[$matchKey] | Where-Object { Test-Path -LiteralPath $_ } })
                if (@($extras | Group-Object { Split-Path $_ -Parent } | Where-Object Count -gt 1).Count) { throw "Hay dos fuentes para el mismo episodio $k en una carpeta." }
                if ($extras.Count -gt 0) { $info.OrigenesPistas = @($info.ArchivoPrincipal.FullName) + $extras }
            } elseif ($global:remixSeriePorEpisodio) { throw "Faltan las pistas del episodio $k. No se genera un resultado incompleto." }
        }
        $cacheHibrido[$claveCache] = $info
        return $info
    }

    if ($grupo.Count -lt 2) { $cacheHibrido[$claveCache] = $info; return $info }

    foreach ($f in $grupo.Group) {
        $hasDV = (ffprobe -v quiet -show_streams -select_streams v:0 "$($f.FullName)") -join "`n"
        if ($hasDV -match "dv_profile=") { $info.ArchivoDV = $f } else { $info.ArchivoHDR10 = $f }
    }

    if ($info.ArchivoDV -and $info.ArchivoHDR10) {
        $info.EsHibrido = $true
        # En híbrido leemos pistas de AMBOS archivos. El orden importa: ponemos primero el que
        # tiene mejor metadata, así en caso de duplicado (mismo idioma+códec+canales) prevalece
        # la pista del archivo "bueno". También usamos ese como ArchivoPrincipal para nombre/serie.
        $metaDV  = Get-CalidadMetadata $info.ArchivoDV.FullName
        $metaHDR = Get-CalidadMetadata $info.ArchivoHDR10.FullName
        Write-Host "   [debug híbrido] HDR10 score metadata=$metaHDR; DV score metadata=$metaDV" -ForegroundColor DarkGray

        if ($metaDV -gt $metaHDR) {
            $info.OrigenesPistas = @($info.ArchivoDV.FullName, $info.ArchivoHDR10.FullName)
            $info.OrigenPistas    = $info.ArchivoDV.FullName
            $info.ArchivoPrincipal = $info.ArchivoDV
            Write-Host "   [debug híbrido] -> Lectura de pistas: DV (preferente) + HDR10 (merge)" -ForegroundColor DarkGray
        } else {
            $info.OrigenesPistas = @($info.ArchivoHDR10.FullName, $info.ArchivoDV.FullName)
            $info.OrigenPistas    = $info.ArchivoHDR10.FullName
            $info.ArchivoPrincipal = $info.ArchivoHDR10
            Write-Host "   [debug híbrido] -> Lectura de pistas: HDR10 (preferente) + DV (merge)" -ForegroundColor DarkGray
        }
    }

    $cacheHibrido[$claveCache] = $info
    return $info
}

# Calcula un "score" de calidad de metadata para elegir el mejor archivo cuando hay híbrido.
# Suma puntos por cada pista de audio/texto que tenga:
#   +2 si trae StreamSize numérico (no vacío) — indicador fuerte de metadata curada
#   +3 si trae Forced=Yes — confirma que el archivo distingue forzados de completos
#   +1 si trae Default=Yes/No no vacío — metadata mínima presente
# Un archivo "pelado" (todos los Forced a "No" sin StreamSize) puntúa muy bajo.
# Un archivo curado (con Forced=Yes en alguna pista, y StreamSize rellenos) puntúa alto.
function Get-CalidadMetadata($ruta) {
    $json = Get-MediainfoJson $ruta
    if (-not $json) { return 0 }
    $score = 0
    foreach ($pista in $json.media.track) {
        if ($pista.'@type' -match "Audio|Text") {
            if ($pista.PSObject.Properties.Name -contains "StreamSize" -and -not [string]::IsNullOrWhiteSpace("$($pista.StreamSize)")) {
                $score += 2
            }
            if ($pista.PSObject.Properties.Name -contains "Forced" -and "$($pista.Forced)" -match "(?i)yes|1|true") {
                $score += 3
            }
            if ($pista.PSObject.Properties.Name -contains "Default" -and -not [string]::IsNullOrWhiteSpace("$($pista.Default)")) {
                $score += 1
            }
        }
    }
    return $score
}

# Resuelve subtítulos con idioma indeterminado preguntando al usuario (con memoria).
# $idiomaGlobalUnd: idioma elegido en el pre-escaneo del lote para los subs 'und' internos
# (modo homogéneo). Si viene, se aplica directamente sin volver a preguntar.
# Recupera el idioma que la GUI asignó a una pista 'und' de un archivo+tipo cuando el emparejado por
# Id EXACTO falla. Motivo: la GUI numera las pistas por índice de ffprobe y el motor por Id de
# mkvmerge; suelen coincidir, pero no siempre. Si para ese archivo+tipo la GUI mandó UNA sola
# decisión 'und' (caso habitual), la aplicamos sin ambigüedad en vez de abrir la consola. Si hay
# varias pistas 'und' del mismo tipo con idiomas distintos, no se puede desambiguar -> $null.
function Get-IdiomaUndGui($rutaArchivo, $tipo) {
    # Las nuevas decisiones usan IDs reales: nunca extrapolar a otra pista del archivo.
    if (Get-CfgGui 'IdiomasPistasExactos') { return $null }
    $cand = @()
    foreach ($k in $global:undPistasGui.Keys) {
        $pk = "$k" -split "\|"
        if ($pk.Count -ge 3 -and $pk[0] -eq $rutaArchivo -and $pk[2] -eq $tipo) { $cand += "$($global:undPistasGui[$k])" }
    }
    $cand = @($cand | Select-Object -Unique)
    if ($cand.Count -eq 1) { return $cand[0] }
    return $null
}

function Resolve-IdiomasSubs($origenesPistas, $archivoPrincipal, $memoria, $idiomaGlobalUnd = $null) {
    $subsDesconocidos = @()

    # Aceptamos tanto un único path (string) como un array de paths
    $listaArchivos = @($origenesPistas)

    foreach ($rutaArchivo in $listaArchivos) {
        $miJsonOrigen = Get-MediainfoJson $rutaArchivo
        if (-not $miJsonOrigen) { continue }
        $nombreArchivo = Split-Path $rutaArchivo -Leaf
        $idMapL = Get-MkvmergeTrackIdMap $rutaArchivo
        $contTextL = 0
        foreach ($pista in $miJsonOrigen.media.track) {
            if ($pista.'@type' -eq "Text") {
                $contTextL++
                $claveMap = "Text+$contTextL"
                $idReal = if ($idMapL.ContainsKey($claveMap)) { $idMapL[$claveMap] } else { $pista.ID - 1 }
                $langCode = $pista.Language
                if ([string]::IsNullOrWhiteSpace($langCode) -or $langCode -eq "und") {
                    # D4: clave de memoria incluye path del archivo para evitar colisiones
                    $subsDesconocidos += [PSCustomObject]@{
                        Origen = "Interno"
                        ID = $idReal
                        ArchivoFuente = $rutaArchivo
                        Info = "Subtítulo Interno (ID Pista: $idReal) en $nombreArchivo"
                    }
                }
            }
        }
    }

    $archivosExternosSubs = Get-ChildItem -LiteralPath $rutaCarpeta -File | Where-Object { $_.Extension -match "\.(srt|ass|sup|ssa|pgs|idx|sub)$" }
    # El .sub de una pareja VobSub .idx/.sub se gestiona a través de su .idx (mkvmerge lo toma
    # automáticamente): no preguntamos su idioma por separado.
    $archivosExternosSubs = @($archivosExternosSubs | Where-Object {
        -not ($_.Extension -match "(?i)^\.sub$" -and (Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($_.FullName, ".idx"))))
    })
    foreach ($ext in $archivosExternosSubs) {
        $miExt = Get-MediainfoJson $ext.FullName
        $pExt = $null
        if ($miExt) { $pExt = $miExt.media.track | Where-Object { $_.'@type' -eq "Text" } | Select-Object -First 1 }
        if ($pExt -or $ext.Extension -match "srt|ass|ssa|sup|pgs|idx|sub") {
            $langCode = if ($pExt) { $pExt.Language } else { "" }
            if ([string]::IsNullOrWhiteSpace($langCode) -or $langCode -eq "und") {
                if     ($ext.Name -match "(?i)(?<![a-z])(latino|latam|lat)(?![a-z])")           { $memoria["Externo_$($ext.FullName)"] = "es-419" }
                elseif ($ext.Name -match "(?i)(?<![a-z])(spa|es|castellano|cast)(?![a-z])")     { $memoria["Externo_$($ext.FullName)"] = "es" }
                elseif ($ext.Name -match "(?i)(?<![a-z])(eng|en|ingles|english)(?![a-z])")      { $memoria["Externo_$($ext.FullName)"] = "eng" }
                elseif ($ext.Name -match "(?i)(?<![a-z])(fre|fr|frances|french)(?![a-z])")      { $memoria["Externo_$($ext.FullName)"] = "fre" }
                else { 
                    $subsDesconocidos += [PSCustomObject]@{
                        Origen = "Externo"; ID = $ext.FullName; ArchivoFuente = $ext.FullName
                        Info = "Archivo Externo: $($ext.Name)"
                    }
                }
            }
        }
    }

    if ($subsDesconocidos.Count -gt 0) {
        Write-Host "`n[!] RESOLUCIÓN DE CONFLICTOS DE IDIOMA:" -ForegroundColor Yellow
        foreach ($sub in $subsDesconocidos) {
            # D4: clave incluye el path para internos también
            $llave = if ($sub.Origen -eq "Interno") { "Interno_$($sub.ArchivoFuente)_$($sub.ID)" } else { "Externo_$($sub.ID)" }
            if (-not $memoria.ContainsKey($llave)) {
                # Si el pre-escaneo del lote ya decidió el idioma de los subs 'und' internos
                # (modo homogéneo), se aplica directamente SIN volver a preguntar (antes se
                # preguntaba dos veces: una a nivel de lote y otra por cada pista).
                if ($idiomaGlobalUnd -and $sub.Origen -eq "Interno") {
                    $memoria[$llave] = $idiomaGlobalUnd
                    continue
                }
                # Emparejado tolerante con la decisión de la GUI (Id ffprobe vs Id mkvmerge).
                if ($sub.Origen -eq "Interno") {
                    $guiCod = Get-IdiomaUndGui $sub.ArchivoFuente "Sub"
                    if ($guiCod) {
                        $memoria[$llave] = $guiCod
                        Write-Host "[GUI] Subtítulo 'und' de $(Split-Path $sub.ArchivoFuente -Leaf) -> idioma '$guiCod' (configuración, emparejado por archivo)." -ForegroundColor DarkGray
                        continue
                    }
                }
                # DESATENDIDO: nunca abrimos la consola. Sin decisión aplicable, se deja 'und' y se anota.
                if ($global:sinPreguntas) {
                    $memoria[$llave] = "und"
                    Write-Host "[GUI] $($sub.Info): sin idioma en la configuración -> se deja 'und' (no se pregunta)." -ForegroundColor DarkYellow
                    try { Add-Incidencia (Split-Path $sub.ArchivoFuente -Leaf) "Subtítulo 'und' sin idioma asignado desde la GUI; se deja indeterminado." } catch {}
                    continue
                }
                Write-Host " -> $($sub.Info)" -ForegroundColor Cyan
                for ($i=0; $i -lt $idiomasComunes.Count; $i++) { 
                    Write-Host (" {0,2}. {1}" -f ($i+1), $idiomasComunes[$i].Nom) -NoNewline
                    if (($i + 1) % 4 -eq 0) { Write-Host "" } 
                }
                Write-Host ""
                # Bucle hasta que el usuario introduzca un idioma válido. Sin idioma no podemos
                # decidir bien forzados/completos, así que es obligatorio.
                $codElegido = $null
                while (-not $codElegido) {
                    $seleccion = Read-Host "Seleccione idioma (1-$($idiomasComunes.Count), 0 para introducir código manualmente)"
                    if ($seleccion -eq "0") {
                        $manual = Read-Host "   Escribe el código de idioma (ej: rus, ara, hin, swe...)"
                        if (-not [string]::IsNullOrWhiteSpace($manual)) { $codElegido = $manual.Trim().ToLower() }
                    } elseif ($seleccion -match '^\d+$' -and [int]$seleccion -gt 0 -and [int]$seleccion -le $idiomasComunes.Count) {
                        $codElegido = $idiomasComunes[[int]$seleccion - 1].Cod
                    } else {
                        Write-Host "   Entrada no válida. Debes elegir un idioma." -ForegroundColor Yellow
                    }
                }
                $memoria[$llave] = $codElegido
            }
        }
    }
}

# Resuelve idiomas indeterminados de pistas de audio (internas y externas) preguntando al usuario.
# Comparte la misma estructura que Resolve-IdiomasSubs pero ofrece la opción "U" para dejar como und,
# porque en audio aceptamos und (la conversión a EAC3 es por compatibilidad y no depende del idioma).
function Resolve-IdiomasAudios($origenesPistas, $archivoPrincipal, $memoria, $idiomaGlobalUnd = $null) {
    $audiosDesconocidos = @()

    $listaArchivos = @($origenesPistas)

    foreach ($rutaArchivo in $listaArchivos) {
        $miJsonOrigen = Get-MediainfoJson $rutaArchivo
        if (-not $miJsonOrigen) { continue }
        $nombreArchivo = Split-Path $rutaArchivo -Leaf
        $idMapL = Get-MkvmergeTrackIdMap $rutaArchivo
        $contAudL = 0
        foreach ($pista in $miJsonOrigen.media.track) {
            if ($pista.'@type' -eq "Audio") {
                $contAudL++
                $claveMap = "Audio+$contAudL"
                $idReal = if ($idMapL.ContainsKey($claveMap)) { $idMapL[$claveMap] } else { $pista.ID - 1 }
                $langCode = $pista.Language
                if ([string]::IsNullOrWhiteSpace($langCode) -or $langCode -eq "und") {
                    $audiosDesconocidos += [PSCustomObject]@{
                        Origen = "Interno"
                        ID = $idReal
                        ArchivoFuente = $rutaArchivo
                        Info = "Pista de Audio Interna (ID Pista: $idReal) en $nombreArchivo"
                    }
                }
            }
        }
    }

    $archivosExternosAudio = Get-ChildItem -LiteralPath $rutaCarpeta -File | Where-Object { $_.Extension -match "\.(ac3|eac3|dts|dtshd|truehd|flac|wav|mka|m4a|aac|opus)$" }
    foreach ($ext in $archivosExternosAudio) {
        $miExt = Get-MediainfoJson $ext.FullName
        $pExt = $null
        if ($miExt) { $pExt = $miExt.media.track | Where-Object { $_.'@type' -eq "Audio" } | Select-Object -First 1 }
        $langCode = if ($pExt) { $pExt.Language } else { "" }
        if ([string]::IsNullOrWhiteSpace($langCode) -or $langCode -eq "und") {
            # Detección automática por nombre (idiomas comunes y patrón audio_<lang>_temp/final)
            if     ($ext.Name -match "(?i)audio_([a-z]{2,3}(?:-[a-z0-9]{2,3})?)_(temp|final)") { $memoria["Externo_$($ext.FullName)"] = $Matches[1].ToLower() }
            elseif ($ext.Name -match "(?i)(?<![a-z])(latino|latam|lat)(?![a-z])")             { $memoria["Externo_$($ext.FullName)"] = "es-419" }
            elseif ($ext.Name -match "(?i)(?<![a-z])(spa|es|castellano|cast)(?![a-z])")       { $memoria["Externo_$($ext.FullName)"] = "es" }
            elseif ($ext.Name -match "(?i)(?<![a-z])(eng|en|ingles|english)(?![a-z])")        { $memoria["Externo_$($ext.FullName)"] = "eng" }
            elseif ($ext.Name -match "(?i)(?<![a-z])(fre|fr|frances|french)(?![a-z])")        { $memoria["Externo_$($ext.FullName)"] = "fre" }
            else {
                $audiosDesconocidos += [PSCustomObject]@{
                    Origen = "Externo"; ID = $ext.FullName; ArchivoFuente = $ext.FullName
                    Info = "Archivo de Audio Externo: $($ext.Name)"
                }
            }
        }
    }

    if ($audiosDesconocidos.Count -gt 0) {
        Write-Host "`n[!] RESOLUCIÓN DE IDIOMA EN PISTAS DE AUDIO:" -ForegroundColor Yellow
        foreach ($au in $audiosDesconocidos) {
            $llave = if ($au.Origen -eq "Interno") { "Interno_$($au.ArchivoFuente)_$($au.ID)" } else { "Externo_$($au.ID)" }
            if (-not $memoria.ContainsKey($llave)) {
                # Si hay un idioma global decidido en el pre-escaneo del lote (modo homogéneo),
                # lo aplicamos directamente SIN preguntar (ya se preguntó una vez para todo el lote).
                if ($idiomaGlobalUnd) {
                    $memoria[$llave] = $idiomaGlobalUnd
                    continue
                }
                # Emparejado tolerante con la decisión de la GUI (Id ffprobe vs Id mkvmerge).
                if ($au.Origen -eq "Interno") {
                    $guiCod = Get-IdiomaUndGui $au.ArchivoFuente "Audio"
                    if ($guiCod) {
                        $memoria[$llave] = $guiCod
                        Write-Host "[GUI] Audio 'und' de $(Split-Path $au.ArchivoFuente -Leaf) -> idioma '$guiCod' (configuración, emparejado por archivo)." -ForegroundColor DarkGray
                        continue
                    }
                }
                # DESATENDIDO: nunca abrimos la consola. Sin decisión aplicable, se deja 'und' y se anota.
                if ($global:sinPreguntas) {
                    $memoria[$llave] = "und"
                    Write-Host "[GUI] $($au.Info): sin idioma en la configuración -> se deja 'und' (no se pregunta)." -ForegroundColor DarkYellow
                    try { Add-Incidencia (Split-Path $au.ArchivoFuente -Leaf) "Audio 'und' sin idioma asignado desde la GUI; se deja indeterminado." } catch {}
                    continue
                }
                Write-Host " -> $($au.Info)" -ForegroundColor Cyan
                for ($i=0; $i -lt $idiomasComunes.Count; $i++) {
                    Write-Host (" {0,2}. {1}" -f ($i+1), $idiomasComunes[$i].Nom) -NoNewline
                    if (($i + 1) % 4 -eq 0) { Write-Host "" }
                }
                Write-Host ""
                $codElegido = $null
                while (-not $codElegido) {
                    $seleccion = Read-Host "Seleccione idioma (1-$($idiomasComunes.Count), 0 para introducir código manualmente, U para dejar como und)"
                    if ($seleccion -match '^[uU]$') {
                        $codElegido = "und"
                    } elseif ($seleccion -eq "0") {
                        $manual = Read-Host "   Escribe el código de idioma (ej: rus, ara, hin, swe...)"
                        if (-not [string]::IsNullOrWhiteSpace($manual)) { $codElegido = $manual.Trim().ToLower() }
                    } elseif ($seleccion -match '^\d+$' -and [int]$seleccion -gt 0 -and [int]$seleccion -le $idiomasComunes.Count) {
                        $codElegido = $idiomasComunes[[int]$seleccion - 1].Cod
                    } else {
                        Write-Host "   Entrada no válida." -ForegroundColor Yellow
                    }
                }
                $memoria[$llave] = $codElegido
            }
        }
    }
}

# Ejecuta un proceso externo redirigiendo stdout/stderr SIN riesgo de deadlock: ambos streams
# se drenan siempre (si no se leen y el proceso llena el buffer del pipe, se queda bloqueado
# para siempre), y la lectura de stderr usa esperas con timeout en lugar de ReadLine()
# bloqueante (que podía dejar el script colgado indefinidamente si el proceso enmudecía).
# $alLeerLineaErr: scriptblock invocado por cada línea de stderr (ffmpeg emite ahí el progreso).
# Devuelve el código de salida del proceso.
function Invoke-ProcesoMonitorizado($exe, $listaArgs, $alLeerLineaErr, $alEsperar = $null) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    foreach ($a in $listaArgs) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    # WorkingDirectory = $PWD (la carpeta de trabajo, fijada con Set-Location). Sin esto, un proceso
    # con salida de ruta RELATIVA escribiría en [Environment]::CurrentDirectory (la carpeta de arranque
    # = Program Files/System32) y daría «Permission denied». Con esto, las rutas relativas resuelven bien.
    try { $psi.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath } catch {}
    $proc = [System.Diagnostics.Process]::Start($psi)
    # stdout no nos interesa, pero hay que drenarlo en segundo plano igualmente
    $drenajeOut = $proc.StandardOutput.ReadToEndAsync()
    $tareaLinea = $proc.StandardError.ReadLineAsync()
    while ($true) {
        $hayLinea = $false
        try { $hayLinea = $tareaLinea.Wait(250) } catch { break }
        if ($hayLinea) {
            $linea = $tareaLinea.Result
            if ($null -eq $linea) { break }   # stream cerrado: el proceso terminó
            if ($alLeerLineaErr) { & $alLeerLineaErr $linea }
            $tareaLinea = $proc.StandardError.ReadLineAsync()
        } elseif ($proc.HasExited) {
            # Proceso terminado: apurar las líneas pendientes (con timeout corto) y salir.
            try {
                while ($tareaLinea.Wait(500)) {
                    $linea = $tareaLinea.Result
                    if ($null -eq $linea) { break }
                    if ($alLeerLineaErr) { & $alLeerLineaErr $linea }
                    $tareaLinea = $proc.StandardError.ReadLineAsync()
                }
            } catch {}
            break
        }
        if ($alEsperar) { & $alEsperar }
    }
    # WaitForExit con TIMEOUT (no la variante sin argumentos, que espera al EOF de los flujos y podía
    # colgar aunque el proceso ya hubiera salido). El bucle solo termina con el proceso ya finalizado.
    [void]$proc.WaitForExit(15000)
    try { [void]$drenajeOut.Wait(3000) } catch {}
    return $proc.ExitCode
}

# Progreso de la fusión: ocupa el tramo 15–40 % de cada elemento del lote.
# La segunda barra detalla la fusión; el mismo JSON lo consumen WPF y la web.
function Set-ProgresoFusion([int]$pct, [string]$fase) {
    $pct = [Math]::Clamp($pct, 0, 100)
    $global:gPct = [int]($global:pctBaseGui + $global:pctPasoGui * (0.15 + 0.25 * $pct / 100))
    $global:gFase = "Fusión Dolby Vision + HDR10 $($global:idxGrupoGui)/$($global:totalGruposGui)"
    $global:gPct2 = $pct; $global:gFase2 = $fase
    Write-ProgresoGui
    Write-Progress -Activity 'Fusión Dolby Vision + HDR10' -Status $fase -PercentComplete $pct
}

# Canal BINARIO directo, sin BAT/cmd ni interpolación de rutas. ArgumentList
# conserva espacios, Unicode y caracteres especiales. Se comprueban ambos procesos.
function Invoke-HdzRpuPipe([string]$inputFile, [string]$outputFile, [double]$duration) {
    $producer=$null; $consumer=$null
    try {
        $sink=[Diagnostics.ProcessStartInfo]::new('dovi_tool')
        foreach($arg in @('-m','3','extract-rpu','-','-o',$outputFile)) { $sink.ArgumentList.Add($arg) }
        $sink.UseShellExecute=$false; $sink.CreateNoWindow=$true
        $sink.RedirectStandardInput=$true; $sink.RedirectStandardOutput=$true; $sink.RedirectStandardError=$true
        $consumer=[Diagnostics.Process]::Start($sink)
        $sinkOut=$consumer.StandardOutput.ReadToEndAsync()
        $sinkErr=$consumer.StandardError.ReadToEndAsync()
        $source=[Diagnostics.ProcessStartInfo]::new('ffmpeg')
        foreach($arg in @('-hide_banner','-loglevel','error','-nostats','-progress','pipe:2',
            '-i',$inputFile,'-map','0:v:0','-c:v','copy','-bsf:v','hevc_mp4toannexb','-f','hevc','-')) { $source.ArgumentList.Add($arg) }
        $source.UseShellExecute=$false; $source.CreateNoWindow=$true
        $source.RedirectStandardOutput=$true; $source.RedirectStandardError=$true
        $producer=[Diagnostics.Process]::Start($source)
        $copy=$producer.StandardOutput.BaseStream.CopyToAsync($consumer.StandardInput.BaseStream)
        $lineTask=$producer.StandardError.ReadLineAsync()
        $inputClosed=$false; $errors=[Collections.Generic.List[string]]::new()
        while($true) {
            if($copy.IsCompleted -and -not $inputClosed) {
                [void]$copy.GetAwaiter().GetResult()
                $consumer.StandardInput.Close(); $inputClosed=$true
                Set-ProgresoFusion 33 'Paso 1/3: finalizando extracción de metadata Dolby Vision…'
            }
            if($consumer.HasExited -and -not $copy.IsCompleted) { throw 'dovi_tool cerró el canal antes de recibir el vídeo completo.' }
            if($lineTask -and $lineTask.Wait(100)) {
                $line=$lineTask.Result
                if($null -eq $line) { $lineTask=$null }
                else {
                    if($line -match '^out_time_ms=(\d+)' -and $duration -gt 0 -and -not $inputClosed) {
                        $pct=[Math]::Min(32,[int](([double]$Matches[1]/1000000)/$duration*33))
                        Set-ProgresoFusion $pct 'Paso 1/3: extrayendo metadata Dolby Vision sin temporal de vídeo…'
                    } elseif($line -and $line -notmatch '^[a-z_0-9]+=') { if($errors.Count -lt 12) { $errors.Add($line) } }
                    $lineTask=$producer.StandardError.ReadLineAsync()
                }
            } elseif(-not $lineTask) { Start-Sleep -Milliseconds 100 }
            if($producer.HasExited -and $consumer.HasExited -and -not $lineTask -and $inputClosed) { break }
        }
        [void]$producer.WaitForExit(1000); [void]$consumer.WaitForExit(1000)
        $detail=$sinkErr.GetAwaiter().GetResult()
        [void]$sinkOut.GetAwaiter().GetResult()
        if($producer.ExitCode -ne 0 -or $consumer.ExitCode -ne 0) {
            throw "ffmpeg=$($producer.ExitCode), dovi_tool=$($consumer.ExitCode): $($errors -join ' ') $detail"
        }
        if(-not (Test-Path -LiteralPath $outputFile) -or (Get-Item -LiteralPath $outputFile).Length -lt 100) { throw 'No se generó metadata Dolby Vision válida.' }
        return $true
    } catch {
        $message=$_.Exception.Message
        Write-Host "   [!] Extracción directa no disponible: $($message.Substring(0,[Math]::Min(1200,$message.Length)))" -ForegroundColor DarkYellow
        return $false
    } finally {
        foreach($child in @($producer,$consumer)) {
            if($child) {
                try { if(-not $child.HasExited) { $child.Kill($true); [void]$child.WaitForExit(3000) } } catch {}
                $child.Dispose()
            }
        }
    }
}

# Fusiona capa Dolby Vision con base HDR10 vía dovi_tool
function Invoke-FusionDolbyVision($archivoDV, $archivoHDR10) {
    Write-Host "`n[>>] Fusionando capa Dolby Vision con HDR10..." -ForegroundColor Cyan

    $actividad = "Fusión Dolby Vision + HDR10"
    Set-ProgresoFusion 0 'Inicializando fusión…'

    # TEMPORALES CON RUTA ABSOLUTA + nombre único por proceso.
    #  · ABSOLUTA: los procesos ffmpeg/dovi_tool se lanzan con System.Diagnostics.Process, que usa
    #    [Environment]::CurrentDirectory (la carpeta de ARRANQUE del proceso = Program Files/System32),
    #    NO el $PWD que fija Set-Location. Con una salida RELATIVA (video_base.hevc) ffmpeg intentaba
    #    escribir en esa carpeta protegida -> «Permission denied» (código -13). Anclar a $rutaCarpeta
    #    lo elimina por completo. [ESTA era la causa real de que Arlo fallara una y otra vez.]
    #  · Nombre con $PID: ningún resto de una ejecución anterior puede chocar con ésta.
    $fRpu  = Join-Path $rutaCarpeta "metadata_p8_$PID.rpu"
    $fBase = Join-Path $rutaCarpeta "video_base_$PID.hevc"
    $fDef  = Join-Path $rutaCarpeta "video_definitivo_$PID.hevc"
    # LIMPIEZA DEFENSIVA: fuera restos con los nombres clásicos Y con los de este PID. Se les quita
    # el atributo de solo lectura (Remove-Item sin -Force falla EN SILENCIO con ellos) y se borra a la fuerza.
    foreach ($tmpV in @((Join-Path $rutaCarpeta "metadata_p8.rpu"),(Join-Path $rutaCarpeta "video_base.hevc"),(Join-Path $rutaCarpeta "video_definitivo.hevc"),(Join-Path $rutaCarpeta "tmp_dv_raw.hevc"),$fRpu,$fBase,$fDef)) {
        if (Test-Path -LiteralPath $tmpV) {
            try { (Get-Item -LiteralPath $tmpV -Force).IsReadOnly = $false } catch {}
            Remove-Item -LiteralPath $tmpV -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $tmpV) { Write-Host "   [!] Aviso: no se pudo borrar el temporal '$tmpV' (¿retenido por otro proceso?)." -ForegroundColor DarkYellow }
        }
    }

    # Duración del video DV (en segundos) — la usamos para calcular % cuando ffmpeg da out_time_ms.
    $duracionTotal = 0.0
    try {
        $dur = ffprobe -v error -show_entries format=duration -of csv=p=0 "$($archivoDV.FullName)" 2>$null
        if ($dur) { $duracionTotal = [double]($dur -replace ',', '.') }
    } catch {}

    # ==== FASE 1: extraer HEVC del archivo DV y aislar RPU (0% → 40%) ====
    Set-ProgresoFusion 0 'Paso 1/3: extrayendo capa Dolby Vision (RPU)…'

    # OPTIMIZACIÓN: para aislar el RPU NO hace falta volcar decenas de GB de HEVC a disco. Se PIPEA
    # ffmpeg -> dovi_tool (el HEVC nunca toca el disco; solo se lee el DV una vez y se escribe el RPU,
    # que son unos KB). Antes se escribía y releía todo el HEVC (~3x más I/O). Si el pipe fallara
    # (dovi_tool sin stdin, etc.), se cae al método clásico con fichero temporal.
    $rpuOK = Invoke-HdzRpuPipe $archivoDV.FullName $fRpu $duracionTotal
    if ($rpuOK) { Write-Host "   -> RPU extraído por pipe (sin volcar el HEVC a disco)." -ForegroundColor DarkGray }

    if (-not $rpuOK) {
        # Respaldo (método clásico): vuelca el HEVC a un temporal y extrae el RPU de ahí.
        Write-Host "   -> (usando método de respaldo con temporal; motivo indicado arriba)" -ForegroundColor DarkYellow
        Set-ProgresoFusion 0 'Paso 1/3: extrayendo vídeo DV por el método de respaldo…'
        Remove-Item -LiteralPath $fRpu -Force -ErrorAction SilentlyContinue
        $tmpRpuPipe = Join-Path $rutaCarpeta "tmp_dv_raw_$PID.hevc"
        $argsFf1 = @(
            "-hide_banner", "-loglevel", "error", "-nostats",
            "-progress", "pipe:2",
            "-i", $archivoDV.FullName,
            "-map", "0:v:0", "-c:v", "copy", "-bsf:v", "hevc_mp4toannexb",
            "-f", "hevc", $tmpRpuPipe, "-y"
        )
        $exit1 = Invoke-ProcesoMonitorizado "ffmpeg" $argsFf1 ({
            param($line)
            if ($line -match '^out_time_ms=(\d+)' -and $duracionTotal -gt 0) {
                $secs = [double]$Matches[1] / 1000000.0
                $pct = [Math]::Min(33, [int](($secs / $duracionTotal) * 33))
                Set-ProgresoFusion $pct 'Paso 1/3: extrayendo HEVC del archivo DV (respaldo)…'
            }
        }.GetNewClosure())
        if ($exit1 -ne 0 -or -not (Test-Path -LiteralPath $tmpRpuPipe)) {
            Write-Progress -Activity $actividad -Completed
            Set-ProgresoGui2 -1
            Write-Host "   [!] ERROR: ffmpeg falló extrayendo HEVC del archivo DV." -ForegroundColor Red
            Remove-Item -LiteralPath $tmpRpuPipe -Force -ErrorAction SilentlyContinue
            return $null
        }
        Set-ProgresoFusion 34 'Paso 1/3: aislando metadata Dolby Vision…'
        $rpuWatch=[Diagnostics.Stopwatch]::StartNew()
        $exitRpu=Invoke-ProcesoMonitorizado 'dovi_tool' @('-m','3','extract-rpu',$tmpRpuPipe,'-o',$fRpu) $null ({
            Set-ProgresoFusion 34 "Paso 1/3: aislando metadata Dolby Vision · $([int]$rpuWatch.Elapsed.TotalSeconds) s"
        }.GetNewClosure())
        Remove-Item -LiteralPath $tmpRpuPipe -Force -ErrorAction SilentlyContinue
        $rpuOK = $exitRpu -eq 0 -and (Test-Path -LiteralPath $fRpu) -and ((Get-Item -LiteralPath $fRpu).Length -ge 100)
    }

    if (-not $rpuOK) {
        Write-Progress -Activity $actividad -Completed
        Set-ProgresoGui2 -1
        Write-Host "   [!] ERROR: no se pudo extraer el RPU del archivo Dolby Vision." -ForegroundColor Red
        Remove-Item -LiteralPath $fRpu -Force -ErrorAction SilentlyContinue
        return $null
    }
    Set-ProgresoFusion 40 'Paso 1/3 completado.'

    # ==== FASE 2: extraer base HDR10 (40% → 75%) ====
    Set-ProgresoFusion 40 'Paso 2/3: extrayendo base HDR10…'
    $argsFf2 = @(
        "-hide_banner", "-loglevel", "error", "-nostats",
        "-progress", "pipe:2",
        "-i", $archivoHDR10.FullName,
        "-map", "0:v:0", "-c:v", "copy", "-bsf:v", "hevc_mp4toannexb",
        $fBase, "-y"
    )
    # Recoge las líneas de stderr que NO son de progreso (=errores reales de ffmpeg) para diagnóstico,
    # y las últimas quedan en el log si falla (antes solo se veía «ffmpeg falló», sin el motivo).
    $erroresFf2 = New-Object System.Collections.Generic.List[string]
    $cbFf2 = {
        param($line)
        if ($line -match '^out_time_ms=(\d+)' -and $duracionTotal -gt 0) {
            $secs = [double]$Matches[1] / 1000000.0
            $pct = 40 + [Math]::Min(35, [int](($secs / $duracionTotal) * 35))
            Set-ProgresoFusion $pct 'Paso 2/3: extrayendo base HDR10…'
        } elseif ($line -and $line -notmatch '^[a-z_]+=') {
            if ($erroresFf2.Count -lt 12) { $erroresFf2.Add($line) }
        }
    }.GetNewClosure()
    # Hasta 2 intentos: un bloqueo transitorio del fichero de salida (justo tras la fase 1) se resuelve
    # solo tras una pausa corta. Antes de cada intento se borra la base por si quedó a medias.
    $exit2 = 0
    for ($intentoFf2 = 1; $intentoFf2 -le 2; $intentoFf2++) {
        Remove-Item -LiteralPath $fBase -Force -ErrorAction SilentlyContinue
        $erroresFf2.Clear()
        $exit2 = Invoke-ProcesoMonitorizado "ffmpeg" $argsFf2 $cbFf2
        if ($exit2 -eq 0) { break }
        if ($intentoFf2 -lt 2) {
            Write-Host "   [!] La base HDR10 no se pudo extraer (intento $intentoFf2/2). Reintentando en 2 s..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds 2
        }
    }
    if ($exit2 -ne 0) {
        Write-Progress -Activity $actividad -Completed
        Set-ProgresoGui2 -1
        Write-Host "   [!] ERROR: ffmpeg falló al extraer base HDR10 (código $exit2)." -ForegroundColor Red
        if ($erroresFf2.Count -gt 0) {
            Write-Host "       Detalle de ffmpeg:" -ForegroundColor DarkYellow
            foreach ($e in $erroresFf2) { Write-Host "         $e" -ForegroundColor DarkGray }
        }
        Remove-Item -LiteralPath $fRpu, $fBase -Force -ErrorAction SilentlyContinue
        return $null
    }
    Set-ProgresoFusion 75 'Paso 2/3 completado.'

    # ==== FASE 3: inject-rpu (75% → 100%) ====
    # dovi_tool no expone progreso fiable, así que monitorizamos el tamaño del fichero de salida
    # comparándolo con la base HDR10 para estimar el avance.
    $tamRef = (Get-Item -LiteralPath $fBase).Length
    Set-ProgresoFusion 75 'Paso 3/3: inyectando RPU en base HDR10…'

    $psi3 = New-Object System.Diagnostics.ProcessStartInfo
    $psi3.FileName = "dovi_tool"
    foreach ($a in @("inject-rpu","--rpu-in",$fRpu,$fBase,"-o",$fDef)) { $psi3.ArgumentList.Add($a) }
    $psi3.RedirectStandardError  = $true
    $psi3.RedirectStandardOutput = $true
    $psi3.UseShellExecute = $false
    $psi3.CreateNoWindow  = $true
    try { $psi3.WorkingDirectory = $rutaCarpeta } catch {}
    $proc3 = [System.Diagnostics.Process]::Start($psi3)
    # Drenaje en segundo plano de stdout/stderr: si no se leen y dovi_tool escribe más de lo
    # que cabe en el buffer del pipe (~4 KB), el proceso se queda bloqueado para siempre.
    $drenOut3 = $proc3.StandardOutput.ReadToEndAsync()
    $drenErr3 = $proc3.StandardError.ReadToEndAsync()
    while (-not $proc3.HasExited) {
        Start-Sleep -Milliseconds 300
        if (Test-Path -LiteralPath $fDef) {
            $tamAct = (Get-Item -LiteralPath $fDef).Length
            if ($tamRef -gt 0) {
                $pct = 75 + [Math]::Min(24, [int](($tamAct / $tamRef) * 24))
                Set-ProgresoFusion $pct 'Paso 3/3: inyectando RPU en base HDR10 (avance estimado por tamaño)…'
            }
        }
    }
    # El bucle de arriba SOLO sale cuando el proceso ya ha terminado (HasExited). Ojo: NO usar
    # WaitForExit() SIN argumentos aquí — su variante "infinita" espera además a que los flujos
    # redirigidos lleguen a EOF, y con ReadToEndAsync eso podía no señalizarse nunca → el montaje se
    # quedaba COLGADO tras la inyección aunque dovi_tool ya hubiera terminado. Con timeout, espera solo
    # al proceso (que ya salió) y drenamos los flujos con su propio límite.
    [void]$proc3.WaitForExit(15000)
    try { [void][System.Threading.Tasks.Task]::WaitAll(@($drenOut3, $drenErr3), 3000) } catch {}

    $exit3=$proc3.ExitCode
    $proc3.Dispose()
    if ($exit3 -ne 0 -or -not (Test-Path -LiteralPath $fDef) -or (Get-Item -LiteralPath $fDef).Length -lt 1MB) {
        Write-Progress -Activity $actividad -Completed
        Set-ProgresoGui2 -1
        Write-Host "`n[!] ERROR CRÍTICO: dovi_tool ha fallado en inject-rpu (código $exit3)." -ForegroundColor Red
        if($drenErr3.IsCompletedSuccessfully) { Write-Host ($drenErr3.Result | Select-Object -First 1) -ForegroundColor DarkYellow }
        Remove-Item -LiteralPath $fRpu, $fBase, $fDef -Force -ErrorAction SilentlyContinue
        return $null
    }

    Set-ProgresoFusion 100 'Fusión completada.'
    Start-Sleep -Milliseconds 200
    Write-Progress -Activity $actividad -Completed
    Set-ProgresoGui2 -1

    return @{
        VideoFusionado = $fDef   # ya es ruta absoluta
        Borrables = @($fRpu, $fBase, $fDef)
    }
}

# Convierte pistas DTS internas a E-AC3 para cualquier idioma que no tenga ya AC3/EAC3 disponible
# (ni interno ni externo). Una conversión por idioma. Aplicado a TODOS los idiomas presentes
# (incluyendo und si lo hay) para garantizar compatibilidad con reproductores sin soporte DTS.
# $modo: "SIEMPRE" (convierte sin preguntar), "NUNCA" (omite siempre), "PREGUNTAR" (una pregunta por archivo)
function Invoke-ConversionDTSMultiidioma($origenesPistas, $modo = "SIEMPRE", $memoriaIdiomas = @{}) {
    Write-Host "`n[>>] Analizando pistas de audio internas..." -ForegroundColor Cyan
    Write-DiagPaso "Conversion DTS: INICIO"

    if ($modo -eq "NUNCA") {
        Write-Host "   -> Conversión DTS desactivada por configuración. Se conserva el audio original." -ForegroundColor DarkGray
        return @()
    }

    $listaArchivos = @($origenesPistas)

    # 1. Listar todas las pistas de audio internas de TODOS los archivos del par.
    # Salida JSON en lugar de CSV: con CSV, si una pista no tenía tag 'language' pero sí
    # 'title', las columnas se desplazaban (el título acababa en Lang); y un título con
    # comas rompía el registro entero.
    $pistasInternas = @()
    foreach ($rutaArchivo in $listaArchivos) {
        $probeAud = $null
        try { $probeAud = ffprobe -v error -select_streams a -show_entries stream=index,codec_name:stream_tags=language,title -of json $rutaArchivo 2>$null | Out-String | ConvertFrom-Json } catch {}
        if (-not $probeAud -or -not $probeAud.streams) { continue }
        $crudas = @($probeAud.streams | ForEach-Object {
            [PSCustomObject]@{
                Index = "$($_.index)"
                Codec = "$($_.codec_name)"
                Lang  = if ($_.tags -and $_.tags.language) { "$($_.tags.language)" } else { "" }
                Title = if ($_.tags -and $_.tags.title)    { "$($_.tags.title)" }    else { "" }
            }
        })
        foreach ($p in $crudas) {
            if(-not (Test-HdzAudioTrackKept $rutaArchivo $p.Index -FfprobeIndex)){continue}
            # Añadimos el path del archivo a cada pista para que la conversión sepa de dónde sacarla
            $p | Add-Member -NotePropertyName "RutaArchivo" -NotePropertyValue $rutaArchivo -Force
            $pistasInternas += $p
        }
    }
    if ($pistasInternas.Count -eq 0) { return @() }

    # Resolver idiomas indeterminados consultando la memoria (Resolve-IdiomasAudios ya las pobló)
    # y normalizar variantes (Castellano vs Latino) usando el Title como pista.
    foreach ($p in $pistasInternas) {
        if ([string]::IsNullOrWhiteSpace($p.Lang) -or $p.Lang -eq "und") {
            $idx = [int]$p.Index   # ojo: aquí "Index" es el índice global de ffmpeg (= ID de mkvmerge)
            $llaveMem = "Interno_$($p.RutaArchivo)_$idx"
            if ($memoriaIdiomas.ContainsKey($llaveMem)) { $p.Lang = $memoriaIdiomas[$llaveMem] }
            elseif ([string]::IsNullOrWhiteSpace($p.Lang)) { $p.Lang = "und" }
        }
        # Normalización: spa+title="Latinoamérica" → es-419
        $p.Lang = Get-LanguageCode $p.Lang $p.Title
    }

    # 2. Agrupar por idioma. Para cada idioma, ver si tiene AC3/EAC3 (interno o externo del mismo idioma).
    $idiomasConAC3 = @{}   # langCode -> $true si ya hay AC3/EAC3
    foreach ($p in $pistasInternas) {
        if ($p.Codec -match "(?i)ac3|eac3") {
            $idiomasConAC3[$p.Lang] = $true
        }
    }
    # Externos AC3/EAC3 con idioma identificado
    $externosAC3 = Get-ChildItem -LiteralPath $rutaCarpeta -File | Where-Object { $_.Extension -match "\.(ac3|eac3)$" }
    foreach ($ext in $externosAC3) {
        $langExt = $null
        $titleExt = ""
        $llaveExt = "Externo_$($ext.FullName)"
        if ($memoriaIdiomas.ContainsKey($llaveExt)) { $langExt = $memoriaIdiomas[$llaveExt] }
        if (-not $langExt) {
            if ($ext.Name -match "(?i)audio_([a-z]{2,3}(?:-[a-z0-9]{2,3})?)_(temp|final)") { $langExt = $Matches[1].ToLower() }
            elseif ($ext.Name -match "(?i)(?<![a-z])(latino|latam|lat)(?![a-z])")           { $langExt = "es-419" }
            elseif ($ext.Name -match "(?i)(?<![a-z])(spa|es|castellano|cast)(?![a-z])")     { $langExt = "es" }
            elseif ($ext.Name -match "(?i)(?<![a-z])(eng|en|ingles|english)(?![a-z])")      { $langExt = "eng" }
            elseif ($ext.Name -match "(?i)(?<![a-z])(fre|fr|frances|french)(?![a-z])")      { $langExt = "fre" }
        }
        $miExt = Get-MediainfoJson $ext.FullName
        if ($miExt) {
            $pAExt = $miExt.media.track | Where-Object { $_.'@type' -eq "Audio" } | Select-Object -First 1
            if ($pAExt) { $titleExt = "$($pAExt.Title)" }
        }
        if ($langExt) { $langExt = Get-LanguageCode $langExt $titleExt }
        if ($langExt) { $idiomasConAC3[$langExt] = $true }
    }

    # 3. Para cada idioma con DTS pero sin AC3/EAC3, elegir la mejor pista DTS y marcarla para conversión.
    # Si el mismo idioma tiene DTS en varios archivos, elegimos la mejor (Master Audio/HD prevalece).
    $aConvertir = @()
    $idiomasDTS = @{}
    foreach ($p in $pistasInternas) {
        if ($p.Codec -match "(?i)dts") {
            $lng = if ([string]::IsNullOrWhiteSpace($p.Lang)) { "und" } else { $p.Lang }
            if (-not $idiomasDTS.ContainsKey($lng)) { $idiomasDTS[$lng] = @() }
            $idiomasDTS[$lng] += $p
        }
    }

    foreach ($lng in $idiomasDTS.Keys) {
        if ($idiomasConAC3.ContainsKey($lng)) {
            Write-Host "   -> Idioma '$lng' ya tiene AC3/EAC3. Se omite conversión DTS." -ForegroundColor DarkGray
            continue
        }
        $mejorDTS = $idiomasDTS[$lng] | Sort-Object { $_.Title -like "*Master*" -or $_.Title -like "*HD*" } -Descending | Select-Object -First 1
        $aConvertir += [PSCustomObject]@{
            Lang  = $lng
            Index = $mejorDTS.Index
            Title = if ([string]::IsNullOrWhiteSpace($mejorDTS.Title)) { "(sin título)" } else { $mejorDTS.Title }
            RutaArchivo = $mejorDTS.RutaArchivo   # de qué MKV concreto extraer
        }
    }

    if ($aConvertir.Count -eq 0) {
        Write-Host "   -> No hay pistas DTS que requieran conversión." -ForegroundColor DarkGray
        return @()
    }

    # 4. Modo PREGUNTAR: una sola pregunta listando todos los idiomas a convertir
    if ($modo -eq "PREGUNTAR") {
        Write-Host "   -> Pistas DTS detectadas para conversión a E-AC3 (compatibilidad):" -ForegroundColor Yellow
        foreach ($conv in $aConvertir) {
            Write-Host "      - $($conv.Lang) (Index $($conv.Index), de $(Split-Path $conv.RutaArchivo -Leaf)) - $($conv.Title)" -ForegroundColor Cyan
        }
        $respDTS = Read-Host "   [?] ¿Convertir todas a E-AC3? (S/N)"
        if ($respDTS -notmatch "^[sS]") {
            Write-Host "   -> Omitidas todas las conversiones por elección del usuario." -ForegroundColor DarkGray
            return @()
        }
    }

    # 5. Convertir cada pista, generando un EAC3 temporal por idioma.
    # IMPORTANTE: preservamos el delay de origen. Algunas pistas DTS no empiezan en 0 (tienen un
    # start_time/retardo para sincronizar con el vídeo, p.ej. 0.971s). Al extraer a un EAC3 crudo
    # ese delay se perdería y el audio quedaría adelantado. Leemos el start_time de la pista y lo
    # reaplicamos en la propia conversión con -af adelay, de modo que el EAC3 ya nace sincronizado.
    # Argumentos de salida de cada pista (mapa, delay, códec). Se agrupan por archivo de origen:
    # FFmpeg demuxa el MKV completo aunque solo se pida una pista, así que convertir N idiomas en
    # N procesos leía el archivo N veces. Con varias salidas en un proceso se lee UNA vez y los
    # codificadores trabajan en paralelo. El audio resultante es el mismo.
    foreach ($conv in $aConvertir) {
        # Nombre intuitivo: "<nombre del video>_audio_<lang>.eac3" (antes: "audio_<lang>_temp.eac3").
        $baseNombre = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path $conv.RutaArchivo -Leaf))
        $audioEAC3_temp = Join-Path $rutaCarpeta "${baseNombre}_audio_$($conv.Lang).eac3"

        # Leer el delay (start_time) de la pista DTS de origen, en segundos.
        $startTimeRaw = ffprobe -v error -select_streams "$($conv.Index)" -show_entries stream=start_time -of csv=p=0 $conv.RutaArchivo 2>$null
        $delaySeg = 0.0
        [double]::TryParse(("$startTimeRaw").Replace(',', '.'), [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$delaySeg) | Out-Null
        $delayMs = [int][Math]::Round($delaySeg * 1000)

        $salidaArgs = @('-map', "0:$($conv.Index)")
        # adelay inserta silencio al inicio para reproducir el retardo original (todos los canales).
        if ($delayMs -gt 0) { $salidaArgs += @('-af', "adelay=${delayMs}:all=1") }
        $salidaArgs += @('-c:a', 'eac3', '-b:a', '1024k', '-y', $audioEAC3_temp)
        $conv | Add-Member -NotePropertyName Salida -NotePropertyValue $audioEAC3_temp -Force
        $conv | Add-Member -NotePropertyName SalidaArgs -NotePropertyValue $salidaArgs -Force

        Write-Host "   -> Extrayendo DTS '$($conv.Lang)' (Index $($conv.Index)) a $($audioEAC3_temp | Split-Path -Leaf)..." -ForegroundColor Gray
        if ($delayMs -gt 0) { Write-Host "      (delay de origen: ${delayMs} ms, se preserva en el EAC3)" -ForegroundColor DarkGray }
        Write-DiagPaso "  ffmpeg DTS->EAC3 preparado: lang=$($conv.Lang) delay=${delayMs}ms"
    }
    $generados = @()
    foreach ($porArchivo in @($aConvertir | Group-Object RutaArchivo)) {
        $convs = @($porArchivo.Group)
        $argsFf = @('-nostdin', '-v', 'error', '-i', $convs[0].RutaArchivo)
        foreach ($conv in $convs) { $argsFf += $conv.SalidaArgs }
        Write-DiagPaso "  ffmpeg DTS->EAC3 INICIO: $($convs.Count) pista(s) en una pasada de $(Split-Path $convs[0].RutaArchivo -Leaf)"
        & ffmpeg @argsFf
        $codigoFf = $LASTEXITCODE
        Write-DiagPaso "  ffmpeg DTS->EAC3 FIN: exit=$codigoFf"
        if ($codigoFf -ne 0 -and $convs.Count -gt 1) {
            # Respaldo: pista a pista, para que un idioma problemático no deje sin convertir a los demás.
            foreach ($conv in $convs) {
                & ffmpeg @(@('-nostdin', '-v', 'error', '-i', $conv.RutaArchivo) + $conv.SalidaArgs)
                $conv | Add-Member -NotePropertyName Ok -NotePropertyValue ($LASTEXITCODE -eq 0) -Force
            }
        } else {
            foreach ($conv in $convs) { $conv | Add-Member -NotePropertyName Ok -NotePropertyValue ($codigoFf -eq 0) -Force }
        }
        foreach ($conv in $convs) {
            if ($conv.Ok -and (Test-Path -LiteralPath $conv.Salida)) {
                $generados += $conv.Salida
            } else {
                Write-Host "   [!] ffmpeg falló convirtiendo DTS '$($conv.Lang)'." -ForegroundColor Red
            }
        }
    }
    Write-DiagPaso "Conversion DTS: FIN ($($generados.Count) pistas convertidas)"
    return $generados
}

# =========================================================================
# CONVERSOR DE AUDIO MANUAL (por pista) — sustituye a la conversión DTS automática.
# Recibe la lista de conversiones del usuario (GUI) para UN archivo y genera, por cada
# una, una pista externa ya convertida (códec/canales/bitrate elegidos), preservando el
# delay de origen (idéntica técnica que la conversión DTS). Devuelve:
#   .Nuevos           = descriptores de pista (Origen="Externo") a inyectar en el mux
#   .IndicesAEliminar = índices de pista ORIGINAL a quitar (cuando NO se «Mantiene original»)
#   .Borrables        = ficheros temporales a borrar al terminar
# =========================================================================
function Invoke-ConversionAudioManual($conversiones, $archivoPrincipal) {
    $res = @{ Nuevos = @(); IndicesAEliminar = @(); PistasAEliminar = @(); Borrables = @() }
    $lista = @($conversiones)
    if ($lista.Count -eq 0) { return $res }
    # Resolver el archivo donante DE ESTE episodio antes de agrupar sustituciones.
    $lista = @(foreach ($item in $lista) {
        $copy = @{}; foreach ($property in $item.PSObject.Properties) { $copy[$property.Name] = $property.Value }
        if ($item -is [Collections.IDictionary]) { $copy=@{}; foreach($key in $item.Keys){$copy[$key]=$item[$key]} }
        if ($copy.FuentePorEpisodio) {
            $episode = Get-HdzEpisodeKey $archivoPrincipal.BaseName
            $candidates = @(Get-ChildItem -LiteralPath (Split-Path "$($copy.ArchivoFuente)" -Parent) -File | Where-Object { $_.Extension -in @('.mkv','.mp4','.ts') -and (Test-HdzEpisodeMatch (Get-HdzEpisodeKey $_.BaseName) $episode) })
            if (-not $episode -or $candidates.Count -ne 1) { throw 'No se puede identificar un único donante de audio para este episodio.' }
            $copy.ArchivoFuente = $candidates[0].FullName
        }
        $selectionSource=if($copy.FuenteExacta){"$($copy.ArchivoFuente)"}else{$archivoPrincipal.FullName}
        if(-not (Test-HdzAudioTrackKept $selectionSource $copy.Index -FfprobeIndex)){continue}
        [pscustomobject]$copy
    })

    Write-DiagPaso "Conversion audio manual: INICIO ($($lista.Count) conversion(es))"
    $rutaFuente = $archivoPrincipal.FullName
    $baseNombre = [System.IO.Path]::GetFileNameWithoutExtension($archivoPrincipal.Name)
    $fmtMediainfo = @{ "eac3" = "E-AC-3"; "ac3" = "AC-3"; "aac" = "AAC" }
    # AAC va en contenedor .m4a (MP4): el .aac crudo (ADTS) no admite 7.1. eac3/ac3 como flujo crudo.
    $extPorCodec  = @{ "eac3" = "eac3"; "ac3" = "ac3"; "aac" = "m4a" }

    # Para cada índice de origen, ¿alguna conversión pide conservar el original? El original solo
    # se elimina si TODAS sus conversiones tienen «Mantener original» = false (regla segura).
    $conservar = @{}
    foreach ($c in $lista) {
        $idx = [int]$c.Index
        $sourceKey = if ($c.FuenteExacta) { "$($c.ArchivoFuente)" } else { $archivoPrincipal.FullName }
        $key = "$sourceKey|$idx"
        if (-not $conservar.ContainsKey($key)) { $conservar[$key] = $false }
        if ([bool]$c.MantenerOriginal) { $conservar[$key] = $true }
    }

    $n = 0
    $preparadas = @()
    foreach ($c in $lista) {
        $n++
        $idx  = [int]$c.Index
        $rutaFuente = if ($c.FuenteExacta) { "$($c.ArchivoFuente)" } else { $archivoPrincipal.FullName }
        if (-not (Test-Path -LiteralPath $rutaFuente -PathType Leaf)) { throw 'No se encuentra el archivo de la pista elegida para convertir.' }
        $probeJson = & ffprobe -v error -show_streams -of json $rutaFuente 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'No se puede verificar la pista de origen para convertir.' }
        $probeTracks = @(($probeJson -join "`n" | ConvertFrom-Json).streams)
        $sourceTrack = @($probeTracks | Where-Object { $_.index -eq $idx -and $_.codec_type -eq 'audio' })
        if ($sourceTrack.Count -ne 1) { throw "La pista $idx no es un audio válido en '$rutaFuente'." }
        $actualLanguage = Get-LanguageCode $sourceTrack[0].tags.language $sourceTrack[0].tags.title
        $expectedLanguage = Get-LanguageCode $c.Lang
        if ($actualLanguage -ne 'und' -and $expectedLanguage -ne 'und' -and $actualLanguage -ne $expectedLanguage) { throw "La pista $idx cambió de idioma en este episodio. Revisa la conversión; original conservado." }
        if (($c.CodecOrigen -and "$($c.CodecOrigen)" -ne "$($sourceTrack[0].codec_name)") -or ($c.CanalesOrigen -gt 0 -and [int]$c.CanalesOrigen -ne [int]$sourceTrack[0].channels)) { throw 'El orden o formato de audios cambió en este episodio. Revisa la conversión.' }
        $sourceAudios = @($probeTracks | Where-Object codec_type -eq audio)
        $audioOrdinal = [array]::IndexOf($sourceAudios, $sourceTrack[0])
        $mkvJson = & mkvmerge -J $rutaFuente 2>$null
        if ($LASTEXITCODE -gt 1) { throw 'No se pueden identificar los audios para el montaje.' }
        $mkvAudios = @((($mkvJson -join "`n") | ConvertFrom-Json).tracks | Where-Object type -eq audio)
        if ($audioOrdinal -lt 0 -or $audioOrdinal -ge $mkvAudios.Count) { throw 'No coincide el inventario de audios entre las herramientas.' }
        $mkvAudioId = [int]$mkvAudios[$audioOrdinal].id
        $cod  = "$($c.CodecDestino)".ToLower()
        $ch   = [int]$c.CanalesDestino
        $br   = [int]$c.BitrateK
        $lang = if ([string]::IsNullOrWhiteSpace("$($c.Lang)")) { "und" } else { "$($c.Lang)" }
        if (-not $fmtMediainfo.ContainsKey($cod)) {
            throw "Códec de destino no soportado: '$cod'. No se sustituye el audio original."
        }
        $ext    = $extPorCodec[$cod]
        $salida = Join-Path $rutaCarpeta "hdz_conv_$([guid]::NewGuid().ToString('N')).${ext}"

        # Delay (start_time) de la pista de origen, para preservar la sincronía (igual que DTS).
        $startTimeRaw = ffprobe -v error -select_streams "$idx" -show_entries stream=start_time -of csv=p=0 $rutaFuente 2>$null
        $delaySeg = 0.0
        [double]::TryParse(("$startTimeRaw").Replace(',', '.'), [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$delaySeg) | Out-Null
        $delayMs = [int][Math]::Round($delaySeg * 1000)

        $nomComercial = switch ($cod) { "eac3" { "DD+" } "ac3" { "DD" } "aac" { "AAC" } default { $cod.ToUpper() } }
        $layStr = switch ($ch) { 8 { "7.1" } 6 { "5.1" } 2 { "2.0" } 1 { "1.0" } default { "$ch ch" } }
        Write-Host "   -> Convirtiendo pista $idx ($lang) a $nomComercial $layStr (${br}k)..." -ForegroundColor Gray
        if ($delayMs -gt 0) { Write-Host "      (delay de origen: ${delayMs} ms, se preserva)" -ForegroundColor DarkGray }
        $salidaArgs = @('-map', "0:$idx")
        if ($delayMs -gt 0) { $salidaArgs += @('-af', "adelay=${delayMs}:all=1") }
        $salidaArgs += @('-c:a', $cod, '-ac', "$ch", '-b:a', "${br}k", '-y', $salida)
        $preparadas += [PSCustomObject]@{ Idx = $idx; RutaFuente = $rutaFuente; Salida = $salida; SalidaArgs = $salidaArgs; Cod = $cod; Ch = $ch; Lang = $lang; Etiqueta = "$nomComercial $layStr"; MkvAudioId = $mkvAudioId }
    }

    # Codificación: UNA lectura del archivo de origen para todas sus conversiones (FFmpeg demuxa el
    # archivo entero aunque solo se pida una pista). Si el proceso conjunto falla, se repite pista a
    # pista para dar el mismo error concreto que antes.
    foreach ($porFuente in @($preparadas | Group-Object RutaFuente)) {
        $grupoConv = @($porFuente.Group)
        $argsFf = @('-nostdin', '-v', 'error', '-i', $grupoConv[0].RutaFuente)
        foreach ($pc in $grupoConv) { $argsFf += $pc.SalidaArgs }
        Write-DiagPaso "  ffmpeg conv INICIO: $($grupoConv.Count) pista(s) en una pasada de $(Split-Path $grupoConv[0].RutaFuente -Leaf)"
        $null = & ffmpeg @argsFf
        $codigoFf = $LASTEXITCODE
        Write-DiagPaso "  ffmpeg conv FIN: exit=$codigoFf"
        foreach ($pc in $grupoConv) {
            if ($codigoFf -ne 0 -and $grupoConv.Count -gt 1) { $null = & ffmpeg @(@('-nostdin', '-v', 'error', '-i', $pc.RutaFuente) + $pc.SalidaArgs); $codigoPc = $LASTEXITCODE } else { $codigoPc = $codigoFf }
            if ($codigoPc -ne 0 -or -not (Test-Path -LiteralPath $pc.Salida)) {
                foreach ($tmpConv in $preparadas) { if (Test-Path -LiteralPath $tmpConv.Salida) { Remove-Item -LiteralPath $tmpConv.Salida -Force } }
                throw "FFmpeg falló convirtiendo la pista $($pc.Idx) a $($pc.Etiqueta). Se conserva el archivo original."
            }
        }
    }

    foreach ($pc in $preparadas) {
        $idx = $pc.Idx; $rutaFuente = $pc.RutaFuente; $salida = $pc.Salida; $cod = $pc.Cod; $ch = $pc.Ch; $lang = $pc.Lang; $mkvAudioId = $pc.MkvAudioId
        $convertedRaw = & ffprobe -v error -show_streams -of json $salida 2>$null
        $converted = if ($LASTEXITCODE -eq 0) { @( (($convertedRaw -join "`n") | ConvertFrom-Json).streams | Where-Object codec_type -eq audio) } else { @() }
        if ($converted.Count -ne 1 -or $converted[0].codec_name -ne $cod -or [int]$converted[0].channels -ne $ch) {
            foreach ($tmpConv in $preparadas) { if (Test-Path -LiteralPath $tmpConv.Salida) { Remove-Item -LiteralPath $tmpConv.Salida -Force } }
            throw 'El audio convertido no contiene el formato solicitado. No se sustituye el original.'
        }
        $nomIdioma = Get-LanguageName $lang ""
        $res.Nuevos += [PSCustomObject]@{
            Origen = "Externo"; ID = $salida; ArchivoFuente = $salida
            Tipo = "Audio"; CodLang = $lang; NomLang = $nomIdioma; PesoLang = (Get-PesoIdioma $nomIdioma)
            Format = $fmtMediainfo[$cod]; Profile = ""; Comm = ""; Chan = $ch
            Size = (Get-Item -LiteralPath $salida).Length; IsForced = $false; MediainfoForcedFlag = $false; NomFinal = ""
        }
        $res.Borrables += $salida
        if (-not $conservar["$rutaFuente|$idx"]) { $res.PistasAEliminar += @{ Ruta = $rutaFuente; Index = $mkvAudioId } }
    }

    # Índices cuyas conversiones NINGUNA conserva el original -> se eliminarán del mux final.
    $res.IndicesAEliminar = @($res.PistasAEliminar | ForEach-Object { [int]$_.Index } | Select-Object -Unique)
    Write-DiagPaso "Conversion audio manual: FIN (nuevas=$($res.Nuevos.Count) eliminar=$($res.IndicesAEliminar.Count))"
    return $res
}

# Extrae pistas PGS para OCR manual. NO hace pausa ni preguntas (se gestiona fuera).
function Invoke-ExtraccionPGS($origenPistas, $idiomasSubsMantener = $null, $prefijoArchivo = "") {
    # Extrae los PGS de un archivo a ficheros .sup. Devuelve el nº de PGS extraídos.
    # Nombre intuitivo: "<nombre del video>_sub_<idx>_<lang>.sup". El nombre del vídeo permite
    # identificar de un vistazo a qué archivo pertenece cada .sup, y evita mezclar los de
    # distintos archivos cuando se extrae todo el lote de golpe (modo serie).
    # Si no se pasa $prefijoArchivo, lo derivamos del propio archivo de origen.
    if (-not $prefijoArchivo) {
        $prefijoArchivo = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path $origenPistas -Leaf))
    }
    Write-Host "   -> Extrayendo PGS de: $(Split-Path $origenPistas -Leaf)" -ForegroundColor Gray
    # Salida JSON en lugar de CSV (mismo motivo que en la conversión DTS: los tags ausentes
    # desplazaban columnas y las comas rompían el parseo).
    $probeSubs = $null
    try { $probeSubs = ffprobe -v error -select_streams s -show_entries stream=index,codec_name:stream_tags=language -of json $origenPistas 2>$null | Out-String | ConvertFrom-Json } catch {}
    $pistasPGS = @()
    $idMap = Get-MkvmergeTrackIdMap $origenPistas
    $ordinal = 0
    if ($probeSubs -and $probeSubs.streams) {
        $pistasPGS = @($probeSubs.streams | ForEach-Object {
            $ordinal++
            if ("$($_.codec_name)" -notmatch "(?i)pgs") { return }
            $id = if ($idMap.ContainsKey("Text+$ordinal")) { $idMap["Text+$ordinal"] } else { $_.index }
            # Subtítulo desmarcado a mano en la GUI: no se extrae (tampoco irá al montaje).
            if (-not (Test-HdzSubTrackKept $origenPistas $id)) { return }
            $lang = if ($_.tags -and $_.tags.language) { "$($_.tags.language)" } else { '' }
            if ($global:undPistasGui.ContainsKey("$origenPistas|$id|Sub")) { $lang = $global:undPistasGui["$origenPistas|$id|Sub"] }
            [PSCustomObject]@{
                Index = $_.index
                Codec = "$($_.codec_name)"
                Lang  = $lang
            }
        })
    }
    if ($pistasPGS.Count -eq 0) {
        return 0
    }
    $aExtraer = @()
    foreach ($sub in $pistasPGS) {
        $lang = if ($sub.Lang) { $sub.Lang } else { "unk" }
        # Si el usuario eligió recortar idiomas, no extraemos los PGS de idiomas descartados.
        if ($idiomasSubsMantener) {
            $codNorm = Get-LanguageCode $lang ""
            $mantener = if ($idiomasSubsMantener -contains "__CAST_ENG__") { $codNorm -in @("es", "eng") } else { $codNorm -in $idiomasSubsMantener }
            if (-not $mantener) {
                Write-Host "      -> Omitido (idioma no seleccionado): $lang" -ForegroundColor DarkGray
                continue
            }
        }
        $aExtraer += [PSCustomObject]@{ Index = $sub.Index; Sup = "${prefijoArchivo}_sub_$($sub.Index)_$lang.sup" }
    }
    if ($aExtraer.Count -eq 0) { return 0 }
    # UNA sola lectura del archivo para todas las pistas: antes cada PGS lanzaba su propio FFmpeg,
    # que recorría el MKV entero (con un remux de 60 GB y 4 PGS se leían 240 GB).
    $argsPgs = @('-nostdin', '-v', 'error', '-i', $origenPistas)
    foreach ($pg in $aExtraer) { $argsPgs += @('-map', "0:$($pg.Index)", '-c', 'copy', '-y', $pg.Sup) }
    & ffmpeg @argsPgs
    if ($LASTEXITCODE -ne 0) {
        # Respaldo: pista a pista, como siempre, para que una pista problemática no impida las demás.
        Write-DiagLinea "Extracción PGS en una pasada falló (exit=$LASTEXITCODE); se repite pista a pista."
        foreach ($pg in $aExtraer) { ffmpeg -nostdin -i $origenPistas -map 0:$($pg.Index) -c copy $pg.Sup -y -v error }
    }
    foreach ($pg in $aExtraer) { Write-Host "      -> Extraído: $($pg.Sup)" -ForegroundColor Gray }
    return $aExtraer.Count
}

# Construye la lista bruta de pistas (internas + externas) con todos sus metadatos
function Build-PistasBrutas($origenesPistas, $esHibrido, $memoriaIdiomas, $decisionPGS = "CONSERVAR_PGS", $idiomasSubsMantener = $null, $prefijoSrtPropio = "", $idiomasAudioMantener = $null) {
    $pistasBrutas = @()
    $idVideo = 0; $altoVideo = 0; $codecVideo = "264"; $hdrVideo = ""

    # Aceptamos un único path o un array. Internamente trabajamos siempre con array.
    $listaArchivos = @($origenesPistas)

    # El video se lee SOLO del primer archivo (el preferente / mejor metadata).
    # Las pistas de audio/subs se leen de TODOS los archivos y luego se deduplican.
    $primerArchivo = $listaArchivos[0]

    for ($idxArchivo = 0; $idxArchivo -lt $listaArchivos.Count; $idxArchivo++) {
        $rutaArchivo = $listaArchivos[$idxArchivo]
        $miJson = Get-MediainfoJson $rutaArchivo
        if (-not $miJson) { continue }

        # Mapeo de IDs reales de mkvmerge por (tipo + orden de aparición). mediainfo a veces
        # numera pistas con huecos (visto en Fight Club: PGS internos como 7, 9, 11, 13, 15...
        # cuando mkvmerge espera 6, 7, 8, 9, 10). El pista.ID - 1 funciona en archivos típicos
        # pero falla en estos casos. mkvmerge -J es la fuente fiable.
        $idMap = Get-MkvmergeTrackIdMap $rutaArchivo
        $contIdx = @{ Video = 0; Audio = 0; Text = 0 }

        foreach ($pista in $miJson.media.track) {
            # Video solo del primer archivo
            if ($pista.'@type' -eq "Video" -and $rutaArchivo -eq $primerArchivo) {
                $contIdx.Video++
                $claveMap = "Video+$($contIdx.Video)"
                $idVideo = if ($idMap.ContainsKey($claveMap)) { $idMap[$claveMap] } else { $pista.ID - 1 }
                $altoVideo = [int]$pista.Height
                $codecVideo = if     ($pista.Format -match "(?i)AV1")              { "AV1" }
                              elseif ($pista.Format -match "(?i)HEVC|H\.?265")     { "265" }
                              elseif ($pista.Format -match "(?i)AVC|H\.?264")      { "264" }
                              else {
                                  Write-Host "   [!] Códec de video no reconocido: '$($pista.Format)' — usando H.264 por defecto" -ForegroundColor DarkYellow
                                  "264"
                              }
                $vidStr = $pista | ConvertTo-Json -Depth 2 -Compress
                $arrH = @()
                if ($vidStr -match "Dolby Vision" -or $esHibrido) { $arrH += "DV" }
                if ($vidStr -match "HDR10\+") { $arrH += "HDR10+" } elseif ($vidStr -match "HDR10") { $arrH += "HDR10" }
                # Fallback: detección por BT.2020 + PQ + >=10 bits cuando los campos HDR_Format
                # de mediainfo vienen vacíos (típico en encodes AV1 hechos con fastflix u otros).
                if (-not ($arrH -contains "HDR10") -and -not ($arrH -contains "HDR10+")) {
                    $primarias = "$($pista.colour_primaries)"
                    $transferencia = "$($pista.transfer_characteristics)"
                    $profBits = 0
                    if ($pista.BitDepth) { $profBits = [int]"$($pista.BitDepth)" }
                    if ($primarias -match "(?i)BT\.?2020" -and $transferencia -match "(?i)PQ|SMPTE ST 2084|ST 2084" -and $profBits -ge 10) {
                        $arrH += "HDR10"
                    }
                }
                $hdrVideo = $arrH -join " "
            }

            if ($pista.'@type' -match "Audio|Text") {
                # ID real en mkvmerge: contamos por tipo y consultamos el map.
                $tipoClave = if ($pista.'@type' -eq "Text") { "Text" } else { "Audio" }
                $contIdx[$tipoClave]++
                $claveMap = "$tipoClave+$($contIdx[$tipoClave])"
                $idMkvmerge = if ($idMap.ContainsKey($claveMap)) { $idMap[$claveMap] } else { $pista.ID - 1 }
                if($tipoClave -eq 'Audio' -and -not (Test-HdzAudioTrackKept $rutaArchivo $idMkvmerge)){continue}
                if($tipoClave -eq 'Text' -and -not (Test-HdzSubTrackKept $rutaArchivo $idMkvmerge)){continue}

                # REMEZCLA: filtra qué archivo aporta audio/subs. El vídeo (primer archivo) NO aporta
                # audio/subs salvo que su carpeta tenga ese rol; los demás archivos, según su rol. El
                # contador ya se incrementó arriba, así que los IDs de las pistas restantes siguen OK.
                if ($global:remixActivo) {
                    if ("$rutaArchivo" -eq "$primerArchivo") {
                        $permAudio = $global:remixVideoAudio; $permSubs = $global:remixVideoSubs
                    } else {
                        $rol = $global:remixRoles["$rutaArchivo"]
                        $permAudio = if ($rol) { [bool]$rol.Audio } else { $true }
                        $permSubs  = if ($rol) { [bool]$rol.Subs } else { $true }
                    }
                    if ($tipoClave -eq "Audio" -and -not $permAudio) { continue }
                    if ($tipoClave -eq "Text" -and -not $permSubs) { continue }
                }

                $langCode = $pista.Language
                $tituloPista = "$($pista.Title)"
                # D4: clave incluye path. Usamos el ID de mkvmerge para coherencia con el resto del flujo.
                $llaveMemoria = "Interno_${rutaArchivo}_$idMkvmerge"
                if ($memoriaIdiomas.ContainsKey($llaveMemoria)) { $langCode = $memoriaIdiomas[$llaveMemoria] }
                if ([string]::IsNullOrWhiteSpace($langCode)) { $langCode = "und" }
                # Normalizamos: si es español + title indica Latino → "es-419"
                $tipoIdioma = if ($pista.'@type' -eq 'Text') { 'Sub' } else { 'Audio' }
                $idiomaManual = $global:undPistasGui.ContainsKey("$rutaArchivo|$idMkvmerge|$tipoIdioma")
                if ($idiomaManual) {
                    $langCode = Get-LanguageCode $global:undPistasGui["$rutaArchivo|$idMkvmerge|$tipoIdioma"] ""
                } else { $langCode = Get-LanguageCode $langCode $tituloPista }

                # Si la pista quedó como 'und', aplicamos el idioma que el usuario eligió en el
                # pre-escaneo del lote (uno global para audios, otro para subs). Para subs, además,
                # se respeta la decisión por archivo concreto si existe (clave "<archivo>|Text").
                if ($langCode -eq "und" -and -not $idiomaManual) {
                    if ($pista.'@type' -eq "Text") {
                        # La decisión de idioma se guardó con el formato REAL del sub ("Text" o
                        # "PGS", antes se buscaba siempre "|Text" y los PGS nunca la encontraban)
                        # y puede estar registrada con el path de este archivo o con el del
                        # principal del par híbrido (donde se hizo la pregunta).
                        $fmtSimpleUnd = if ("$($pista.Format)" -match "(?i)srt|subrip|ass|ssa|utf-?8|text") { "Text" } else { "PGS" }
                        $clavesUnd = @("${rutaArchivo}|$fmtSimpleUnd")
                        if ($rutaArchivo -ne $primerArchivo) { $clavesUnd += "${primerArchivo}|$fmtSimpleUnd" }
                        $undResuelto = $false
                        foreach ($kUnd in $clavesUnd) {
                            if ($global:decisionesIdiomaUnd.ContainsKey($kUnd)) {
                                $langCode = $global:decisionesIdiomaUnd[$kUnd]
                                $undResuelto = $true
                                break
                            }
                        }
                        if (-not $undResuelto -and $global:idiomaUndSubLote) {
                            $langCode = $global:idiomaUndSubLote
                        }
                    } elseif ($pista.'@type' -eq "Audio") {
                        if ($global:idiomaUndAudioLote) {
                            $langCode = $global:idiomaUndAudioLote
                        }
                    }
                }
                $lNom = Get-LanguageName $langCode $(if ($idiomaManual) { '' } else { $tituloPista })

                # Bug 8: capturar flag de mediainfo si existe
                $forcedFlag = $false
                if ($pista.PSObject.Properties.Name -contains "Forced") {
                    if ("$($pista.Forced)" -match "(?i)yes|1|true") { $forcedFlag = $true }
                }
                # Heurística adicional: si el Title de la pista incluye palabras tipo "forced",
                # "forzado", "forzados" o variantes con guiones (p.ej. "es-ES--forced--"),
                # marcamos como forzado. Algunos releases (Disney+, Apple TV) usan Title pero
                # dejan el flag Forced=No, y sin esto se nos escapan.
                if ($tituloPista -match "(?i)(forced|forzado|forzados)") { $forcedFlag = $true }
                # SDH: flag hearing-impaired (mediainfo ServiceKind=HI o mkvmerge -J) o Title.
                $sdhFlag = ("$($pista.ServiceKind)" -match '(?i)\bHI\b') -or ($tituloPista -match $patronTituloSdh)
                if (-not $sdhFlag -and $pista.'@type' -eq "Text") {
                    $mjSdh = Get-MkvmergeJson $rutaArchivo
                    $tSdh = @($mjSdh.tracks | Where-Object { $_.id -eq [int]$idMkvmerge }) | Select-Object -First 1
                    if ($tSdh -and $tSdh.properties.flag_hearing_impaired -eq $true) { $sdhFlag = $true }
                }

                $pistasBrutas += [PSCustomObject]@{
                    Origen = "Interno"; ID = $idMkvmerge
                    ArchivoFuenteMkv = $rutaArchivo   # nuevo: de qué MKV viene esta pista
                    Tipo = if ($pista.'@type' -eq "Text") { "Sub" } else { "Audio" }
                    CodLang = $langCode; NomLang = $lNom; PesoLang = Get-PesoIdioma $lNom
                    Format = $pista.Format; Profile = $pista.Format_Profile
                    Comm = $pista.Format_Commercial_IfAny; Chan = $pista.Channels
                    Size = if ($pista.StreamSize) { [long]$pista.StreamSize } else { 0 }
                    IsForced = $false; MediainfoForcedFlag = $forcedFlag; NomFinal = ""
                    SdhFlag = [bool]$sdhFlag
                }
            }
        }
    }

    # ----- DEDUPLICACIÓN entre archivos del par DV+HDR10 -----
    # Diagnóstico previo: listamos TODOS los audios leídos (de todos los archivos) antes de dedup,
    # para detectar si falta algún audio de alguno de los archivos del híbrido.
    foreach ($p in @($pistasBrutas | Where-Object { $_.Tipo -eq "Audio" })) {
        Write-DiagLinea "  [merge audio leido] $($p.NomLang) $($p.Format) $($p.Chan)ch <- $(Split-Path $p.ArchivoFuenteMkv -Leaf)"
    }
    # Audios: clave (idioma + códec_simplificado + canales). Si hay duplicado, conservamos el primero
    # añadido (que viene del archivo preferente, según orden de $listaArchivos).
    # Subs: clave (idioma + formato_simplificado + categoría_tamaño). La categoría distingue subs
    # forzados de completos por tamaño (heurística 35%): así un sub forzado de 3KB y uno completo
    # de 30KB no se consideran duplicados aunque compartan idioma+formato.
    if ($listaArchivos.Count -gt 1 -and -not $global:remixActivo) {

        # Pre-paso: medir tamaño real de subs internos sin StreamSize reportado.
        # mediainfo deja vacío StreamSize en muchos SRT internos; sin eso la categorización
        # forzado/completo no funciona. Extraemos a disco solo los que hagan falta.
        $subsAMedir = @($pistasBrutas | Where-Object { $_.Tipo -eq "Sub" -and $_.Origen -eq "Interno" -and $_.Size -le 0 -and $_.ArchivoFuenteMkv })
        if ($subsAMedir.Count -gt 0) {
            Write-Host "   [debug merge] Midiendo tamaño real de $($subsAMedir.Count) sub(s) interno(s) sin StreamSize..." -ForegroundColor DarkGray
            foreach ($s in $subsAMedir) {
                $tam = Measure-SubEnDisco $s.ArchivoFuenteMkv $s.ID
                $s.Size = $tam
            }
        }

        # Calcular categoría forzado/completo para cada sub interno, agrupando por (idioma+formato)
        # para que el "más grande del grupo" sea coherente. Audios no necesitan categoría.
        $gruposSub = @{}   # clave (idioma+fmtSimple) -> lista de subs del grupo
        foreach ($p in $pistasBrutas) {
            if ($p.Tipo -ne "Sub" -or $p.Origen -ne "Interno") { continue }
            $fmtSimple = if ($p.Format -match "(?i)srt|subrip|ass|ssa|utf-?8|text") { "Text" } else { "PGS" }
            $kg = "$($p.CodLang)|$fmtSimple"
            if (-not $gruposSub.ContainsKey($kg)) { $gruposSub[$kg] = @() }
            $gruposSub[$kg] += $p
        }
        # Etiquetamos cada sub con su CategoriaTam: "Forzado" si pesa ≤35% del max del grupo, "Completo" si no
        # (criterio coherente con Set-FlagForzados). Si el grupo tiene un solo sub o todos pesan 0,
        # se etiquetan todos como "Completo" (sin distinción posible).
        foreach ($kg in $gruposSub.Keys) {
            $lista = $gruposSub[$kg]
            $maxS = 0
            foreach ($s in $lista) { if ($s.Size -gt $maxS) { $maxS = $s.Size } }
            foreach ($s in $lista) {
                $cat = if ($maxS -gt 0 -and $s.Size -le ($maxS * 0.35)) { "Forzado" } else { "Completo" }
                $s | Add-Member -NotePropertyName "CategoriaTam" -NotePropertyValue $cat -Force
            }
        }

        $vistasAudio = @{}
        $vistasSub   = @{}
        $deduplicadas = @()
        $descartadas  = 0
        foreach ($p in $pistasBrutas) {
            if ($p.Origen -ne "Interno") { $deduplicadas += $p; continue }
            if ($p.Tipo -eq "Audio") {
                # Códec simplificado: agrupamos las variantes (DTS-HD MA / DTS / etc.) por nombre comercial básico
                $codSimple = "$($p.Format)"
                if ($p.Format -match "(?i)E-?AC-?3" -or $p.Comm -match "(?i)Plus") { $codSimple = "EAC3" }
                elseif ($p.Format -match "(?i)AC-?3")    { $codSimple = "AC3" }
                elseif ($p.Format -match "(?i)TrueHD|MLP") { $codSimple = "TrueHD" }
                elseif ($p.Format -match "(?i)DTS")      { $codSimple = "DTS" }
                $clave = "AUDIO|$($p.CodLang)|$codSimple|$($p.Chan)"
                if ($vistasAudio.ContainsKey($clave)) {
                    Write-Host "   [debug merge] Audio duplicado descartado: $($p.NomLang) $codSimple $($p.Chan)ch (de $(Split-Path $p.ArchivoFuenteMkv -Leaf))" -ForegroundColor DarkGray
                    $descartadas++
                    continue
                }
                $vistasAudio[$clave] = $true
                $deduplicadas += $p
            } elseif ($p.Tipo -eq "Sub") {
                $fmtSimple = if ($p.Format -match "(?i)srt|subrip|ass|ssa|utf-?8|text") { "Text" } else { "PGS" }
                $catTam = if ($p.PSObject.Properties.Name -contains "CategoriaTam") { $p.CategoriaTam } else { "Completo" }
                $clave = "SUB|$($p.CodLang)|$fmtSimple|$catTam"
                if ($vistasSub.ContainsKey($clave)) {
                    Write-Host "   [debug merge] Sub duplicado descartado: $($p.NomLang) $fmtSimple $catTam (de $(Split-Path $p.ArchivoFuenteMkv -Leaf))" -ForegroundColor DarkGray
                    $descartadas++
                    continue
                }
                $vistasSub[$clave] = $true
                $deduplicadas += $p
            } else {
                $deduplicadas += $p
            }
        }
        if ($descartadas -gt 0) {
            Write-Host "   [merge híbrido] Pistas combinadas de $($listaArchivos.Count) archivos; $descartadas duplicadas descartadas." -ForegroundColor Cyan
        } else {
            Write-Host "   [merge híbrido] Pistas combinadas de $($listaArchivos.Count) archivos (sin duplicados)." -ForegroundColor Cyan
        }
        # Diagnóstico: qué audios sobrevivieron a la dedup y de qué archivo vienen.
        foreach ($p in @($deduplicadas | Where-Object { $_.Tipo -eq "Audio" })) {
            Write-DiagLinea "  [merge audio superviviente] $($p.NomLang) $($p.Format) $($p.Chan)ch <- $(Split-Path $p.ArchivoFuenteMkv -Leaf)"
        }
        $pistasBrutas = $deduplicadas
    }

    # Externos: audios sueltos, SRT, y PGS (.sup) que el usuario haya dejado a mano.
    # Incluimos .sup en la lista, pero más abajo distinguimos los EXTRAÍDOS por el script
    # (patrón "<algo>_sub_<N>_<lang>.sup" o "sub_<N>_<lang>.sup") de los que mete el usuario.
    $archivosExternos = Get-ChildItem -LiteralPath $rutaCarpeta -File | Where-Object { $_.Extension -match "\.(ac3|eac3|dts|dtshd|truehd|flac|wav|srt|ass|ssa|sup|idx|sub)$" }

    # Patrón de archivos generados/extraídos por el script desde PGS:
    #   SRT convertidos: "<nombre>_sub_<N>_<lang>.srt"   (o "sub_<N>_<lang>.srt" en versiones viejas)
    #   SUP extraídos:   "<nombre>_sub_<N>_<lang>.sup"   (o "sub_<N>_<lang>.sup")
    $patronSrtPgsGenerico = "(?i)^(.+_)?sub_\d+_[a-z]{2,3}\.srt$"
    $patronSupExtraido    = "(?i)^(.+_)?sub_\d+_[a-z]{2,3}\.sup$"

    # Los .sup EXTRAÍDOS por el script NUNCA se meten como externos: o ya están dentro del MKV
    # como PGS originales (opción mantener), o se van a eliminar (opción solo SRT). Los .sup que
    # el usuario deja a mano (con cualquier OTRO nombre) SÍ se meten en ambas opciones.
    $archivosExternos = @($archivosExternos | Where-Object { $_.Name -notmatch $patronSupExtraido })

    # Parejas VobSub .idx/.sub: al pasarle el .idx, mkvmerge toma su .sub automáticamente.
    # Si metiéramos también el .sub como input separado, la pista saldría duplicada.
    $archivosExternos = @($archivosExternos | Where-Object {
        -not ($_.Extension -match "(?i)^\.sub$" -and (Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($_.FullName, ".idx"))))
    })

    # SRT: cada archivo solo recoge SUS propios SRT (los que empiezan por su nombre). Los SRT de
    # otros archivos del lote se descartan aquí para no mezclarlos (modo serie).
    if ($prefijoSrtPropio) {
        $prefijoEsc = [regex]::Escape($prefijoSrtPropio)
        $archivosExternos = @($archivosExternos | Where-Object {
            if ($_.Name -match $patronSrtPgsGenerico) {
                return ($_.Name -match "(?i)^${prefijoEsc}_sub_\d+_[a-z]{2,3}\.srt$")
            }
            return $true
        })
    }
    # NOTA: en AMBAS opciones (CONSERVAR_PGS y ELIMINAR_PGS) los SRT convertidos SÍ entran al MKV.
    # La diferencia entre opciones es si se conservan o no los PGS INTERNOS del MKV, lo cual se
    # gestiona fuera (filtro de pistas internas tipo PGS según $decisionPGS).
    foreach ($ext in $archivosExternos) {
        $miExt = Get-MediainfoJson $ext.FullName
        $pExt = $null
        if ($miExt) { $pExt = $miExt.media.track | Where-Object { $_.'@type' -match "Audio|Text" } | Select-Object -First 1 }

        # Bug 7: detección de tipo más fiable
        $tipoPista = Get-TipoPistaExterno $ext $pExt
        if (-not $tipoPista) { 
            Write-Host "   [!] Externo no clasificable, ignorando: $($ext.Name)" -ForegroundColor DarkYellow
            continue 
        }

        $langCode = if ($pExt) { $pExt.Language } else { "" }
        $llaveMemoria = "Externo_$($ext.FullName)"
        if ($memoriaIdiomas.ContainsKey($llaveMemoria)) { $langCode = $memoriaIdiomas[$llaveMemoria] } 
        elseif ([string]::IsNullOrWhiteSpace($langCode) -or $langCode -eq "und") {
            if     ($ext.Name -match "(?i)(?<![a-z])(latino|latam|lat)(?![a-z])")           { $langCode = "es-419" }
            elseif ($ext.Name -match "(?i)(?<![a-z])(spa|es|castellano|cast)(?![a-z])")     { $langCode = "es" }
            elseif ($ext.Name -match "(?i)(?<![a-z])(eng|en|ingles|english)(?![a-z])")      { $langCode = "eng" }
            elseif ($ext.Name -match "(?i)(?<![a-z])(fre|fr|frances|french)(?![a-z])")      { $langCode = "fre" }
            else { $langCode = "und" }
        }
        # Patrón de los EAC3 generados por el propio script: "<nombre del video>_audio_<lang>.eac3".
        # También soportamos los formatos antiguos por compatibilidad: audio_<lang>_temp/final.eac3.
        # Extraemos el código de idioma (códigos cortos spa/eng o compuestos es-419).
        if ($ext.Name -match "(?i)_audio_([a-z]{2,3}(?:-[a-z0-9]{2,3})?)\.eac3$") { $langCode = $Matches[1].ToLower() }
        elseif ($ext.Name -match "(?i)audio_([a-z]{2,3}(?:-[a-z0-9]{2,3})?)_(temp|final)") { $langCode = $Matches[1].ToLower() }

        # Title del externo (mediainfo). Sirve para detectar Latino si el código es solo "es"
        $tituloExt = if ($pExt) { "$($pExt.Title)" } else { "" }
        $langCode = Get-LanguageCode $langCode $tituloExt

        # Bug 8: flag de mediainfo en externos también
        $forcedFlag = $false
        if ($pExt -and $pExt.PSObject.Properties.Name -contains "Forced") {
            if ("$($pExt.Forced)" -match "(?i)yes|1|true") { $forcedFlag = $true }
        }
        # Heurística adicional: si el nombre del archivo contiene "forced" o "forzado", asumimos forzado real
        if ($ext.Name -match "(?i)\b(forced|forzado|forzados)\b") { $forcedFlag = $true }
        # Y si el Title (de mediainfo) lo indica también
        if ($tituloExt -match "(?i)(forced|forzado|forzados)") { $forcedFlag = $true }
        # SDH en externos: ServiceKind=HI, Title o nombre del archivo (p. ej. "pelicula.es.sdh.srt").
        $sdhFlagExt = ($pExt -and "$($pExt.ServiceKind)" -match '(?i)\bHI\b') -or ($tituloExt -match $patronTituloSdh) -or
                      ($ext.BaseName -match '(?i)(?<![a-z])(sdh|cc|sordos)(?![a-z])')   # "hi" no: es el código de hindi

        $pistasBrutas += [PSCustomObject]@{
            Origen = "Externo"; ID = $ext.FullName; Tipo = $tipoPista
            ArchivoFuenteMkv = $null   # los externos no vienen de un MKV
            CodLang = $langCode; NomLang = (Get-LanguageName $langCode $tituloExt); PesoLang = Get-PesoIdioma (Get-LanguageName $langCode $tituloExt)
            Format  = if ($pExt) { $pExt.Format } else { $ext.Extension.Trim('.') }
            Profile = if ($pExt) { $pExt.Format_Profile } else { "" }
            Comm    = if ($pExt) { $pExt.Format_Commercial_IfAny } else { "" }
            Chan    = if ($pExt) { $pExt.Channels } else { "" }
            Size    = if ($pExt -and $pExt.StreamSize) { [long]$pExt.StreamSize } elseif ($ext.Length) { [long]$ext.Length } else { 0 }
            IsForced = $false; MediainfoForcedFlag = $forcedFlag; NomFinal = ""
            SdhFlag = [bool]$sdhFlagExt
            NombreExterno = $ext.Name
        }
    }

    # Filtro de idiomas de subtítulos (cuando hay >3 idiomas y el usuario eligió recortar).
    # Se aplica sobre TODAS las pistas de subtítulos (internas + externas), antes de devolver.
    # Quitar un idioma elimina TODO de ese idioma (forzados y completos). Los audios no se tocan.
    if ($idiomasSubsMantener) {
        $antes = @($pistasBrutas | Where-Object { $_.Tipo -eq "Sub" }).Count
        if ($idiomasSubsMantener -contains "__CAST_ENG__") {
            # Mantener solo castellano (es) e inglés (eng). Nota: NO incluye latino (es-419) a propósito.
            $pistasBrutas = @($pistasBrutas | Where-Object {
                $_.Tipo -ne "Sub" -or $_.CodLang -in @("es", "eng")
            })
        } else {
            # Lista explícita de códigos a mantener
            $pistasBrutas = @($pistasBrutas | Where-Object {
                $_.Tipo -ne "Sub" -or $_.CodLang -in $idiomasSubsMantener
            })
        }
        $despues = @($pistasBrutas | Where-Object { $_.Tipo -eq "Sub" }).Count
        if ($antes -ne $despues) {
            Write-Host "   [filtro idiomas subs] Subs: $antes -> $despues (eliminados $($antes - $despues) de idiomas no seleccionados)" -ForegroundColor DarkGray
        }
    }

    # Filtro de idiomas de AUDIO (remezcla, temporada homogénea o decisión por película).
    # Lista de códigos de idioma a conservar; quita el resto. No toca los subtítulos.
    if ($idiomasAudioMantener -and @($idiomasAudioMantener).Count -gt 0) {
        # La selección llega desde ffprobe/GUI y las pistas desde MediaInfo. Canonizamos
        # también la selección para admitir configuraciones antiguas que guarden "th".
        $idiomasAudioCanon = @($idiomasAudioMantener | ForEach-Object {
            Get-LanguageCode "$_" ""
        } | Where-Object { $_ } | Select-Object -Unique)
        $antesA = @($pistasBrutas | Where-Object { $_.Tipo -eq "Audio" }).Count
        $pistasBrutas = @($pistasBrutas | Where-Object { $_.Tipo -ne "Audio" -or $_.CodLang -in $idiomasAudioCanon })
        $despuesA = @($pistasBrutas | Where-Object { $_.Tipo -eq "Audio" }).Count
        if ($antesA -ne $despuesA) {
            Write-Host "   [filtro idiomas audio] Audios: $antesA -> $despuesA (eliminados $($antesA - $despuesA) de idiomas no seleccionados)" -ForegroundColor DarkGray
        }
    }

    return @{
        Pistas = $pistasBrutas
        IdVideo = $idVideo
        AltoVideo = $altoVideo
        CodecVideo = $codecVideo
        HdrVideo = $hdrVideo
    }
}

# Ordena audios por idioma + calidad y prepara su nombre comercial
function Format-Audios($audios) {
    foreach ($a in $audios) {
        $pts = 10
        $esDTS = ($a.Format -match "(?i)DTS")
        $esDolby = ($a.Format -match "(?i)E-?AC-?3|AC-?3|TrueHD|MLP" -or $a.Comm -match "(?i)Dolby|Plus|Atmos")
        # Pts = calidad técnica de la pista (Atmos > TrueHD/MA > DTS > DD+ > DD ...)
        if ($a.Comm -match "(?i)Atmos" -or $a.Profile -match "(?i)X")        { $pts = 100 } 
        elseif ($a.Format -match "(?i)TrueHD" -or $a.Profile -match "(?i)MA|Master Audio") { $pts = 90 } 
        elseif ($esDTS)                                                       { $pts = 70 } 
        elseif ($a.Format -match "(?i)E-?AC-?3" -or $a.Comm -match "(?i)Plus" -or $a.Profile -match "(?i)E-?AC-?3") { $pts = 60 } 
        elseif ($a.Format -match "(?i)AC-?3")                                 { $pts = 50 }
        # PtsCalidad = calidad técnica PURA, antes de la demotion de DTS en castellano/latino.
        # La usa el filtro de híbridos para elegir la mejor pista por idioma: con Pts (demotado)
        # un EAC3 convertido (60) "ganaba" al DTS-HD original castellano (40) y lo descartaba.
        $a | Add-Member -NotePropertyName "PtsCalidad" -NotePropertyValue $pts -Force
        if ($a.PesoLang -le 2 -and $esDTS) { $pts = 40 }
        $a | Add-Member -NotePropertyName "Pts" -NotePropertyValue $pts -Force

        # PesoFamilia = orden por familia de códecs. 1 = Dolby (siempre antes), 2 = DTS, 3 = otros.
        # Esto coloca cualquier audio Dolby por encima de cualquier DTS del mismo idioma,
        # independientemente de Pts. Reglamento del usuario.
        $pesoFamilia = 3
        if     ($esDolby) { $pesoFamilia = 1 }
        elseif ($esDTS)   { $pesoFamilia = 2 }
        $a | Add-Member -NotePropertyName "PesoFamilia" -NotePropertyValue $pesoFamilia -Force

        $cStr = switch ("$($a.Chan)") { "8" {"7.1"} "6" {"5.1"} "2" {"2.0"} "1" {"1.0"} default {"$($a.Chan)"} }
        if (-not $cStr) { $cStr = "2.0" }

        # Nombre largo (para mkvpropedit --set name=): formato bonito con espacios
        # P. ej.: "Castellano DD+ 5.1", "Inglés DTS-HD MA 7.1", "Castellano DD+ 5.1 Atmos".
        # Set-Banderas añade el bitrate REAL tras muxear y convertir, no el del origen.
        $codStr = $a.Format
        if ($a.Format -match "(?i)E-?AC-?3" -or $a.Comm -match "(?i)Plus" -or $a.Profile -match "(?i)E-?AC-?3") { $codStr = "DD+" }
        elseif ($a.Format -match "(?i)AC-?3")    { $codStr = "DD" }
        elseif ($a.Format -match "(?i)TrueHD|MLP") { $codStr = "TrueHD" }
        elseif ($a.Format -match "(?i)DTS") {
            # Solo dos casos: DTS-HD MA (cuando profile o commercial-string contienen MA / Master Audio)
            # o DTS a secas (todo lo demás: Core, X, HR, ES, etc.). Decisión del usuario.
            # Importante: miramos también Comm (Format_Commercial_IfAny) porque mediainfo a veces
            # deja Profile vacío y mete la info en Comm (ej. "DTS-HD MA + DTS:X").
            if ($a.Profile -match "(?i)MA|Master Audio" -or $a.Comm -match "(?i)MA|Master Audio") { $codStr = "DTS-HD MA" }
            else { $codStr = "DTS" }
        }
        elseif ($a.Format -match "(?i)AAC") { $codStr = "AAC" }
        elseif ($a.Format -match "(?i)FLAC") { $codStr = "FLAC" }
        elseif ($a.Format -match "(?i)PCM|LPCM") { $codStr = "LPCM" }
        $atm = if ($a.Comm -match "(?i)Atmos" -or $a.Format -match "(?i)Atmos") { " Atmos" } else { "" }
        $a.NomFinal = "$($a.NomLang) $codStr $cStr$atm"
    }
    # Orden final: 1) idioma (PesoLang), 2) familia Dolby antes que DTS (PesoFamilia), 3) calidad (Pts desc)
    return ,@($audios | Sort-Object PesoLang, PesoFamilia, @{Expression={$_.Pts}; Descending=$true})
}

# Ordena subtítulos detectando forzados con flag de mediainfo + heurística (Bug 8)
function Format-Subs($subs, $rutaMkvOrigen = $null, $decisionesSubUnico = $null) {
    Set-FlagForzados $subs $rutaMkvOrigen $decisionesSubUnico
    Set-FlagSdh $subs
    $subsF = @(); $orden = 0
    foreach ($s in $subs) {
        $tStr = if ($s.IsForced) { "Forzados" } elseif ($s.EsSDH) { "SDH" } else { "Completos" }
        $fStr = if ($s.Format -match "(?i)srt|subrip|ass|ssa|utf-?8|text") { "Planos" } else { "PGS" }
        $s.NomFinal = "$($s.NomLang) $tStr $fStr"
        $s | Add-Member -NotePropertyName "FmtPeso" -NotePropertyValue (Get-PesoFormatoSub $fStr) -Force
        $s | Add-Member -NotePropertyName "TipoSub" -NotePropertyValue $tStr -Force
        $s | Add-Member -NotePropertyName "FmtSub" -NotePropertyValue $fStr -Force
        $s | Add-Member -NotePropertyName "OrdenOrigen" -NotePropertyValue ($orden++) -Force
        $subsF += $s
    }
    $subsF = Select-SubsPorTipo $subsF (Get-CfgGui "TiposSubsMantener")
    # Dentro de un idioma: forzados, completos y SDH al final; empates en orden de origen.
    return ,@($subsF | Sort-Object FmtPeso, PesoLang, @{Expression={$_.IsForced}; Descending=$true}, EsSDH, OrdenOrigen)
}

# Ensambla el MKV final con mkvmerge
function Invoke-Ensamblaje($archivoPrincipal, $origenesPistas, $esHibrido, $videoA_Muxear, $idVideo, $audiosOrdenados, $subsOrdenados, $carpetaMux = $null) {
    # mkvmerge escribe directamente en la carpeta de salida: si está en otro disco, se evita copiar
    # después el MKV entero (decenas de GB) y además se lee de un disco mientras se escribe en otro.
    $dirMux = if ($carpetaMux) { $carpetaMux } else { $rutaCarpeta }
    $archivoSalidaTemporal = Join-Path $dirMux "Ensamblaje_$([guid]::NewGuid().ToString('N')).mkv"
    $argsMkv = @("-o", $archivoSalidaTemporal, "--no-global-tags", "--gui-mode")

    $listaArchivos = @($origenesPistas)

    # ID de la pista de vídeo en el archivo que realmente la aporta: en híbrido el input 0 es
    # el HEVC fusionado, cuya ÚNICA pista es siempre la 0 ($idVideo es el ID en el MKV origen
    # y no aplica ahí; solo coincidía cuando el vídeo era casualmente la pista 0 del origen).
    $idVideoSalida = if ($esHibrido) { 0 } else { $idVideo }

    # Pre-cálculo: para cada MKV de origen, qué track-IDs (audio y sub) sobreviven a la deduplicación.
    # mkvmerge incluye TODAS las pistas de cada input por defecto; si no le pasamos -a/-s explícitos,
    # se cuelan pistas duplicadas o no deseadas. Por tanto construimos los filtros aquí.
    $audiosPorMkv = @{}   # path → lista de IDs de audio a incluir
    $subsPorMkv   = @{}   # path → lista de IDs de sub a incluir
    foreach ($mkv in $listaArchivos) {
        $audiosPorMkv[$mkv] = @()
        $subsPorMkv[$mkv]   = @()
    }
    foreach ($a in $audiosOrdenados) {
        if ($a.Origen -eq "Interno" -and $audiosPorMkv.ContainsKey($a.ArchivoFuenteMkv)) {
            $audiosPorMkv[$a.ArchivoFuenteMkv] += $a.ID
        }
    }
    foreach ($s in $subsOrdenados) {
        if ($s.Origen -eq "Interno" -and $subsPorMkv.ContainsKey($s.ArchivoFuenteMkv)) {
            $subsPorMkv[$s.ArchivoFuenteMkv] += $s.ID
        }
    }

    # Mapa: path absoluto → índice de archivo en mkvmerge.
    # En híbrido, el video viene del archivo fusionado (índice 0) y las pistas no-video de los MKV
    # originales (índices 1, 2, ...). En no-híbrido, el primer MKV es índice 0.
    $archMapeados = @{}
    if ($esHibrido) {
        # 0 = video fusionado HEVC
        $archMapeados[$videoA_Muxear] = 0
        $idxFile = 1
        foreach ($mkv in $listaArchivos) {
            if (-not $archMapeados.ContainsKey($mkv)) {
                $archMapeados[$mkv] = $idxFile
                $idxFile++
            }
        }
    } else {
        # No híbrido: índice 0 = primer archivo (aporta el vídeo). En REMEZCLA hay más archivos
        # (audio/subs de otras carpetas) que TAMBIÉN deben mapearse 1,2,… para el track-order.
        $idxFile = 0
        foreach ($mkv in $listaArchivos) { if (-not $archMapeados.ContainsKey($mkv)) { $archMapeados[$mkv] = $idxFile; $idxFile++ } }
    }

    $trackOrder = @("0:$idVideoSalida")
    $argsMkv += "--default-track-flag", "$($idVideoSalida):1"

    # Construye los argumentos -a/-s/-A/-S para un MKV concreto. Si la lista de IDs está vacía,
    # se usa -A/-S (no incluir ninguna pista de ese tipo). Si tiene IDs, se pasa -a 1,2,3.

    if ($esHibrido) {
        # Bug 5: detectar fps real en lugar de hardcodear 23.976
        # Usamos el primer archivo de la lista (el preferente) como referencia del fps
        $fpsReal = Get-FpsReal $listaArchivos[0]
        if ($fpsReal) {
            $argsMkv += "--default-duration"; $argsMkv += "0:${fpsReal}fps"
            Write-Host "   -> FPS detectado para video fusionado: $fpsReal" -ForegroundColor DarkGray
        } else {
            Write-Host "   [!] No se pudo detectar el fps real; mkvmerge usará el del header." -ForegroundColor DarkYellow
        }
        # Input 0: el video fusionado HEVC (no aporta audios/subs, pero con -A -S por seguridad)
        $argsMkv += "-A"; $argsMkv += "-S"
        $argsMkv += $videoA_Muxear
        # Inputs 1..N: cada MKV de origen sin video, con filtros explícitos de qué audios/subs incluir
        foreach ($mkv in $listaArchivos) {
            $argsMkv += "--no-video"
            $audIds = $audiosPorMkv[$mkv]
            $subIds = $subsPorMkv[$mkv]
            if ($audIds.Count -gt 0) { $argsMkv += "-a"; $argsMkv += ($audIds -join ",") }
            else                     { $argsMkv += "-A" }
            if ($subIds.Count -gt 0) { $argsMkv += "-s"; $argsMkv += ($subIds -join ",") }
            else                     { $argsMkv += "-S" }
            $argsMkv += $mkv
        }
    } else {
        # No híbrido. Input 0 = archivo de vídeo (conserva su vídeo; sus audios/subs solo si el filtro
        # los dejó). En REMEZCLA, inputs 1+ = las otras carpetas (--no-video) con sus audios/subs.
        for ($fi = 0; $fi -lt $listaArchivos.Count; $fi++) {
            $mkv = $listaArchivos[$fi]
            if ($fi -gt 0) { $argsMkv += "--no-video" }
            $audIds = $audiosPorMkv[$mkv]
            $subIds = $subsPorMkv[$mkv]
            if ($audIds.Count -gt 0) { $argsMkv += "-a"; $argsMkv += ($audIds -join ",") }
            else                     { $argsMkv += "-A" }
            if ($subIds.Count -gt 0) { $argsMkv += "-s"; $argsMkv += ($subIds -join ",") }
            else                     { $argsMkv += "-S" }
            $argsMkv += $mkv
        }
    }

    # Externos (audio/sub) van al final, cada uno como input separado
    $externosAUsar = @($audiosOrdenados) + @($subsOrdenados) | Where-Object { $_.Origen -eq "Externo" }
    foreach ($e in $externosAUsar) {
        if (-not $archMapeados.ContainsKey($e.ID)) { $archMapeados[$e.ID] = $idxFile; $idxFile++ }
        $argsMkv += $e.ID
    }

    # Construir el track-order: para cada pista, su input-index y su track-id dentro del input.
    foreach ($a in $audiosOrdenados) { 
        if ($a.Origen -eq "Interno") {
            $tId = $a.ID
            $llaveA = $a.ArchivoFuenteMkv
        } else {
            $tId = 0
            $llaveA = $a.ID   # path del externo
        }
        $trackOrder += "$($archMapeados[$llaveA]):$tId" 
    }
    foreach ($s in $subsOrdenados) { 
        if ($s.Origen -eq "Interno") {
            $tId = $s.ID
            $llaveS = $s.ArchivoFuenteMkv
        } else {
            $tId = 0
            $llaveS = $s.ID
        }
        $trackOrder += "$($archMapeados[$llaveS]):$tId" 
    }

    $argsMkv += "--track-order"; $argsMkv += ($trackOrder -join ",")

    # Volcado al log del comando completo de mkvmerge ANTES de ejecutarlo.
    # Así, si algo falla a mitad o el archivo queda mal, tenemos la línea de invocación exacta.
    Write-DiagComandoMkvmerge $argsMkv

    Write-Host "   -> Muxeando archivo temporal..." -ForegroundColor Gray
    Write-DiagPaso "mkvmerge: INICIO"
    # Capturamos toda la salida (no solo el progreso) por si mkvmerge falla.
    # Las líneas que coincidan con #GUI#progress se usan para la barra; el resto se acumula
    # como mensajes de mkvmerge para diagnóstico.
    $salidaMkv = New-Object System.Collections.Generic.List[string]
    Set-ProgresoGui2 0 "Ensamblando $($archivoPrincipal.BaseName)"   # arranca la 2ª barra de la GUI
    $ultPctMkv = -1
    & mkvmerge @argsMkv 2>&1 | ForEach-Object {
        $linea = "$_"
        if ($linea -match "#GUI#progress (\d+)%") {
            $porcentaje = [int]$Matches[1]
            Write-Progress -Activity "Ensamblando MKV con mkvmerge" -Status "Completado: $porcentaje%" -PercentComplete $porcentaje
            # 2ª barra de la GUI: solo escribimos cuando cambia el entero (evita E/S de más).
            if ($porcentaje -ne $ultPctMkv) { Set-ProgresoGui2 $porcentaje "Ensamblando $($archivoPrincipal.BaseName)"; $ultPctMkv = $porcentaje }
        } else {
            $salidaMkv.Add($linea)
        }
    }
    $codigoMkv = $LASTEXITCODE
    Write-DiagPaso "mkvmerge: FIN (exit=$codigoMkv)"
    Write-Progress -Activity "Ensamblando MKV con mkvmerge" -Completed
    Set-ProgresoGui2 -1   # oculta la 2ª barra al terminar el ensamblado

    # Volcado al log de la salida completa de mkvmerge (siempre, no solo cuando falla).
    # Incluye warnings que mkvmerge dé aunque haya generado el archivo OK.
    Write-DiagRaw "[mkvmerge] --- Código de salida: $codigoMkv ---"
    Write-DiagRaw "[mkvmerge] --- Salida completa ---"
    foreach ($l in $salidaMkv) {
        if (-not [string]::IsNullOrWhiteSpace($l)) { Write-DiagRaw "[mkvmerge] $l" }
    }

    # Códigos de salida de mkvmerge: 0 = OK, 1 = terminó CON AVISOS (el archivo se genera
    # igualmente y suele ser válido), 2 = error real. Antes el código 1 se trataba como fatal:
    # se descartaba un muxeo correcto y se dejaba el temporal "Ensamblaje_*.mkv" huérfano en
    # la carpeta (que la siguiente ejecución trataría como un vídeo de entrada más).
    if (-not (Test-Path -LiteralPath $archivoSalidaTemporal) -or $codigoMkv -ge 2) {
        Write-Host "`n[!] ERROR CRÍTICO: mkvmerge falló (código $codigoMkv) y no generó el archivo final." -ForegroundColor Red
        Write-Host "   -> Detalles en el log." -ForegroundColor DarkRed
        Remove-Item -LiteralPath $archivoSalidaTemporal -ErrorAction SilentlyContinue
        return $null
    }
    if ($codigoMkv -eq 1) {
        Write-Host "   [!] mkvmerge terminó con avisos (código 1). El archivo se generó; detalles en el log." -ForegroundColor DarkYellow
        Add-Incidencia $global:archivoEnCurso "mkvmerge emitió avisos durante el muxeo (código 1). El archivo se generó igualmente; revisar el log."
    }
    return $archivoSalidaTemporal
}

# Aplica banderas de pista (default/forced/idioma/nombre) al MKV ya muxeado.
# $defaultPreferidoAudio: "DOLBY" o "DTS". Cuando el idioma prioritario tiene ambos,
# el flag default va a la pista de la familia elegida (sin cambiar el orden de pistas).
function Set-Banderas($archivoMkv, $audiosOrdenados, $subsOrdenados, $defaultPreferidoAudio = "DOLBY") {
    # Leer ANTES de borrar las etiquetas: mkvmerge acaba de escribir las estadísticas
    # de cada pista, incluidas las externas/convertidas, en el orden definitivo.
    # No usar el bitrate de la película, una pista anterior ni el ajuste del encoder.
    $cacheMediainfo.Remove($archivoMkv) | Out-Null
    $audioInfo = @((Get-MediainfoJson $archivoMkv).media.track | Where-Object { $_.'@type' -eq 'Audio' })
    for ($audioIndex = 0; $audioIndex -lt $audiosOrdenados.Count; $audioIndex++) {
        $trackInfo = if ($audioInfo.Count -eq $audiosOrdenados.Count) { $audioInfo[$audioIndex] } else { $null }
        $audiosOrdenados[$audioIndex].NomFinal = Add-HdzAudioBitrateToName $audiosOrdenados[$audioIndex].NomFinal $trackInfo
        Write-DiagLinea "Nombre audio final #$($audioIndex + 1): $($audiosOrdenados[$audioIndex].NomFinal)"
    }
    # Bug 9: Invoke-Mkvpropedit captura errores
    Invoke-Mkvpropedit @($archivoMkv, "--tags", "all:", "--delete", "title") "borrar título global" | Out-Null
    Invoke-Mkvpropedit @($archivoMkv, "--edit", "track:v1", "--set", "flag-default=1", "--set", "flag-forced=0") "video por defecto" | Out-Null

    # Determinar qué pista de audio (índice 1-based) lleva el flag default.
    # Por defecto es la primera (idioma prioritario + Dolby por orden). Pero si el usuario
    # eligió "DTS" y el idioma prioritario tiene una pista DTS, el default va a esa pista DTS.
    $idxDefault = 1
    if ($audiosOrdenados.Count -gt 0) {
        $pesoMinAud = ($audiosOrdenados | Measure-Object PesoLang -Minimum).Minimum
        if ($defaultPreferidoAudio -eq "DTS") {
            for ($k = 0; $k -lt $audiosOrdenados.Count; $k++) {
                if ($audiosOrdenados[$k].PesoLang -eq $pesoMinAud -and $audiosOrdenados[$k].Format -match "(?i)DTS") {
                    $idxDefault = $k + 1
                    break
                }
            }
        } else {
            # DOLBY: primera pista del idioma prioritario que sea Dolby (normalmente la #1)
            for ($k = 0; $k -lt $audiosOrdenados.Count; $k++) {
                $a = $audiosOrdenados[$k]
                $esDolby = ($a.Format -match "(?i)E-?AC-?3|AC-?3|TrueHD|MLP" -or $a.Comm -match "(?i)Dolby|Plus|Atmos")
                if ($a.PesoLang -eq $pesoMinAud -and $esDolby) {
                    $idxDefault = $k + 1
                    break
                }
            }
        }
    }

    for ($i=1; $i -le $audiosOrdenados.Count; $i++) {
        $isDef = if ($i -eq $idxDefault) { 1 } else { 0 }
        $langVal = if ([string]::IsNullOrWhiteSpace($audiosOrdenados[$i-1].CodLang)) { "und" } else { $audiosOrdenados[$i-1].CodLang }
        Invoke-Mkvpropedit @(
            $archivoMkv, "--edit", "track:a$i",
            "--set", "name=$($audiosOrdenados[$i-1].NomFinal)",
            "--set", "language=$langVal",
            "--set", "flag-default=$isDef"
        ) "audio #$i" | Out-Null
    }

    $forzActivo = $false
    for ($i=1; $i -le $subsOrdenados.Count; $i++) {
        $s = $subsOrdenados[$i-1]
        # flag-forced va en TODOS los subs realmente forzados (es metadato de la pista, también
        # en otros idiomas; antes solo lo recibía el primero y el resto quedaba con forced=0).
        # flag-default solo en el primero: es el que el reproductor debe autoseleccionar.
        $isF = if ($s.IsForced) { 1 } else { 0 }
        $isDef = if ($s.IsForced -and -not $forzActivo) { $forzActivo = $true; 1 } else { 0 }
        $isH = if ($s.EsSDH -and -not $s.IsForced) { 1 } else { 0 }
        $langVal = if ([string]::IsNullOrWhiteSpace($s.CodLang)) { "und" } else { $s.CodLang }
        Invoke-Mkvpropedit @(
            $archivoMkv, "--edit", "track:s$i",
            "--set", "name=$($s.NomFinal)",
            "--set", "language=$langVal",
            "--set", "flag-forced=$isF",
            "--set", "flag-default=$isDef",
            "--set", "flag-hearing-impaired=$isH"
        ) "sub #$i" | Out-Null
    }
}

# Genera capturas a partir del MKV final.
# Si el vídeo es HDR ($esHdr=$true), aplica tonemapping para que la captura se vea bien en SDR.
# Si es SDR, hace una captura directa (sin tonemap, que falsearía los colores).
function New-Capturas($archivoFinalDestino, $nombreFinal, $numCapturas, $esHdr = $true, $dirCapturas = $null) {
    # Adaptador de la GUI al núcleo compartido. El algoritmo vive únicamente en
    # HDZ-Capturas.ps1 para que el menú contextual y HDZ Studio sean idénticos.
    $global:ultimasCapturas = @()
    if ($numCapturas -le 0) { return }

    try {
    $res = New-HdzCapturas -ArchivoVideo $archivoFinalDestino -NombreFinal $nombreFinal `
        -NumCapturas $numCapturas -EsHdr ([bool]$esHdr) -DirCapturas $dirCapturas `
        -OnProgress {
            param($pct, $fase)
            Set-ProgresoGui2 ([int]$pct) "$fase"
        } `
        -OnDiagnostic {
            param($texto)
            Write-DiagPaso "$texto"
        } `
        -OnIncident {
            param($archivo, $mensaje)
            Add-Incidencia "$archivo" "$mensaje"
        }

    $global:ultimasCapturas = @($res.Capturas)
    foreach ($rutaCaptura in @($res.Capturas)) { $global:capturasLote += $rutaCaptura }
    } catch {
        # Las capturas son opcionales: su destino o FFmpeg pueden fallar sin invalidar
        # el MKV ya verificado. No saltar el torrent, el historial ni el resto del lote.
        $mensaje = "No se pudieron generar las capturas: $($_.Exception.Message). El MKV está creado; se continúa con el torrent si está solicitado."
        Write-Host "   [!] $mensaje" -ForegroundColor Yellow
        Add-Incidencia $global:archivoEnCurso $mensaje
    } finally {
        Set-ProgresoGui2 -1   # limpiar también cuando falla la preparación del destino
    }
}

# Lee mediainfo del archivo MKV final ya muxeado y devuelve los componentes técnicos
# que se van a usar en el nombre del archivo: resolución, HDR detallado, códec de video
# y descripción del audio principal (códec + canales + Atmos opcional).
# Esto garantiza que el nombre refleja exactamente lo que el archivo final contiene,
# en lugar de inferirlo del archivo de origen (que en híbridos DV+HDR10+ puede no
# tener toda la metadata combinada).
function Get-DatosTecnicosMkv($rutaMkv) {
    $resultado = [PSCustomObject]@{
        Resolucion  = ""             # Sin datos no inventamos una resolución HD.
        CodecVideo  = "264"        # "264", "265" o "AV1"
        HdrVideo    = ""           # ej: "DV HDR10+", "HDR10", "DV", ...
        AudioPista  = ""           # ej: "DD+ 5.1", "TrueHD 7.1 Atmos", "DTS-HD MA 5.1"
    }

    $json = Get-MediainfoJson $rutaMkv
    if (-not $json) { return $resultado }

    # --- VIDEO ---
    $pistaVideo = $json.media.track | Where-Object { $_.'@type' -eq 'Video' } | Select-Object -First 1
    if ($pistaVideo) {
        # Resolución
        $resultado.Resolucion = Get-HdzVideoResolution $pistaVideo

        # Códec de video
        $fmt = "$($pistaVideo.Format)"
        $resultado.CodecVideo = if     ($fmt -match "(?i)AV1")              { "AV1" }
                                elseif ($fmt -match "(?i)HEVC|H\.?265")     { "265" }
                                elseif ($fmt -match "(?i)AVC|H\.?264")      { "264" }
                                else { "264" }

        # HDR: leemos el campo HDR_Format que en el archivo final ya combina la info de DV + HDR10/HDR10+
        $hdrStr = "$($pistaVideo.HDR_Format) $($pistaVideo.HDR_Format_Compatibility) $($pistaVideo.HDR_Format_String)"
        $arrH = @()
        if ($hdrStr -match "(?i)Dolby Vision") { $arrH += "DV" }
        if     ($hdrStr -match "(?i)HDR10\+|SMPTE ST 2094 App 4") { $arrH += "HDR10+" }
        elseif ($hdrStr -match "(?i)HDR10")                       { $arrH += "HDR10" }

        # Detección secundaria por espacio de color cuando HDR_Format no está disponible.
        # Muchos encodes AV1 (fastflix, etc.) conservan BT.2020 + PQ + 10 bits pero no incluyen
        # los metadatos SMPTE ST 2086 que mediainfo necesita para rellenar HDR_Format.
        # Si vemos BT.2020 + PQ/SMPTE ST 2084 + >=10 bits, es HDR10 estándar.
        if ($arrH.Count -eq 0) {
            $primarias = "$($pistaVideo.colour_primaries)"
            $transferencia = "$($pistaVideo.transfer_characteristics)"
            $profBits = 0
            if ($pistaVideo.BitDepth) { $profBits = [int]"$($pistaVideo.BitDepth)" }
            if ($primarias -match "(?i)BT\.?2020" -and $transferencia -match "(?i)PQ|SMPTE ST 2084|ST 2084" -and $profBits -ge 10) {
                $arrH += "HDR10"
            }
        }

        $resultado.HdrVideo = $arrH -join " "
    }

    # --- AUDIO PRINCIPAL: la primera pista de audio del archivo final (ya viene ordenada por Format-Audios) ---
    $pistaAudio = $json.media.track | Where-Object { $_.'@type' -eq 'Audio' } | Select-Object -First 1
    if ($pistaAudio) {
        # Canales
        $cStr = switch ("$($pistaAudio.Channels)") { "8" {"7.1"} "6" {"5.1"} "2" {"2.0"} "1" {"1.0"} default { "$($pistaAudio.Channels)" } }
        if (-not $cStr) { $cStr = "2.0" }

        # Códec comercial (mismo razonamiento que Format-Audios pero releyendo del final)
        $fmtA   = "$($pistaAudio.Format)"
        $profA  = "$($pistaAudio.Format_Profile)"
        $commA  = "$($pistaAudio.Format_Commercial_IfAny)"
        $featA  = "$($pistaAudio.Format_AdditionalFeatures)"

        $codStr = $fmtA
        if     ($fmtA -match "(?i)E-?AC-?3" -or $commA -match "(?i)Plus" -or $profA -match "(?i)E-?AC-?3") { $codStr = "DD+" }
        elseif ($fmtA -match "(?i)AC-?3")         { $codStr = "DD" }
        elseif ($fmtA -match "(?i)TrueHD|MLP")    { $codStr = "TrueHD" }
        elseif ($fmtA -match "(?i)DTS") {
            # Solo dos casos: DTS-HD MA (cuando profile o commercial-string contienen MA / Master Audio)
            # o DTS a secas (todo lo demás: Core, X, HR, ES, etc.). Decisión del usuario.
            # Importante: miramos también Comm porque mediainfo a veces deja Profile vacío
            # y mete la info en Comm (ej. "DTS-HD MA + DTS:X").
            if ($profA -match "(?i)MA|Master Audio" -or $commA -match "(?i)MA|Master Audio") { $codStr = "DTS-HD MA" }
            else { $codStr = "DTS" }
        }
        elseif ($fmtA -match "(?i)AAC")           { $codStr = "AAC" }
        elseif ($fmtA -match "(?i)FLAC")          { $codStr = "FLAC" }
        elseif ($fmtA -match "(?i)PCM|LPCM")      { $codStr = "LPCM" }

        $atm = if ($commA -match "(?i)Atmos" -or $fmtA -match "(?i)Atmos") { " Atmos" } else { "" }
        $resultado.AudioPista = "$codStr $cStr$atm"
    }

    return $resultado
}

# =========================================================================
# CREACIÓN DE TORRENTS: las funciones (New-TorrentNucleo/Archivo/Pack) viven en el
# módulo compartido HDZ-Torrent.ps1, que también usa la GUI, para no duplicar el
# formato bencode. Se carga aquí.
# =========================================================================
. (Join-Path $PSScriptRoot "HDZ-Torrent.ps1")

# =========================================================================
# FASE 1: ESCANEO INICIAL Y CUESTIONARIO GLOBAL
# =========================================================================
try { Clear-Host } catch {}   # en hosts sin consola interactiva Clear-Host lanza excepción
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "       LÍNEA DE MONTAJE HDZ INICIADA     " -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Log: $rutaLog" -ForegroundColor DarkGray

Write-Host "`nComprobando entorno..." -ForegroundColor DarkGray
# D7: incluimos dovi_tool y mediainfo en el check (mediainfo ya estaba; dovi_tool faltaba)
if (-not (Test-Dependencias @("ffmpeg", "ffprobe", "mediainfo", "mkvmerge", "mkvpropedit", "mkvextract", "dovi_tool"))) {
    Write-Host "Instala las herramientas que faltan en el PATH." -ForegroundColor Yellow
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

# Volcado inicial al log: entorno completo del sistema y contenido de la carpeta.
# No se muestra en pantalla (Write-Verbose en transcript), pero permite diagnosticar
# diferencias entre máquinas o detectar archivos externos inesperados.
Write-DiagEntorno
Write-DiagCarpeta "CARPETA AL INICIO"

# =========================================================================
# REMEZCLA MANUAL: el usuario elige los archivos exactos y qué aporta cada uno. El archivo marcado
# como Vídeo da la imagen final y los demás aportan solo Audio y/o Subs según sus interruptores. No
# hay emparejado por nombre, idioma o carpeta: se mezclan exactamente las fuentes seleccionadas.
# =========================================================================
$global:remixActivo  = $false
$global:remixFuentes = @{}   # clave -> @(rutas de archivos de audio/subs de otras carpetas)
$global:remixRoles   = @{}   # rutaArchivo -> @{ Audio = bool; Subs = bool }
$global:remixVideoAudio = $false
$global:remixVideoSubs  = $false
$global:remixVideoArchivos = @() # vacío = todos los vídeos de la carpeta de vídeo
$global:remixManual = $false
$global:remixFuentesManual = @()
$global:remixSeriePorEpisodio = $false

$cfgRemezcla = Get-CfgGui "Remezcla"
if ($cfgRemezcla -and $cfgRemezcla.Carpetas) {
    $rzCarpetas = @($cfgRemezcla.Carpetas | Where-Object { $_ -and "$($_.Ruta)".Trim() -and (Test-Path -LiteralPath "$($_.Ruta)") })
    $rzVideo = @($rzCarpetas | Where-Object { $_.Video }) | Select-Object -First 1
    if ($rzCarpetas.Count -ge 2 -and $rzVideo) {
        # Todas las releases son fuentes válidas, incluidas las que llevan -HDZ.
        $esVidRz = { param($f) ("$($f.Extension)" -match "(?i)\.(mkv|mp4|ts)$") -and ($f.Name -notmatch "(?i)_FINAL") -and ($f.Name -notmatch "(?i)^Ensamblaje_") }
        # La carpeta del vídeo principal es solo el punto de trabajo; el filtro de abajo deja pasar
        # exclusivamente el archivo marcado como Vídeo.
        $rutaCarpeta = "$($rzVideo.Ruta)"
        Set-Location -LiteralPath $rutaCarpeta
        $global:remixSeriePorEpisodio = ("$($cfgRemezcla.Modo)" -eq "SERIE_EPISODIOS")
        if ($global:remixSeriePorEpisodio) {
            # Serie: el título de release NO participa. Solo se admiten capítulos con SxxEyy/1x01,
            # para que un extra o un vídeo sin episodio nunca reciba pistas de otro archivo por error.
            $global:remixVideoArchivos = @(Get-ChildItem -LiteralPath $rzVideo.Ruta -File -ErrorAction SilentlyContinue |
                Where-Object { (& $esVidRz $_) -and ((Get-ClaveRemezcla $_.BaseName) -match '^s\d+e\d+(?:-\d+)*$') } |
                ForEach-Object { $_.FullName })
            if ($global:remixVideoArchivos.Count -eq 0) {
                Write-Host "[Remezcla] Serie por episodios: no se encontraron capítulos con SxxEyy/1x01 en la carpeta de vídeo." -ForegroundColor Red
            }
        }
        if ("$($rzVideo.Archivo)" -and (Test-Path -LiteralPath "$($rzVideo.Archivo)")) { $global:remixVideoArchivos = @("$($rzVideo.Archivo)") }
        $global:remixVideoAudio = [bool]$rzVideo.Audio
        $global:remixVideoSubs  = [bool]$rzVideo.Subs
        $todasManuales = (@($rzCarpetas | Where-Object { "$($_.Archivo)" -and (Test-Path -LiteralPath "$($_.Archivo)") }).Count -eq $rzCarpetas.Count)
        if ($todasManuales) {
            $global:remixManual = $true
            foreach ($c in @($rzCarpetas | Where-Object { -not $_.Video -and ($_.Audio -or $_.Subs) })) {
                $rutaFuente = "$($c.Archivo)"
                $global:remixFuentesManual += $rutaFuente
                $global:remixRoles[$rutaFuente] = @{ Audio = [bool]$c.Audio; Subs = [bool]$c.Subs }
            }
            $global:remixFuentesManual = @($global:remixFuentesManual | Select-Object -Unique)
            Write-Host "[Remezcla] Manual activa. Vídeo: $(Split-Path "$($rzVideo.Archivo)" -Leaf). Fuentes de pistas: $($global:remixFuentesManual.Count)." -ForegroundColor Cyan
        } else {
            # Compatibilidad con planes antiguos que solo guardaban carpetas: se conserva su
            # emparejado histórico por nombre, pero las nuevas filas siempre usan el modo manual.
            foreach ($c in @($rzCarpetas | Where-Object { -not $_.Video -and ($_.Audio -or $_.Subs) })) {
                $ficherosFuente = if ("$($c.Archivo)" -and (Test-Path -LiteralPath "$($c.Archivo)")) { @(Get-Item -LiteralPath "$($c.Archivo)") } else { @(Get-ChildItem -LiteralPath $c.Ruta -File -ErrorAction SilentlyContinue | Where-Object { & $esVidRz $_ }) }
                foreach ($f in @($ficherosFuente | Where-Object { & $esVidRz $_ })) {
                    $k = Get-ClaveRemezcla $f.BaseName
                    if ([string]::IsNullOrWhiteSpace($k) -or ($global:remixSeriePorEpisodio -and $k -notmatch '^s\d+e\d+(?:-\d+)*$')) { continue }
                    if (-not $global:remixFuentes.ContainsKey($k)) { $global:remixFuentes[$k] = @() }
                    $global:remixFuentes[$k] += $f.FullName
                    $global:remixRoles[$f.FullName] = @{ Audio = [bool]$c.Audio; Subs = [bool]$c.Subs }
                }
            }
            $etqRz = if ($global:remixSeriePorEpisodio) { "Serie por episodio SxxEyy" } else { "Plan por carpetas" }
            Write-Host "[Remezcla] $etqRz. Fuentes de audio/subs: $($global:remixFuentes.Count) capítulo(s)/título(s)." -ForegroundColor Cyan
        }
        $global:remixActivo = $true
    } else {
        Write-Host "[Remezcla] Plan incompleto (faltan carpetas o carpeta de video). Se procesa normal." -ForegroundColor DarkYellow
    }
}

# Filtro global de idiomas de AUDIO (remezcla o lote homogéneo). Null = todos.
$global:idiomasAudioMantener = $null
$cfgAudLang = Get-CfgGui "IdiomasAudioMantener"
if ($cfgAudLang) { $global:idiomasAudioMantener = @(@($cfgAudLang) | ForEach-Object { "$_" } | Where-Object { $_ }) }

$todosLosArchivos = @(Get-ChildItem -Include "*.mp4", "*.mkv", "*.ts" -Recurse -Depth 0 | Where-Object { $_.Name -notmatch "_FINAL" -and $_.Name -notmatch "(?i)^Ensamblaje_" })
if ($global:remixActivo -and @($global:remixVideoArchivos).Count -gt 0) {
    $todosLosArchivos = @($todosLosArchivos | Where-Object { $global:remixVideoArchivos -contains $_.FullName })
}
if ($todosLosArchivos.Count -eq 0) {
    Write-Host "No hay vídeos para procesar en la carpeta." -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

# Selección de archivos de la GUI: procesar SOLO los marcados (por nombre de archivo).
$cfgSeleccionGui = Get-CfgGui "ArchivosSeleccionados"
if ($cfgSeleccionGui) {
    $nombresSel = @($cfgSeleccionGui | ForEach-Object { "$_" })
    $antesSel = $todosLosArchivos.Count
    $todosLosArchivos = @($todosLosArchivos | Where-Object { $nombresSel -contains $_.Name })
    Write-Host "[GUI] Selección de archivos: $($todosLosArchivos.Count) de $antesSel (configuración)." -ForegroundColor DarkGray
    if ($todosLosArchivos.Count -eq 0) {
        Write-Host "La selección de la GUI no coincide con ningún archivo de la carpeta." -ForegroundColor Red
        try { Stop-Transcript | Out-Null } catch {}
        exit 1
    }
}

# Agrupamos archivos ignorando etiquetas para encontrar híbridos
# Agrupa archivos del mismo episodio quitando del nombre los marcadores que pueden diferir entre
# las dos versiones del par DV+HDR10 (capa HDR, códec de audio, etiqueta Atmos, formato de plataforma).
# Es case-insensitive y cubre las variaciones más comunes en releases de Apple TV, iTunes, Disney+, etc.
$normalizadorAgrupacion = '(?i)[\._\s\-\(\)]+(Dolby[\._\s\-]Vision|DolbyVision|HDR10\+|HDR10|HDR|DV|2160p|1080p|UHD|WEB[\._\s\-]?DL|Apple[\._\s\-]?TV|iTunes|Disney\+?|Atmos|TrueHD|DTS[\._\s\-]?HD[\._\s\-]?MA|DTS[\._\s\-]?HD|DTS[\._\s\-]?X|DTS|E[\._\s\-]?AC[\._\s\-]?3|EAC3|AC3|DDP\+?|DD\+|DDP|DD|AAC|FLAC|MA|HRA)(?=[\._\s\-\(\)]|$)'
$grupos = @($todosLosArchivos | Group-Object { ($_.BaseName -replace $normalizadorAgrupacion, "") -replace "\s+", " " })

Write-Host "Detectados $($grupos.Count) archivo(s) para procesar." -ForegroundColor Green
$global:totalGruposGui = $grupos.Count
Set-ProgresoGui 2 "Preparando lote" ""

# --- MODO DE LOTE (homogéneo vs heterogéneo) ---
# Si todos los archivos pertenecen al mismo proyecto (típico: episodios de una temporada),
# las preguntas de título/año/origen/etc. se hacen UNA VEZ. Si cada archivo es distinto
# (películas o episodios sueltos sin relación), se preguntan por cada uno.
$modoLote = "HOMOGENEO"
$cfgModoLote = Get-CfgGui "ModoLote"
if ($grupos.Count -gt 1) {
    if ("$cfgModoLote" -in @("HOMOGENEO", "HETEROGENEO")) {
        $modoLote = "$cfgModoLote"
        Write-Host "[GUI] Modo de procesamiento: $modoLote (configuración)." -ForegroundColor DarkGray
    } else {
        $modoLote = Mostrar-Menu "Modo de procesamiento" @(
            @{Nombre="Mismo proyecto para todos (típico: temporada de serie)"; Valor="HOMOGENEO"},
            @{Nombre="Cada archivo es distinto (películas/episodios sueltos)"; Valor="HETEROGENEO"}
        )
    }
} else {
    # Solo hay un archivo (o un grupo). Normalmente es homogéneo. PERO si la GUI mandó HETEROGENEO
    # explícito Y trae identidad POR ARCHIVO para este grupo, hay que RESPETARLO: es un trabajo
    # «por película» de la cola (cada trabajo procesa UNA sola peli con su propia identidad en
    # ProyectoPorArchivo). Si no, el motor caería al título GLOBAL (el de la última pestaña activa)
    # y TODAS las pelis saldrían con el mismo nombre. [bug: todas salían «Vaiana 2»]
    if ("$cfgModoLote" -eq "HETEROGENEO") {
        $cfgPPA = Get-CfgGui "ProyectoPorArchivo"
        $tienePF = $false
        if ($cfgPPA) { foreach ($ff in $grupos[0].Group) { if ($cfgPPA.PSObject.Properties.Name -contains "$($ff.Name)") { $tienePF = $true; break } } }
        if ($tienePF) {
            $modoLote = "HETEROGENEO"
            Write-Host "[GUI] Modo de procesamiento: HETEROGENEO (trabajo por pelicula, identidad propia)." -ForegroundColor DarkGray
        }
    }
    Write-Host "   -> Archivo: $($grupos[0].Group[0].Name)" -ForegroundColor Gray
}

# Datos de proyecto: en modo homogéneo se piden ahora; en heterogéneo, dentro del bucle.
$datosProyectoGlobal = $null
if ($modoLote -eq "HOMOGENEO") {
    $datosProyectoGlobal = Get-DatosProyecto $null
}

# Preguntas que SIEMPRE son globales (no cambian entre archivos)
Write-Host "`n--- OPCIONES GENERALES (aplican a todos) ---" -ForegroundColor Yellow
# La pregunta de PGS se ha movido al bucle: solo se hace si se detectan PGS reales en cada archivo.
$cfgCaps = Get-CfgGui "NumCapturas"
if ($null -ne $cfgCaps) {
    $numCapturas = [int]$cfgCaps
    Write-Host "[GUI] Capturas por archivo: $numCapturas (configuración)." -ForegroundColor DarkGray
} else {
    $numCapturas = Read-Host "Número de capturas finales por archivo (0 para saltar)"
    $numCapturas = if ([int]::TryParse($numCapturas, [ref]$null)) { [int]$numCapturas } else { 0 }
}

# Acción con los originales: BORRAR / PROCESADO (renombrar .procesado) / INTACTO (no tocar).
$accionOriginales = "PROCESADO"
$cfgAccion = Get-CfgGui "AccionOriginales"
$cfgBorrar = Get-CfgGui "BorrarOriginales"
if ("$cfgAccion" -in @("BORRAR", "PROCESADO", "INTACTO")) {
    $accionOriginales = "$cfgAccion"
    Write-Host "[GUI] Originales al terminar: $accionOriginales (configuración)." -ForegroundColor DarkGray
} elseif ($null -ne $cfgBorrar) {
    $accionOriginales = if ([bool]$cfgBorrar) { "BORRAR" } else { "PROCESADO" }   # compat configs antiguas
    Write-Host "[GUI] Originales al terminar: $accionOriginales (configuración)." -ForegroundColor DarkGray
} else {
    $accionOriginales = Mostrar-Menu "¿Qué hacer con los originales al terminar?" @(
        @{Nombre="Borrarlos (Recomendado para ahorrar espacio)"; Valor="BORRAR"},
        @{Nombre="Conservarlos (Añadir .procesado al nombre)"; Valor="PROCESADO"},
        @{Nombre="Mantenerlos intactos (sin cambios)"; Valor="INTACTO"}
    )
}
$borrarOriginales = ($accionOriginales -eq "BORRAR")   # compat con el resto del código

# Cambio 5: ¿añadir el sufijo -HDZ al nombre final?
$cfgSufijo = Get-CfgGui "SufijoHDZ"
if ($null -ne $cfgSufijo) {
    $anadirSufijoHDZ = [bool]$cfgSufijo
    Write-Host "[GUI] Sufijo '-HDZ' en el nombre final: $(if ($anadirSufijoHDZ) { 'Sí' } else { 'No' }) (configuración)." -ForegroundColor DarkGray
} else {
    $respSufijo = Read-Host "`n¿Añadir el sufijo '-HDZ' al nombre final? (S/N)"
    $anadirSufijoHDZ = ($respSufijo -match "^[sS]")
}

# Carpetas de salida elegidas en la GUI (vacías = junto a los vídeos de origen).
#  - CarpetaSalida (sesión): carpeta explícita para el MKV resultado de ESTE montaje.
$carpetaSalidaGui  = "$(Get-CfgGui 'CarpetaSalida')".Trim()
$carpetaTorrentGui = "$(Get-CfgGui 'CarpetaTorrent')".Trim()
# Carpeta para ARCHIVAR los originales «.procesado» + las capturas (ajuste). Se crea UNA SUBCARPETA
# POR PROYECTO (= nombre de la carpeta de trabajo) dentro de ella. NO afecta al MKV resultado, que
# sigue yendo a la carpeta de salida puntual o, si está vacía, junto al origen.
$carpetaProcesados = "$(Get-CfgGui 'CarpetaProcesados')".Trim()
$dirProcesados = if ($carpetaProcesados) { Join-Path $carpetaProcesados (Split-Path $rutaCarpeta -Leaf) } else { "" }
if ($carpetaSalidaGui)  { try { [void][System.IO.Directory]::CreateDirectory($carpetaSalidaGui) }  catch {}; Write-Host "[GUI] Carpeta de salida del archivo: $carpetaSalidaGui" -ForegroundColor DarkGray }
if ($dirProcesados)     { try { [void][System.IO.Directory]::CreateDirectory($dirProcesados) } catch {}; Write-Host "[GUI] Originales .procesado + capturas -> $dirProcesados" -ForegroundColor DarkGray }
if ($carpetaTorrentGui) { try { [void][System.IO.Directory]::CreateDirectory($carpetaTorrentGui) } catch {}; Write-Host "[GUI] Carpeta de salida del torrent: $carpetaTorrentGui" -ForegroundColor DarkGray }

# ¿Crear archivos .torrent? Modos: NO / INDIVIDUAL (uno por archivo) / PACK (uno del
# lote completo, carpeta + multi-file) / AMBOS.
$modoTorrent = "NO"
$torrentAnnounce = ""
$cfgModoTorrent = Get-CfgGui "ModoTorrent"
$cfgTorrentCompat = Get-CfgGui "CrearTorrent"   # compatibilidad con configs antiguas (bool)
if ("$cfgModoTorrent" -in @("NO", "INDIVIDUAL", "PACK", "AMBOS")) {
    $modoTorrent = "$cfgModoTorrent"
    Write-Host "[GUI] Torrents: $modoTorrent (configuración)." -ForegroundColor DarkGray
} elseif ($null -ne $cfgTorrentCompat) {
    $modoTorrent = if ([bool]$cfgTorrentCompat) { "INDIVIDUAL" } else { "NO" }
    Write-Host "[GUI] Torrents: $modoTorrent (configuración)." -ForegroundColor DarkGray
} else {
    $modoTorrent = Mostrar-Menu "¿Crear archivos .torrent de los resultados?" @(
        @{Nombre="No"; Valor="NO"},
        @{Nombre="Sí: uno por archivo"; Valor="INDIVIDUAL"},
        @{Nombre="Sí: un PACK del lote completo (carpeta + torrent multi-archivo)"; Valor="PACK"},
        @{Nombre="Sí: ambos (por archivo y pack)"; Valor="AMBOS"}
    )
}
if ($modoTorrent -ne "NO") {
    $cfgAnn = Get-CfgGui "TorrentAnnounce"
    if ($null -ne $cfgAnn) {
        $torrentAnnounce = "$cfgAnn".Trim()
        Write-Host "[GUI] URL de anuncio tomada de la configuración." -ForegroundColor DarkGray
    } else {
        $torrentAnnounce = Read-Host "   URL de anuncio del tracker (ENTER para omitir)"
        $torrentAnnounce = "$torrentAnnounce".Trim()
    }
}

# Pre-escaneo: ¿hay algún archivo con audio DTS? Si no, ni siquiera preguntamos por la conversión.
Write-Host "`nComprobando si algún archivo tiene audio DTS..." -ForegroundColor DarkGray
$hayDTS = $false
$archivosConDTS = 0
$totalArchivos = ($grupos | ForEach-Object { $_.Group.Count } | Measure-Object -Sum).Sum
$nProc = 0
foreach ($g in $grupos) {
    foreach ($f in $g.Group) {
        $nProc++
        Write-Progress -Activity "Comprobando audio DTS en el lote" -Status "$nProc/$totalArchivos : $($f.Name)" -PercentComplete (($nProc/$totalArchivos)*100)
        Set-ProgresoGui ([int](2 + 2 * $nProc / [Math]::Max(1,$totalArchivos))) "Comprobando audio DTS ($nProc/$totalArchivos)" $f.Name
        $codecs = ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 $f.FullName 2>$null
        if ($codecs -match "(?i)dts") { 
            $hayDTS = $true
            $archivosConDTS++
            break
        }
    }
}
Write-Progress -Activity "Comprobando audio DTS en el lote" -Completed

# La conversión DTS automática se RETIRÓ: ahora el usuario convierte cualquier audio (DTS
# incluido) manualmente desde la GUI («Convertir audio»), que envía ConversionesAudioManual /
# ConversionesPorArchivo. Por eso el modo automático queda SIEMPRE en NUNCA (inerte): la pista
# DTS se conserva tal cual salvo que el usuario pida convertirla.
$modoConversionDTS = "NUNCA"
if ($hayDTS) {
    Write-Host "   -> Detectado audio DTS en $archivosConDTS archivo(s) del lote (conversión ahora es manual desde la GUI)." -ForegroundColor DarkGray
}

# Pre-escaneo de pistas con idioma 'und' (audio y subtítulo): si las hay, preguntar UNA vez
# por tipo a qué idioma corresponden. Va el PRIMERO porque resuelve idiomas que el resto de
# pre-escaneos (filtro de idiomas, subs únicos) van a necesitar ya normalizados.
if ($modoLote -eq "HOMOGENEO") {
    Set-ProgresoGui 4 "Detectando idiomas indeterminados (und)…" ""
    Resolve-IdiomasUndLote $grupos
}

# Pre-escaneo de idiomas de subtítulos: si hay >3 idiomas distintos, preguntar qué mantener.
# Va PRIMERO (antes que el forzado/completo) para no preguntar por subs de idiomas que se
# van a descartar. En HOMOGÉNEO se decide una vez para todo el lote.
$idiomasSubsMantenerGlobal = $null
if ($modoLote -eq "HOMOGENEO") {
    Set-ProgresoGui 6 "Analizando idiomas de subtítulos…" ""
    $idiomasSubsMantenerGlobal = Resolve-IdiomasSubsLote $grupos
}

# Pre-escaneo de subs únicos sin señal de forzado: solo aplica al modo HOMOGÉNEO.
# Se ejecuta DESPUÉS del filtro de idiomas y lo respeta: no pregunta por subs de idiomas
# que ya se van a descartar. En HETEROGÉNEO se preguntará en el bucle, archivo por archivo.
$decisionesSubUnico = @{}
if ($modoLote -eq "HOMOGENEO") {
    $decisionesSubUnico = Resolve-SubsUnicosLote $grupos $idiomasSubsMantenerGlobal
}

# Cambio 2a: ¿algún archivo del lote tiene, en su idioma de mayor prioridad, audio Dolby Y DTS
# a la vez? Si es así, preguntamos cuál de los dos lleva el flag default (la pista por defecto).
# El orden de pistas NO cambia (Dolby siempre va primero); solo cambia a qué pista del idioma
# prioritario se le pone default=1. Si no existe la casuística, no preguntamos.
$defaultPreferidoAudio = "DOLBY"   # valor por defecto si no se pregunta
$existeCasoDolbyDTS = $false
# Decisión pre-elegida en la GUI: si está definida, nos saltamos también el escaneo de la
# casuística Dolby+DTS (solo servía para decidir si hacía falta preguntar).
$cfgDefAudio = Get-CfgGui "DefaultPreferidoAudio"
if ("$cfgDefAudio" -in @("DOLBY", "DTS")) {
    $defaultPreferidoAudio = "$cfgDefAudio"
    Write-Host "[GUI] Pista de audio predeterminada: $defaultPreferidoAudio (configuración)." -ForegroundColor DarkGray
} else {
# La conversión DTS->EAC3 puede CREAR un audio Dolby donde antes solo había DTS. Por eso
# evaluamos la casuística sobre el ESTADO FINAL: para cada idioma miramos qué audios quedarán.
# Regla de conversión (igual que Invoke-ConversionDTSMultiidioma): un idioma con DTS y SIN
# AC3/EAC3 previo recibirá un EAC3 convertido si la conversión está activa. En modo PREGUNTAR
# asumimos que se convierte (decisión del usuario).
$conversionActiva = ($modoConversionDTS -eq "SIEMPRE" -or $modoConversionDTS -eq "PREGUNTAR")
foreach ($g in $grupos) {
    $hibridoInfo = Resolve-Hibrido $g
    $rutas = $hibridoInfo.OrigenesPistas
    # Recolectar audios de todos los archivos del grupo, agrupados por idioma
    $porIdioma = @{}  # lang -> @{ PesoLang; TieneDolby; TieneDTS; TieneAC3oEAC3 }
    foreach ($ruta in $rutas) {
        $mi = Get-MediainfoJson $ruta
        if (-not $mi) { continue }
        foreach ($p in $mi.media.track) {
            if ($p.'@type' -ne "Audio") { continue }
            $lang = "$($p.Language)"; if ([string]::IsNullOrWhiteSpace($lang)) { $lang = "und" }
            $lang = Get-LanguageCode $lang "$($p.Title)"
            $nom = Get-LanguageName $lang "$($p.Title)"
            $esDTS = ("$($p.Format)" -match "(?i)DTS")
            $esEAC3oAC3 = ("$($p.Format)" -match "(?i)E-?AC-?3|AC-?3")
            $esDolby = ($esEAC3oAC3 -or "$($p.Format)" -match "(?i)TrueHD|MLP" -or "$($p.Format_Commercial_IfAny)" -match "(?i)Dolby|Plus|Atmos")
            if (-not $porIdioma.ContainsKey($lang)) {
                $porIdioma[$lang] = @{ PesoLang = (Get-PesoIdioma $nom); TieneDolby = $false; TieneDTS = $false; TieneAC3oEAC3 = $false }
            }
            if ($esDolby)     { $porIdioma[$lang].TieneDolby = $true }
            if ($esDTS)       { $porIdioma[$lang].TieneDTS = $true }
            if ($esEAC3oAC3)  { $porIdioma[$lang].TieneAC3oEAC3 = $true }
        }
    }
    if ($porIdioma.Keys.Count -eq 0) { continue }
    # Idioma prioritario del grupo (menor PesoLang)
    $pesoMin = ($porIdioma.Values | ForEach-Object { $_.PesoLang } | Measure-Object -Minimum).Minimum
    foreach ($lang in $porIdioma.Keys) {
        $info = $porIdioma[$lang]
        if ($info.PesoLang -ne $pesoMin) { continue }
        # Estado FINAL de este idioma:
        $tendraDTS = $info.TieneDTS
        # Tendrá Dolby si ya lo tiene, O si se va a crear por conversión (DTS sin AC3/EAC3 previo)
        $tendraDolby = $info.TieneDolby
        if ($conversionActiva -and $info.TieneDTS -and -not $info.TieneAC3oEAC3) { $tendraDolby = $true }
        if ($tendraDolby -and $tendraDTS) { $existeCasoDolbyDTS = $true; break }
    }
    if ($existeCasoDolbyDTS) { break }
}

if ($existeCasoDolbyDTS) {
    $defaultPreferidoAudio = Mostrar-Menu "Se ha detectado audio Dolby y DTS en el mismo idioma. ¿Cuál quieres como pista de audio predeterminada?" @(
        @{Nombre="Dolby (DD+/TrueHD/DD)"; Valor="DOLBY"},
        @{Nombre="DTS (DTS-HD MA/DTS)"; Valor="DTS"}
    )
}
}   # fin del else: sin configuración GUI para la pista predeterminada

# =========================================================================
# PRE-ESCANEO DE PGS (modo HOMOGÉNEO): preguntas al inicio + extracción y pausa únicas.
# Objetivo: responder todo al principio y dejar el script trabajando sin más interrupciones.
# En HETEROGÉNEO esto se hace por archivo dentro del bucle (junto a sus preguntas).
# =========================================================================
$decisionExtraerPGS = $false       # ¿extraer PGS para OCR?
$decisionConservarPGS = "CONSERVAR_PGS"  # tras convertir: conservar PGS o solo SRT
$pgsYaExtraidos = $false           # marca para que el bucle no vuelva a extraer/pausar
if ($modoLote -eq "HOMOGENEO") {
    # ¿Hay PGS en algún archivo del lote?
    $hayPgsEnLote = $false
    foreach ($g in $grupos) {
        $hi = Resolve-Hibrido $g
        foreach ($mkv in $hi.OrigenesPistas) {
            if (Test-TienePGS $mkv) { $hayPgsEnLote = $true; break }
        }
        if ($hayPgsEnLote) { break }
    }

    if ($hayPgsEnLote) {
        $cfgExtraer = Get-CfgGui "ExtraerPGS"
        $rExtraer = if ($null -ne $cfgExtraer) {
            Write-Host "`n[GUI] Extraer PGS para OCR en Subtitle Edit: $(if ($cfgExtraer) { 'Sí' } else { 'No' }) (configuración)." -ForegroundColor DarkGray
            if ($cfgExtraer) { "S" } else { "N" }
        } else {
            Read-Host "`n[?] Hay subtítulos PGS en el lote. ¿Extraerlos para OCR en Subtitle Edit? (S/N)"
        }
        if ($rExtraer -match "^[sS]") {
            $decisionExtraerPGS = $true
            $cfgConsPGS = Get-CfgGui "DecisionConservarPGS"
            if ("$cfgConsPGS" -in @("CONSERVAR_PGS", "ELIMINAR_PGS")) {
                $decisionConservarPGS = "$cfgConsPGS"
                Write-Host "[GUI] Tras convertir los PGS: $(if ($decisionConservarPGS -eq 'CONSERVAR_PGS') { 'mantener PGS + SRT' } else { 'solo SRT (borrar PGS)' }) (configuración)." -ForegroundColor DarkGray
            } else {
                $decisionConservarPGS = Mostrar-Menu "Tras convertir los PGS a SRT, ¿qué hago con ellos?" @(
                    @{Nombre="Mantener PGS + SRT (conserva los PGS del vídeo, añade los SRT de la carpeta y cualquier PGS extra que dejes ahí)"; Valor="CONSERVAR_PGS"},
                    @{Nombre="Mantener solo SRT y borrar PGS (elimina los PGS del vídeo y deja solo los SRT de la carpeta)"; Valor="ELIMINAR_PGS"}
                )
            }
        }
    }
}

Write-Host "`n[+] Configuración guardada. Iniciando cadena de montaje..." -ForegroundColor Green
Write-DiagConfiguracion
# Rutas de los MKV finales de ESTA ejecución (las usa el torrent de PACK al terminar)
$global:archivosFinalesLote = @()
$global:capturasLote = @()        # rutas de TODAS las capturas del lote (para el resultado del PACK)
$respuestasIdiomasSubs = @{}   # Memoria global de idiomas para subs (D4: claves con path)
$respuestasIdiomasAudios = @{} # Memoria global de idiomas para audios
# Pre-carga de las decisiones POR PISTA de la GUI: con la clave ya en memoria, ni
# Resolve-IdiomasAudios/Subs ni Build-PistasBrutas vuelven a preguntar por esas pistas.
foreach ($kGui in $global:undPistasGui.Keys) {
    $partesGui = $kGui -split "\|"
    if ($partesGui.Count -lt 3) { continue }
    $llaveGui = "Interno_$($partesGui[0])_$($partesGui[1])"
    if ($partesGui[2] -eq "Audio") { $respuestasIdiomasAudios[$llaveGui] = $global:undPistasGui[$kGui] }
    else                           { $respuestasIdiomasSubs[$llaveGui]   = $global:undPistasGui[$kGui] }
    Write-Host "[GUI] Pista $($partesGui[2]) #$($partesGui[1]) de $(Split-Path $partesGui[0] -Leaf) -> idioma '$($global:undPistasGui[$kGui])' (configuración)." -ForegroundColor DarkGray
}

# Extracción + pausa ÚNICA del lote (HOMOGÉNEO), si el usuario pidió extraer PGS.
# Extraemos los PGS de todos los archivos (con prefijo para no mezclarlos), hacemos UNA sola
# pausa para que el usuario los convierta todos juntos en Subtitle Edit, y luego el bucle
# procesa todo sin más interrupciones.
if ($modoLote -eq "HOMOGENEO" -and $decisionExtraerPGS) {
    Write-Host "`n[>>] Extrayendo subtítulos PGS de todo el lote..." -ForegroundColor Cyan
    $totalExtraidos = 0
    foreach ($g in $grupos) {
        $hi = Resolve-Hibrido $g
        $prefijo = [System.IO.Path]::GetFileNameWithoutExtension($hi.ArchivoPrincipal.Name)
        foreach ($mkv in $hi.OrigenesPistas) {
            if (Test-TienePGS $mkv) {
                $totalExtraidos += Invoke-ExtraccionPGS $mkv $idiomasSubsMantenerGlobal $prefijo
                break  # solo del primer archivo con PGS del par
            }
        }
    }
    if ($totalExtraidos -gt 0) {
        Write-Host "`n=======================================================" -ForegroundColor Magenta
        Write-Host " PAUSA: Pásalos por Subtitle Edit y guarda los .srt en la carpeta en la que tienes el video." -ForegroundColor Yellow
        Write-Host " (Se procesará todo el lote sin más interrupciones al continuar.)" -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Magenta
        Read-Host "Presiona ENTER cuando hayas terminado para continuar el montaje..."
    }
    $pgsYaExtraidos = $true
}

# =========================================================================
# FASE BATCH: BUCLE PRINCIPAL DE PROCESAMIENTO
# =========================================================================
# Si el lote acaba en una carpeta de temporada/pack, los MKV terminados se agrupan al final.
# Misma condición que el bloque del pack (al final del script), calculada aquí por adelantado.
$packAlFinal = ($modoTorrent -in @("PACK", "AMBOS")) -or (($modoLote -eq "HOMOGENEO") -and @($grupos).Count -gt 1 -and ($modoTorrent -ne "INDIVIDUAL"))
# MKV terminados en el disco de trabajo que aún deben ir a su carpeta de salida (con su acción
# sobre los originales, que espera a que el MKV esté verificado en el destino).
$global:pendientesSalida = [System.Collections.Generic.List[object]]::new()
foreach ($grupo in $grupos) {
    $archivoFinalDestino=''; $rutaTorrentFinal=''; $origenesPistas=@(); $archivosBorrables=@()
    # El índice interno comienza en 0, pero el progreso que ve el usuario es 1..N. Debe avanzar
    # ANTES de emitir cualquier fase de este grupo; si no, toda la ejecución se queda en «0/N».
    $global:idxGrupoGui++

    # D2: try/catch por episodio para que un fallo no aborte todo el script
    try {

        $hibridoInfo = Resolve-Hibrido $grupo
        $esHibrido        = $hibridoInfo.EsHibrido
        $archivoDV        = $hibridoInfo.ArchivoDV
        $archivoHDR10     = $hibridoInfo.ArchivoHDR10
        $archivoPrincipal = $hibridoInfo.ArchivoPrincipal
        $origenPistas     = $hibridoInfo.OrigenPistas       # singular (1er archivo) — compat
        $origenesPistas   = $hibridoInfo.OrigenesPistas     # lista de archivos para mergear pistas

        Write-Host "`n=========================================================" -ForegroundColor Magenta
        Write-Host " PROCESANDO: $($archivoPrincipal.Name)" -ForegroundColor Magenta
        $global:archivoEnCurso = $archivoPrincipal.Name

        # --- Decisiones POR ARCHIVO (modo «Cada archivo distinto»): la GUI manda un mapa
        # DecisionesPorArchivo[nombre] con DTS/audio-defecto/filtro/PGS propios de cada película.
        # Si no hay entrada (modo homogéneo), se usan los valores globales de siempre. ---
        $pfDec = $null
        $cfgDPA = Get-CfgGui "DecisionesPorArchivo"
        if ($cfgDPA -and $archivoPrincipal -and ($cfgDPA.PSObject.Properties.Name -contains $archivoPrincipal.Name)) { $pfDec = $cfgDPA.$($archivoPrincipal.Name) }
        $modoDTSArchivo  = if ($pfDec -and "$($pfDec.Dts)" -in @("SIEMPRE", "NUNCA", "PREGUNTAR")) { "$($pfDec.Dts)" } else { $modoConversionDTS }
        $defAudioArchivo = if ($pfDec -and "$($pfDec.DefAudio)" -in @("DOLBY", "DTS")) { "$($pfDec.DefAudio)" } else { $defaultPreferidoAudio }
        if ($pfDec) { Write-Host "   [GUI] Decisiones propias de esta película: audio-def=$defAudioArchivo." -ForegroundColor DarkGray }
        # Ajustes de General POR PELÍCULA (originales/sufijo/torrent). Si no hay, valor global de siempre.
        $accionOrigEste  = $accionOriginales
        $sufijoEste      = $anadirSufijoHDZ
        $modoTorrentEste = $modoTorrent
        $cfgGPA = Get-CfgGui "GeneralPorArchivo"
        if ($cfgGPA -and $archivoPrincipal -and ($cfgGPA.PSObject.Properties.Name -contains $archivoPrincipal.Name)) {
            $pfGen = $cfgGPA.$($archivoPrincipal.Name)
            if (($pfGen.PSObject.Properties.Name -contains 'AccionOriginales') -and "$($pfGen.AccionOriginales)") { $accionOrigEste = "$($pfGen.AccionOriginales)" }
            if ($pfGen.PSObject.Properties.Name -contains 'SufijoHDZ') { $sufijoEste = [bool]$pfGen.SufijoHDZ }
            if (($pfGen.PSObject.Properties.Name -contains 'ModoTorrent') -and "$($pfGen.ModoTorrent)") { $modoTorrentEste = "$($pfGen.ModoTorrent)" }
            Write-Host "   [GUI] Ajustes propios de esta película: originales=$accionOrigEste, sufijo=$(if ($sufijoEste) {'Sí'} else {'No'}), torrent=$modoTorrentEste." -ForegroundColor DarkGray
        }
        # Conversiones de audio manuales para ESTE archivo: por-película si existe, si no la global.
        $convAudioEste = @()
        $cfgConvArch = Get-CfgGui "ConversionesPorArchivo"
        if ($null -ne $cfgConvArch -and $null -ne $archivoPrincipal -and ($cfgConvArch.PSObject.Properties.Name -contains $archivoPrincipal.Name)) {
            if ($cfgConvArch.$($archivoPrincipal.Name) -is [array]) { $convAudioEste = $cfgConvArch.$($archivoPrincipal.Name) } else { $convAudioEste = @($cfgConvArch.$($archivoPrincipal.Name)) }
        } else {
            $cfgConvGlobal = Get-CfgGui "ConversionesAudioManual"
            if ($null -ne $cfgConvGlobal) {
                if ($cfgConvGlobal -is [array]) { $convAudioEste = $cfgConvGlobal } else { $convAudioEste = @($cfgConvGlobal) }
            }
        }
        $global:pctBaseGui = if ($global:totalGruposGui -gt 0) { [int](100 * ($global:idxGrupoGui - 1) / $global:totalGruposGui) } else { 0 }
        $global:pctPasoGui = if ($global:totalGruposGui -gt 0) { 100.0 / $global:totalGruposGui } else { 100.0 }
        Set-ProgresoGui ([int]($global:pctBaseGui + $global:pctPasoGui * 0.05)) "Procesando $($global:idxGrupoGui)/$($global:totalGruposGui)" $archivoPrincipal.Name
        Write-DiagPaso "INICIO procesado de $($archivoPrincipal.Name)"
        Write-Host "=========================================================" -ForegroundColor Magenta

        if ($esHibrido) { Write-Host "[!] Pareja Híbrida Detectada (DV + HDR10) — pistas combinadas de ambos archivos" -ForegroundColor Green }

        # Diagnóstico: volcamos al log toda la información sobre los archivos de entrada
        # (uno solo en no-híbridos, los dos en híbridos). Es la radiografía del input.
        for ($_i = 0; $_i -lt $origenesPistas.Count; $_i++) {
            $etiqueta = if ($origenesPistas.Count -gt 1) { "ENTRADA $($_i + 1)/$($origenesPistas.Count)" } else { "ENTRADA" }
            Write-DiagArchivoEntrada $origenesPistas[$_i] $etiqueta
        }
        Write-DiagLinea "ArchivoPrincipal: $($archivoPrincipal.FullName)"
        Write-DiagLinea "EsHibrido: $esHibrido"
        Write-DiagLinea "OrigenesPistas: $($origenesPistas -join '  ;  ')"

        # Datos de proyecto: globales en homogéneo, preguntados aquí en heterogéneo
        if ($modoLote -eq "HOMOGENEO") {
            $datosProyecto = $datosProyectoGlobal
        } else {
            $datosProyecto = Get-DatosProyecto $archivoPrincipal.Name
        }
        $tituloPelicula    = $datosProyecto.Titulo
        $anoPelicula       = $datosProyecto.Ano
        $esSerie           = $datosProyecto.EsSerie
        $tipoOrigen        = $datosProyecto.TipoOrigen
        $webTipo           = $datosProyecto.WebTipo
        $plataformaFormato = $datosProyecto.PlataformaFormato
        $etiquetasExtra    = $datosProyecto.EtiquetasExtra

        # Auto-Detección de Episodio (con override POR ARCHIVO desde la GUI: permite indicar varios
        # episodios en un mismo vídeo —S01E01-E02— y numerar por orden, sin preguntar en consola).
        $serieTag = ""
        if ($esSerie) {
            $nmEp = $archivoPrincipal.Name
            $epMap = Get-CfgGui "EpisodiosPorArchivo"
            $ovrEp = ""
            if ($epMap -and ($epMap.PSObject.Properties.Name -contains $nmEp)) { $ovrEp = "$($epMap.$nmEp)".Trim() }
            if ($ovrEp) {
                $serieTag = $ovrEp
                Write-Host " -> Capítulo indicado (GUI): $serieTag" -ForegroundColor Green
            } else {
                $serieTag = Detectar-Episodio $nmEp
                if ($serieTag) {
                    Write-Host " -> Capítulo detectado automáticamente: $serieTag" -ForegroundColor Green
                } elseif ($global:sinPreguntas) {
                    Write-Host " -> [GUI] Sin episodio en el nombre ni indicado; se deja sin capítulo." -ForegroundColor Yellow
                } else {
                    $serieTag = Read-Host " -> No pude detectar el capítulo para este archivo. Escríbelo (ej: S01E01)"
                }
            }
        }

        # Pre-carga de mediainfo y mkvmerge -J del archivo (o ambos, si es híbrido). La primera
        # lectura puede ser lenta en archivos grandes (AV1, UHD remuxes), así que la disparamos
        # AQUÍ una sola vez con barra de progreso, en lugar de en silencio dentro de cada
        # Resolve-* posterior. Las siguientes lecturas usan la caché y son instantáneas.
        Set-ProgresoGui ([int]($global:pctBaseGui + $global:pctPasoGui * 0.15)) "Analizando pistas $($global:idxGrupoGui)/$($global:totalGruposGui)" $archivoPrincipal.Name
        Write-DiagPaso "Pre-carga mediainfo+mkvmerge: INICIO"
        $totalArch = $origenesPistas.Count
        $nArch = 0
        foreach ($ruta in $origenesPistas) {
            $nArch++
            Write-Progress -Activity "Analizando archivo" -Status "$nArch/$totalArch : $(Split-Path $ruta -Leaf)" -PercentComplete (($nArch/$totalArch)*100)
            Write-DiagPaso "  mediainfo INICIO: $(Split-Path $ruta -Leaf)"
            Get-MediainfoJson $ruta | Out-Null
            Write-DiagPaso "  mediainfo FIN, mkvmerge -J INICIO: $(Split-Path $ruta -Leaf)"
            Get-MkvmergeJson $ruta | Out-Null
            Write-DiagPaso "  mkvmerge -J FIN: $(Split-Path $ruta -Leaf)"
        }
        Write-Progress -Activity "Analizando archivo" -Completed
        Write-DiagPaso "Pre-carga mediainfo+mkvmerge: FIN"

        # Resolución de conflictos de idioma. Audios primero (los necesita la conversión DTS),
        # subtítulos después. En híbrido recorre AMBOS archivos del par.
        # En HOMOGÉNEO, si el pre-escaneo del lote ya decidió el idioma de los 'und', se aplica
        # sin volver a preguntar (pasamos el idioma global).
        Resolve-IdiomasAudios $origenesPistas $archivoPrincipal $respuestasIdiomasAudios $global:idiomaUndAudioLote
        Resolve-IdiomasSubs   $origenesPistas $archivoPrincipal $respuestasIdiomasSubs   $global:idiomaUndSubLote

        # Idiomas de subtítulos a mantener: VA PRIMERO para no preguntar por subs de idiomas
        # que se van a descartar. En HOMOGÉNEO usamos la decisión global del pre-escaneo;
        # en HETEROGÉNEO preguntamos para este archivo concreto (si tiene >3 idiomas).
        if ($modoLote -eq "HOMOGENEO") {
            $idiomasSubsMantener = $idiomasSubsMantenerGlobal
        } elseif ($pfDec -and ($pfDec.PSObject.Properties.Name -contains "Filtro")) {
            # Filtro de idiomas propio de esta película (mismas reglas que IdiomasSubsMantener).
            $fv = $pfDec.Filtro
            $idiomasSubsMantener = if ($null -eq $fv -or "$fv" -eq "TODOS") { $null }
                                   elseif ("$fv" -eq "CAST_ENG") { @("__CAST_ENG__") }
                                   else { @($fv) }
        } else {
            $idiomasSubsMantener = Resolve-IdiomasSubsArchivo $origenesPistas
        }

        # Resolución de subs únicos sin señal: DESPUÉS del filtro de idiomas (lo respeta).
        # En HETEROGÉNEO se pregunta archivo a archivo aquí. En HOMOGÉNEO solo si alguna
        # combinación quedó marcada como "__PREGUNTAR__" en el pre-escaneo.
        $hayPendientesEnEsteArchivo = $false
        if ($modoLote -eq "HETEROGENEO") {
            $hayPendientesEnEsteArchivo = $true
        } else {
            foreach ($k in $decisionesSubUnico.Keys) {
                if ($k.StartsWith("$($archivoPrincipal.FullName)|") -and $decisionesSubUnico[$k] -eq "__PREGUNTAR__") {
                    $hayPendientesEnEsteArchivo = $true
                    break
                }
            }
        }
        if ($hayPendientesEnEsteArchivo) {
            Resolve-SubsUnicosArchivo $origenesPistas $archivoPrincipal $decisionesSubUnico $idiomasSubsMantener
        }

        # Preguntas de PGS (HETEROGÉNEO): se hacen aquí, junto al resto de preguntas del archivo,
        # ANTES de la pausa. La extracción + pausa ocurren después, en la FASE 2.
        $decisionExtraerPGSHetero = $false
        $decisionConservarPGSHetero = "CONSERVAR_PGS"
        if ($modoLote -eq "HETEROGENEO") {
            $tienePgsEste = $false
            foreach ($mkv in $origenesPistas) { if (Test-TienePGS $mkv) { $tienePgsEste = $true; break } }
            if ($tienePgsEste) {
                $cfgExtraerH = if ($pfDec -and ($pfDec.PSObject.Properties.Name -contains "ExtraerPGS")) { [bool]$pfDec.ExtraerPGS } else { Get-CfgGui "ExtraerPGS" }
                $rEx = if ($null -ne $cfgExtraerH) {
                    Write-Host "`n[GUI] Extraer PGS para OCR: $(if ($cfgExtraerH) { 'Sí' } else { 'No' }) (configuración)." -ForegroundColor DarkGray
                    if ($cfgExtraerH) { "S" } else { "N" }
                } else {
                    Read-Host "`n[?] Este archivo tiene subtítulos PGS. ¿Extraerlos para OCR en Subtitle Edit? (S/N)"
                }
                if ($rEx -match "^[sS]") {
                    $decisionExtraerPGSHetero = $true
                    $cfgConsPGSH = if ($pfDec -and $pfDec.ConservarPGS) { "$($pfDec.ConservarPGS)" } else { Get-CfgGui "DecisionConservarPGS" }
                    if ("$cfgConsPGSH" -in @("CONSERVAR_PGS", "ELIMINAR_PGS")) {
                        $decisionConservarPGSHetero = "$cfgConsPGSH"
                        Write-Host "[GUI] Tras convertir los PGS: $(if ($decisionConservarPGSHetero -eq 'CONSERVAR_PGS') { 'mantener PGS + SRT' } else { 'solo SRT (borrar PGS)' }) (configuración)." -ForegroundColor DarkGray
                    } else {
                        $decisionConservarPGSHetero = Mostrar-Menu "Tras convertir los PGS a SRT, ¿qué hago con ellos?" @(
                            @{Nombre="Mantener PGS + SRT (conserva los PGS del vídeo, añade los SRT de la carpeta y cualquier PGS extra que dejes ahí)"; Valor="CONSERVAR_PGS"},
                            @{Nombre="Mantener solo SRT y borrar PGS (elimina los PGS del vídeo y deja solo los SRT de la carpeta)"; Valor="ELIMINAR_PGS"}
                        )
                    }
                }
            }
        }

        # =========================================================================
        # FASE 2: PRE-PROCESAMIENTO (FUSIÓN, EXTRACCIÓN DTS Y PGS)
        # =========================================================================
        $archivosBorrables = @()
        $videoA_Muxear = $archivoPrincipal.FullName
        $estimatedBytes = [long]((@($origenesPistas | ForEach-Object { Get-Item -LiteralPath $_ }) | Measure-Object Length -Sum).Sum * 1.15) + 100MB
        Assert-HdzFreeSpace $rutaCarpeta $estimatedBytes
        if ($global:remixActivo) { Assert-HdzRemixDurations $archivoPrincipal.FullName @($origenesPistas) }

        if ($esHibrido) {
            $resFusion = Invoke-FusionDolbyVision $archivoDV $archivoHDR10
            if (-not $resFusion) { 
                Write-Host "   Saltando este archivo para no detener la cadena..." -ForegroundColor Yellow
                Add-Incidencia $global:archivoEnCurso "Fusión Dolby Vision falló. Archivo SALTADO (no procesado)."
                continue 
            }
            $videoA_Muxear      = $resFusion.VideoFusionado
            $archivosBorrables += $resFusion.Borrables
        }

        $archivosBorrables += Invoke-ConversionDTSMultiidioma $origenesPistas $modoDTSArchivo $respuestasIdiomasAudios

        # --- PGS ---
        # HOMOGÉNEO: ya se preguntó y se extrajo todo al inicio (pausa única). Solo recogemos
        # las decisiones globales; no se vuelve a preguntar ni a pausar.
        # HETEROGÉNEO: se pregunta, extrae y pausa para este archivo concreto (junto a sus datos).
        if ($modoLote -eq "HOMOGENEO") {
            $decisionPGS = $decisionConservarPGS
            # Si no se generó ningún SRT para este archivo (el usuario no lo convirtió), no podemos
            # eliminar los PGS o el archivo se quedaría sin esos subs: forzamos conservar.
            if ($decisionPGS -eq "ELIMINAR_PGS") {
                $prefijoEste = [System.IO.Path]::GetFileNameWithoutExtension($archivoPrincipal.Name)
                $prefijoEsteEsc = [regex]::Escape($prefijoEste)
                $srtDeEste = @(Get-ChildItem -LiteralPath $rutaCarpeta -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "(?i)^${prefijoEsteEsc}_sub_\d+_[a-z]{2,3}\.srt$" })
                if ($srtDeEste.Count -eq 0) {
                    Write-Host "`n[i] No se detectaron SRT convertidos; se conservarán los PGS originales de este archivo." -ForegroundColor DarkGray
                    $decisionPGS = "CONSERVAR_PGS"
                }
            }
        } else {
            # HETEROGÉNEO: pregunta + extracción + pausa para este archivo.
            $decisionPGS = "CONSERVAR_PGS"
            $tienePgsAlguno = $false
            foreach ($mkv in $origenesPistas) {
                if (Test-TienePGS $mkv) { $tienePgsAlguno = $true; break }
            }
            if ($tienePgsAlguno -and $decisionExtraerPGSHetero) {
                Write-Host "`n[>>] Extrayendo subtítulos PGS..." -ForegroundColor Cyan
                $totalEx = 0
                # Prefijo basado en el ArchivoPrincipal: en híbridos el MKV con PGS puede ser el
                # OTRO archivo del par, y el resto del flujo (detección de SRT generados, filtro
                # $prefijoSrtPropio) busca los SRT por el nombre del principal. Sin esto, los
                # SRT convertidos por el usuario no se recogían.
                $prefijoHet = [System.IO.Path]::GetFileNameWithoutExtension($archivoPrincipal.Name)
                foreach ($mkv in $origenesPistas) {
                    if (Test-TienePGS $mkv) { $totalEx += Invoke-ExtraccionPGS $mkv $idiomasSubsMantener $prefijoHet; break }
                }
                if ($totalEx -gt 0) {
                    Write-Host "`n=======================================================" -ForegroundColor Magenta
                    Write-Host " PAUSA: Pásalos por Subtitle Edit y guarda los .srt en la carpeta en la que tienes el video." -ForegroundColor Yellow
                    Write-Host "=======================================================" -ForegroundColor Magenta
                    Read-Host "Presiona ENTER cuando hayas terminado para continuar el montaje..."
                    $decisionPGS = $decisionConservarPGSHetero
                    # Si no hay SRT generados para este archivo, forzar conservar
                    $prefHet = [regex]::Escape([System.IO.Path]::GetFileNameWithoutExtension($archivoPrincipal.Name))
                    $srtGen = @(Get-ChildItem -LiteralPath $rutaCarpeta -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "(?i)^${prefHet}_sub_\d+_[a-z]{2,3}\.srt$" })
                    if ($decisionPGS -eq "ELIMINAR_PGS" -and $srtGen.Count -eq 0) {
                        Write-Host "   -> No se detectaron SRT generados; se conservarán los PGS originales." -ForegroundColor DarkGray
                        $decisionPGS = "CONSERVAR_PGS"
                    }
                }
            } elseif (-not $tienePgsAlguno) {
                Write-Host "`n[i] Sin subtítulos PGS en este archivo, paso directo." -ForegroundColor DarkGray
            }
        }

        # =========================================================================
        # FASE 3: LÓGICA REMUX (ENSAMBLAJE DE PISTAS)
        # =========================================================================
        Set-ProgresoGui ([int]($global:pctBaseGui + $global:pctPasoGui * 0.45)) "Ensamblando MKV $($global:idxGrupoGui)/$($global:totalGruposGui)" $archivoPrincipal.Name
        Write-Host "`n[>>] Construyendo Track Order y Ensamblando..." -ForegroundColor Cyan
        Write-DiagPaso "Build-PistasBrutas + Format-* + Set-Banderas: INICIO"

        # Build-PistasBrutas resuelve idiomas tanto de audios como de subs internos/externos.
        # Combinamos las dos memorias para que tenga acceso a todas las respuestas.
        $memoriaCombinada = @{}
        foreach ($k in $respuestasIdiomasAudios.Keys) { $memoriaCombinada[$k] = $respuestasIdiomasAudios[$k] }
        foreach ($k in $respuestasIdiomasSubs.Keys)   { $memoriaCombinada[$k] = $respuestasIdiomasSubs[$k] }
        $prefijoSrtPropio = [System.IO.Path]::GetFileNameWithoutExtension($archivoPrincipal.Name)
        # Preguntar forzado/completo de los subs EXTERNOS únicos (SRT sueltos o convertidos de PGS),
        # ahora que ya están en la carpeta (tras la pausa de Subtitle Edit, si la hubo).
        Resolve-SubsExternosForzados $origenesPistas $prefijoSrtPropio $decisionesSubUnico $idiomasSubsMantener
        $idiomasAudioMantenerArchivo = $global:idiomasAudioMantener
        if ($pfDec -and ($pfDec.PSObject.Properties.Name -contains "AudioLangs") -and @($pfDec.AudioLangs).Count -gt 0) {
            $idiomasAudioMantenerArchivo = @($pfDec.AudioLangs | ForEach-Object { "$_" } | Where-Object { $_ })
        }
        $analisis = Build-PistasBrutas $origenesPistas $esHibrido $memoriaCombinada $decisionPGS $idiomasSubsMantener $prefijoSrtPropio $idiomasAudioMantenerArchivo
        $idVideo    = $analisis.IdVideo
        $altoVideo  = $analisis.AltoVideo
        $codecVideo = $analisis.CodecVideo
        $hdrVideo   = $analisis.HdrVideo

        $audios = @($analisis.Pistas | Where-Object { $_.Tipo -eq "Audio" })
        # Red de seguridad de REMEZCLA: si este capítulo/peli se queda SIN audio (no se emparejó la
        # fuente de audio de otra carpeta, p.ej. nombres muy distintos), avisamos en vez de generar un
        # MKV mudo en silencio. El resultado igual se monta, pero la incidencia queda registrada.
        if ($global:remixActivo -and @($audios).Count -eq 0) {
            Write-Host "   [!] REMEZCLA: '$($archivoPrincipal.BaseName)' se queda SIN audio (no se emparejo ninguna fuente de audio para este capitulo)." -ForegroundColor Red
            Add-Incidencia $archivoPrincipal.Name "Remezcla: sin audio (no se emparejo la fuente de audio de otra carpeta para este capitulo/pelicula)."
        }
        # Format-Audios calcula Pts (calidad), PesoFamilia y NomFinal, y ordena. DEBE ir antes del
        # filtro de híbrido, porque ese filtro se basa en Pts (que aquí aún no existe en las pistas).
        $audiosOrdenados = Format-Audios $audios

        # En HÍBRIDOS (par DV + HDR10/HDR10+), cada archivo de origen aporta sus propias pistas de
        # audio, duplicadas por idioma con calidades distintas (p.ej. el DV trae AC-3 y el HDR10+
        # trae E-AC-3 Atmos o AAC). Nos quedamos SOLO con la mejor pista por idioma (mayor Pts).
        # En no-híbridos no se toca: se conservan todas las pistas del idioma.
        if ($esHibrido -and $audiosOrdenados.Count -gt 1) {
            # Índice único por pista para identificarla sin depender de -eq sobre objetos
            # (que en PowerShell no compara por referencia de forma fiable).
            for ($i = 0; $i -lt $audiosOrdenados.Count; $i++) {
                $audiosOrdenados[$i] | Add-Member -NotePropertyName "_idxFiltro" -NotePropertyValue $i -Force
            }
            # Solo compiten las pistas INTERNAS (las duplicadas entre los dos MKV del par).
            # Las EXTERNAS (EAC3 convertidos por el script, audios del usuario) se conservan
            # siempre: si compitieran, el EAC3 convertido podía "ganar" al DTS original
            # castellano (demotado en Pts por la regla de orden) y hacer que se descartara.
            # Se compara por PtsCalidad (calidad técnica pura, sin esa demotion).
            $mejorIdxPorIdioma = @{}   # lang -> @{ Idx; Pts }
            foreach ($a in $audiosOrdenados) {
                if ($a.Origen -ne "Interno") { continue }
                $lng = "$($a.CodLang)"
                $pts = [double]$a.PtsCalidad
                if (-not $mejorIdxPorIdioma.ContainsKey($lng) -or $pts -gt $mejorIdxPorIdioma[$lng].Pts) {
                    $mejorIdxPorIdioma[$lng] = @{ Idx = $a._idxFiltro; Pts = $pts }
                }
            }
            $idxGanadores = @($mejorIdxPorIdioma.Values | ForEach-Object { $_.Idx })
            $audiosFiltrados = @($audiosOrdenados | Where-Object { $_.Origen -ne "Interno" -or $idxGanadores -contains $_._idxFiltro })
            $descartados = $audiosOrdenados.Count - $audiosFiltrados.Count
            if ($descartados -gt 0) {
                Write-Host "   [híbrido] Audios redundantes descartados: $descartados (se conserva el mejor por idioma)." -ForegroundColor DarkGray
                foreach ($a in $audiosFiltrados) {
                    Write-DiagLinea "  [hibrido mejor audio] $($a.NomLang): $($a.NomFinal) ($($a.Pts) pts) <- $(Split-Path $a.ArchivoFuenteMkv -Leaf)"
                }
            }
            $audiosOrdenados = $audiosFiltrados
        }

        # --- Conversiones de audio manuales (GUI) ---
        # Se aplican DESPUÉS de la selección/orden: el usuario eligió pistas concretas, así que no
        # compiten por el scoring. Genera las pistas convertidas (externas), elimina las originales
        # que NO se conservan, e inserta las nuevas reordenando con el mismo criterio (idioma/familia).
        if (@($convAudioEste).Count -gt 0) {
            $rcConv = Invoke-ConversionAudioManual $convAudioEste $archivoPrincipal
            $archivosBorrables += $rcConv.Borrables
            if (@($rcConv.IndicesAEliminar).Count -gt 0) {
                $antesAud = $audiosOrdenados.Count
                $audiosOrdenados = @($audiosOrdenados | Where-Object {
                    $track = $_
                    -not ($track.Origen -eq "Interno" -and @($rcConv.PistasAEliminar | Where-Object { $_.Index -eq [int]$track.ID -and $_.Ruta -eq $track.ArchivoFuenteMkv }).Count -gt 0)
                })
                $quit = $antesAud - $audiosOrdenados.Count
                if ($quit -gt 0) { Write-Host "   [conversión audio] $quit pista(s) original(es) sustituida(s) por su versión convertida." -ForegroundColor DarkGray }
            }
            if (@($rcConv.Nuevos).Count -gt 0) {
                $audiosOrdenados = Format-Audios (@($audiosOrdenados) + @($rcConv.Nuevos))
                Write-Host "   [conversión audio] $(@($rcConv.Nuevos).Count) pista(s) convertida(s) añadida(s) al archivo final." -ForegroundColor Green
            }
        }


        $subs = @($analisis.Pistas | Where-Object { $_.Tipo -eq "Sub" })

        # Si el usuario eligió eliminar los PGS originales tras convertirlos a SRT,
        # filtramos aquí las pistas internas en formato PGS. Los SRT generados (que ya están
        # en la carpeta como subs externos) entran al archivo final en su lugar.
        if ($decisionPGS -eq "ELIMINAR_PGS") {
            $antesCount = $subs.Count
            foreach ($pgsGroup in @($subs | Where-Object { $_.Origen -eq 'Interno' -and "$($_.Format)" -match '(?i)pgs' } | Group-Object CodLang)) {
                $replacements = @($subs | Where-Object { $_.CodLang -eq $pgsGroup.Name -and $_.Origen -eq 'Externo' -and "$($_.Format)" -match '(?i)srt|subrip|utf-8' })
                if ($replacements.Count -lt $pgsGroup.Count) { throw "Faltan SRT externos para sustituir todos los PGS de '$($pgsGroup.Name)'. Se conservan los originales; completa el OCR o elige mantener PGS." }
            }
            $subs = @($subs | Where-Object {
                -not ($_.Origen -eq "Interno" -and "$($_.Format)" -match "(?i)pgs")
            })
            $eliminados = $antesCount - $subs.Count
            if ($eliminados -gt 0) {
                Write-Host "   [decisión PGS] Eliminados $eliminados sub(s) PGS originales (se conservan solo los SRT convertidos)." -ForegroundColor DarkGray
            }
        }

        $subsOrdenados = Format-Subs $subs $origenPistas $decisionesSubUnico

        # Volcado al log de las pistas que vamos a muxear (post-resolución/dedup/forzados/orden).
        # Es lo que le pasaremos a mkvmerge.
        Write-DiagPistasFinal $audiosOrdenados $subsOrdenados $idVideo $altoVideo $codecVideo $hdrVideo

        # Carpeta de salida del MKV resultado. Puede elegirse POR ARCHIVO (mapa de la GUI); si este
        # archivo no tiene una propia, se usa la global; si tampoco hay global, se queda en origen.
        # Se resuelve ANTES de ensamblar para que mkvmerge escriba ya allí.
        $carpetaSalidaArch = $carpetaSalidaGui
        $csMap = Get-CfgGui "CarpetaSalidaPorArchivo"
        $nmSal = $archivoPrincipal.Name
        if ($csMap -and ($csMap.PSObject.Properties.Name -contains $nmSal)) {
            $csVal = "$($csMap.$nmSal)".Trim()
            if ($csVal) { $carpetaSalidaArch = $csVal }
        }
        # Dónde se hace el trabajo pesado (mux, banderas, verificación, capturas y hash del torrent):
        #  - por defecto en la carpeta de trabajo, y el MKV terminado viaja UNA vez al final. Si la
        #    salida es un HDD o un recurso de red, escribir allí y luego releerlo entero para el
        #    torrent costaba dos viajes por el disco/red lentos;
        #  - si el origen está en red y la salida es local, se ensambla directamente en la salida.
        $carpetaMux = $null
        $moverAlFinal = $false
        $salidaDistinta = $carpetaSalidaArch -and ([IO.Path]::GetFullPath($carpetaSalidaArch).TrimEnd('\') -ine [IO.Path]::GetFullPath($rutaCarpeta).TrimEnd('\'))
        if ($salidaDistinta -and -not ((Test-HdzRutaRed $rutaCarpeta) -and -not (Test-HdzRutaRed $carpetaSalidaArch))) {
            $moverAlFinal = $true
            Write-DiagLinea "Trabajo en la carpeta de origen; el MKV terminado se moverá a '$carpetaSalidaArch' al final."
        } elseif ($salidaDistinta) {
            try {
                [void][System.IO.Directory]::CreateDirectory($carpetaSalidaArch)
                $muxBytes = [long](@($origenesPistas | ForEach-Object { (Get-Item -LiteralPath $_).Length }) | Measure-Object -Sum).Sum + 100MB
                Assert-HdzFreeSpace $carpetaSalidaArch $muxBytes
                $carpetaMux = $carpetaSalidaArch
            } catch {
                # Sin acceso o sin espacio: se ensambla en origen y el movimiento posterior informa del error.
                Write-DiagLinea "Ensamblaje en origen (carpeta de salida no utilizable): $($_.Exception.Message)"
            }
        }
        $archivoSalidaTemporal = Invoke-Ensamblaje $archivoPrincipal $origenesPistas $esHibrido $videoA_Muxear $idVideo $audiosOrdenados $subsOrdenados $carpetaMux
        if (-not $archivoSalidaTemporal) {
            Write-Host "   Limpiando y saltando al siguiente archivo..." -ForegroundColor Yellow
            Add-Incidencia $global:archivoEnCurso "mkvmerge falló al ensamblar. Archivo SALTADO (no procesado)."
            foreach ($del in $archivosBorrables) { Remove-Item -LiteralPath $del -Force -ErrorAction SilentlyContinue }
            continue
        }

        # =========================================================================
        # FASE 4: ETIQUETADO Y RENOMBRADO HDZ
        # =========================================================================
        Write-Host "`n[>>] Aplicando banderas y calculando nombre final..." -ForegroundColor Cyan
        Write-DiagPaso "mkvpropedit + calculo nombre: INICIO"
        Set-ProgresoGui ([int]($global:pctBaseGui + $global:pctPasoGui * 0.60)) "Aplicando banderas $($global:idxGrupoGui)/$($global:totalGruposGui)" $archivoPrincipal.Name
        Set-Banderas $archivoSalidaTemporal $audiosOrdenados $subsOrdenados $defAudioArchivo
        Assert-HdzMux $archivoSalidaTemporal @($audiosOrdenados).Count @($subsOrdenados).Count $archivoPrincipal.FullName

        # Leemos los datos técnicos del archivo final ya muxeado (resolución, audio, HDR, códec).
        # Es la fuente fiable: refleja exactamente lo que mediainfo verá en el .mkv resultante,
        # incluyendo la combinación DV+HDR10+ que solo aparece tras la fusión con dovi_tool.
        # Nota: hay que invalidar la cache de mediainfo para este path porque el archivo
        # acaba de ser modificado por mkvmerge/mkvpropedit.
        $cacheMediainfo.Remove($archivoSalidaTemporal) | Out-Null
        $datosTec = Get-DatosTecnicosMkv $archivoSalidaTemporal

        $resStr      = $datosTec.Resolucion
        $codecVideo  = $datosTec.CodecVideo
        $hdrVideo    = $datosTec.HdrVideo
        $audioFichero = $datosTec.AudioPista

        # Cambio 2b: el nombre del archivo se basa en el MEJOR audio del idioma prioritario,
        # prefiriendo DTS sobre Dolby. Recorremos $audiosOrdenados (ya ordenado por idioma),
        # tomamos el idioma de mayor prioridad presente, y dentro de ese idioma elegimos:
        #   - si hay DTS, el mejor DTS (DTS-HD MA > DTS)
        #   - si no hay DTS, el mejor Dolby (el primero de ese idioma)
        # El resultado sustituye al audio "por defecto" (primera pista) que daba Get-DatosTecnicosMkv.
        if ($audiosOrdenados -and $audiosOrdenados.Count -gt 0) {
            $pesoMin = ($audiosOrdenados | Measure-Object PesoLang -Minimum).Minimum
            $audiosIdiomaTop = @($audiosOrdenados | Where-Object { $_.PesoLang -eq $pesoMin })
            $audioParaNombre = $null
            # ¿hay DTS en el idioma prioritario?
            $dtsDelTop = @($audiosIdiomaTop | Where-Object { $_.Format -match "(?i)DTS" })
            if ($dtsDelTop.Count -gt 0) {
                # Mejor DTS: DTS-HD MA antes que DTS pelado
                $audioParaNombre = $dtsDelTop | Sort-Object @{Expression={ if ($_.Profile -match "(?i)MA|Master Audio" -or $_.Comm -match "(?i)MA|Master Audio") {1} else {0} }; Descending=$true} | Select-Object -First 1
            } else {
                # No hay DTS: el primer audio del idioma top (que será el mejor Dolby por orden)
                $audioParaNombre = $audiosIdiomaTop[0]
            }
            if ($audioParaNombre) {
                # Reconstruir la cadena "CODEC CANALES [Atmos]" desde la pista elegida (sin idioma)
                $aFmt = $audioParaNombre.Format; $aProf = $audioParaNombre.Profile; $aComm = $audioParaNombre.Comm
                $cN = switch ("$($audioParaNombre.Chan)") { "8" {"7.1"} "6" {"5.1"} "2" {"2.0"} "1" {"1.0"} default { "$($audioParaNombre.Chan)" } }
                if (-not $cN) { $cN = "2.0" }
                $cod = $aFmt
                if ($aFmt -match "(?i)E-?AC-?3" -or $aComm -match "(?i)Plus" -or $aProf -match "(?i)E-?AC-?3") { $cod = "DD+" }
                elseif ($aFmt -match "(?i)AC-?3")    { $cod = "DD" }
                elseif ($aFmt -match "(?i)TrueHD|MLP") { $cod = "TrueHD" }
                elseif ($aFmt -match "(?i)DTS") {
                    if ($aProf -match "(?i)MA|Master Audio" -or $aComm -match "(?i)MA|Master Audio") { $cod = "DTS-HD MA" } else { $cod = "DTS" }
                }
                elseif ($aFmt -match "(?i)AAC") { $cod = "AAC" }
                elseif ($aFmt -match "(?i)FLAC") { $cod = "FLAC" }
                elseif ($aFmt -match "(?i)PCM|LPCM") { $cod = "LPCM" }
                $atmN = if ($aComm -match "(?i)Atmos" -or $aFmt -match "(?i)Atmos") { " Atmos" } else { "" }
                $audioFichero = "$cod $cN$atmN"
            }
        }

        # Volcado al log de los datos técnicos releídos del archivo final.
        Write-DiagSeccion "DATOS TÉCNICOS RELEÍDOS DEL ARCHIVO FINAL"
        Write-DiagLinea "Resolucion: $resStr"
        Write-DiagLinea "CodecVideo: $codecVideo"
        Write-DiagLinea "HdrVideo: '$hdrVideo'  (vacío si no detectado)"
        Write-DiagLinea "AudioPista (Get-DatosTecnicosMkv): '$($datosTec.AudioPista)'"
        Write-DiagLinea "AudioFichero (para nombre, regla DTS): '$audioFichero'"

        $base = "$tituloPelicula ($anoPelicula)"
        if ($serieTag) { $base += " $serieTag" }

        # =========================================================================
        # CONSTRUCCIÓN DEL NOMBRE FINAL SEGÚN NORMAS HDZ
        # =========================================================================
        # Separador: ESPACIO en todos los casos (WEB-DL y Físico).
        # Audio: el formato leído del archivo final, sin idioma (ej: "DD+ 5.1", "TrueHD 7.1 Atmos").
        # =========================================================================

        # Sufijo -HDZ: opcional según elección del usuario (cambio 5).
        $sufijoHDZ = if ($sufijoEste) { "-HDZ" } else { "" }

        if ($tipoOrigen -eq "WEB") {
            # Patrón WEB: Título (Año) [Etiq] [SXXEXX] 2160p PLAT WEB-DL|WEBRip AUDIO [HDR] H.265[-HDZ].mkv
            $piezas = @()
            $piezas += $base
            if ($etiquetasExtra) { $piezas += $etiquetasExtra }
            $piezas += $resStr
            $piezas += $plataformaFormato
            $piezas += $webTipo   # "WEB-DL" o "WEBRip"
            $piezas += $audioFichero
            if ($hdrVideo) { $piezas += $hdrVideo }
            $piezas += if ($codecVideo -eq "AV1") { "AV1$sufijoHDZ" } else { "H.$codecVideo$sufijoHDZ" }
        } else {
            # Patrón Físico: Título (Año) [Etiq] FORMATO RESOLUCION [CAPA] [CODEC] AUDIO[-HDZ].mkv
            # CODEC: "x265"/"x264" en Rip y MHD; "HEVC" en Remastered; vacío en Full/Remux.
            $codecTag = ""
            if ($plataformaFormato -match "Rip")           { $codecTag = if ($codecVideo -eq "AV1") { "AV1" } else { "x$codecVideo" } }
            elseif ($plataformaFormato -eq "Remastered")   { $codecTag = if ($codecVideo -eq "AV1") { "AV1" } else { "HEVC" } }
            elseif ($plataformaFormato -eq "MHD")          { $codecTag = if ($codecVideo -eq "AV1") { "AV1" } else { "x$codecVideo" } }
            # En Full/Remux el códec NO se incluye

            $piezas = @()
            $piezas += $base
            if ($etiquetasExtra) { $piezas += $etiquetasExtra }
            $piezas += $plataformaFormato
            $piezas += $resStr
            if ($hdrVideo) { $piezas += $hdrVideo }
            if ($codecTag) { $piezas += $codecTag }
            $piezas += "$audioFichero$sufijoHDZ"
        }

        $nombreFinal = (($piezas | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }) -join " ") + ".mkv"
        # Fuera los caracteres que Windows NO admite en un nombre de archivo (: ? * " < > | / \).
        # Son MUY normales en los títulos («Underworld: La Rebelión de los Licántropos»), y sin esto
        # el Rename-Item de más abajo lanzaba IOException («El parámetro no es correcto») y, con
        # $ErrorActionPreference = "Stop", el montaje MORÍA en seco justo tras muxear: te dejaba el
        # archivo bien hecho pero con el nombre «Ensamblaje_...» para siempre y sin ningún error a
        # la vista. El nombre del pack ya se limpiaba así; el del archivo se había quedado sin ello.
        foreach ($chInv in [System.IO.Path]::GetInvalidFileNameChars()) { $nombreFinal = $nombreFinal.Replace("$chInv", "") }
        $nombreFinal = ($nombreFinal -replace "\s+", " ").Trim()

        # =========================================================================
        # FASE 5: CAPTURAS Y LIMPIEZA
        # =========================================================================
        # Limpieza de temporales (antes de renombrar el resultado).
        Write-Host "`n[>>] Limpiando archivos temporales..." -ForegroundColor Cyan
        Write-DiagPaso "Limpieza y renombrado final: INICIO"
        Set-ProgresoGui ([int]($global:pctBaseGui + $global:pctPasoGui * 0.78)) "Limpiando temporales $($global:idxGrupoGui)/$($global:totalGruposGui)" $archivoPrincipal.Name
        foreach ($del in $archivosBorrables) { Remove-Item -LiteralPath $del -Force -ErrorAction SilentlyContinue }
        # Limpiar los .sup extraídos y los .srt convertidos de ESTE archivo. En AMBAS opciones
        # (mantener PGS+SRT / solo SRT) ya se han metido al MKV lo que correspondía, así que estos
        # archivos de paso de la carpeta ya no hacen falta. Como todos llevan el nombre del vídeo
        # delante ("<nombre>_sub_<N>_<lang>.ext"), borramos SOLO los de este archivo (los que
        # empiezan por su nombre), sin tocar los de archivos del lote aún sin procesar.
        # OJO: solo borramos los .sup EXTRAÍDOS (patrón sub_<N>_<lang>), no los .sup sueltos que
        # el usuario haya dejado a mano con otro nombre.
        $prefijoLimpieza = [System.IO.Path]::GetFileNameWithoutExtension($archivoPrincipal.Name)
        $prefijoLimpiezaEsc = [regex]::Escape($prefijoLimpieza)
        # Los subtítulos externos/OCR se conservan: no son temporales de este trabajo.

        # El original permanece intacto hasta verificar el destino final.

        # Las colisiones se resuelven con un sufijo; nunca se libera el nombre borrando la fuente.
        $archivoFinalDestino = Rename-EvitarColision $archivoSalidaTemporal $nombreFinal
        # Si se ensambló en la salida ya está allí; si se trabaja en origen, se mueve al final.
        $yaEnSalida = $carpetaSalidaArch -and ([IO.Path]::GetFullPath((Split-Path $archivoFinalDestino -Parent)).TrimEnd('\') -ieq [IO.Path]::GetFullPath($carpetaSalidaArch).TrimEnd('\'))
        if ($carpetaSalidaArch -and -not $yaEnSalida -and -not $moverAlFinal) {
            try { $archivoFinalDestino = Move-HdzFinalASalida $archivoFinalDestino $carpetaSalidaArch }
            catch { throw "No se pudo guardar en la carpeta de salida. Originales intactos: $($_.Exception.Message)" }
        }
        Assert-HdzMux $archivoFinalDestino @($audiosOrdenados).Count @($subsOrdenados).Count $archivoPrincipal.FullName
        $fuentesOrig = @()
        if (Test-Path -LiteralPath $archivoFinalDestino) {
            # TODOS los archivos fuente de este grupo: 1 normal, 2 en híbrido, y vídeo+audios+subs en
            # remezcla (cada uno en su carpeta de origen). La acción se aplica a todos por igual.
            $fuentesOrig = @(@($origenesPistas) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
            if (@($fuentesOrig).Count -eq 0 -and $archivoPrincipal) { $fuentesOrig = @($archivoPrincipal.FullName) }
            if (-not $moverAlFinal) { Invoke-AccionOriginales $fuentesOrig $accionOrigEste $global:archivoEnCurso }
        }
        # Las capturas van a la carpeta de «procesados + capturas» (ajuste) si está configurada (en su
        # subcarpeta por proyecto); si no, a la carpeta de origen (donde la subida también las localiza).
        $dirCapturasArchivo = if ($dirProcesados) { $dirProcesados } else { $rutaCarpeta }

        # Volcado al log del archivo final, post-renombrado.
        Write-DiagArchivoSalida $archivoFinalDestino $nombreFinal

        # Capturas: tonemapped solo si el vídeo es HDR. $hdrVideo viene de Get-DatosTecnicosMkv
        # (será "DV HDR10", "HDR10", "HDR10+", etc. en HDR; cadena vacía en SDR).
        $videoEsHdr = -not [string]::IsNullOrWhiteSpace($hdrVideo)
        # Capturas POR ARCHIVO (modo «Cada archivo distinto»): si la GUI mandó un valor propio para
        # esta película en ProyectoPorArchivo, se usa; si no, el global $numCapturas.
        $capturasArchivo = $numCapturas
        $cfgPFCaps = Get-CfgGui "ProyectoPorArchivo"
        if ($cfgPFCaps -and $archivoPrincipal -and ($cfgPFCaps.PSObject.Properties.Name -contains $archivoPrincipal.Name)) {
            $ncPF = $cfgPFCaps.$($archivoPrincipal.Name).NumCapturas
            if ($null -ne $ncPF -and [int]$ncPF -ge 0) { $capturasArchivo = [int]$ncPF }
        }
        Set-ProgresoGui ([int]($global:pctBaseGui + $global:pctPasoGui * 0.85)) "Generando capturas $($global:idxGrupoGui)/$($global:totalGruposGui)" (Split-Path $archivoFinalDestino -Leaf)
        New-Capturas $archivoFinalDestino (Split-Path $archivoFinalDestino -Leaf) $capturasArchivo $videoEsHdr $dirCapturasArchivo

        $rutaTorrentFinal = ''
        # Torrent del resultado final (si se pidió). Fallo no fatal: se anota y se sigue.
        if ($modoTorrentEste -in @("INDIVIDUAL", "AMBOS")) {
            Set-ProgresoGui ([int]($global:pctBaseGui + $global:pctPasoGui * 0.93)) "Creando torrent $($global:idxGrupoGui)/$($global:totalGruposGui)" (Split-Path $archivoFinalDestino -Leaf)
            Write-Host "`n[>>] Creando archivo .torrent..." -ForegroundColor Cyan
            try {
                $nomTorr = Split-Path $archivoFinalDestino -Leaf
                Set-ProgresoGui2 0 "Hasheando torrent: $nomTorr"
                # Si el MKV aún está en el disco de trabajo, el .torrent va ya a la carpeta de salida
                # (donde lo dejaba antes, junto al MKV).
                $carpetaTorrentArch = if ($carpetaTorrentGui) { $carpetaTorrentGui } elseif ($moverAlFinal) { $carpetaSalidaArch } else { "" }
                $rutaTorrentFinal = New-TorrentArchivo $archivoFinalDestino $torrentAnnounce "" $carpetaTorrentArch {
                    param($pct) Set-ProgresoGui2 $pct "Hasheando torrent ($pct%)"
                }
                Set-ProgresoGui2 -1
                Write-Host "   -> Torrent creado: $(Split-Path $rutaTorrentFinal -Leaf)" -ForegroundColor Green
            } catch {
                Write-Host "   [!] No se pudo crear el .torrent: $($_.Exception.Message)" -ForegroundColor Red
                Add-Incidencia $global:archivoEnCurso "Fallo creando el .torrent: $($_.Exception.Message)"
            }
        }

        # Viaje único del MKV terminado (capturas y torrent ya hechos en el disco de trabajo).
        if ($moverAlFinal -and -not $packAlFinal) {
            Set-ProgresoGui ([int]($global:pctBaseGui + $global:pctPasoGui * 0.96)) "Moviendo a la carpeta de salida $($global:idxGrupoGui)/$($global:totalGruposGui)" (Split-Path $archivoFinalDestino -Leaf)
            try {
                $archivoFinalDestino = Move-HdzFinalASalida $archivoFinalDestino $carpetaSalidaArch
                Assert-HdzMux $archivoFinalDestino @($audiosOrdenados).Count @($subsOrdenados).Count $archivoPrincipal.FullName
                Invoke-AccionOriginales $fuentesOrig $accionOrigEste $global:archivoEnCurso
            } catch {
                Add-Incidencia $global:archivoEnCurso "No se pudo llevar el MKV a la carpeta de salida; sigue en '$archivoFinalDestino' y los originales no se han tocado: $($_.Exception.Message)"
            }
        } elseif ($moverAlFinal) {
            # Se agrupa al final en la carpeta de temporada/pack (que se arma en el disco de trabajo).
            $global:pendientesSalida.Add([pscustomobject]@{ Ruta = $archivoFinalDestino; Destino = $carpetaSalidaArch; Entregado = $false; Fuentes = $fuentesOrig; Accion = $accionOrigEste; Archivo = $global:archivoEnCurso; Audios = @($audiosOrdenados).Count; Subs = @($subsOrdenados).Count; Principal = $archivoPrincipal.FullName })
        }
        $global:archivosFinalesLote += $archivoFinalDestino
        if ($rutaTorrentFinal) {
            # la GUI crea una pestaña de subida; le pasamos las capturas de ESTE archivo y la
            # carpeta de origen para que las localice aunque el MKV se haya movido a otra carpeta.
            Add-ResultadoGui "archivo" $rutaTorrentFinal $archivoFinalDestino $global:ultimasCapturas $rutaCarpeta
        }

        try {
            $historyIncidents = @($global:incidencias | ForEach-Object { "$_" })
            [void](Add-HdzHistory @{kind='montaje';status=$(if($historyIncidents.Count){'Con incidencias'}else{'Verificado'});sources=@($origenesPistas);video=$archivoFinalDestino;torrent=$rutaTorrentFinal;captures=@($global:ultimasCapturas);incidents=$historyIncidents;tracks=@{video=1;audio=@($audiosOrdenados|ForEach-Object { @{language=$_.CodLang;format=$_.Format;source=$_.ArchivoFuenteMkv} });subtitles=@($subsOrdenados|ForEach-Object { @{language=$_.CodLang;format=$_.Format} })}})
        } catch { Add-Incidencia $global:archivoEnCurso "No se pudo guardar el historial: $($_.Exception.Message)" }
        $etiquetaTipo = if ($esSerie) { "Episodio" } else { "Archivo" }
        Set-ProgresoGui ([int]($global:pctBaseGui + $global:pctPasoGui)) "Completado $($global:idxGrupoGui)/$($global:totalGruposGui)" (Split-Path $archivoFinalDestino -Leaf)
        Write-Host " ¡OK! $etiquetaTipo completado: $(Split-Path $archivoFinalDestino -Leaf) " -ForegroundColor Green
        Write-DiagPaso "FIN archivo OK: $(Split-Path $archivoFinalDestino -Leaf)"

    } catch {
        # D2: capturamos cualquier excepción no controlada para no abortar el batch
        Write-Host "`n[!] EXCEPCIÓN procesando el grupo: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
        Add-Incidencia $global:archivoEnCurso "EXCEPCIÓN no controlada: $($_.Exception.Message)"
        try { [void](Add-HdzHistory @{kind='montaje';status='Fallido';sources=@($origenesPistas);video=$archivoFinalDestino;torrent=$rutaTorrentFinal;incidents=@($_.Exception.Message)}) } catch {}
        # Limpieza defensiva de temporales (nombres clásicos y con sufijo de este proceso)
        foreach ($temporary in @($archivosBorrables)) {
            if ($temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        }
        Write-Host "   -> Continuando con el siguiente elemento..." -ForegroundColor Yellow
        continue
    }
}

# =========================================================================
# TORRENT DE PACK (lote completo): se crea una carpeta con el nombre del pack,
# se mueven dentro los MKV finales y se genera el .torrent multi-archivo junto
# a ella, listo para subir y sembrar.
# =========================================================================
# La CARPETA de temporada se crea cuando el modo es "Mismo proyecto" (HOMOGENEO) con VARIOS episodios
# — independiente del torrent. El .torrent del pack se crea solo si se eligió PACK/AMBOS. En
# INDIVIDUAL NO se agrupa (los .torrent por episodio ya apuntan a los archivos sueltos).
$nFinales = @($global:archivosFinalesLote).Count
$hacerTorrentPack = ($modoTorrent -in @("PACK", "AMBOS")) -and $nFinales -gt 0
$agruparTemporada = ($modoLote -eq "HOMOGENEO") -and $nFinales -gt 1 -and ($modoTorrent -ne "INDIVIDUAL")
if ($hacerTorrentPack -or $agruparTemporada) {
    try {
        # Nombre de la carpeta/pack: se HEREDA del nombre de un episodio, sustituyendo SxxEyy(-Ezz)
        # por Sxx (convención de temporada). Por defecto sería el del E01, pero si la temporada
        # MEZCLA specs (unos episodios H.264 y otros H.265, o unos DD+ 5.1 y otros DD 2.0…), el pack
        # debe llevar el nombre de la MAYORÍA de episodios: si no, una temporada casi toda en H.265
        # saldría como "H.264" solo porque el E01 lo era (igual con el audio). Se vota por el NOMBRE
        # COMPLETO ya normalizado (sin el número de episodio): así el códec, el audio, el HDR y la
        # resolución del pack son los del grueso de la temporada de una vez, y el nombre es SIEMPRE
        # el real de un episodio (no se manipulan cadenas -> imposible generar un token inválido).
        # Empate -> gana el E01 (no se cambia el comportamiento sin un motivo claro).
        $finalesPack = @($global:archivosFinalesLote)
        $normalizarEp = {
            param($ruta)
            $sinExt = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path $ruta -Leaf))
            (($sinExt -replace '(?i)\b(S\d{1,3})E\d{1,4}(?:-E?\d{1,4})*\b', '$1') -replace '\s+', ' ').Trim()
        }
        $normLote = @($finalesPack | ForEach-Object { & $normalizarEp $_ })
        $nombrePackAuto = $normLote[0]   # por defecto, el del primer episodio (E01)
        if ($finalesPack.Count -gt 1) {
            $conteoNorm = @{}
            foreach ($nm in $normLote) { $conteoNorm[$nm] = 1 + [int]$conteoNorm[$nm] }
            $maxC = ($conteoNorm.Values | Measure-Object -Maximum).Maximum
            if ($maxC -gt 1 -and $conteoNorm.Keys.Count -gt 1) {
                # Hay specs mezcladas. Si el E01 ya es (co)mayoritario se queda; si no, se toma el
                # primer episodio cuyo nombre normalizado sea el más repetido.
                if ([int]$conteoNorm[$normLote[0]] -ne $maxC) {
                    for ($qi = 0; $qi -lt $normLote.Count; $qi++) {
                        if ([int]$conteoNorm[$normLote[$qi]] -eq $maxC) { $nombrePackAuto = $normLote[$qi]; break }
                    }
                }
                $reparto = ($conteoNorm.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "«$($_.Key)» x$($_.Value)" }) -join " · "
                Write-Host "`n[i] Episodios con specs mezcladas (codec/audio/HDR). El pack usa el nombre mayoritario:" -ForegroundColor DarkYellow
                Write-Host "    $nombrePackAuto" -ForegroundColor DarkYellow
                Write-Host "    Reparto: $reparto" -ForegroundColor DarkGray
            }
        }
        $cfgNombrePack = Get-CfgGui "TorrentPackNombre"
        $nombrePack = if ($cfgNombrePack) {
            Write-Host "`n[GUI] Nombre de la temporada/pack: $("$cfgNombrePack".Trim()) (configuración)." -ForegroundColor DarkGray
            "$cfgNombrePack".Trim()
        } elseif ($global:cfgGui) {
            Write-Host "`n[GUI] Nombre de la temporada/pack (automático): $nombrePackAuto" -ForegroundColor DarkGray
            $nombrePackAuto
        } else {
            $rPack = Read-Host "`nNombre del pack (ENTER = $nombrePackAuto)"
            if ([string]::IsNullOrWhiteSpace($rPack)) { $nombrePackAuto } else { $rPack.Trim() }
        }
        foreach ($chInv in [System.IO.Path]::GetInvalidFileNameChars()) { $nombrePack = $nombrePack.Replace("$chInv", "") }
        if ([string]::IsNullOrWhiteSpace($nombrePack)) { $nombrePack = "Temporada HDZ" }

        Write-Host "`n[>>] Agrupando $nFinales archivo(s) en la carpeta '$nombrePack'..." -ForegroundColor Cyan
        Set-ProgresoGui 98 $(if ($hacerTorrentPack) { "Creando torrent del pack…" } else { "Agrupando temporada…" }) $nombrePack
        $baseDirPack = if ($carpetaSalidaGui) { $carpetaSalidaGui } else { $rutaCarpeta }
        $rutaPackFinal = Join-Path $baseDirPack $nombrePack
        $pendientesPorRuta = @{}
        foreach ($pend in $global:pendientesSalida) { $pendientesPorRuta[$pend.Ruta] = $pend }
        # Si todos los MKV siguen en el disco de trabajo, el pack se arma y se hashea allí y después
        # viaja una sola vez. Si no, como siempre: se arma directamente en la salida.
        $packLocal = $pendientesPorRuta.Count -gt 0 -and @($global:archivosFinalesLote | Where-Object { -not $pendientesPorRuta.ContainsKey($_) }).Count -eq 0 -and
                     ([IO.Path]::GetFullPath($baseDirPack).TrimEnd('\') -ine [IO.Path]::GetFullPath($rutaCarpeta).TrimEnd('\'))
        $rutaPack = if ($packLocal) { Join-Path $rutaCarpeta $nombrePack } else { $rutaPackFinal }
        if ($packLocal -and (Test-Path -LiteralPath $rutaPackFinal)) {
            $ocupados = @($global:archivosFinalesLote | Where-Object { Test-Path -LiteralPath (Join-Path $rutaPackFinal (Split-Path $_ -Leaf)) })
            if ($ocupados.Count) { throw "El pack de destino ya contiene '$(Split-Path $ocupados[0] -Leaf)'. No se reutiliza; los nuevos MKV se conservan en '$rutaCarpeta'." }
        }
        [void][System.IO.Directory]::CreateDirectory($rutaPack)
        # Si el pack cae en otro disco, cada archivo se COPIA entero: progreso por archivo (i/n) y,
        # dentro de cada uno, el byte a byte que pinta Move-ConProgreso.
        $iPack = 0; $nPack = [Math]::Max(1, @($global:archivosFinalesLote).Count)
        Set-ProgresoGui2 0 "Moviendo archivos a la carpeta…"
        foreach ($fFinal in $global:archivosFinalesLote) {
            $iPack++
            if (Test-Path -LiteralPath $fFinal) {
                $destinoPack = Join-Path $rutaPack (Split-Path $fFinal -Leaf)
                if ((Test-Path -LiteralPath $destinoPack) -and $destinoPack -ne $fFinal) {
                    throw "El pack ya contiene '$([IO.Path]::GetFileName($destinoPack))'. No se reutiliza; el nuevo se conserva en '$fFinal'."
                }
                if (-not (Test-Path -LiteralPath $destinoPack)) {
                    Set-ProgresoGui2 ([int](100 * ($iPack - 1) / $nPack)) "Moviendo al pack $iPack/$nPack…"
                    Move-ConProgreso $fFinal $destinoPack "Moviendo al pack ($iPack/$nPack)"
                    if ($pendientesPorRuta.ContainsKey($fFinal)) { $pendientesPorRuta[$fFinal].Ruta = $destinoPack }
                    if (-not $packLocal) { [void](Add-HdzHistory @{kind='traslado';status='Guardado en el pack';sources=@($fFinal);video=$destinoPack}) }
                }
            }
        }
        Set-ProgresoGui2 -1
        if ($hacerTorrentPack) {
            Set-ProgresoGui2 0 "Hasheando torrent del pack…"
            # Armado en local, el .torrent se guarda ya donde quedará el pack (junto a su carpeta).
            $carpetaTorrentPack = if ($carpetaTorrentGui) { $carpetaTorrentGui } elseif ($packLocal) { $baseDirPack } else { "" }
            $rutaTorrentPack = New-TorrentPack $rutaPack $torrentAnnounce "" $carpetaTorrentPack {
                param($pct) Set-ProgresoGui2 $pct "Hasheando torrent del pack ($pct%)"
            } -expectedFiles @($global:archivosFinalesLote | ForEach-Object { Join-Path $rutaPack (Split-Path $_ -Leaf) })
            Set-ProgresoGui2 -1
        }
        if ($packLocal) {
            # Viaje único de la temporada ya hasheada a su carpeta de salida.
            [void][System.IO.Directory]::CreateDirectory($rutaPackFinal)
            $iPack = 0
            foreach ($pend in @($global:pendientesSalida)) {
                $iPack++
                if (-not (Test-Path -LiteralPath $pend.Ruta)) { continue }
                $destinoPack = Join-Path $rutaPackFinal (Split-Path $pend.Ruta -Leaf)
                Set-ProgresoGui2 ([int](100 * ($iPack - 1) / $nPack)) "Moviendo el pack a la salida $iPack/$nPack…"
                Move-ConProgreso $pend.Ruta $destinoPack "Moviendo el pack a la salida ($iPack/$nPack)"
                [void](Add-HdzHistory @{kind='traslado';status='Guardado en el pack';sources=@($pend.Ruta);video=$destinoPack})
                $pend.Ruta = $destinoPack; $pend.Entregado = $true
            }
            Set-ProgresoGui2 -1
            if (-not @(Get-ChildItem -LiteralPath $rutaPack -Force -ErrorAction SilentlyContinue).Count) { Remove-Item -LiteralPath $rutaPack -Force -ErrorAction SilentlyContinue }
            $rutaPack = $rutaPackFinal
        } else {
            foreach ($pend in $global:pendientesSalida) { if ($pend.Ruta.StartsWith($rutaPackFinal.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $pend.Entregado = $true } }
        }
        if ($hacerTorrentPack) {
            Write-Host "   -> Pack listo: carpeta '$nombrePack' + $(Split-Path $rutaTorrentPack -Leaf)" -ForegroundColor Green
            $primerVideoPack = @(Get-ChildItem -LiteralPath $rutaPack -File -Recurse -ErrorAction SilentlyContinue |
                                 Where-Object { $_.Extension -match "(?i)^\.(mkv|mp4)$" } | Sort-Object FullName | Select-Object -First 1)
            # En el PACK las capturas conservan el nombre de cada episodio (no el del pack), así que
            # pasamos las rutas exactas de TODO el lote + la carpeta de origen donde quedaron.
            Add-ResultadoGui "pack" $rutaTorrentPack $(if ($primerVideoPack.Count) { $primerVideoPack[0].FullName } else { "" }) $global:capturasLote $rutaCarpeta
            [void](Add-HdzHistory @{kind='pack';status='Pack creado';video=$rutaPack;torrent=$rutaTorrentPack;captures=@($global:capturasLote)})
        } else {
            Set-ProgresoGui2 -1
            Write-Host "   -> Temporada agrupada en: $rutaPack (sin torrent)." -ForegroundColor Green
        }
    } catch {
        Write-Host "   [!] No se pudo agrupar/crear el torrent de la temporada: $($_.Exception.Message)" -ForegroundColor Red
        Add-Incidencia $null "Fallo agrupando la temporada/creando el torrent: $($_.Exception.Message)"
    }
}

# MKV terminados que siguen en el disco de trabajo (sin pack, o si el pack falló): viaje a su
# carpeta de salida. La acción sobre los originales solo se aplica si el MKV llegó y se verificó.
foreach ($pend in @($global:pendientesSalida)) {
    try {
        if (-not $pend.Entregado -and (Test-Path -LiteralPath $pend.Ruta)) {
            $pend.Ruta = Move-HdzFinalASalida $pend.Ruta $pend.Destino
            $pend.Entregado = $true
        }
        if ($pend.Entregado) {
            Assert-HdzMux $pend.Ruta $pend.Audios $pend.Subs $pend.Principal
            Invoke-AccionOriginales $pend.Fuentes $pend.Accion $pend.Archivo
        }
    } catch {
        Add-Incidencia $pend.Archivo "No se pudo llevar el MKV a la carpeta de salida; sigue en '$($pend.Ruta)' y los originales no se han tocado: $($_.Exception.Message)"
    }
}

# Resumen final: si hubo incidencias, las listamos para que no pasen desapercibidas.
if ($global:incidencias.Count -gt 0) {
    Write-Host "`n=========================================" -ForegroundColor Yellow
    Write-Host " PROCESO TERMINADO CON $($global:incidencias.Count) INCIDENCIA(S) " -ForegroundColor Yellow
    Write-Host "=========================================" -ForegroundColor Yellow
    foreach ($inc in $global:incidencias) {
        Write-Host "  [!] $inc" -ForegroundColor Red
    }
    Write-Host "`nRevisa el log para más detalle: $rutaLog" -ForegroundColor DarkYellow
    Set-ProgresoGuiFin "Terminado con $($global:incidencias.Count) incidencia(s)"
} else {
    Write-Host "`n=========================================" -ForegroundColor Green
    Write-Host " ¡TODOS LOS ARCHIVOS PROCESADOS CON ÉXITO! " -ForegroundColor Green
    Write-Host "=========================================" -ForegroundColor Green
    Set-ProgresoGuiFin "¡Todos los archivos procesados!"
}

try { Stop-Transcript | Out-Null } catch {}

# Limpieza global de seguridad: borrar cualquier .sup residual de Subtitle Edit que pudiera
# haber quedado (archivos de paso, nunca se muxean).
try {
    # Sin limpieza global por patrón: los subtítulos preparados se conservan.
} catch {}

# Anexar el diagnóstico al log principal (un solo archivo final) y borrar el temporal.
# Se hace tras Stop-Transcript para que el log ya no esté bloqueado por el transcript.
try {
    if (Test-Path -LiteralPath $global:rutaDiag) {
        Add-Content -LiteralPath $rutaLog -Value "`r`n`r`n=================== DIAGNÓSTICO DETALLADO ===================`r`n" -Encoding UTF8
        Get-Content -LiteralPath $global:rutaDiag -Encoding UTF8 | Add-Content -LiteralPath $rutaLog -Encoding UTF8
        Remove-Item -LiteralPath $global:rutaDiag -ErrorAction SilentlyContinue
    }
} catch {}
