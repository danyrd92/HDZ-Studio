# Serie (episodios): UNA pestaña de subida con ficha común, capturas agrupadas por episodio,
# subida en orden (parando en el primer fallo y retomando), «abrir todos» y estado para la web.
# Sin red: el tracker, el host de imágenes y la apertura de torrents se simulan.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($ok,$message){if(-not $ok){throw $message}}
$testRoot=Join-Path $env:TEMP ('hdz_test_serie_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$ff=Join-Path $root 'bin/ffmpeg.exe'
. (Join-Path $root 'HDZ-Torrent.ps1')
$torrents=@()
foreach($n in 3,1,2){   # desordenados a propósito
    $base="Serie Prueba (2022) S01E0$n 90p NF WEB-DL AAC 1.0 H.264-HDZ"
    $mkv=Join-Path $testRoot "$base.mkv"
    & $ff -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=1' -f lavfi -i 'sine=frequency=440:duration=1' -map 0:v -map 1:a -c:v libx264 -preset ultrafast -c:a aac -shortest $mkv
    Assert ($LASTEXITCODE -eq 0) 'No se pudo crear el vídeo de prueba'
    foreach($c in 1,2){ & $ff -v error -f lavfi -i "color=c=red:s=160x90:d=0.1" -frames:v 1 (Join-Path $testRoot "${base}_cap_$c.png"); Assert ($LASTEXITCODE -eq 0) 'No se pudo crear la captura' }
    $torrents+=New-TorrentArchivo $mkv 'https://tracker.invalid/announce' '' $testRoot
}
$env:HDZ_GUI_TEST='1'; $env:HDZ_GUI_TEST_DIR=$testRoot
$env:HDZ_HISTORY_TEST_DIR=Join-Path $testRoot 'history'
try {
    . (Join-Path $root 'HDZ-GUI.ps1')
    # --- Simulaciones (sin red) ---
    $script:subidasHechas=@(); $script:fallarEn=''
    function Invoke-HdzRestMethod { param($Uri,$Method,$Form,$Headers,$TimeoutSec)
        $nm="$($Form.name)"
        if($script:fallarEn -and $nm -match $script:fallarEn){ throw 'Fallo simulado del tracker' }
        $script:subidasHechas+=[pscustomobject]@{Name=$nm;Desc="$($Form.description)";Ep="$($Form.episode_number)"}
        [pscustomobject]@{success=$true;message='ok';data="https://tracker.invalid/torrent/download/$($script:subidasHechas.Count).rss"} }
    function Send-Imagenes([string[]]$rutas) { [pscustomobject]@{Items=@($rutas|ForEach-Object{[pscustomobject]@{Ruta=$_;Full="https://img.invalid/$([uri]::EscapeDataString([IO.Path]::GetFileName($_)))"}});Error=$null} }
    function Descargar-TorrentTracker($url,$token,$dirDest,$nombreFallback) { $d=Join-Path $testRoot ("tracker_"+[guid]::NewGuid().ToString('N')+'.torrent'); Copy-Item -LiteralPath $torrents[0] -Destination $d; $d }
    function Publicar-TorrentAgente($ruta) { $null }
    $script:abiertos=@()
    function Get-HdzAppTorrent { 'C:\fake\qbittorrent.exe' }
    function Start-Process { param($FilePath,$ArgumentList) $script:abiertos+=[pscustomobject]@{Exe=$FilePath;Args=@($ArgumentList)} }
    $ui.cfgTrackerToken.Text='token-de-prueba'; $ui.cfgTrackerUrl.Text='https://tracker.invalid'; $ui.cfgTmdbKey.Text=''
    $script:firmaSel=$null

    # --- Chips de torrent con nombre de serie ---
    $ui.swSerie.IsChecked=$true
    $txt=@($script:gruposChips['torrent'] | ForEach-Object { "$($_.Radio.Content)" }) -join '|'
    Assert ($txt -match 'Serie \(episodios\)' -and $txt -match 'Serie \(pack\)') "Chips de torrent: $txt"

    # --- Carga de los 3 episodios: UNA pestaña, en orden ---
    $ui.navSubida.IsChecked=$true
    $antes=@($script:tabs).Count
    Cargar-EpisodiosSerie $torrents
    $series=@($script:tabs | Where-Object { $_.Serie })
    Assert ($null -ne $script:serieEps -and @($script:serieEps).Count -eq 3) "Episodios en la pestaña: $(@($script:serieEps).Count)"
    Assert ($series.Count -eq 1) "Pestañas de serie: $($series.Count)"
    $orden=@(Get-EpisodiosSerieOrdenados | ForEach-Object { Get-EtiquetaEpisodio $_ }) -join ','
    Assert ($orden -eq 'S01E01,S01E02,S01E03') "Orden: $orden"
    Assert ("$($ui.cardSerieEps.Visibility)" -eq 'Visible' -and "$($ui.upTitulo.Visibility)" -eq 'Collapsed' -and "$($ui.cardMediainfo.Visibility)" -eq 'Collapsed') 'La vista de serie no oculta lo de una subida suelta'
    Assert ("$($ui.btnSubir.Content)" -match 'Subir todos') "Botón: $($ui.btnSubir.Content)"
    # Capturas agrupadas: 6, con su episodio y en orden.
    $epsCaps=@($script:capRows | ForEach-Object { "$($_.Ep)" })
    Assert ($epsCaps.Count -eq 6 -and ($epsCaps -join ',') -eq 'S01E01,S01E01,S01E02,S01E02,S01E03,S01E03') "Capturas por episodio: $($epsCaps -join ',')"
    # Cada episodio: su MediaInfo propio.
    Assert (@($script:serieEps | Where-Object { -not $_.Mediainfo }).Count -eq 0) 'Falta el MediaInfo de algún episodio'
    # Marcar solo la 2ª captura del E01 y la 1ª del E03; E02 sin capturas.
    for($k=0;$k -lt 6;$k++){ $script:capRows[$k].Check.IsChecked = ($k -in 1,4) }
    Assert ("$($ui.upDescripcion.Text)" -notmatch 'img\.invalid') 'La descripción común no debe llevar capturas'

    # --- Web: estado ---
    $est=Componer-EstadoAgente | ConvertFrom-Json
    Assert ($est.serie.activa -and $est.serie.total -eq 3 -and @($est.serie.episodios).Count -eq 3) 'La web no recibe la serie'
    Assert (@($est.capturas | Where-Object { $_.ep -eq 'S01E02' }).Count -eq 2) 'La web no recibe el episodio de cada captura'
    Assert ($est.esSerieProyecto) 'La web no sabe que el proyecto es una serie'

    # --- Subida con fallo en el E02: se para ahí ---
    $script:fallarEn='S01E02'
    Invoke-SubidaSerie
    $estados=@(Get-EpisodiosSerieOrdenados | ForEach-Object { $_.Estado }) -join ','
    Assert ($estados -eq 'subido,error,pendiente') "Estados tras el fallo: $estados"
    Assert ($script:subidasHechas.Count -eq 1 -and $script:subidasHechas[0].Name -match 'S01E01') 'Debió subir solo el E01'
    Assert ($script:subidasHechas[0].Desc -match 'S01E01.*_cap_2\.png' -and $script:subidasHechas[0].Desc -notmatch '_cap_1\.png') "Capturas del E01: $($script:subidasHechas[0].Desc)"
    Assert ("$($ui.upDescripcion.Text)" -notmatch 'img\.invalid') 'La descripción común quedó con capturas tras subir'
    # --- Se corrige y se retoma: solo E02 y E03, en orden ---
    $script:fallarEn=''
    Invoke-SubidaSerie
    $nombres=@($script:subidasHechas | ForEach-Object { if($_.Name -match '(S01E\d+)'){$Matches[1]} }) -join ','
    Assert ($nombres -eq 'S01E01,S01E02,S01E03') "Orden de subida: $nombres"
    Assert ($script:subidasHechas[1].Desc -notmatch 'img\.invalid') 'El E02 no debía llevar capturas'
    Assert ($script:subidasHechas[2].Desc -match 'S01E03.*_cap_1\.png' -and $script:subidasHechas[2].Desc -notmatch 'S01E01') "Capturas del E03: $($script:subidasHechas[2].Desc)"
    Assert (@(Get-EpisodiosSerieOrdenados | Where-Object { $_.Estado -ne 'subido' }).Count -eq 0) 'No quedaron todos subidos'
    # --- Abrir todos: una sola llamada con los 3 torrents ---
    Abrir-TorrentsSerie
    Assert ($script:abiertos.Count -eq 1 -and @($script:abiertos[0].Args).Count -eq 3) "Abrir todos: $($script:abiertos.Count) llamadas"
    # --- Cambiar de pestaña y volver conserva la serie ---
    Nueva-Tab
    Assert ($null -eq $script:serieEps -and "$($ui.cardSerieEps.Visibility)" -eq 'Collapsed') 'Una pestaña normal muestra la vista de serie'
    Cambiar-Tab ([array]::IndexOf(@($script:tabs | ForEach-Object { [bool]$_.Serie }), $true))
    Assert (@($script:serieEps).Count -eq 3 -and @($script:capRows | Where-Object Ep).Count -eq 6) 'La serie no se restauró al volver a su pestaña'
    Write-Host "OK Test-SerieEpisodios: una pestaña, capturas por episodio, subida en orden con parada y reanudación, abrir todos y web. $testRoot"
} finally {
    Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_GUI_TEST_DIR,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
