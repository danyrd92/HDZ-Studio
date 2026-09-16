# =========================================================================
# HDZ-Torrent.ps1 — Creación de torrents v1 (bencode + SHA-1 por piezas).
# Compartido por HDZnew.ps1 (motor) y HDZ-GUI.ps1 (interfaz), para no duplicar
# el formato. Torrents PRIVADOS (private=1): no se distribuyen por DHT/PEX.
# Sin dependencias externas. El progreso se reporta con el callback opcional
# $onProgress (recibe el porcentaje 0-100); si es $null, no informa.
# =========================================================================

function New-TorrentNucleo($nombre, $archivos, $rutaSalida, $announce = "", $source = "", $forzarMulti = $false, [scriptblock]$onProgress = $null) {
    $lista = @($archivos | ForEach-Object {
        $fi = Get-Item -LiteralPath $_.Ruta
        [PSCustomObject]@{ Ruta = $fi.FullName; Tam = [long]$fi.Length; Modified = $fi.LastWriteTimeUtc.Ticks; Componentes = @($_.Componentes) }
    })
    $tamTotal = [long]($lista | Measure-Object Tam -Sum).Sum
    if ($tamTotal -le 0) { throw "no hay datos que hashear" }

    $pieceLen = if     ($tamTotal -le 512MB) { 1MB }
                elseif ($tamTotal -le 2GB)   { 2MB }
                elseif ($tamTotal -le 8GB)   { 4MB }
                elseif ($tamTotal -le 32GB)  { 8MB }
                else                         { 16MB }

    $sha = [System.Security.Cryptography.SHA1]::Create()
    $piezas = New-Object System.IO.MemoryStream
    $ms = $null; $temporaryTorrent = $null
    try {
    $buf = New-Object byte[] $pieceLen
    $enBuf = 0
    $leidoTotal = [long]0
    $ultPct = -1
    foreach ($a in $lista) {
        $fs = [System.IO.File]::OpenRead($a.Ruta)
        try {
            if ($fs.Length -ne $a.Tam) { throw "El archivo cambió antes de crear el torrent: $($a.Ruta)" }
            while ($true) {
                $n = $fs.Read($buf, $enBuf, $pieceLen - $enBuf)
                if ($n -le 0) { break }
                $enBuf += $n
                $leidoTotal += $n
                if ($enBuf -eq $pieceLen) {
                    $hash = $sha.ComputeHash($buf, 0, $pieceLen)
                    $piezas.Write($hash, 0, 20)
                    $enBuf = 0
                }
                if ($onProgress) {
                    $pct = [int](100 * $leidoTotal / $tamTotal)
                    if ($pct -ne $ultPct) { & $onProgress $pct; $ultPct = $pct }
                }
            }
        } finally { $fs.Dispose() }
    }
    if ($enBuf -gt 0) {
        $hash = $sha.ComputeHash($buf, 0, $enBuf)
        $piezas.Write($hash, 0, 20)
    }
    if ($onProgress) { & $onProgress 100 }

    # --- bencode (claves de cada diccionario en orden alfabético) ---
    $ms = New-Object System.IO.MemoryStream
    $asc = [System.Text.Encoding]::ASCII
    $wRaw = { param($s) $b = $asc.GetBytes("$s"); $ms.Write($b, 0, $b.Length) }
    $wStr = { param($s) $b = [System.Text.Encoding]::UTF8.GetBytes("$s"); & $wRaw "$($b.Length):"; $ms.Write($b, 0, $b.Length) }

    & $wRaw "d"
    if (-not [string]::IsNullOrWhiteSpace($announce)) { & $wStr "announce"; & $wStr "$announce".Trim() }
    & $wStr "created by";    & $wStr "HDZ Studio"
    & $wStr "creation date"; & $wRaw "i$([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds())e"
    & $wStr "info"
    & $wRaw "d"
    if ($lista.Count -eq 1 -and -not $forzarMulti) {
        & $wStr "length"; & $wRaw "i$($lista[0].Tam)e"
    } else {
        & $wStr "files"; & $wRaw "l"
        foreach ($a in $lista) {
            & $wRaw "d"
            & $wStr "length"; & $wRaw "i$($a.Tam)e"
            & $wStr "path";   & $wRaw "l"
            foreach ($comp in $a.Componentes) { & $wStr $comp }
            & $wRaw "e"
            & $wRaw "e"
        }
        & $wRaw "e"
    }
    & $wStr "name";         & $wStr $nombre
    & $wStr "piece length"; & $wRaw "i${pieceLen}e"
    & $wStr "pieces";       & $wRaw "$($piezas.Length):"
    $bytesPiezas = $piezas.ToArray(); $ms.Write($bytesPiezas, 0, $bytesPiezas.Length)
    & $wStr "private";      & $wRaw "i1e"
    if (-not [string]::IsNullOrWhiteSpace($source)) { & $wStr "source"; & $wStr "$source".Trim() }
    & $wRaw "e"
    & $wRaw "e"

    foreach ($entry in $lista) {
        $current = Get-Item -LiteralPath $entry.Ruta
        if ($current.Length -ne $entry.Tam -or $current.LastWriteTimeUtc.Ticks -ne $entry.Modified) { throw "El contenido cambió durante el cálculo: $($entry.Ruta). No se publica el torrent." }
    }
    $temporaryTorrent = "$rutaSalida.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllBytes($temporaryTorrent, $ms.ToArray())
    [System.IO.File]::Move($temporaryTorrent, $rutaSalida, $true)
    } finally {
        if ($temporaryTorrent -and (Test-Path -LiteralPath $temporaryTorrent)) { Remove-Item -LiteralPath $temporaryTorrent -Force }
        $sha.Dispose(); $piezas.Dispose(); if ($ms) { $ms.Dispose() }
    }
    return $rutaSalida
}

# Torrent de UN archivo. El .torrent conserva la extensión del vídeo ("X.mkv" -> "X.mkv.torrent").
# $carpetaSalida: dónde dejar el .torrent (vacío = junto al archivo).
function New-TorrentArchivo($rutaArchivo, $announce = "", $source = "", $carpetaSalida = "", [scriptblock]$onProgress = $null) {
    $fi = Get-Item -LiteralPath $rutaArchivo
    $dir = if (-not [string]::IsNullOrWhiteSpace($carpetaSalida)) { $carpetaSalida } else { $fi.DirectoryName }
    [void][System.IO.Directory]::CreateDirectory($dir)
    $salida = Join-Path $dir "$($fi.Name).torrent"
    return New-TorrentNucleo $fi.Name @(@{ Ruta = $fi.FullName; Componentes = @($fi.Name) }) $salida $announce $source $false $onProgress
}

# Torrent de una CARPETA (pack de temporada): multi-file con todos los archivos (recursivo).
# $carpetaSalida: dónde dejar el .torrent (vacío = junto a la carpeta del pack).
function New-TorrentPack($rutaCarpetaPack, $announce = "", $source = "", $carpetaSalida = "", [scriptblock]$onProgress = $null, $expectedFiles = $null) {
    $dirPack = Get-Item -LiteralPath $rutaCarpetaPack
    $files = @(Get-ChildItem -LiteralPath $dirPack.FullName -File -Recurse | Where-Object { $_.Extension -notin @('.torrent','.tmp','.part') } | Sort-Object FullName)
    if ($null -ne $expectedFiles) {
        $unexpected = @($files | Where-Object { $_.FullName -notin $expectedFiles })
        $missing = @($expectedFiles | Where-Object { $_ -notin $files.FullName })
        if ($unexpected.Count -or $missing.Count) { throw 'El pack contiene archivos ajenos a este lote o faltan resultados. No se crea el torrent; revisa la carpeta de destino.' }
    }
    $archivos = @($files | ForEach-Object {
        $rel = $_.FullName.Substring($dirPack.FullName.Length).TrimStart('\', '/')
        @{ Ruta = $_.FullName; Componentes = @($rel -split "[\\/]") }
    })
    if ($archivos.Count -eq 0) { throw "la carpeta del pack está vacía" }
    $dir = if (-not [string]::IsNullOrWhiteSpace($carpetaSalida)) { $carpetaSalida } else { $dirPack.Parent.FullName }
    [void][System.IO.Directory]::CreateDirectory($dir)
    $salida = Join-Path $dir "$($dirPack.Name).torrent"
    return New-TorrentNucleo $dirPack.Name $archivos $salida $announce $source $true $onProgress
}
