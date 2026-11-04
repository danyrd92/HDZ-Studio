# =========================================================================
# HDZ-Disco.ps1 — discos completos (ISO de Blu-ray, UHD o DVD) en HD ZERO Studio
# =========================================================================
# Este fichero no ejecuta nada al cargarse. Lo cargan HDZ-Capturas.ps1 (y con
# él el motor, el menú contextual y capturas.ps1) y la interfaz.
#
# HDZ Studio NO ripea discos: parte del .iso que ya creó el programa de ripeo
# del usuario. Desde ahí:
#
#   - Open-HdzDisco localiza la película principal dentro del ISO. Primero
#     intenta leerlo directamente con FFmpeg (protocolo bluray:, que sigue la
#     playlist más larga); si no puede, monta el ISO con Windows y busca el
#     vídeo principal (BDMV\STREAM o VIDEO_TS). Close-HdzDisco lo desmonta,
#     solo si lo montó él.
#   - Get-HdzDiscoDatos saca resolución, códec, HDR, Dolby Vision y el audio
#     principal con ffprobe.
#   - ConvertFrom-HdzBdinfo lee lo mismo de un informe de BDInfo, que es la
#     fuente más fiable y la que pide el tracker.
#   - Get-HdzDiscoNombre compone el nombre de la release con esos datos.
# =========================================================================

function Test-HdzEsDisco([string]$Ruta) {
    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $false }
    return ([System.IO.Path]::GetExtension($Ruta) -ieq '.iso')
}

# ffprobe en JSON sobre una entrada de disco. Devuelve $null si no hay vídeo legible.
function Invoke-HdzDiscoProbe([string[]]$ArgsEntrada, [string]$Entrada) {
    try {
        $argumentos = @('-v', 'error', '-show_streams', '-show_format', '-of', 'json') + @($ArgsEntrada) + @($Entrada)
        $raw = (& ffprobe @argumentos 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
        $json = $raw | ConvertFrom-Json
        $videos = @($json.streams | Where-Object { "$($_.codec_type)" -eq 'video' -and -not ($_.disposition -and $_.disposition.attached_pic -eq 1) })
        if ($videos.Count -eq 0) { return $null }
        return $json
    } catch { return $null }
}

# Letra de unidad de un ISO montado (o $null).
function Get-HdzDiscoUnidad([string]$RutaIso) {
    try {
        $vol = Get-DiskImage -ImagePath $RutaIso -ErrorAction Stop | Get-Volume -ErrorAction Stop | Select-Object -First 1
        if ($vol -and $vol.DriveLetter) { return "$($vol.DriveLetter):\" }
    } catch {}
    return $null
}

# Película principal dentro de una unidad o carpeta con estructura de disco.
# Devuelve @{ Tipo; Entrada; ArgsEntrada; Filtro } o $null.
function Find-HdzDiscoPrincipal([string]$Raiz) {
    $bdmv = Join-Path $Raiz 'BDMV'
    if (Test-Path -LiteralPath $bdmv -PathType Container) {
        # Con un BDMV completo, libbluray sigue la playlist más larga: así se respeta el
        # «seamless branching» (una película troceada en varios .m2ts).
        if (Test-Path -LiteralPath (Join-Path $bdmv 'index.bdmv') -PathType Leaf) {
            $entrada = "bluray:$Raiz"
            if (Invoke-HdzDiscoProbe @() $entrada) {
                return [pscustomobject]@{ Tipo = 'bluray'; Entrada = $entrada; ArgsEntrada = @(); Filtro = '' }
            }
        }
        $m2ts = @(Get-ChildItem -LiteralPath (Join-Path $bdmv 'STREAM') -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Extension -match '(?i)^\.(m2ts|mts)$' } | Sort-Object Length -Descending | Select-Object -First 1)
        if ($m2ts.Count -gt 0) {
            return [pscustomobject]@{ Tipo = 'bluray'; Entrada = $m2ts[0].FullName; ArgsEntrada = @(); Filtro = '' }
        }
    }

    $videoTs = Join-Path $Raiz 'VIDEO_TS'
    if (Test-Path -LiteralPath $videoTs -PathType Container) {
        # Cada título es VTS_nn_1.VOB, VTS_nn_2.VOB… (el _0 es el menú). La película es el
        # título que más ocupa; sus VOB se leen seguidos con el protocolo concat de FFmpeg.
        $grupos = @(Get-ChildItem -LiteralPath $videoTs -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '(?i)^VTS_(\d{2})_([1-9])\.VOB$' } |
                    Group-Object { ($_.Name -replace '(?i)^VTS_(\d{2})_.*$', '$1') } |
                    Sort-Object { ($_.Group | Measure-Object Length -Sum).Sum } -Descending)
        if ($grupos.Count -gt 0) {
            $vobs = @($grupos[0].Group | Sort-Object Name | ForEach-Object { $_.FullName })
            $entrada = if ($vobs.Count -eq 1) { $vobs[0] } else { 'concat:' + ($vobs -join '|') }
            # Los DVD son entrelazados y anamórficos: se desentrelaza y se corrige el aspecto
            # para que las capturas no salgan con rayas ni estiradas.
            return [pscustomobject]@{ Tipo = 'dvd'; Entrada = $entrada; ArgsEntrada = @(); Filtro = 'yadif,scale=trunc(iw*sar/2)*2:ih,setsar=1' }
        }
    }

    # Imagen sin estructura de disco: el vídeo más grande que contenga.
    $suelto = @(Get-ChildItem -LiteralPath $Raiz -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '(?i)^\.(m2ts|mts|ts|mkv|mp4|vob|avi)$' } |
                Sort-Object Length -Descending | Select-Object -First 1)
    if ($suelto.Count -gt 0) {
        return [pscustomobject]@{ Tipo = 'archivo'; Entrada = $suelto[0].FullName; ArgsEntrada = @(); Filtro = '' }
    }
    return $null
}

# Abre un ISO para leer su película principal. Llama SIEMPRE a Close-HdzDisco al terminar.
function Open-HdzDisco {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RutaIso, [switch]$SinLecturaDirecta)

    if (-not (Test-Path -LiteralPath $RutaIso -PathType Leaf)) { throw "No existe la imagen de disco: $RutaIso" }
    $iso = (Resolve-Path -LiteralPath $RutaIso).Path
    $disco = [pscustomobject]@{
        Iso = $iso; Tipo = ''; Entrada = ''; ArgsEntrada = @(); Filtro = ''
        Montado = $false; Unidad = $null; Etiqueta = ''; Metodo = ''
    }

    # 1) Lectura directa, sin montar: libbluray abre el ISO por dentro.
    if (-not $SinLecturaDirecta) {
        $entrada = "bluray:$iso"
        if (Invoke-HdzDiscoProbe @() $entrada) {
            $disco.Tipo = 'bluray'; $disco.Entrada = $entrada; $disco.Metodo = 'directo'
            return $disco
        }
    }

    # 2) Montar el ISO con Windows (no necesita permisos de administrador). Si ya estaba
    #    montado (por ejemplo, abierto en el Explorador), se reutiliza y no se desmonta luego.
    $unidad = Get-HdzDiscoUnidad $iso
    if (-not $unidad) {
        try { Mount-DiskImage -ImagePath $iso -StorageType ISO -ErrorAction Stop | Out-Null }
        catch { throw "No se pudo montar la imagen de disco: $($_.Exception.Message)" }
        $disco.Montado = $true
        # La letra de unidad tarda un instante en aparecer tras montar.
        for ($i = 0; $i -lt 40 -and -not $unidad; $i++) {
            $unidad = Get-HdzDiscoUnidad $iso
            if (-not $unidad) { Start-Sleep -Milliseconds 250 }
        }
    }
    try {
        if (-not $unidad) { throw 'Windows montó la imagen de disco pero no le asignó una letra de unidad.' }
        $disco.Unidad = $unidad
        try { $disco.Etiqueta = "$((Get-Volume -DriveLetter $unidad.Substring(0, 1) -ErrorAction Stop).FileSystemLabel)" } catch {}
        $principal = Find-HdzDiscoPrincipal $unidad
        if (-not $principal) { throw 'No encontré la película dentro de la imagen de disco (ni BDMV ni VIDEO_TS).' }
        $disco.Tipo = $principal.Tipo; $disco.Entrada = $principal.Entrada
        $disco.ArgsEntrada = @($principal.ArgsEntrada); $disco.Filtro = $principal.Filtro
        $disco.Metodo = 'montado'
        return $disco
    } catch {
        Close-HdzDisco $disco
        throw
    }
}

function Close-HdzDisco($Disco) {
    if (-not $Disco -or -not $Disco.Montado) { return }
    try { Dismount-DiskImage -ImagePath $Disco.Iso -ErrorAction Stop | Out-Null } catch {}
    $Disco.Montado = $false
}

# --- Etiquetas comunes ---------------------------------------------------

function Get-HdzDiscoResolucion([int]$Ancho, [int]$Alto, [bool]$Entrelazado = $false) {
    $sufijo = if ($Entrelazado) { 'i' } else { 'p' }
    if ($Ancho -ge 3200 -or $Alto -ge 1700) { return '2160p' }
    if ($Ancho -ge 1800 -or $Alto -ge 1000) { return "1080$sufijo" }
    if ($Ancho -ge 1200 -or $Alto -ge 700)  { return '720p' }
    if ($Alto -ge 560) { return "576$sufijo" }
    if ($Alto -gt 0)   { return "480$sufijo" }
    return ''
}

function Get-HdzDiscoCanales([int]$Canales) {
    switch ($Canales) {
        8 { '7.1' } 7 { '6.1' } 6 { '5.1' } 3 { '2.1' } 2 { '2.0' } 1 { '1.0' }
        default { if ($Canales -gt 0) { "$($Canales).0" } else { '' } }
    }
}

# Idiomas que se prefieren para nombrar el audio (castellano primero, luego latino, luego el resto).
function Get-HdzDiscoPesoIdioma([string]$Idioma) {
    $i = "$Idioma".Trim().ToLowerInvariant()
    if ($i -match '^(spa|es|esp|spanish|castellano|español|espanol)$') { return 0 }
    if ($i -match 'latin|lat') { return 1 }
    return 2
}

function New-HdzDiscoDatos {
    [ordered]@{
        Resolucion = ''; Codec = ''; HDR10 = $false; HDR10P = $false; HLG = $false; DV = $false
        Audio = ''; AudioCanales = ''; AudioIdioma = ''; Duracion = 0.0; Etiqueta = ''; Fuente = ''
    }
}

# --- Datos técnicos con ffprobe ------------------------------------------

function ConvertFrom-HdzDiscoProbe($Probe) {
    $d = New-HdzDiscoDatos
    $d.Fuente = 'ffprobe'
    if (-not $Probe) { return [pscustomobject]$d }
    $videos = @($Probe.streams | Where-Object { "$($_.codec_type)" -eq 'video' -and -not ($_.disposition -and $_.disposition.attached_pic -eq 1) })
    $v = $videos | Sort-Object { [int]"0$($_.width)" * [int]"0$($_.height)" } -Descending | Select-Object -First 1
    if ($v) {
        $entrelazado = "$($v.field_order)" -match '^(tt|bb|tb|bt)$'
        $d.Resolucion = Get-HdzDiscoResolucion ([int]"0$($v.width)") ([int]"0$($v.height)") $entrelazado
        $d.Codec = switch -Regex ("$($v.codec_name)") {
            '^hevc$' { 'HEVC' } '^h264$' { 'AVC' } '^vc1$' { 'VC-1' } '^mpeg2video$' { 'MPEG-2' } '^av1$' { 'AV1' }
            default { "$($v.codec_name)".ToUpperInvariant() }
        }
        switch -Regex ("$($v.color_transfer)") {
            '^smpte2084$'   { $d.HDR10 = $true }
            '^arib-std-b67$' { $d.HLG = $true }
        }
        # Dolby Vision: registro de configuración DOVI en cualquier pista de vídeo, o la capa de
        # mejora típica de los UHD (un segundo HEVC de menor resolución junto al principal).
        foreach ($s in $videos) {
            foreach ($sd in @($s.side_data_list)) { if ("$($sd.side_data_type)" -match '(?i)DOVI|Dolby Vision') { $d.DV = $true } }
        }
        $hevc = @($videos | Where-Object { "$($_.codec_name)" -eq 'hevc' })
        if ($hevc.Count -ge 2 -and $d.HDR10) { $d.DV = $true }
        foreach ($sd in @($v.side_data_list)) { if ("$($sd.side_data_type)" -match '(?i)2094-40|HDR10\+') { $d.HDR10P = $true } }
    }

    $audios = @($Probe.streams | Where-Object { "$($_.codec_type)" -eq 'audio' })
    if ($audios.Count -gt 0) {
        $a = @($audios | Sort-Object @{ Expression = { Get-HdzDiscoPesoIdioma "$($_.tags.language)" } }, @{ Expression = { [int]"0$($_.index)" } })[0]
        $perfil = "$($a.profile)"
        $d.Audio = switch -Regex ("$($a.codec_name)") {
            '^dts$'       { if ($perfil -match '(?i)DTS:X') { 'DTS:X' } elseif ($perfil -match '(?i)HD MA') { 'DTS-HD MA' } elseif ($perfil -match '(?i)HD HRA|High Res') { 'DTS-HD HRA' } else { 'DTS' } }
            '^truehd$'    { if ($perfil -match '(?i)Atmos') { 'TrueHD Atmos' } else { 'TrueHD' } }
            '^eac3$'      { if ($perfil -match '(?i)Atmos') { 'DD+ Atmos' } else { 'DD+' } }
            '^ac3$'       { 'DD' }
            '^pcm_'       { 'LPCM' }
            '^mp2$'       { 'MP2' }
            default       { "$($a.codec_name)".ToUpperInvariant() }
        }
        $d.AudioCanales = Get-HdzDiscoCanales ([int]"0$($a.channels)")
        $d.AudioIdioma = "$($a.tags.language)"
    }

    $dur = 0.0
    if ([double]::TryParse("$($Probe.format.duration)".Replace(',', '.'), [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$dur)) { $d.Duracion = $dur }
    return [pscustomobject]$d
}

function Get-HdzDiscoDatos {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Disco)
    $probe = Invoke-HdzDiscoProbe @($Disco.ArgsEntrada) "$($Disco.Entrada)"
    $datos = ConvertFrom-HdzDiscoProbe $probe
    $datos.Etiqueta = "$($Disco.Etiqueta)"
    return $datos
}

# --- BDInfo --------------------------------------------------------------

# Lee un informe de BDInfo (completo o «Quick Summary») y devuelve los mismos datos que
# Get-HdzDiscoDatos. Toma la primera playlist del informe, que es la película principal.
function ConvertFrom-HdzBdinfo([string]$Texto) {
    $d = New-HdzDiscoDatos
    $d.Fuente = 'bdinfo'
    if ([string]::IsNullOrWhiteSpace($Texto)) { return [pscustomobject]$d }
    $lineas = @($Texto -split "\r?\n")

    foreach ($l in $lineas) {
        if (-not $d.Etiqueta -and $l -match '^\s*Disc (?:Label|Title):\s*(.+?)\s*$') { $d.Etiqueta = $Matches[1] }
    }

    $patronVideo = '(?i)(MPEG-H HEVC|MPEG-4 AVC|SMPTE VC-1|VC-1|MPEG-2)\s+Video'
    $videos = @($lineas | Where-Object { $_ -match $patronVideo -and $_ -match '\d{3,4}[pi]\b' })
    if ($videos.Count -gt 0) {
        $principal = @($videos | Where-Object { $_ -notmatch '^\s*(Video:\s*)?\*' })
        $v = if ($principal.Count -gt 0) { $principal[0] } else { $videos[0] }
        if ($v -match $patronVideo) {
            $d.Codec = switch -Regex ($Matches[1]) { 'HEVC' { 'HEVC' } 'AVC' { 'AVC' } 'VC-1' { 'VC-1' } 'MPEG-2' { 'MPEG-2' } }
        }
        if ($v -match '\b(\d{3,4})([pi])\b') { $d.Resolucion = "$($Matches[1])$($Matches[2])" }
        if ($v -match '(?i)HDR10\+') { $d.HDR10P = $true }
        if ($v -match '(?i)\bHDR10\b') { $d.HDR10 = $true }
        if ($v -match '(?i)\bHLG\b') { $d.HLG = $true }
        # Dolby Vision aparece en la capa de mejora (la línea con «*») o en la principal.
        foreach ($x in $videos) {
            if ($x -match '(?i)Dolby Vision') { $d.DV = $true }
            if ($x -match '(?i)HDR10\+') { $d.HDR10P = $true }
        }
    }

    $patronAudio = '(?i)(DTS:X Master Audio|DTS-HD Master Audio|DTS-HD High-Res Audio|DTS Audio|Dolby TrueHD/Atmos Audio|Dolby TrueHD Audio|Dolby Digital Plus/Atmos Audio|Dolby Digital Plus Audio|Dolby Digital EX Audio|Dolby Digital Audio|LPCM Audio)'
    $audios = @()
    foreach ($l in $lineas) {
        if ($l -match '(?i)^\s*(Subtitle|Presentation Graphics)') { continue }
        if ($l -notmatch $patronAudio) { continue }
        $codec = $Matches[1]
        # Formato completo: «Codec  Idioma  Bitrate  Canales / …». Quick summary: «Audio: Idioma / Codec / Canales / …».
        $idioma = ''
        if ($l -match '^\s*Audio:\s*([^/]+?)\s*/') { $idioma = $Matches[1] }
        elseif ($l -match "$([regex]::Escape($codec))\s{2,}([A-Za-zÀ-ÿ\- ]+?)\s{2,}") { $idioma = $Matches[1] }
        $resto = $l.Substring($l.IndexOf($codec) + $codec.Length)
        $canales = if ($resto -match '\b(\d\.\d)\b') { $Matches[1] } else { '' }
        $audios += [pscustomobject]@{ Codec = $codec; Idioma = $idioma.Trim(); Canales = $canales; Orden = $audios.Count }
    }
    if ($audios.Count -gt 0) {
        $a = @($audios | Sort-Object @{ Expression = { Get-HdzDiscoPesoIdioma $_.Idioma } }, Orden)[0]
        $d.Audio = switch -Regex ($a.Codec) {
            'DTS:X'                 { 'DTS:X' }
            'DTS-HD Master'         { 'DTS-HD MA' }
            'DTS-HD High-Res'       { 'DTS-HD HRA' }
            '^DTS Audio'            { 'DTS' }
            'TrueHD/Atmos'          { 'TrueHD Atmos' }
            'TrueHD'                { 'TrueHD' }
            'Digital Plus/Atmos'    { 'DD+ Atmos' }
            'Digital Plus'          { 'DD+' }
            'Digital EX|Digital Audio' { 'DD' }
            'LPCM'                  { 'LPCM' }
        }
        $d.AudioCanales = $a.Canales
        $d.AudioIdioma = $a.Idioma
    }
    return [pscustomobject]$d
}

# Busca junto al ISO un informe de BDInfo ya generado (el .txt que guarda BDInfo).
# Devuelve @{ Ruta; Texto } o $null.
function Get-HdzBdinfoJunto([string]$RutaIso) {
    if (-not (Test-Path -LiteralPath $RutaIso -PathType Leaf)) { return $null }
    $dir = Split-Path -Parent (Resolve-Path -LiteralPath $RutaIso).Path
    $base = [System.IO.Path]::GetFileNameWithoutExtension($RutaIso)
    $txts = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Extension -ieq '.txt' -and $_.Length -gt 0 -and $_.Length -lt 4MB })
    # Primero los que llevan el nombre del ISO; después cualquier informe de BDInfo de la carpeta.
    $orden = @($txts | Sort-Object @{ Expression = { if ($_.BaseName -like "$base*") { 0 } elseif ($_.Name -match '(?i)bdinfo') { 1 } else { 2 } } }, Name)
    foreach ($t in $orden) {
        try { $texto = [IO.File]::ReadAllText($t.FullName) } catch { continue }
        if ($texto -match '(?im)^\s*(DISC INFO:|Disc (Title|Label):|PLAYLIST REPORT:)') {
            # Si en la carpeta hay varios ISO, un informe con el nombre de otro no vale.
            $otrosIso = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.iso' -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -ne $base })
            if ($t.BaseName -notlike "$base*" -and @($otrosIso | Where-Object { $t.BaseName -like "$($_.BaseName)*" }).Count -gt 0) { continue }
            return [pscustomobject]@{ Ruta = $t.FullName; Texto = $texto.TrimEnd() }
        }
    }
    return $null
}

# --- Nombre de la release ------------------------------------------------

# Marca del tipo de disco para el nombre: UHDFull (2160p), BDFull (Blu-ray) o DVDFull.
function Get-HdzDiscoMarca($Datos, [string]$Tipo = '') {
    if ("$($Datos.Resolucion)" -eq '2160p') { return 'UHDFull' }
    if ($Tipo -eq 'dvd' -or "$($Datos.Resolucion)" -match '^(576|480)') { return 'DVDFull' }
    return 'BDFull'
}

# «Título (Año) UHDFull 2160p DV HDR10 HEVC DTS-HD MA 5.1». Es el nombre que se ve en el
# tracker: puede llevar «:», que Windows no admite en un archivo (ver ConvertTo-HdzNombreArchivo).
function Get-HdzDiscoNombre {
    [CmdletBinding()]
    param([string]$Titulo, [string]$Anio, $Datos, [string]$Tipo = '')
    $partes = New-Object System.Collections.Generic.List[string]
    $t = "$Titulo".Trim()
    if ($t) { $partes.Add($(if ("$Anio".Trim()) { "$t ($("$Anio".Trim()))" } else { $t })) }
    $partes.Add((Get-HdzDiscoMarca $Datos $Tipo))
    if ($Datos.Resolucion) { $partes.Add("$($Datos.Resolucion)") }
    if ($Datos.DV) { $partes.Add('DV') }
    if ($Datos.HDR10P) { $partes.Add('HDR10+') } elseif ($Datos.HDR10) { $partes.Add('HDR10') } elseif ($Datos.HLG) { $partes.Add('HLG') }
    if ($Datos.Codec) { $partes.Add("$($Datos.Codec)") }
    if ($Datos.Audio) { $partes.Add((@("$($Datos.Audio)", "$($Datos.AudioCanales)") | Where-Object { $_ }) -join ' ') }
    return (($partes | Where-Object { $_ }) -join ' ')
}

# Nombre válido de archivo para Windows: «Avatar: Fuego y ceniza» -> «Avatar - Fuego y ceniza».
function ConvertTo-HdzNombreArchivo([string]$Nombre) {
    $n = "$Nombre" -replace '\s*:\s*', ' - '
    $n = $n -replace '[<>"/\\|?*\x00-\x1f]', ''
    $n = ($n -replace '\s{2,}', ' ').Trim().TrimEnd('.')
    return $n
}

# Título y año a partir del nombre del ISO (por ejemplo «Avatar 3 jupk.iso» o
# «Avatar.Fire.and.Ash.2025.UHD.iso»), para buscarlo en TMDB.
function Get-HdzDiscoTituloDesdeArchivo([string]$Nombre) {
    $t = [System.IO.Path]::GetFileNameWithoutExtension("$Nombre")
    $anio = ''
    if ($t -match '\b(19\d{2}|20\d{2})\b') { $anio = $Matches[1] }
    $t = $t -replace '\(?\b(19\d{2}|20\d{2})\b\)?.*$', ''
    $t = $t -replace '(?i)\b(UHD|Full|BD|BluRay|Blu-Ray|2160p|1080p|ISO|BD25|BD50|BD66|BD100|DVD[59]?|Remux)\b.*$', ''
    $t = ($t -replace '[._]', ' ' -replace '\s{2,}', ' ').Trim(' ', '-')
    return [pscustomobject]@{ Titulo = $t; Anio = $anio }
}
