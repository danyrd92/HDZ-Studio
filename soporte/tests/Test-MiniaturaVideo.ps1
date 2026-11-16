# Descargas de YouTube con la miniatura guardada como SEGUNDA pista de vídeo (PNG): el motor debe
# quedarse con el vídeo H.264, no meter la miniatura en el MKV y terminar sin incidencias.
$ErrorActionPreference='Stop'
$appRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture=Join-Path $env:TEMP ('hdz_miniatura_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
$source=Join-Path $fixture 'Serie # Episodio 1# Titulo HD.mkv'
& "$appRoot/bin/ffmpeg.exe" -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=2' -f lavfi -i 'sine=frequency=440:duration=2' -f lavfi -i 'color=c=red:s=160x90:r=1:d=1' -map 0:v -map 1:a -map 2:v -c:v:0 libx264 -preset ultrafast -c:v:1 png -c:a aac -metadata:s:a:0 language=spa -shortest $source
if($LASTEXITCODE -ne 0){throw 'Cannot create fixture'}
$hash=(Get-FileHash -LiteralPath $source).Hash
$env:HDZ_GUI_TEST='1';$env:HDZ_HISTORY_TEST_DIR=Join-Path $fixture 'history'
function Assert($condition,$message){if(-not $condition){throw $message}}
try {
    $inVideos=@((& "$appRoot/bin/ffprobe.exe" -v error -show_streams -of json $source | Out-String | ConvertFrom-Json).streams | Where-Object codec_type -eq video)
    Assert ($inVideos.Count -eq 2 -and @($inVideos.codec_name) -contains 'png') "Fixture sin miniatura PNG: $(@($inVideos.codec_name) -join ',')"
    . "$appRoot/HDZ-GUI.ps1"
    $ui.txtCarpeta.Text=$fixture;$rows=@(& $scanWorker @($source));$script:ultimoScan=$rows;$script:seleccion=@{$rows[0].Nombre=$true};Construir-Adaptacion $rows
    $ui.txtTitulo.Text='Miniatura Audit';$ui.txtAno.Text='2026';$ui.swSerie.IsChecked=$true
    Set-ChipValor 'originales' 'INTACTO';Set-ChipValor 'torrent' 'NO';Set-ChipValor 'capturasProy' 0
    $ui.cfgCarpetaProcesados.Text='';$ui.cfgCarpetaTorrent.Text='';$ui.txtAnnounce.Text='';$ui.txtSalidaArchivo.Text=Join-Path $fixture 'output'
    $script:testJobsMontaje=@();Iniciar-Montaje 'unico';Assert ($script:testJobsMontaje.Count -eq 1) "No crea trabajo: $($ui.lblEstado.Text)"
    $job=$script:testJobsMontaje[0];$stdout=Join-Path $fixture 'stdout.txt'
    $p=Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-File',('"'+$job.LauncherPath+'"')) -RedirectStandardOutput $stdout -RedirectStandardError (Join-Path $fixture 'stderr.txt')
    if(-not $p.WaitForExit(90000)){$p.Kill($true);throw 'Timeout'}
    Assert ($p.ExitCode -eq 0) "Motor terminó con $($p.ExitCode) (2 = incidencias): $fixture"
    $out=@(Get-ChildItem -LiteralPath (Join-Path $fixture 'output') -Recurse -Filter '*.mkv')[0]
    Assert $out "No hay MKV final: $fixture"
    $streams=@((& "$appRoot/bin/ffprobe.exe" -v error -show_streams -of json $out.FullName | Out-String | ConvertFrom-Json).streams)
    $videos=@($streams|Where-Object codec_type -eq video);$audios=@($streams|Where-Object codec_type -eq audio)
    Assert ($videos.Count -eq 1 -and $videos[0].codec_name -eq 'h264') "Vídeos finales: $(@($videos.codec_name) -join ',')"
    Assert ($audios.Count -eq 1) "Audios finales: $($audios.Count)"
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $hash) 'Se alteró el original'
    Write-Host "MINIATURA_VIDEO_OK: miniatura PNG descartada, H.264 + audio conservados y original intacto. $fixture"
} finally { Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue }
