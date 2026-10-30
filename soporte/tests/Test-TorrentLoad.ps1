# Recorrido real: orden remota -> historial -> ficha -> MediaInfo -> miniaturas.
# No se sustituyen Anadir-SubidaAuto ni Cargar-TorrentParaSubir por mocks.
$ErrorActionPreference='Stop'
$testRepo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$testRoot=Join-Path $env:TEMP ('hdz_test_load_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$video=Join-Path $testRoot 'Synthetic.2026.mkv';$png=Join-Path $testRoot 'fixture.png'
& (Join-Path $testRepo 'bin/ffmpeg.exe') -v error -f lavfi -i 'color=c=blue:s=320x180:r=24:d=1' -c:v libx264 -preset ultrafast $video
if($LASTEXITCODE -ne 0){throw 'No se pudo generar el vídeo'}
& (Join-Path $testRepo 'bin/ffmpeg.exe') -v error -f lavfi -i 'testsrc=size=1280x720' -frames:v 1 $png
if($LASTEXITCODE -ne 0){throw 'No se pudo generar la imagen'}
$caps=@(1..6|ForEach-Object {$path=Join-Path $testRoot "Synthetic_cap_$_.png";Copy-Item -LiteralPath $png -Destination $path;$path})
. (Join-Path $testRepo 'HDZ-Torrent.ps1')
$torrent=New-TorrentArchivo $video
$torrentHash=(Get-FileHash $torrent).Hash
$env:HDZ_GUI_TEST='1';$env:HDZ_GUI_TEST_DIR=$testRoot;$env:HDZ_HISTORY_TEST_DIR=Join-Path $testRoot 'history'
try {
    . (Join-Path $testRepo 'HDZ-GUI.ps1')
    Reset-Todo
    $ui.cfgTmdbKey.Text=''
    $rutaMemTorrents=Join-Path $testRoot 'memory.json'
    [IO.File]::WriteAllText($rutaMemTorrents,(@(@{TorrentRuta=$torrent;Video=$video;Capturas=$caps;Origen=$testRoot})|ConvertTo-Json))
    [void](Add-HdzHistory @{kind='torrent';status='Creado';torrent=$torrent})
    $script:agSync=[hashtable]::Synchronized(@{Estado=$null;PushNow=$false})
    Start-HdzAgentStateTimer
    Aplicar-ComandoAgente ([pscustomobject]@{type='click';name='btnTorrentUltimo';_id='test-full-torrent-load';session=$script:agSession})
    if(-not $script:agCompleted['test-full-torrent-load'].ok){throw 'Falló la orden remota'}
    if($ui.txtTorrentSubir.Text -ne $torrent -or $script:videoSubir -ne $video){throw 'No se cargó el torrent o vídeo esperado'}
    if($script:capRows.Count -ne 6 -or $script:capPreviewCache.Count -ne 6){throw 'No se cargaron las seis capturas'}
    if([string]::IsNullOrWhiteSpace($ui.upMediainfo.Text)){throw 'No se cargó MediaInfo'}
    $state=Componer-EstadoAgente|ConvertFrom-Json
    if(@($state.capturas|Where-Object {$_.thumb -like 'data:image/jpeg;base64,*'}).Count -ne 6){throw 'Faltan miniaturas en la web'}
    if($script:networkBusy -or $script:capPreviewSync){throw 'La interfaz quedó ocupada'}
    if((Get-FileHash $torrent).Hash -ne $torrentHash){throw 'Se modificó el torrent'}
    Reset-Todo
    if($script:capPreviewCache.Count -or $script:capRows.Count){throw 'Quedaron miniaturas tras reiniciar'}
    Write-Host "TORRENT_FULL_LOAD_REGRESSION_OK: $testRoot"
} finally {
    if($script:agStateTimer){$script:agStateTimer.Stop()}
    Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_GUI_TEST_DIR,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue
}
