# Funciones puras compartidas. No inicia trabajos ni conexiones al cargarse.
function Get-HdzAudioBitrateLabel($Track) {
    # MediaInfo JSON expresa BitRate en bits/s y Duration en segundos.
    # No usar BitRate_Nominal/Maximum ni el bitrate global del archivo: para VBR
    # y formatos sin pérdida interesa el promedio real de ESTA pista.
    $rate = 0.0
    if ($Track) {
        [void][double]::TryParse(("$($Track.BitRate)" -replace '\s', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$rate)
        if (-not [double]::IsFinite($rate) -or $rate -le 0) {
            $size = 0.0; $seconds = 0.0
            $hasSize = [double]::TryParse("$($Track.StreamSize)", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$size)
            $hasDuration = [double]::TryParse("$($Track.Duration)", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)
            $rate = if ($hasSize -and $hasDuration -and $size -gt 0 -and $seconds -gt 0) { $size * 8 / $seconds } else { 0.0 }
        }
    }
    if (-not [double]::IsFinite($rate) -or $rate -le 0) { return 'bitrate no disponible' }
    $kbps = [Math]::Max(1, [Math]::Round($rate / 1000, 0, [MidpointRounding]::AwayFromZero))
    return $kbps.ToString('0', [Globalization.CultureInfo]::InvariantCulture) + ' kb/s'
}

function Get-HdzAudioConversionBitrateK([int]$RequestedK, $SourceStream, [string]$Codec) {
    # Una conversión nunca puede tener más bitrate que su origen (p. ej. DTS 768 -> DD+ 768,
    # no 1024). $SourceStream = stream de ffprobe -show_streams (JSON). Se prefiere la
    # estadística BPS del MKV (promedio real de la pista; en DTS-HD MA el bit_rate de ffprobe
    # es solo el del núcleo) y, si no hay, bit_rate. Sin dato fiable se respeta lo pedido.
    $bps = 0.0
    if ($SourceStream) {
        $tags = $SourceStream.tags
        $candidates = @()
        if ($tags) { $candidates += @($tags.BPS, $tags.'BPS-eng') }
        $candidates += $SourceStream.bit_rate
        foreach ($candidate in $candidates) {
            $value = 0.0
            if ([double]::TryParse(("$candidate" -replace '\s', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and [double]::IsFinite($value) -and $value -gt 0) { $bps = $value; break }
        }
    }
    $target = $RequestedK
    if ($bps -gt 0) { $target = [Math]::Min($RequestedK, [int][Math]::Floor($bps / 1000)) }
    if ("$Codec".ToLower() -eq 'ac3') {
        # AC-3 solo admite bitrates de la tabla estándar: se baja al inmediato inferior.
        $ac3Rates = @(32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640)
        $allowed = @($ac3Rates | Where-Object { $_ -le $target })
        $target = if ($allowed.Count) { $allowed[-1] } else { 32 }
    }
    return [Math]::Max(32, $target)
}

function Add-HdzAudioBitrateToName([string]$Name, $Track) {
    # Idempotente, también si se vuelve a aplicar el nombre a un resultado previo.
    $baseName = $Name -replace '(?i)\s+@\s+(?:\d+(?:[.,]\d+)?\s+kb/s|bitrate no disponible)\s*$', ''
    return $baseName.TrimEnd() + ' @ ' + (Get-HdzAudioBitrateLabel $Track)
}

function Get-HdzVideoResolution($Video) {
    # MediaInfo y ffprobe: misma clasificación en montaje, escritorio, web y subida.
    # La anchura reconoce formatos panorámicos recortados (1920x800 = clase 1080),
    # también con los laterales recortados unos píxeles (1916x814, 1904x800, 1276x534).
    # No se infiere HD a partir de un umbral de altura ni de un nombre de archivo.
    $height = 0; $width = 0
    if (-not $Video -or -not [int]::TryParse("$($Video.Height)", [ref]$height) -or $height -le 0) { return '' }
    [void][int]::TryParse("$($Video.Width)", [ref]$width)
    $lines = if ($height -eq 1088) { 1080 } else { $height }
    foreach ($format in @(@{Min=7200;Max=8192;Lines=4320},@{Min=3600;Max=4096;Lines=2160},@{Min=1800;Max=2048;Lines=1080},@{Min=1200;Max=1280;Lines=720})) {
        if ($width -ge $format.Min -and $width -le $format.Max -and $height -le $format.Lines -and $height -ge ($format.Lines / 2)) {
            $lines = $format.Lines; break
        }
    }
    $scanType = "$($Video.ScanType)"
    $fieldOrder = "$($Video.FieldOrder) $($Video.field_order)".Trim()
    $interlaced = $scanType -match '(?i)interlaced|MBAFF|PAFF'
    if ($scanType -notmatch '(?i)progressive' -and $fieldOrder -match '(?i)\b(tt|bb|tb|bt)\b') { $interlaced = $true }
    $suffix = if ($interlaced) { 'i' } else { 'p' }
    return "$lines$suffix"
}

function Get-HdzResolutionTrackerId([string]$Resolution) {
    if (-not $Resolution) { return $null }
    # IDs del catálogo actual; un formato no estándar se publica como Other.
    $ids = @{'4320p'=1;'2160p'=2;'1080p'=3;'1080i'=4;'720p'=5;'576p'=6;'576i'=7;'480p'=8;'480i'=9}
    if ($ids.ContainsKey($Resolution)) { return $ids[$Resolution] }
    return 10
}

function Convert-HdzLanguage([string]$Language) {
    $code = $Language.Trim().ToLowerInvariant()
    if (-not $code) { return 'und' }
    if (-not $script:hdzLanguageMap) {
        $script:hdzLanguageMap = @{}
        foreach ($culture in [Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::NeutralCultures)) {
            if ($culture.TwoLetterISOLanguageName.Length -eq 2) { $script:hdzLanguageMap[$culture.TwoLetterISOLanguageName] = $culture.ThreeLetterISOLanguageName }
        }
        foreach ($pair in @('fre:fra','ger:deu','dut:nld','cze:ces','baq:eus','chi:zho','wel:cym','gre:ell','ice:isl','mac:mkd','may:msa','per:fas','rum:ron','slo:slk','alb:sqi','arm:hye','bur:mya','geo:kat','tib:bod')) {
            $parts = $pair.Split(':'); $script:hdzLanguageMap[$parts[0]] = $parts[1]
        }
    }
    if ($script:hdzLanguageMap.ContainsKey($code)) { return $script:hdzLanguageMap[$code] }
    return $code
}

function Get-HdzEpisodeKey([string]$Name) {
    $text = $Name -replace '[._]', ' '
    $match = [regex]::Match($text, '(?i)\bS(?<s>\d{1,3})\s*E(?<e>\d{1,4})(?<tail>(?:\s*-?\s*E\d{1,4}|-\d{1,4})*)\b')
    if (-not $match.Success) { $match = [regex]::Match($text, '(?i)\b(?<s>\d{1,3})x(?<e>\d{1,4})(?<tail>(?:-\d{1,4})*)\b') }
    if (-not $match.Success) { $match = [regex]::Match($text, '(?i)\bE(?<e>\d{1,4})(?<tail>(?:-E?\d{1,4})*)\b') }
    if (-not $match.Success) { return $null }
    $season = if ($match.Groups['s'].Success) { [int]$match.Groups['s'].Value } else { 0 }
    $episodes = [Collections.Generic.List[int]]::new()
    $first = [int]$match.Groups['e'].Value; $episodes.Add($first)
    $tail = $match.Groups['tail'].Value; $parts = @([regex]::Matches($tail, '\d+'))
    if ($parts.Count -eq 1 -and $tail.Contains('-')) {
        $end = [int]$parts[0].Value
        if ($end -lt $first -or $end - $first -gt 1000) { throw 'Rango de episodios inválido.' }
        for ($ep=$first+1; $ep -le $end; $ep++) { $episodes.Add($ep) }
    } else { foreach ($part in $parts) { $episodes.Add([int]$part.Value) } }
    return "s${season}e$((@($episodes | Sort-Object -Unique)) -join '-')"
}

function Assert-HdzMux([string]$Path, [int]$AudioCount, [int]$SubtitleCount, [string]$Source) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -le 0) { throw 'El MKV final no existe o está vacío. Originales conservados.' }
    $raw = & ffprobe -v error -show_streams -show_format -of json $Path 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'No se puede verificar el MKV final. Originales conservados.' }
    $probe = ($raw -join "`n") | ConvertFrom-Json
    # ffprobe expone las carátulas adjuntas como streams de vídeo. Solo se
    # excluyen las marcadas attached_pic; un segundo vídeo real sigue siendo error.
    $videos = @($probe.streams | Where-Object { $_.codec_type -eq 'video' -and $_.disposition.attached_pic -ne 1 }).Count
    $audios = @($probe.streams | Where-Object codec_type -eq audio).Count
    $subtitles = @($probe.streams | Where-Object codec_type -eq subtitle).Count
    if ($videos -ne 1 -or $audios -ne $AudioCount -or $subtitles -ne $SubtitleCount) {
        throw "El MKV no contiene las pistas solicitadas (vídeo: $videos/1; audio: $audios/$AudioCount; subtítulos: $subtitles/$SubtitleCount). Se conservan todos los originales."
    }
    $duration = 0.0
    if (-not [double]::TryParse("$($probe.format.duration)", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration) -or $duration -le 0) { throw 'Duración final no válida. Originales conservados.' }
    if ($Source) {
        $rawSource = & ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $Source 2>$null
        $sourceDuration = 0.0
        if ($LASTEXITCODE -ne 0 -or -not [double]::TryParse("$rawSource", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$sourceDuration)) { throw 'No se puede comprobar la duración de origen.' }
        if ([math]::Abs($duration - $sourceDuration) -gt [math]::Max(3, $sourceDuration * 0.001)) { throw 'La duración final difiere del vídeo original. Se conservan los originales.' }
    }
}

# Clave de emparejado de remezcla, compartida por la GUI y el motor (antes duplicada en ambos).
# SERIE: SOLO temporada+episodio (SxxEyy), ignorando el título — así casan releases del mismo
# show con TÍTULO EN DISTINTO IDIOMA y/o sin año. PELÍCULA (sin episodio): título+año.
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

# Emparejado sin usar títulos. E01 puede casar con SxxE01, pero nunca se
# resuelve una ambigüedad escogiendo el primer archivo encontrado.
function Test-HdzEpisodeMatch([string]$Left, [string]$Right) {
    if ($Left -eq $Right) { return $true }
    if ($Left -notmatch '^s(\d+)e(\d+(?:-\d+)*)$') { return $false }
    $season = [int]$Matches[1]; $episodes = $Matches[2]
    if ($Right -notmatch '^s(\d+)e(\d+(?:-\d+)*)$') { return $false }
    return ($episodes -eq $Matches[2] -and ($season -eq 0 -or [int]$Matches[1] -eq 0))
}

function Assert-HdzFreeSpace([string]$Directory, [long]$RequiredBytes) {
    $full = [IO.Path]::GetFullPath($Directory)
    $driveRoot = [IO.Path]::GetPathRoot($full)
    if ($driveRoot.StartsWith('\\')) {
        if (-not ('HdzDisk.Space' -as [type])) {
            Add-Type -Namespace HdzDisk -Name Space -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)] public static extern bool GetDiskFreeSpaceEx(string path, out ulong available, out ulong total, out ulong free);'
        }
        [ulong]$available = 0; [ulong]$total = 0; [ulong]$free = 0
        if (-not [HdzDisk.Space]::GetDiskFreeSpaceEx($driveRoot, [ref]$available, [ref]$total, [ref]$free)) { throw "No se puede comprobar el espacio disponible en $driveRoot." }
    } else { $available = ([IO.DriveInfo]::new($driveRoot)).AvailableFreeSpace }
    if ($available -lt $RequiredBytes) { throw "No hay espacio suficiente en $driveRoot. Necesario: $([math]::Round($RequiredBytes/1GB,2)) GB; libre: $([math]::Round($available/1GB,2)) GB. Originales intactos." }
}

function Assert-HdzRemixDurations([string]$Video, [string[]]$Sources) {
    $reference = $null
    foreach ($file in @($Video) + @($Sources | Where-Object { $_ -ne $Video } | Select-Object -Unique)) {
        $raw = & ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $file 2>$null
        $seconds = 0.0
        if ($LASTEXITCODE -ne 0 -or -not [double]::TryParse("$raw", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) -or $seconds -le 0) { throw "No se puede comprobar la duración de '$(Split-Path $file -Leaf)'." }
        if ($null -eq $reference) { $reference = $seconds }
        elseif ([math]::Abs($seconds - $reference) -gt [math]::Max(3, $reference * 0.001)) { throw "Las versiones de la remezcla tienen duraciones diferentes: '$(Split-Path $file -Leaf)' ($seconds s frente a $reference s). Revisa que sean el mismo montaje; no se ha cambiado ningún original." }
    }
}

# --- Subtítulos de texto: tipo (completo / forzado / SDH) y variante del español por el contenido ---
# La GUI lo usa al analizar (para proponer el tipo y el idioma de cada pista) y el motor cuando monta
# sin decisión de la GUI. Funciones puras: reciben el texto ya leído.
function Get-HdzBloquesSub([string]$Texto) {
    if (-not $Texto) { return @() }
    if ($Texto -match '(?m)^\[Events\]') {
        # ASS/SSA: el texto es el décimo campo de cada «Dialogue:»; fuera etiquetas {\...} y \N.
        return @([regex]::Matches($Texto, '(?m)^Dialogue:(?:[^,\r\n]*,){9}(.*)$') | ForEach-Object {
            (($_.Groups[1].Value -replace '\{[^}]*\}', '') -replace '\[Nn]', ' ').Trim()
        } | Where-Object { $_ })
    }
    return @($Texto -split '\r?\n\s*\r?\n' | Where-Object { $_ -match '-->' } | ForEach-Object {
        ((($_ -split '\r?\n') | Where-Object { $_ -notmatch '-->' -and $_ -notmatch '^\s*\d+\s*$' }) -join ' ').Trim()
    } | Where-Object { $_ })
}
# Variante del español: los castellanos tutean en plural (vosotros, «habláis»), los latinos usan
# «ustedes» y su propio vocabulario. Devuelve 'es', 'es-419' o $null si el texto no lo deja claro.
function Get-HdzVarianteEspanol([string[]]$Bloques) {
    $t = ' ' + ((@($Bloques) -join ' ').ToLowerInvariant()) + ' '
    if ($t.Length -lt 200) { return $null }
    $castFuerte = [regex]::Matches($t, '(?<![\p{L}])(vosotr[oa]s|vuestr[oa]s?|os\s+(?:lo|la|los|las|he|ha|has|hemos|hab[eé]is|vais|voy|dejo|digo|quiero|juro)|(?!diecis|veintis)\p{L}{2,}(?:[aá]is|[eé]is)(?=[^\p{L}]))(?![\p{L}])').Count
    $castDebil = [regex]::Matches($t, '(?<![\p{L}])(vale[,.!?¡¿]|t[ií][oa][,.!?]|ordenador|m[oó]vil|zumo|gilipollas|guay|mola|coche|patata|tronco[,.!?])').Count
    $lat = [regex]::Matches($t, '(?<![\p{L}])(ustedes|carro|computadora|celular|jugo|manejar|lind[oa]s?|ch[eé]vere|ahorita|enojad[oa]s?|ac[aá](?=[^\p{L}])|platicar|rentar|boleto|g[uü]ey|chamac[oa]s?|mesero|pararse|apur[aá]te|qu[eé]\s+onda)(?![\p{L}])').Count
    # «coche», «vale»... también se oyen en partes de Latinoamérica (y en traducciones neutras): pesan poco.
    $cast = 2 * $castFuerte + 0.5 * $castDebil
    # «vosotros/habláis» no existe en latino: con pocas apariciones ya decide.
    if ($castFuerte -ge 3 -and $cast -ge $lat) { return 'es' }
    if ($lat -ge 3 -and $lat -ge 2.5 * [math]::Max(1, $cast)) { return 'es-419' }
    if ($cast -ge 4 -and $cast -ge 1.5 * $lat) { return 'es' }
    return $null
}
# $Minutos: duración del vídeo completo (0 si el texto es solo una muestra: entonces no se decide
# «forzado» por densidad). $EsEspanol: calcula también la variante.
function Get-HdzInfoTextoSub([string]$Texto, [double]$Minutos = 0, [switch]$EsEspanol) {
    $bloques = @(Get-HdzBloquesSub $Texto)
    $n = $bloques.Count
    $r = [ordered]@{ Bloques = $n; Sonido = 0.0; Descripciones = 0.0; Tipo = $null; Variante = $null }
    if ($n -eq 0) { return [pscustomobject]$r }
    # SDH: describe sonidos ([APLAUSOS], (risas)) o nombra a quien habla («HANNAH: ...»). Un completo
    # normal casi nunca lleva corchetes; las notas musicales (♪) solas no bastan, salen en canciones.
    $desc = @($bloques | Where-Object { $_ -match '\[[^\]]{2,}\]|\([^\)]{3,}\)' }).Count
    $son = @($bloques | Where-Object { $_ -match '\[[^\]]+\]|\([^\)]{3,}\)|\u266A' }).Count
    $hablante = @($bloques | Where-Object { $_ -cmatch '^\s*-?\s*\p{Lu}[\p{Lu}\s\.]{1,24}:\s' }).Count
    $r.Sonido = [math]::Round($son / $n, 3); $r.Descripciones = [math]::Round($desc / $n, 3)
    if ($Minutos -ge 10 -and $n -lt 150 -and ($n / $Minutos) -lt 1.0) { $r.Tipo = 'Forzados' }
    elseif ($r.Sonido -ge 0.2 -or $desc -ge 10 -or ($desc -ge 5 -and $r.Descripciones -ge 0.03) -or ($hablante -ge 5 -and ($hablante / $n) -ge 0.03)) { $r.Tipo = 'SDH' }
    elseif ($n -ge 30) { $r.Tipo = 'Completos' }
    if ($EsEspanol -and $r.Tipo -ne 'Forzados') { $r.Variante = Get-HdzVarianteEspanol $bloques }
    return [pscustomobject]$r
}
# Idioma de un subtítulo externo por su nombre («Peli.es.srt», «Peli.latino.srt», «Peli_sub_3_spa.srt»).
function Get-HdzIdiomaNombreSub([string]$Nombre) {
    $base = [IO.Path]::GetFileNameWithoutExtension($Nombre)
    if ($base -match '(?i)_sub_\d+_([a-z]{2,3})$') { $c = $Matches[1].ToLowerInvariant() }
    elseif ($base -match '(?i)(?<![a-z])(latino|latam|lat|es-419|es-la|es-mx)(?![a-z])') { return 'es-419' }
    elseif ($base -match '(?i)(?<![a-z])(castellano|cast|es-es)(?![a-z])') { return 'es' }
    else {
        # La etiqueta de idioma va al final («…Love It.es.cc»): se busca desde la extensión hacia
        # atrás, para que una palabra del título («It», «De») no se tome por el idioma.
        $c = $null
        $trozos = @($base -split '[\._\s-]+' | Where-Object { $_ })
        for ($i = $trozos.Count - 1; $i -ge 1; $i--) {
            if ($trozos[$i] -match '^(?i)(spa|es|eng|en|fre|fra|fr|ger|deu|de|ita|it|por|pt|jpn|ja|chi|zho|zh|kor|ko|cat|ca|eus|eu|glg|gl)$') { $c = $trozos[$i].ToLowerInvariant(); break }
        }
        if (-not $c) { return 'und' }
    }
    switch ($c) { { $_ -in 'spa','es' } { 'es' } { $_ -in 'eng','en' } { 'eng' } default { Convert-HdzLanguage $c } }
}
# Castellano / latino / otro a partir del código y el título de una pista (igual que ConvCanon de la GUI
# para el español; el resto de idiomas, en su código de tres letras).
function ConvertTo-HdzIdiomaSubCanon($lang, $title = "") {
    $l = Convert-HdzLanguage "$lang"
    if ([string]::IsNullOrWhiteSpace($l) -or $l -eq "und") { return "und" }
    if ($l -match "^es-(419|mx|ar|co|cl|pe|ve|la|us)$" -or $l -eq "lat") { return "es-419" }
    if ($l -in @("es", "spa", "cas") -or $l -match "^es-") { if ("$title" -match "(?i)latino|latinoam|latam|hispanoam") { return "es-419" }; return "es" }
    return $l
}
