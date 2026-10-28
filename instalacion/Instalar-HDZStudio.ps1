# =========================================================================
# Instalar-HDZStudio.ps1  —  Instalador / configurador de HDZ Studio
# =========================================================================
# Deja el programa listo para usar en CUALQUIER equipo Windows, sin importar
# lo que el usuario tenga instalado:
#   - Descarga las herramientas portables (ffmpeg, mkvmerge/mkvextract/mkvpropedit,
#     mediainfo, dovi_tool) a la carpeta "bin\" junto al programa. El programa
#     usa SIEMPRE esas (PATH local) -> da igual versiones viejas o que no estén
#     en el PATH del sistema.
#   - Asegura PowerShell 7 (winget -> MSI -> instrucción manual).
#   - Crea el acceso directo "HDZ Studio" (Escritorio + Menú Inicio) con su icono.
#
# IMPORTANTE: este script está escrito para Windows PowerShell 5.1 (el que viene
# de serie en todo Windows 10/11), porque tiene que poder ejecutarse ANTES de
# instalar PowerShell 7. No usar sintaxis exclusiva de PS7 (?:, ??, ?.).
# =========================================================================

# --- Versiones de las herramientas que no se auto-resuelven por URL "latest" ---
# (ffmpeg y dovi_tool se resuelven solos a la última; estas dos llevan la versión
#  en la URL, así que cuando salga una nueva basta con actualizar el número aquí.)
param([switch]$SkipContextMenu, [switch]$SkipShortcuts)

$verMkvtoolnix = "99.0"
$verMediaInfo  = "26.05"

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
}
$setupLog = Join-Path $env:TEMP 'HDZ-Studio-setup.log'
trap {
    try {
        Add-Content -LiteralPath $setupLog -Encoding UTF8 -Value ("[{0:yyyy-MM-dd HH:mm:ss}] ERROR: {1}`n{2}" -f (Get-Date), $_.Exception.Message, ($_ | Out-String))
    } catch {}
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Registro detallado: $setupLog" -ForegroundColor Yellow
    exit 1
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

function Escribe($txt, $color = "Gray") { Write-Host $txt -ForegroundColor $color }
function Titulo($txt) { Write-Host ""; Write-Host "==== $txt ====" -ForegroundColor Cyan }

# --- Localizar la carpeta del programa (donde está HDZ-GUI.ps1) -----------
$instalDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$candidatos = @((Split-Path -Parent $instalDir), $instalDir)
$appRoot = $null
foreach ($c in $candidatos) {
    if ($c -and (Test-Path -LiteralPath (Join-Path $c "HDZ-GUI.ps1"))) { $appRoot = $c; break }
}
if (-not $appRoot) {
    Escribe "No encuentro HDZ-GUI.ps1. Pon esta carpeta 'instalacion' DENTRO de la carpeta del programa." "Red"
    return
}
$bin = Join-Path $appRoot "bin"
[void][System.IO.Directory]::CreateDirectory($bin)
# El instalador completo contiene las herramientas probadas. No se sustituuyen
# por builds "latest" descargadas durante la instalación.
$toolLockPath = Join-Path $appRoot 'tools.lock.json'
if (-not (Test-Path -LiteralPath $toolLockPath)) { throw 'Falta tools.lock.json. Usa el instalador completo de HDZ Studio.' }
$toolLock = Get-Content -LiteralPath $toolLockPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($required in @('ffmpeg.exe','ffprobe.exe','mkvmerge.exe','mkvextract.exe','mkvpropedit.exe','MediaInfo.exe','dovi_tool.exe','PowerShell-7.6.3-win-x64.msi')) {
    if ($required -notin @($toolLock.files.name)) { throw "El paquete no declara $required. Instalación cancelada." }
}
foreach ($tool in $toolLock.files) {
    $toolPath = Join-Path $bin $tool.name
    if ([IO.Path]::GetFileName($tool.name) -ne $tool.name -or -not (Test-Path -LiteralPath $toolPath) -or (Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash -ne $tool.sha256) { throw "Herramienta ausente o modificada: $($tool.name). Reinstala el paquete completo." }
}
$tmp = Join-Path $env:TEMP ("hdz_inst_" + [System.Guid]::NewGuid().ToString("N"))
[void][System.IO.Directory]::CreateDirectory($tmp)

Escribe ""
Escribe "  HDZ Studio — Instalador" "White"
Escribe "  Programa : $appRoot"
Escribe "  Herramientas (bin) : $bin"

# Las herramientas son exactamente las del paquete verificado.
$resumen = @()
$rutaVerJson = Join-Path $bin 'herramientas.json'
$verInstaladas = @{ paquete = $toolLock.version }
foreach ($tool in $toolLock.files) { $resumen += [pscustomobject]@{Herramienta=$tool.name;Estado='OK (SHA256 verificado)'} }
function RutaPwsh {
    # Un proceso de PowerShell de 32 bits puede tener ProgramFiles redirigido.
    $programFilesNative = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $expected = Join-Path $programFilesNative 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $expected) { return $expected }
    return $null
}
function Get-HdzRuntimeInstallOptions([string]$Msi, [bool]$AlreadyAdmin) {
    $options=@{FilePath=(Join-Path $env:WINDIR 'System32\msiexec.exe');ArgumentList=@('/i',('"'+$Msi+'"'),'/quiet','/norestart','ADD_PATH=1');WindowStyle='Hidden';Wait=$true;PassThru=$true;ErrorAction='Stop'}
    if(-not $AlreadyAdmin){$options.Verb='RunAs'}
    return $options
}
$pwshPath = RutaPwsh
if (-not $pwshPath) {
    $msi = Join-Path $bin 'PowerShell-7.6.3-win-x64.msi'
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $runtimeOptions=Get-HdzRuntimeInstallOptions $msi ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    $install = Start-Process @runtimeOptions
    if ($install.ExitCode -notin @(0,3010)) { throw "PowerShell no se pudo instalar (código $($install.ExitCode))." }
    $pwshPath = RutaPwsh
    if (-not $pwshPath) { throw 'PowerShell no está disponible tras instalarlo.' }
}
# .NET 8 solo se necesita para la extensión moderna del menú contextual.
# Esa instalación es opcional y se intenta más abajo junto al menú; un fallo
# de red o una política de Windows no debe impedir usar HDZ Studio.


# --- Lanzador oculto (.vbs) + acceso directo con icono ---------------------
Titulo "Acceso directo"
$vbs = Join-Path $appRoot "HDZ Studio.vbs"
$gui = Join-Path $appRoot "HDZ-GUI.ps1"
$exePwsh = $pwshPath
if (-not $exePwsh) { $exePwsh = "pwsh" }   # si aun no esta, se resolvera por PATH cuando exista
# El .vbs arranca pwsh OCULTO (sin consola). Comillas dobles escapadas para VBScript.
$contVbs = 'CreateObject("WScript.Shell").Run """' + $exePwsh + '"" -NoProfile -ExecutionPolicy Bypass -File ""' + $gui + '""", 0, False'
Set-Content -LiteralPath $vbs -Value $contVbs -Encoding ASCII
Escribe "  Lanzador: $vbs"

$ico = Join-Path $appRoot "HDZ.ico"
function CreaAcceso($destinoLnk) {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($destinoLnk)
    $lnk.TargetPath = "$env:WINDIR\System32\wscript.exe"
    $lnk.Arguments = '"' + $vbs + '"'
    $lnk.WorkingDirectory = $appRoot
    if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = $ico }
    $lnk.Description = "HDZ Studio"
    $lnk.Save()
}
if (-not $SkipShortcuts) { try {
    $escritorio = [Environment]::GetFolderPath("Desktop")
    CreaAcceso (Join-Path $escritorio "HDZ Studio.lnk")
    $menu = Join-Path ([Environment]::GetFolderPath("Programs")) "HDZ Studio.lnk"
    CreaAcceso $menu
    Escribe "  Creado en Escritorio y Menu Inicio." "Green"
} catch {
    Escribe "  [!] No pude crear el acceso directo: $($_.Exception.Message)" "Yellow"
} }

# --- Menú contextual de capturas ------------------------------------------
# El instalador separado se autoeleva para registrar el respaldo clásico en
# HKLM y la extensión moderna de Windows 11.
$instMenuCapturas = Join-Path $appRoot "instalacion\Instalar-menu-capturas.ps1"
if (-not $SkipContextMenu -and (Test-Path -LiteralPath $instMenuCapturas)) {
    Titulo "Menú contextual"
    try { & $instMenuCapturas } catch { Escribe "  [!] No pude instalar el menú contextual: $($_.Exception.Message)" "Yellow" }
}

# --- Verificacion final ----------------------------------------------------
Titulo "Verificacion"
$chequeos = @(
    @{ N = "ffmpeg";      F = "ffmpeg.exe" },
    @{ N = "ffprobe";     F = "ffprobe.exe" },
    @{ N = "mkvmerge";    F = "mkvmerge.exe" },
    @{ N = "mkvextract";  F = "mkvextract.exe" },
    @{ N = "mkvpropedit"; F = "mkvpropedit.exe" },
    @{ N = "mediainfo";   F = "MediaInfo.exe" },
    @{ N = "dovi_tool";   F = "dovi_tool.exe" }
)
foreach ($c in $chequeos) {
    $ok = Test-Path -LiteralPath (Join-Path $bin $c.F)
    if ($ok) { Escribe ("  [OK]   " + $c.N) "Green" } else { Escribe ("  [FALTA] " + $c.N + "  -> ver el aviso MANUAL de arriba") "Yellow" }
}

# Registrar las versiones instaladas (bin\herramientas.json) para futuras actualizaciones:
# así, al cambiar una versión objetivo, el instalador sabe qué re-descargar y qué dejar igual.
try { ($verInstaladas | ConvertTo-Json) | Set-Content -LiteralPath $rutaVerJson -Encoding UTF8 } catch {}

# Limpieza de temporales
try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}

Titulo "Resumen"
$resumen | Format-Table -AutoSize | Out-String | Write-Host
Escribe ""
Escribe "  Listo. Abre 'HDZ Studio' desde el acceso directo del Escritorio." "White"
Escribe "  (Si acabas de instalar PowerShell 7, cierra y vuelve a abrir sesion si el acceso no arranca a la primera.)" "Gray"
Escribe ""
