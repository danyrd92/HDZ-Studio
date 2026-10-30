param([switch]$Remix)
$ErrorActionPreference='Stop'
$audioAppRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture=Join-Path $env:TEMP ('hdz_audio_tracks_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
$source=Join-Path $fixture 'Source.mkv'
& "$audioAppRoot/bin/ffmpeg.exe" -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=2' -f lavfi -i 'sine=frequency=440:duration=2' -map 0:v -map 1:a -map 1:a -map 1:a -c:v libx264 -preset ultrafast -c:a:0 aac -c:a:1 ac3 -c:a:2 aac -metadata:s:a:0 language=spa -metadata:s:a:1 language=spa -metadata:s:a:2 language=eng -shortest $source
if($LASTEXITCODE -ne 0){throw 'Cannot create fixture'}
$hash=(Get-FileHash -LiteralPath $source).Hash
$env:HDZ_GUI_TEST='1';$env:HDZ_HISTORY_TEST_DIR=Join-Path $fixture 'history'
function Assert($condition,$message){if(-not $condition){throw $message}}
try {
 . "$audioAppRoot/HDZ-GUI.ps1"
 $ui.txtCarpeta.Text=$fixture;$rows=@(& $scanWorker @($source));$script:ultimoScan=$rows;$script:seleccion=@{$rows[0].Nombre=$true};Construir-Adaptacion $rows
 $trackSource=$source
 if($Remix){
  $trackSource=Join-Path $fixture 'Donor.mkv';Copy-Item -LiteralPath $source -Destination $trackSource
  $ui.swRemezcla.IsChecked=$true;Add-FilaRemezcla $fixture $source;Add-FilaRemezcla $fixture $trackSource
  $script:remezclaCarpetas[0].Video.IsChecked=$true;$script:remezclaCarpetas[0].Audio.IsChecked=$false;$script:remezclaCarpetas[0].Subs.IsChecked=$false
  $script:remezclaCarpetas[1].Video.IsChecked=$false;$script:remezclaCarpetas[1].Audio.IsChecked=$true
  $raw=@(& $scanWorker @($source,$trackSource));$rows=@(Combinar-EscaneoRemezcla $raw @(Leer-RemezclaCarpetas));$script:ultimoScan=$rows;$script:seleccion=@{$rows[0].Nombre=$true};Construir-Adaptacion $rows
 }
 Assert ($script:audioTrackRows.Count -eq 3) 'No enumera cada pista'
 $removed=@($script:audioTrackRows|Where-Object Id -eq 2)[0]
 Aplicar-ComandoAgente ([pscustomobject]@{type='set_audio_track';archivo=$trackSource;id=2;value=$false;session=$script:agSession;projectTab=$script:tabProyActual})
 Assert (-not $removed.Choice.IsChecked) 'Orden remota no desmarca pista'
 Assert (@($script:audioTrackRows|Where-Object {$_.Choice.IsChecked}).Count -eq 2) 'Elimina otra pista del mismo idioma'
 $snapshot=Snapshot-DecisionesTab;Construir-Adaptacion $rows;Restore-DecisionesTab $snapshot
 Assert (-not @($script:audioTrackRows|Where-Object Id -eq 2)[0].Choice.IsChecked) 'Pierde selección al reconstruir'
 $state=Componer-EstadoAgente|ConvertFrom-Json
 Assert ($state.audioTracksSupported -and @($state.audioTracks|Where-Object {-not $_.sel}).Count -eq 1) 'Estado remoto incorrecto'
 $ui.txtTitulo.Text='Audio Tracks Audit';$ui.txtAno.Text='2026';$ui.swSerie.IsChecked=$false
 Set-ChipValor 'originales' 'INTACTO';Set-ChipValor 'torrent' 'NO';Set-ChipValor 'capturasProy' 0
 $ui.cfgCarpetaProcesados.Text='';$ui.cfgCarpetaTorrent.Text='';$ui.txtAnnounce.Text='';$ui.txtSalidaArchivo.Text=Join-Path $fixture 'output'
 $script:testJobsMontaje=@();Iniciar-Montaje 'unico';Assert ($script:testJobsMontaje.Count -eq 1) 'No crea trabajo'
 $job=$script:testJobsMontaje[0];$config=$job.CfgJson|ConvertFrom-Json
 Assert (@($config.PistasAudioExcluidas).Count -eq 1) 'No envía exclusión exacta'
 # Una conversión configurada para la pista desmarcada también debe omitirse.
 $config|Add-Member -Force -NotePropertyName ConversionesAudioManual -NotePropertyValue @(@{Index=2;CodecDestino='eac3';CanalesDestino=1;BitrateK=128;Lang='es';MantenerOriginal=$true;FuenteExacta=$true;ArchivoFuente=$trackSource})
 [IO.File]::WriteAllText($job.CfgPath,($config|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
 $p=Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-File',('"'+$job.LauncherPath+'"')) -RedirectStandardOutput (Join-Path $fixture 'stdout.txt') -RedirectStandardError (Join-Path $fixture 'stderr.txt')
 if(-not $p.WaitForExit(60000)){$p.Kill($true);throw 'Timeout'}
 Assert ($p.ExitCode -eq 0) "Motor falló: $fixture"
 $out=@(Get-ChildItem -LiteralPath (Join-Path $fixture 'output') -Filter '*.mkv')[0]
 $probe=& "$audioAppRoot/bin/ffprobe.exe" -v error -show_streams -of json $out.FullName | Out-String | ConvertFrom-Json
 $audios=@($probe.streams|Where-Object codec_type -eq audio)
 Assert ($audios.Count -eq 2) 'Número de pistas incorrecto'
 Assert (@($audios|Where-Object codec_name -eq aac).Count -eq 2) 'Se convirtió o mantuvo la pista excluida'
 Assert (@($audios|Where-Object {$_.tags.language -eq 'spa'}).Count -eq 1) 'Falta la otra pista castellana'
 Assert ((Get-FileHash -LiteralPath $source).Hash -eq $hash) 'Se alteró el original'
 Assert ((Get-FileHash -LiteralPath $trackSource).Hash -eq $hash) 'Se alteró el donante'
 Reset-Todo;Assert ($script:audioTracksExcluded.Count -eq 0 -and $script:audioTrackRows.Count -eq 0) 'Reset conserva selección'
 Write-Host "AUDIO_TRACK_SELECTION_OK: GUI, web command, snapshot, real mux, excluded conversion and source intact. $fixture"
}finally{Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue}
