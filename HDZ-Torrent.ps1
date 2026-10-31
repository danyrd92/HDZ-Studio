# =========================================================================
# HDZ-Torrent.ps1 — Creación de torrents v1 (bencode + SHA-1 por piezas).
# Compartido por HDZnew.ps1 (motor) y HDZ-GUI.ps1 (interfaz), para no duplicar
# el formato. Torrents PRIVADOS (private=1): no se distribuyen por DHT/PEX.
# Sin dependencias externas. El progreso se reporta con el callback opcional
# $onProgress (recibe el porcentaje 0-100); si es $null, no informa.
# =========================================================================

# Se compila al crear el primer torrent, no al cargar el módulo (no retrasa el arranque de la GUI).
function Initialize-HdzPieceHasher {
    if ('HdzTorrent.PieceHasher' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Buffers;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Threading.Tasks;
namespace HdzTorrent {
  public static class PieceHasher {
    // Lee los archivos en orden (las piezas cruzan sus límites) y calcula el SHA-1 de cada pieza
    // en tareas paralelas; los resúmenes se escriben en el orden original. El progreso se notifica
    // desde el hilo que llama, nunca desde las tareas.
    public static byte[] Hash(string[] paths, long[] sizes, int pieceLen, Action<long> onRead) {
      int workers = Math.Max(1, Math.Min(Environment.ProcessorCount - 1, 6));
      var pending = new Queue<Task<byte[]>>();
      var output = new MemoryStream();
      byte[] current = ArrayPool<byte>.Shared.Rent(pieceLen); int fill = 0; long total = 0;
      try {
        for (int i = 0; i < paths.Length; i++) {
          using (var fs = new FileStream(paths[i], FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20, FileOptions.SequentialScan)) {
            if (fs.Length != sizes[i]) throw new IOException("El archivo cambió antes de crear el torrent: " + paths[i]);
            int n;
            while ((n = fs.Read(current, fill, pieceLen - fill)) > 0) {
              fill += n; total += n;
              if (fill == pieceLen) { Submit(pending, current, fill, output, workers); current = ArrayPool<byte>.Shared.Rent(pieceLen); fill = 0; }
              if (onRead != null) onRead(total);
            }
          }
        }
        if (fill > 0) { Submit(pending, current, fill, output, workers); current = null; }
        while (pending.Count > 0) output.Write(pending.Dequeue().GetAwaiter().GetResult(), 0, 20);
        return output.ToArray();
      } finally {
        foreach (var task in pending) { try { task.Wait(); } catch { } }
        if (current != null) ArrayPool<byte>.Shared.Return(current);
      }
    }
    static void Submit(Queue<Task<byte[]>> pending, byte[] buffer, int length, MemoryStream output, int workers) {
      while (pending.Count >= workers + 1) output.Write(pending.Dequeue().GetAwaiter().GetResult(), 0, 20);
      pending.Enqueue(Task.Run(() => {
        try { return SHA1.HashData(new ReadOnlySpan<byte>(buffer, 0, length)); }
        finally { ArrayPool<byte>.Shared.Return(buffer); }
      }));
    }
  }
}
'@
}

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

    $piezas = New-Object System.IO.MemoryStream
    $ms = $null; $temporaryTorrent = $null
    try {
    # Las piezas se leen en orden y se hashean en paralelo (varios núcleos): con SSD/NVMe un solo
    # núcleo de SHA-1 era el cuello de botella. El .torrent resultante es idéntico byte a byte.
    $estadoPct = @{ Ultimo = -1 }
    $alLeer = if ($onProgress) {
        [Action[long]]{ param($leido) $pct = [int](100 * $leido / $tamTotal); if ($pct -ne $estadoPct.Ultimo) { $estadoPct.Ultimo = $pct; & $onProgress $pct } }
    } else { $null }
    Initialize-HdzPieceHasher
    $bytesPiezas = [HdzTorrent.PieceHasher]::Hash([string[]]@($lista.Ruta), [long[]]@($lista.Tam), [int]$pieceLen, $alLeer)
    $piezas.Write($bytesPiezas, 0, $bytesPiezas.Length)
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
        $piezas.Dispose(); if ($ms) { $ms.Dispose() }
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
