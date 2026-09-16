# Historial local: nunca almacena credenciales ni reconstruye torrents.
function Get-HdzHistoryDirectory {
    $directory = if ($script:hdzHistoryTestDirectory) { $script:hdzHistoryTestDirectory } else { Join-Path $env:APPDATA 'HDZ-Studio\Historial' }
    if ($env:HDZ_HISTORY_TEST_DIR -and [IO.Path]::GetFullPath($env:HDZ_HISTORY_TEST_DIR).StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\hdz_test_', [StringComparison]::OrdinalIgnoreCase)) { $directory=$env:HDZ_HISTORY_TEST_DIR }
    [void][IO.Directory]::CreateDirectory($directory)
    return $directory
}
function Add-HdzHistory([hashtable]$Record) {
    $entry = [ordered]@{id=[guid]::NewGuid().ToString('N');date=[DateTime]::UtcNow.ToString('o');seed='No comprobado'}
    # Lista positiva: evita copiar configuraciones, tokens o enlaces privados.
    foreach ($key in @('kind','status','sources','video','torrent','captures','incidents','tracks','torrentId')) {
        if ($Record.ContainsKey($key)) { $entry[$key] = $Record[$key] }
    }
    if ($entry.torrent -and (Test-Path -LiteralPath $entry.torrent -PathType Leaf)) { $entry.torrentHash=(Get-FileHash -LiteralPath $entry.torrent -Algorithm SHA256).Hash.ToLowerInvariant() }
    $directory = Get-HdzHistoryDirectory
    $final = Join-Path $directory ($entry.id + '.json'); $temporary = $final + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($entry|ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$final)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    return [pscustomobject]$entry
}
function Get-HdzHistory([int]$Limit=30) {
    foreach ($file in @(Get-ChildItem -LiteralPath (Get-HdzHistoryDirectory) -File -Filter '*.json' | Where-Object BaseName -match '^[0-9a-f]{32}$' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $Limit)) {
        try { Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Warning "No se pudo leer el registro $($file.BaseName)." }
    }
}
function Get-HdzHistoryTorrent([string]$Id) {
    if ($Id -notmatch '^[0-9a-f]{32}$') { throw 'Registro de historial inválido.' }
    $file = Join-Path (Get-HdzHistoryDirectory) ($Id + '.json')
    $record = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $record.torrent -or -not (Test-Path -LiteralPath $record.torrent -PathType Leaf)) { throw 'El torrent original ya no está en su ruta guardada. No se regenera.' }
    if ((Get-FileHash -LiteralPath $record.torrent -Algorithm SHA256).Hash -ne $record.torrentHash) { throw 'El archivo torrent ha cambiado desde que se guardó. No se entrega como si fuera el original.' }
    return $record.torrent
}

function Get-HdzLatestCreatedTorrent([string[]]$Folders=@()) {
    # El historial sobrevive al reinicio del proyecto. No confundir un torrent
    # creado para subir con el archivo registrado que devuelve el tracker.
    $records=[Collections.Generic.List[object]]::new()
    $changed=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($record in @(Get-HdzHistory -Limit ([int]::MaxValue))) {
        if($record.kind -notin @('torrent','montaje','pack') -or $record.status -eq 'Fallido' -or -not $record.torrent){continue}
        $date=[DateTimeOffset]::MinValue
        # ConvertFrom-Json puede materializar ISO 8601 como DateTime. Pasarlo a
        # [string] usa mes/día, pero TryParse lo leía con la cultura española:
        # 09/10 se convertía en octubre y 09/13..09/31 se descartaban.
        if($record.date -is [DateTimeOffset]){$date=$record.date}
        elseif($record.date -is [DateTime]){$date=[DateTimeOffset]$record.date}
        elseif(-not [DateTimeOffset]::TryParse([string]$record.date,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$date)){continue}
        $records.Add(@{Date=$date;Record=$record})
    }
    foreach($entry in @($records | Sort-Object Date -Descending)) {
        $record=$entry.Record
        try {
            $file=Get-Item -LiteralPath $record.torrent -Force -ErrorAction Stop
            if($file.PSIsContainer -or $file.Extension -ine '.torrent'){continue}
            if($record.torrentHash -and (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash -ne $record.torrentHash){
                [void]$changed.Add($file.FullName);continue
            }
            return $file.FullName
        } catch { continue }
    }
    # Respaldo para torrents anteriores al historial o creados en otra carpeta.
    $files=foreach($folder in @($Folders | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | Select-Object -Unique)) {
        if(Test-Path -LiteralPath $folder -PathType Container -ErrorAction SilentlyContinue){
            Get-ChildItem -LiteralPath $folder -Filter '*.torrent' -File -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object {-not $changed.Contains($_.FullName)}
        }
    }
    $latest=@($files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if($latest.Count){return $latest[0].FullName}
    return $null
}

function Rotate-HdzLog([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -lt 4MB) { return }
    if ((Split-Path $Path -Leaf) -notmatch '^proyecto_[\w.\-]+\.log$') { return }
    $archive = $Path + '.' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '.gz'
    if (Test-Path -LiteralPath $archive) { return }
    $source=$null; $target=$null; $gzip=$null
    try {
        $source=[IO.File]::OpenRead($Path); $target=[IO.File]::Open($archive,'CreateNew','Write','None')
        $gzip=[IO.Compression.GZipStream]::new($target,[IO.Compression.CompressionLevel]::Optimal)
        $source.CopyTo($gzip); $gzip.Dispose(); $gzip=$null; $source.Dispose(); $source=$null
        [IO.File]::WriteAllText($Path,"[Log anterior archivado en $(Split-Path $archive -Leaf)]`r`n",[Text.UTF8Encoding]::new($false))
    } catch { Write-Warning 'No se pudo archivar el log; se conserva su contenido.' }
    finally { if($gzip){$gzip.Dispose()}; if($target){$target.Dispose()}; if($source){$source.Dispose()} }
    # Los archivos comprimidos se conservan para diagnóstico; nunca se borran por patrón amplio.
}
