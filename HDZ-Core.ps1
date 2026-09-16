# Funciones puras compartidas. No inicia trabajos ni conexiones al cargarse.
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
