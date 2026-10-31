# Distribución completa firmada, verificación SHA256 y reversión ante fallos.
param([switch]$Forzar, [switch]$NoRelanzar, [int]$WaitForProcessId=0)
# Start-Process desde PowerShell 7 hereda PSModulePath con sus módulos primero.
# Windows PowerShell 5.1 necesita sus propios módulos (p. ej. Get-FileHash).
# Solo se cambia el entorno de ESTE actualizador, no el del usuario/sistema.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
}
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$appRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$temporary = Join-Path $env:TEMP ('hdz_update_' + [guid]::NewGuid().ToString('N'))
$client = New-Object Net.WebClient
$client.Headers.Add('User-Agent', 'HDZ-Studio-Updater')
$applied = [Collections.Generic.List[object]]::new()
$mutex = $null; $ownsMutex = $false
$relaunched = $false
$resultPath = Join-Path $PSScriptRoot 'ultimo-resultado.json'
function Resolve-UpdatePath($Root, $Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.{1,2}([\\/]|$)|:|[\x00-\x1f]' -or $Relative -match '(?i)\.cfg$|\.env$|\.settings\.json$') { throw "Ruta de actualización no permitida: $Relative" }
    $resolved = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $resolved.StartsWith($Root.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'La actualización intenta salir de su carpeta.' }
    return $resolved
}
function Download-UpdateFile([string]$Relative, [string]$Destination) {
    $encoded = (($Relative -split '[\\/]' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
    $candidates = @(@($script:downloadPreferredBase) + @($bases) | Where-Object { $_ } | Select-Object -Unique)
    foreach ($candidate in $candidates) {
        for ($attempt=1; $attempt -le 2; $attempt++) {
            try {
                if ($candidate -match '^file:') { $client.DownloadFile($candidate + $encoded, $Destination) }
                else { Invoke-WebRequest -Uri ($candidate + $encoded) -OutFile $Destination -UseBasicParsing -TimeoutSec 60 -UserAgent 'HDZ-Studio-Updater' -ErrorAction Stop | Out-Null }
                $script:downloadPreferredBase = $candidate
                return
            } catch {
                if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
                Write-Host "No se pudo descargar $Relative (intento $attempt/2). Se probará otra vez u otra conexión." -ForegroundColor Yellow
            }
        }
    }
    throw "No se pudo descargar $Relative por ninguna conexión. No se ha aplicado la actualización; inténtalo de nuevo más tarde."
}
try {
    if (-not (Test-Path -LiteralPath (Join-Path $appRoot 'HDZ-GUI.ps1'))) { throw 'No se reconoce la instalación de HDZ Studio.' }
    $mutex = [Threading.Mutex]::new($false, 'Global\HDZStudio.Actualizador')
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Ya hay una actualización en curso.' }
    $config = Get-Content -LiteralPath (Join-Path $appRoot 'HDZ-update.config.json') -Raw | ConvertFrom-Json
    $base = "$env:HDZ_UPDATE_BASE"
    if (-not $base) { $base = "$($config.baseUrl)" }
    # GitHub Releases: la última release estable publica version.json, version.sig y el zip.
    if (-not $base -and "$($config.repo)" -match '^[\w.-]+/[\w.-]+$') { $base = "https://github.com/$($config.repo)/releases/latest/download/" }
    if (-not $base) { throw 'No hay origen de actualizaciones configurado.' }
    $base = $base.TrimEnd('/') + '/'
    if ($base -notmatch '^https://' -and -not ($env:HDZ_UPDATE_BASE -and $base -match '^file:')) { throw 'Las actualizaciones requieren HTTPS.' }
    $bases = @($base)
    if (-not $env:HDZ_UPDATE_BASE) {
        foreach ($fallback in @($config.fallbackUrls | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })) {
            if ("$fallback" -notmatch '^https://') { throw 'La conexión alternativa de actualización requiere HTTPS.' }
            $bases += "$fallback".TrimEnd('/') + '/'
        }
    }
    $script:downloadPreferredBase = $null
    [void][IO.Directory]::CreateDirectory($temporary)
    $manifestPath = Join-Path $temporary 'version.json'; $signaturePath = Join-Path $temporary 'version.sig'
    Download-UpdateFile 'version.json' $manifestPath
    Download-UpdateFile 'version.sig' $signaturePath
    $trustedKey = Join-Path $appRoot 'update-public-key.xml'
    if (-not (Test-Path -LiteralPath $trustedKey)) { throw 'Falta la clave de actualización. Instala el paquete completo firmado.' }
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.FromXmlString([IO.File]::ReadAllText($trustedKey))
        $signature = [Convert]::FromBase64String([IO.File]::ReadAllText($signaturePath).Trim())
        if (-not $rsa.VerifyData([IO.File]::ReadAllBytes($manifestPath), 'SHA256', $signature)) { throw 'Firma inválida. No se cambia ningún archivo.' }
    } finally { $rsa.Dispose() }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -ne 2 -or -not $manifest.sha256 -or @($manifest.archivos).Count -lt 5) { throw 'Manifiesto incompleto.' }
    $localVersion = (Get-Content -LiteralPath (Join-Path $appRoot 'VERSION.txt') -Raw).Trim()
    if (-not $Forzar -and [version]$manifest.version -le [version]$localVersion) { Write-Host "Ya está instalada la versión $localVersion."; return }
    # Paquete zip (GitHub): un solo archivo con todo el código, verificado con la huella firmada.
    # Las herramientas no van en el zip; si faltan o cambian, se descargan de su URL firmada.
    # Sin «paquete» (servidor propio) cada archivo se descarga por separado, como siempre.
    $packageRoot = $null
    if ($manifest.paquete) {
        $packageName = "$($manifest.paquete.nombre)"
        if ($packageName -notmatch '^[\w.-]+\.zip$' -or "$($manifest.paquete.sha256)" -notmatch '^[0-9a-fA-F]{64}$') { throw 'Paquete de actualización no válido.' }
        $packagePath = Join-Path $temporary $packageName
        Download-UpdateFile $packageName $packagePath
        if ((Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash -ne "$($manifest.paquete.sha256)") { throw 'El paquete descargado no coincide con la publicación.' }
        $packageRoot = Join-Path $temporary 'paquete'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($packagePath, $packageRoot)
    }
    $pending = @()
    foreach ($name in @($manifest.archivos | Select-Object -Unique)) {
        $target = Resolve-UpdatePath $appRoot $name; $stage = Resolve-UpdatePath $temporary $name
        $expected = "$($manifest.sha256.PSObject.Properties[$name].Value)"
        if ($expected -notmatch '^[0-9a-fA-F]{64}$') { throw "Falta la huella de $name." }
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $expected) {
            Write-Host "Ya verificado, sin descargar: $name"
            continue
        }
        [void][IO.Directory]::CreateDirectory((Split-Path $stage -Parent))
        $toolUrl = if ($manifest.herramientas) { "$($manifest.herramientas.PSObject.Properties[$name].Value)" } else { '' }
        $packaged = if ($packageRoot) { Resolve-UpdatePath $packageRoot $name } else { $null }
        if ($packaged -and (Test-Path -LiteralPath $packaged -PathType Leaf)) { Copy-Item -LiteralPath $packaged -Destination $stage }
        elseif ($toolUrl) {
            if ($toolUrl -notmatch '^https://') { throw "La herramienta $name requiere HTTPS." }
            Invoke-WebRequest -Uri $toolUrl -OutFile $stage -UseBasicParsing -TimeoutSec 600 -UserAgent 'HDZ-Studio-Updater' -ErrorAction Stop | Out-Null
        }
        elseif ($packageRoot) { throw "El paquete no contiene $name." }
        else { Download-UpdateFile $name $stage }
        if ((Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash -ne $expected) { throw "La descarga de $name no coincide con la publicación." }
        if ($name -eq 'VERSION.txt' -and [IO.File]::ReadAllText($stage).Trim() -ne "$($manifest.version)") { throw 'Versión incoherente.' }
        $pending += [pscustomobject]@{Name=$name;Target=$target;Stage=$stage}
        Write-Host "Verificado: $name"
    }
    foreach ($required in @('HDZ-GUI.ps1','HDZnew.ps1','HDZ-Core.ps1','HDZ-Async.ps1','HDZ-Capturas.ps1','HDZ-Torrent.ps1','VERSION.txt')) {
        if ($required -notin $manifest.archivos) { throw "Falta el componente obligatorio $required." }
    }
    $pending += [pscustomobject]@{Name='version.json';Target=(Join-Path $appRoot 'version.json');Stage=$manifestPath}
    $pending += [pscustomobject]@{Name='version.sig';Target=(Join-Path $appRoot 'version.sig');Stage=$signaturePath}
    # El botón arranca el instalador y cierra la GUI de forma ordenada. Esperar su
    # salida sin matar procesos evita la carrera de una descarga muy rápida.
    if($WaitForProcessId -gt 0){
        $previous=Get-Process -Id $WaitForProcessId -ErrorAction SilentlyContinue
        if($previous -and -not $previous.WaitForExit(30000)){throw 'El programa no se cerró a tiempo. No se han cambiado archivos.'}
    }
    $active = @(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.Name -match '^pwsh\.exe$' -and "$($_.CommandLine)".IndexOf($appRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.CommandLine -match 'HDZ-GUI\.ps1|HDZnew\.ps1' })
    if ($active.Count) { throw 'Cierra HDZ Studio antes de actualizar. Si hay un montaje, espera a que termine.' }
    $backup = Join-Path $PSScriptRoot ('copia-seguridad\' + $localVersion + '_' + (Get-Date -Format yyyyMMdd_HHmmss))
    [void][IO.Directory]::CreateDirectory($backup)
    try {
        foreach ($entry in @($pending | Sort-Object @{Expression={if($_.Name -eq 'VERSION.txt'){1}else{0}}},Name)) {
            $saved = Resolve-UpdatePath $backup $entry.Name; $existed = Test-Path -LiteralPath $entry.Target
            if ($existed) { [void][IO.Directory]::CreateDirectory((Split-Path $saved -Parent)); Copy-Item -LiteralPath $entry.Target -Destination $saved }
            [void][IO.Directory]::CreateDirectory((Split-Path $entry.Target -Parent))
            $replacement = $entry.Target + '.hdz_update_' + [guid]::NewGuid().ToString('N') + '.tmp'
            try {
                Copy-Item -LiteralPath $entry.Stage -Destination $replacement
                if ($existed) { [IO.File]::Replace($replacement, $entry.Target, $saved, $true) }
                else { [IO.File]::Move($replacement, $entry.Target) }
                $applied.Add([pscustomobject]@{Target=$entry.Target;Saved=$saved;Existed=$existed})
            } finally { if (Test-Path -LiteralPath $replacement) { Remove-Item -LiteralPath $replacement -Force } }
        }
    } catch {
        for ($i=$applied.Count-1; $i -ge 0; $i--) {
            $item=$applied[$i]
            if ($item.Existed) { Copy-Item -LiteralPath $item.Saved -Destination $item.Target -Force }
            elseif (Test-Path -LiteralPath $item.Target) { Remove-Item -LiteralPath $item.Target -Force }
        }
        throw "La actualización se revirtió. Respaldo: $backup. $($_.Exception.Message)"
    }
    Write-Host "Actualizado y verificado: $($manifest.version). Respaldo: $backup"
    if ($WaitForProcessId -gt 0) {
        @{ok=$true;message="Actualización a $($manifest.version) completada."} | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
        Copy-Item -LiteralPath $resultPath -Destination (Join-Path $PSScriptRoot 'ultima-actualizacion.json') -Force
    }
    if (-not $NoRelanzar -and (Test-Path -LiteralPath (Join-Path $appRoot 'HDZ Studio.vbs'))) {
        Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $appRoot 'HDZ Studio.vbs') + '"') -WindowStyle Hidden
        $relaunched = $true
    }
} catch {
    if ($WaitForProcessId -gt 0 -and $ownsMutex) {
        try {
            @{ok=$false;message="No se pudo completar la actualización: $($_.Exception.Message)"} | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
            Copy-Item -LiteralPath $resultPath -Destination (Join-Path $PSScriptRoot 'ultima-actualizacion.json') -Force
        } catch {}
    }
    Write-Error "No se pudo actualizar HDZ Studio: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
} finally {
    # También reabrir si falla la descarga/firma o si ya estaba actualizado.
    # Solo para una petición del programa y cuando el proceso anterior ha salido.
    if ($WaitForProcessId -gt 0 -and $ownsMutex -and -not $NoRelanzar -and -not $relaunched) {
        try {
            $previous = Get-Process -Id $WaitForProcessId -ErrorAction SilentlyContinue
            $previousGone = (-not $previous) -or $previous.WaitForExit(30000)
            $active = @(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.Name -eq 'pwsh.exe' -and "$($_.CommandLine)".IndexOf($appRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.CommandLine -match 'HDZ-GUI\.ps1|HDZnew\.ps1' })
            if ($previousGone -and -not $active.Count -and (Test-Path -LiteralPath (Join-Path $appRoot 'HDZ Studio.vbs'))) {
                Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $appRoot 'HDZ Studio.vbs') + '"') -WindowStyle Hidden
            }
        } catch { Write-Warning 'No se pudo reabrir HDZ Studio automáticamente.' }
    }
    $client.Dispose()
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
    $resolvedTemp = [IO.Path]::GetFullPath($temporary)
    if ($resolvedTemp.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedTemp -Leaf) -match '^hdz_update_[0-9a-f]{32}$' -and (Test-Path -LiteralPath $resolvedTemp)) { Remove-Item -LiteralPath $resolvedTemp -Recurse -Force }
}
