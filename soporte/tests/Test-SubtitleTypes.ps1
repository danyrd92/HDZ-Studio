# Tipos de subtítulos (Completos / Forzados / SDH): detección de SDH, filtro de la GUI/web y
# «un sub por idioma + tipo + formato, el primero». Sin medios reales.
$ErrorActionPreference = 'Stop'
$tiposAppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tiposTestRoot = Join-Path $env:TEMP ('hdz_subtypes_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tiposTestRoot)
function Assert($ok, $msg) { if (-not $ok) { throw $msg } }
$fixtureDir = Join-Path $tiposTestRoot 'fixtures'
[void][IO.Directory]::CreateDirectory($fixtureDir)
function New-Srt($nombre, $texto, [int]$bloques, [switch]$Sonidos) {
    $sb = [Text.StringBuilder]::new()
    for ($i = 1; $i -le $bloques; $i++) {
        $ini = [TimeSpan]::FromMilliseconds(($i - 1) * 100); $fin = $ini.Add([TimeSpan]::FromMilliseconds(90))
        $linea = if ($Sonidos -and ($i % 2 -eq 0)) { '[música de suspense]' } else { "$texto $i" }
        [void]$sb.Append("$i`n$($ini.ToString('hh\:mm\:ss\,fff')) --> $($fin.ToString('hh\:mm\:ss\,fff'))`n$linea`n`n")
    }
    $ruta = Join-Path $fixtureDir $nombre
    [IO.File]::WriteAllText($ruta, $sb.ToString(), [Text.UTF8Encoding]::new($false))
    $ruta
}
$esForz  = New-Srt 'es_forzado.srt' 'Cartel' 2
$esCompA = New-Srt 'es_compA.srt'   'Primera traduccion' 18
$esCompB = New-Srt 'es_compB.srt'   'Segunda traduccion' 18
$esGrande = New-Srt 'es_grande.srt'  'Cartel grande' 10
$esSdh   = New-Srt 'es_sdh.srt'     'Dialogo' 20 -Sonidos
$esSdh2  = New-Srt 'es_sdh2.srt'    'Dialogo sin marca' 20 -Sonidos
$frComp  = New-Srt 'fr_comp.srt'    'Traduction' 18
$frSdh   = New-Srt 'fr_sdh.srt'     'Dialogue' 20 -Sonidos
$video = Join-Path $fixtureDir 'video.mkv'
& (Join-Path $tiposAppRoot 'bin/ffmpeg.exe') -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=2' -f lavfi -i 'sine=frequency=440:duration=2' -map 0:v -map 1:a -c:v libx264 -preset ultrafast -c:a aac -metadata:s:a:0 language=spa -shortest $video
Assert ($LASTEXITCODE -eq 0) 'No se pudo generar el vídeo sintético'
$source = Join-Path $tiposTestRoot 'Subtipos.Test.2026.mkv'
# Orden de origen: forzado, completo A, completo B, «completo» pequeño sin marca (forzado grande: 55%),
# SDH (flag), SDH sin marca (solo contenido), fr completo, fr SDH (título).
& (Join-Path $tiposAppRoot 'bin/mkvmerge.exe') -q -o $source $video `
    --language 0:spa --forced-display-flag 0:1 $esForz `
    --language 0:spa $esCompA `
    --language 0:spa $esCompB `
    --language 0:spa $esGrande `
    --language 0:spa --hearing-impaired-flag 0:1 $esSdh `
    --language 0:spa $esSdh2 `
    --language 0:fre $frComp `
    --language 0:fre --track-name '0:Français SDH' $frSdh
Assert ($LASTEXITCODE -eq 0) 'No se pudo generar la fuente sintética'
Remove-Item -LiteralPath $fixtureDir -Recurse -Force   # los SRT sueltos entrarían como externos
$sourceHash = (Get-FileHash -LiteralPath $source).Hash

function Get-SubsResultado($dirSalida) {
    $out = @(Get-ChildItem -LiteralPath $dirSalida -Filter '*.mkv')[0]
    Assert ($null -ne $out) "Falta el resultado en $dirSalida"
    $j = & (Join-Path $tiposAppRoot 'bin/mkvmerge.exe') -J $out.FullName | Out-String | ConvertFrom-Json
    @($j.tracks | Where-Object type -eq 'subtitles')
}

$env:HDZ_GUI_TEST = '1'; $env:HDZ_HISTORY_TEST_DIR = Join-Path $tiposTestRoot 'history'
try {
    . (Join-Path $tiposAppRoot 'HDZ-GUI.ps1')
    $ui.txtCarpeta.Text = $tiposTestRoot
    $rows = @(& $scanWorker @($source))
    Assert (-not $rows[0].Error) "Análisis: $($rows[0].Error)"
    $script:ultimoScan = $rows
    $script:seleccion = @{ $rows[0].Nombre = $true }
    Construir-Adaptacion $rows
    Assert ($ui.cardFiltro.Visibility -eq 'Visible') 'No se muestra la tarjeta de subtítulos'
    Assert (@($script:chipsTiposSub).Count -eq 3) 'Faltan los tres botones de tipo'
    Assert (@($script:chipsTiposSub | Where-Object IsChecked).Count -eq 3) 'Los tipos no empiezan todos marcados'
    $state = Componer-EstadoAgente | ConvertFrom-Json
    Assert ($state.tiposSubsVisible -and @($state.tiposSubs).Count -eq 3) 'La web no recibe el selector de tipos'

    $ui.txtTitulo.Text = 'Subtipos Audit'; $ui.txtAno.Text = '2026'
    $ui.swSerie.IsChecked = $false
    Set-ChipValor 'originales' 'INTACTO'; Set-ChipValor 'torrent' 'NO'; Set-ChipValor 'capturasProy' 0
    Set-ChipValor 'filtro' 'TODOS'
    $ui.cfgCarpetaProcesados.Text = ''; $ui.cfgCarpetaTorrent.Text = ''; $ui.txtAnnounce.Text = ''

    function Invoke-Caso($nombre) {
        $dir = Join-Path $tiposTestRoot "output_$nombre"
        $ui.txtSalidaArchivo.Text = $dir
        $script:testJobsMontaje = @()
        Iniciar-Montaje 'unico'
        Assert ($script:testJobsMontaje.Count -eq 1) "No se creó el trabajo ($nombre): $($ui.lblEstado.Text)"
        $job = $script:testJobsMontaje[0]
        $stdout = Join-Path $tiposTestRoot "stdout_$nombre.txt"; $stderr = Join-Path $tiposTestRoot "stderr_$nombre.txt"
        $p = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-File',('"'+$job.LauncherPath+'"')) -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if (-not $p.WaitForExit(90000)) { $p.Kill($true); throw "Montaje bloqueado ($nombre): $tiposTestRoot" }
        Assert ($p.ExitCode -eq 0) "Motor falló ($nombre): $tiposTestRoot"
        [pscustomobject]@{ Cfg = ($job.CfgJson | ConvertFrom-Json); Subs = (Get-SubsResultado $dir) }
    }

    # Caso 1: los tres tipos. Un sub por idioma + tipo + formato; el primero de cada uno, salvo el
    # «completo» de tamaño muy distinto, que se conserva como dudoso.
    $r1 = Invoke-Caso 'todos'
    Assert ($r1.Cfg.PSObject.Properties.Name -notcontains 'TiposSubsMantener') 'Con los tres marcados no debe enviarse filtro'
    $nombres = @($r1.Subs | ForEach-Object { $_.properties.track_name })
    $esperado = @('Castellano Forzados Planos','Castellano Completos Planos','Castellano Completos Planos','Castellano SDH Planos','Francés Completos Planos','Francés SDH Planos')
    Assert ((@($nombres) -join '|') -eq ($esperado -join '|')) "Pistas inesperadas: $($nombres -join ' | ')"
    $compEs = $r1.Subs[1]
    $grandeEs = $r1.Subs[2]
    $sdhEs = $r1.Subs[3]
    $log1 = Get-Content -LiteralPath (Join-Path $tiposTestRoot 'stdout_todos.txt') -Raw
    Assert ($log1 -match 'DUDOSO') 'No se avisa del completo dudoso'
    Assert ($log1 -match 'marcado SDH por contenido') 'No se analizó el contenido'
    Assert ($log1 -notmatch 'ffmpeg no sacó') 'Se usó el respaldo en vez de los 10 primeros minutos'
    Assert ($sdhEs.properties.flag_hearing_impaired -eq $true) 'El SDH no lleva la marca hearing-impaired'
    Assert ($r1.Subs[1].properties.flag_hearing_impaired -ne $true) 'Un completo quedó marcado como SDH'
    # El completo que queda es el PRIMERO (A), no el B: se comprueba por contenido.
    # Fuera de la carpeta de origen: un SRT suelto ahí entraría como externo en el caso 2.
    $dirExtr = Join-Path $env:TEMP ('hdz_subtypes_extr_' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dirExtr)
    $tmpA = Join-Path $dirExtr 'compA.srt'
    $outMkv = @(Get-ChildItem -LiteralPath (Join-Path $tiposTestRoot 'output_todos') -Filter '*.mkv')[0].FullName
    & (Join-Path $tiposAppRoot 'bin/mkvextract.exe') $outMkv tracks "$($compEs.id):$tmpA" | Out-Null
    Assert ((Get-Content -LiteralPath $tmpA -Raw) -match 'Primera traduccion') 'No se conservó el primer completo'
    $tmpG = Join-Path $dirExtr 'grande.srt'
    & (Join-Path $tiposAppRoot 'bin/mkvextract.exe') $outMkv tracks "$($grandeEs.id):$tmpG" | Out-Null
    Assert ((Get-Content -LiteralPath $tmpG -Raw) -match 'Cartel grande') 'El dudoso conservado no es el pequeño'
    $tmpS = Join-Path $dirExtr 'sdhEs.srt'
    & (Join-Path $tiposAppRoot 'bin/mkvextract.exe') $outMkv tracks "$($sdhEs.id):$tmpS" | Out-Null
    Assert ((Get-Content -LiteralPath $tmpS -Raw) -match 'Dialogo 1\b') 'No se conservó el primer SDH (el marcado)'

    # Caso 2: el móvil desmarca SDH. Llega como TiposSubsMantener y no queda ningún SDH.
    Aplicar-ComandoAgente ([pscustomobject]@{type='set_sub_tipo';code='SDH';value=$false;_id='subtypes-web-1';session=$script:agSession})
    $state = Componer-EstadoAgente | ConvertFrom-Json
    Assert (-not (@($state.tiposSubs | Where-Object v -eq 'SDH')[0].sel)) 'La web no refleja SDH desmarcado'
    $r2 = Invoke-Caso 'sinsdh'
    Assert ((@($r2.Cfg.TiposSubsMantener) -join ',') -eq 'Completos,Forzados') "Filtro enviado: $(@($r2.Cfg.TiposSubsMantener) -join ',')"
    $nombres2 = @($r2.Subs | ForEach-Object { $_.properties.track_name })
    Assert ((@($nombres2) -join '|') -eq 'Castellano Forzados Planos|Castellano Completos Planos|Castellano Completos Planos|Francés Completos Planos') "Sin SDH: $($nombres2 -join ' | ')"

    # Caso 3: ningún tipo marcado no lanza el montaje.
    foreach ($tb in $script:chipsTiposSub) { $tb.IsChecked = $false }
    $script:testJobsMontaje = @()
    Iniciar-Montaje 'unico'
    Assert ($script:testJobsMontaje.Count -eq 0) 'Se lanzó un montaje sin tipos de subtítulo'
    Assert ($ui.lblEstado.Text -match 'Tipos de subtítulos') "Falta el aviso: $($ui.lblEstado.Text)"

    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $sourceHash) 'El original fue modificado'
    Reset-Todo
    Assert (@($script:chipsTiposSub | Where-Object IsChecked).Count -eq 3) 'Empezar de Zero no restablece los tipos'
    Write-Host "SUBTITLE_TYPES_OK: SDH por flag, título y contenido (10 primeros minutos); filtro GUI/web; primero de cada tipo; completo dudoso conservado. $tiposTestRoot"
} finally {
    Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue
}
