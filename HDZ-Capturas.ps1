# =========================================================================
# HDZ-Capturas.ps1 — núcleo compartido de capturas de HD ZERO Studio
# =========================================================================
# Este fichero no ejecuta nada al cargarse. Solo define las funciones que usan
# HDZnew.ps1, capturas.ps1 y la acción del menú contextual.
#
# El algoritmo de New-HdzCapturas debe mantenerse como la única implementación:
#
#   - calcula una ventana útil evitando el arranque y los créditos finales;
#   - distribuye las capturas uniformemente (una sola = centro del vídeo);
#   - aplica tonemapping a HDR y conserva los colores directos en SDR;
#   - escribe PNG sin pérdida a la resolución original y comprueba que no esté vacío;
#   - reintenta el reparto si la duración declarada está inflada.
# =========================================================================

function Get-HdzVideoTrackFromMediaInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RutaVideo)

    try {
        $raw = (& mediainfo --Output=JSON "$RutaVideo" 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $json = $raw | ConvertFrom-Json
        if ($json -and $json.media -and $json.media.track) {
            return @($json.media.track | Where-Object { "$($_.'@type')" -eq 'Video' } | Select-Object -First 1)[0]
        }
    } catch {}
    return $null
}

function Test-HdzVideoHdr {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RutaVideo)

    # Es la misma detección que Get-DatosTecnicosMkv en HDZnew.ps1: primero se
    # consulta HDR_Format y, si falta, se usa BT.2020 + PQ + al menos 10 bits.
    $pista = Get-HdzVideoTrackFromMediaInfo $RutaVideo
    if ($pista) {
        $hdrStr = "$($pista.HDR_Format) $($pista.HDR_Format_Compatibility) $($pista.HDR_Format_String)"
        if ($hdrStr -match '(?i)Dolby Vision|HDR10\+|SMPTE ST 2094 App 4|HDR10') { return $true }

        $primarias = "$($pista.colour_primaries)"
        $transferencia = "$($pista.transfer_characteristics)"
        $profBits = 0
        if ($pista.BitDepth) { $profBits = [int]"$($pista.BitDepth)" }
        if ($primarias -match '(?i)BT\.?2020' -and
            $transferencia -match '(?i)PQ|SMPTE ST 2084|ST 2084|HLG|ARIB' -and
            $profBits -ge 10) { return $true }
        return $false
    }

    # Respaldo para instalaciones sin MediaInfo o con metadata incompleta.
    try {
        $probe = (& ffprobe -v error -select_streams v:0 -show_entries `
            stream=color_primaries,color_transfer,bits_per_raw_sample,pix_fmt `
            -of default=noprint_wrappers=1:nokey=0 "$RutaVideo" 2>$null | Out-String)
        if ($probe -match '(?im)color_primaries=(bt2020|bt2020nc)' -and
            $probe -match '(?im)color_transfer=(smpte2084|arib-std-b67)' -and
            $probe -match '(?im)(bits_per_raw_sample=1[0-9]|pix_fmt=.*10)') { return $true }
    } catch {}
    return $false
}

function New-HdzCapturas {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivoVideo,
        [Parameter(Mandatory)][int]$NumCapturas,
        [bool]$EsHdr = $true,
        [string]$DirCapturas = $null,
        [string]$NombreFinal = $null,
        [scriptblock]$OnProgress = $null,
        [scriptblock]$OnDiagnostic = $null,
        [scriptblock]$OnIncident = $null
    )

    if (-not (Test-Path -LiteralPath $ArchivoVideo -PathType Leaf)) {
        throw "No existe el vídeo: $ArchivoVideo"
    }
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        throw 'FFmpeg no encontrado.'
    }
    if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
        throw 'FFprobe no encontrado.'
    }

    $dirCap = if (-not [string]::IsNullOrWhiteSpace("$DirCapturas")) {
        "$DirCapturas"
    } else {
        Split-Path -Parent (Resolve-Path -LiteralPath $ArchivoVideo).Path
    }
    [void][System.IO.Directory]::CreateDirectory($dirCap)

    $baseNombre = if (-not [string]::IsNullOrWhiteSpace("$NombreFinal")) {
        [System.IO.Path]::GetFileNameWithoutExtension("$NombreFinal")
    } else {
        [System.IO.Path]::GetFileNameWithoutExtension($ArchivoVideo)
    }

    $resultado = [ordered]@{
        Capturas    = @()
        Solicitadas = [int]$NumCapturas
        Fallos      = 0
        Duracion    = 0.0
        EsHdr       = [bool]$EsHdr
        Inicio      = $null
        Fin         = $null
    }
    if ($NumCapturas -le 0) { return [pscustomobject]$resultado }

    $tipoCaptura = if ($EsHdr) { 'tonemapped (HDR)' } else { 'directas (SDR)' }
    Write-Host "`n[>>] Generando $NumCapturas capturas $tipoCaptura..." -ForegroundColor Cyan
    if ($OnDiagnostic) { [void](& $OnDiagnostic "Capturas: INICIO ($NumCapturas, $tipoCaptura)") }

    # Las acciones recibidas como callbacks mantienen a este núcleo independiente
    # de la GUI: HDZnew actualiza su segunda barra y el menú contextual actualiza
    # su ventana de progreso.
    $setProgress = {
        param([int]$Pct, [string]$Fase)
        if ($OnProgress) { [void](& $OnProgress $Pct $Fase) }
    }.GetNewClosure()
    $addIncident = {
        param([string]$Archivo, [string]$Mensaje)
        if ($OnIncident) { [void](& $OnIncident $Archivo $Mensaje) }
    }.GetNewClosure()

    # "$(...)" protege contra ffprobe devolviendo $null o varias líneas.
    $rawDur = "$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$ArchivoVideo" 2>$null)".Trim()
    $dur = 0.0
    $durValida = (-not [string]::IsNullOrWhiteSpace($rawDur)) -and
                 [double]::TryParse($rawDur.Replace(',', '.'), [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dur) -and
                 $dur -gt 0
    $resultado.Duracion = $dur

    if ($durValida) {
        # Segundo de inicio de la primera captura, según duración:
        #  - <=5 min (300 s): 20 s fijo;
        #  - 5 a 30 min: escala lineal de 20 s hasta 300 s;
        #  - >=30 min (1800 s): 300 s fijo.
        if ($dur -le 300) {
            $inic = 20
        } elseif ($dur -ge 1800) {
            $inic = 300
        } else {
            $inic = 20 + (300 - 20) * ($dur - 300) / (1800 - 300)
        }

        # Margen final para no caer en créditos: 60 s en vídeos largos y un 8 %
        # proporcional en los cortos.
        $margenFin = if ($dur -lt 1800) { [Math]::Min(60, $dur * 0.08) } else { 60 }
        $fin = $dur - $margenFin
        if ($fin -le $inic) {
            $inic = $dur * 0.10
            $fin  = $dur * 0.90
        }
        $resultado.Inicio = $inic
        $resultado.Fin = $fin

        # Saca UN fotograma en el segundo indicado. Solo devuelve la ruta si
        # FFmpeg escribió realmente una imagen no vacía.
        $sacarCaptura = {
            param($t)
            $ts = ([int]$t).ToString('D4')
            $finalCapture = Join-Path $dirCap "${baseNombre}_cap_$ts.png"
            $rc = Join-Path $dirCap (".hdz_cap_" + [guid]::NewGuid().ToString('N') + '.png')
            if ($EsHdr) {
                & ffmpeg -noaccurate_seek -ss $t -i "$ArchivoVideo" -frames:v 1 `
                    -vf 'zscale=t=linear:npl=250,tonemap=tonemap=reinhard:desat=2,zscale=p=709:t=709:m=709,format=rgb24' `
                    -compression_level 6 "$rc" -y -loglevel fatal 2>$null | Out-Null
            } else {
                & ffmpeg -noaccurate_seek -ss $t -i "$ArchivoVideo" -frames:v 1 `
                    -vf 'format=rgb24' -compression_level 6 "$rc" -y -loglevel fatal 2>$null | Out-Null
            }
            # En SMB, el nombre temporal con punto puede recibir el atributo Hidden.
            # Sin -Force, Get-Item no lo devuelve y se descarta una captura válida.
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $rc) -and ((Get-Item -LiteralPath $rc -Force -ErrorAction SilentlyContinue).Length -gt 8)) {
                $signature = [IO.File]::ReadAllBytes($rc)[0..7]
                if ([BitConverter]::ToString([byte[]]$signature) -eq '89-50-4E-47-0D-0A-1A-0A') {
                    [IO.File]::Move($rc, $finalCapture, $true)
                    # Un atributo Hidden explícito puede sobrevivir al renombrado.
                    $attributes = [IO.File]::GetAttributes($finalCapture)
                    if ($attributes -band [IO.FileAttributes]::Hidden) {
                        [IO.File]::SetAttributes($finalCapture, ($attributes -band (-bnot [IO.FileAttributes]::Hidden)))
                    }
                    return $finalCapture
                }
            }
            if (Test-Path -LiteralPath $rc) { Remove-Item -LiteralPath $rc -Force -ErrorAction SilentlyContinue }
            return $null
        }.GetNewClosure()

        # Calcula N segundos objetivo repartidos por igual en [inicio..fin].
        # Con N=1 se utiliza el centro de la ventana.
        $puntos = {
            param($ini, $finv, $n)
            $r = @()
            for ($j = 0; $j -lt $n; $j++) {
                if ($n -eq 1) { $r += [int]($ini + ($finv - $ini) / 2) }
                else { $r += [int]($ini + (($finv - $ini) * $j / ($n - 1))) }
            }
            @($r)
        }.GetNewClosure()

        # 1ª pasada: reparto sobre la duración declarada.
        $okCaps = @()
        $objetivos = @(& $puntos $inic $fin $NumCapturas)
        for ($i = 0; $i -lt $objetivos.Count; $i++) {
            & $setProgress ([int](100 * $i / $NumCapturas)) "Generando capturas ($($i + 1)/$NumCapturas)"
            $r = & $sacarCaptura $objetivos[$i]
            if ($r) {
                $okCaps += $r
                Write-Host "   -> Captura en segundo $($objetivos[$i])" -ForegroundColor Gray
            } else {
                Write-Host "   -> (sin imagen en el segundo $($objetivos[$i]))" -ForegroundColor DarkYellow
            }
        }

        # Si faltan capturas y al menos una salió, normalmente la duración del
        # contenedor está inflada. Rehacemos el reparto dentro del último punto
        # que produjo imagen, sin dejar PNGs de la primera pasada.
        if ($okCaps.Count -ge 1 -and $okCaps.Count -lt $NumCapturas) {
            $finReal = 0
            for ($i = 0; $i -lt $objetivos.Count; $i++) {
                $ts = ([int]$objetivos[$i]).ToString('D4')
                $rc = Join-Path $dirCap "${baseNombre}_cap_$ts.png"
                if ($rc -in $okCaps) { $finReal = $objetivos[$i] }
            }
            if ($finReal -gt $inic) {
                Write-Host "   [i] Solo $($okCaps.Count)/$NumCapturas capturas: la duración declarada ($([int]$dur)s) parece inflada. Rehago el reparto en [$([int]$inic)..$([int]$finReal)]s." -ForegroundColor DarkYellow
                if ($OnDiagnostic) { [void](& $OnDiagnostic "Capturas: duración inflada (dur=$([int]$dur)s, fin real ~$([int]$finReal)s). Relleno dentro del rango con imagen.") }
                foreach ($old in $okCaps) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
                $okCaps = @()
                $objetivos2 = @(& $puntos $inic $finReal $NumCapturas)
                for ($i = 0; $i -lt $objetivos2.Count; $i++) {
                    & $setProgress ([int](100 * $i / $NumCapturas)) "Generando capturas ($($i + 1)/$NumCapturas)"
                    $r = & $sacarCaptura $objetivos2[$i]
                    if ($r) {
                        $okCaps += $r
                        Write-Host "   -> Captura en segundo $($objetivos2[$i])" -ForegroundColor Gray
                    }
                }
            }
        }

        $okCaps = @($okCaps | Select-Object -Unique)
        $resultado.Capturas = @($okCaps)
        $resultado.Fallos = [Math]::Max(0, $NumCapturas - $okCaps.Count)
        if ($okCaps.Count -lt $NumCapturas) {
            & $addIncident (Split-Path $ArchivoVideo -Leaf) "Solo se generaron $($okCaps.Count) de $NumCapturas capturas (posible duración incorrecta en los metadatos del archivo)."
        }
    } else {
        Write-Host '   [!] No se pudo leer la duración del archivo; se omiten las capturas.' -ForegroundColor DarkYellow
        $resultado.Fallos = $NumCapturas
        & $addIncident (Split-Path $ArchivoVideo -Leaf) 'No se pudieron generar capturas (duración no legible con ffprobe).'
    }

    & $setProgress 100 "Capturas terminadas ($($resultado.Capturas.Count)/$NumCapturas)"
    if ($OnDiagnostic) { [void](& $OnDiagnostic "Capturas: FIN ($($resultado.Capturas.Count)/$NumCapturas)") }
    return [pscustomobject]$resultado
}
