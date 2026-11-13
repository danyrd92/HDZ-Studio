$ErrorActionPreference='Stop'
$appRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture=Join-Path $env:TEMP ('hdz_sub_tracks_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
# Tres subtítulos de texto (castellano, inglés y francés) en un MKV mínimo.
$srts=@();$srtDir=Join-Path $fixture 'srt';[void][IO.Directory]::CreateDirectory($srtDir)   # fuera de la carpeta del vídeo: si no, el motor los añade como externos
foreach($lang in 'spa','eng','fre'){
 $srt=Join-Path $srtDir "$lang.srt"
 [IO.File]::WriteAllText($srt,"1`r`n00:00:00,100 --> 00:00:01,500`r`nTexto $lang`r`n`r`n",[Text.UTF8Encoding]::new($false));$srts+=$srt
}
$source=Join-Path $fixture 'Source.mkv'
& "$appRoot/bin/ffmpeg.exe" -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=2' -f lavfi -i 'sine=frequency=440:duration=2' -i $srts[0] -i $srts[1] -i $srts[2] -map 0:v -map 1:a -map 2 -map 3 -map 4 -c:v libx264 -preset ultrafast -c:a aac -c:s srt -metadata:s:a:0 language=spa -metadata:s:s:0 language=spa -metadata:s:s:1 language=eng -metadata:s:s:2 language=fre -shortest $source
if($LASTEXITCODE -ne 0){throw 'Cannot create fixture'}
$hash=(Get-FileHash -LiteralPath $source).Hash
$env:HDZ_GUI_TEST='1';$env:HDZ_HISTORY_TEST_DIR=Join-Path $fixture 'history'
function Assert($condition,$message){if(-not $condition){throw $message}}
try {
 . "$appRoot/HDZ-GUI.ps1"
 $ui.txtCarpeta.Text=$fixture;$rows=@(& $scanWorker @($source));$script:ultimoScan=$rows;$script:seleccion=@{$rows[0].Nombre=$true};Construir-Adaptacion $rows
 Assert ($script:subTrackRows.Count -eq 3) 'No enumera cada subtítulo'
 Assert ($ui.cardSubTracks.Visibility -eq 'Visible') 'La tarjeta de subtítulos no se muestra'
 Assert ("$($ui.bdgSubTracks.Text)" -match '^3 de 3') "Contador inicial incorrecto: $($ui.bdgSubTracks.Text)"
 $eng=@($script:subTrackRows|Where-Object {$_.Etiqueta -match 'Inglés'})[0]
 Assert $eng 'No encuentra el subtítulo inglés'
 # Clic real en la casilla (mismo camino que el ratón).
 $eng.Choice.IsChecked=$false;$eng.Choice.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
 Assert ($script:subTracksExcluded.Count -eq 1) 'El clic no excluye el subtítulo'
 Assert ("$($ui.bdgSubTracks.Text)" -match '^2 de 3') "Contador tras desmarcar: $($ui.bdgSubTracks.Text)"
 # La web vuelve a marcarlo y lo desmarca otra vez.
 Aplicar-ComandoAgente ([pscustomobject]@{type='set_sub_track';archivo=$eng.Archivo;id=$eng.Id;value=$true;session=$script:agSession;projectTab=$script:tabProyActual})
 Assert ($eng.Choice.IsChecked -and $script:subTracksExcluded.Count -eq 0) 'Orden remota no marca el subtítulo'
 Aplicar-ComandoAgente ([pscustomobject]@{type='set_sub_track';archivo=$eng.Archivo;id=$eng.Id;value=$false;session=$script:agSession;projectTab=$script:tabProyActual})
 Assert (-not $eng.Choice.IsChecked) 'Orden remota no desmarca el subtítulo'
 Assert (@($script:subTrackRows|Where-Object {$_.Choice.IsChecked}).Count -eq 2) 'Se desmarcó otro subtítulo'
 # Pestañas: se reconstruye la tarjeta y se restaura la selección.
 $snapshot=Snapshot-DecisionesTab;Construir-Adaptacion $rows;Restore-DecisionesTab $snapshot
 Assert (-not @($script:subTrackRows|Where-Object Key -eq $eng.Key)[0].Choice.IsChecked) 'Pierde la selección al reconstruir'
 Assert (@($script:subTrackRows|Where-Object {$_.Choice.IsChecked}).Count -eq 2) 'Restaurar marca o desmarca de más'
 $state=Componer-EstadoAgente|ConvertFrom-Json
 Assert ($state.subTracksSupported -and @($state.subTracks).Count -eq 3 -and @($state.subTracks|Where-Object {-not $_.sel}).Count -eq 1) 'Estado remoto incorrecto'
 # Montaje real: el inglés no debe llegar al MKV final.
 $ui.txtTitulo.Text='Sub Tracks Audit';$ui.txtAno.Text='2026';$ui.swSerie.IsChecked=$false
 Set-ChipValor 'originales' 'INTACTO';Set-ChipValor 'torrent' 'NO';Set-ChipValor 'capturasProy' 0
 $ui.cfgCarpetaProcesados.Text='';$ui.cfgCarpetaTorrent.Text='';$ui.txtAnnounce.Text='';$ui.txtSalidaArchivo.Text=Join-Path $fixture 'output'
 $script:testJobsMontaje=@();Iniciar-Montaje 'unico';Assert ($script:testJobsMontaje.Count -eq 1) 'No crea trabajo'
 $job=$script:testJobsMontaje[0];$config=$job.CfgJson|ConvertFrom-Json
 Assert (@($config.PistasSubsExcluidas).Count -eq 1 -and "$(@($config.PistasSubsExcluidas)[0].Id)" -eq "$($eng.Id)") 'No envía la exclusión exacta al motor'
 $p=Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-File',('"'+$job.LauncherPath+'"')) -RedirectStandardOutput (Join-Path $fixture 'stdout.txt') -RedirectStandardError (Join-Path $fixture 'stderr.txt')
 if(-not $p.WaitForExit(90000)){$p.Kill($true);throw 'Timeout'}
 Assert ($p.ExitCode -eq 0) "Motor falló ($($p.ExitCode)): $fixture"
 $out=@(Get-ChildItem -LiteralPath (Join-Path $fixture 'output') -Filter '*.mkv')[0]
 Assert $out "No hay MKV de salida: $fixture"
 $probe=& "$appRoot/bin/ffprobe.exe" -v error -show_streams -of json $out.FullName | Out-String | ConvertFrom-Json
 $subs=@($probe.streams|Where-Object codec_type -eq subtitle)
 Assert ($subs.Count -eq 2) "Número de subtítulos incorrecto: $($subs.Count)"
 Assert (-not @($subs|Where-Object {$_.tags.language -eq 'eng'})) 'El subtítulo excluido llegó al resultado'
 Assert (@($subs|Where-Object {$_.tags.language -eq 'spa'}).Count -eq 1 -and @($subs|Where-Object {$_.tags.language -eq 'fre'}).Count -eq 1) 'Falta un subtítulo que debía quedarse'
 Assert ((Get-FileHash -LiteralPath $source).Hash -eq $hash) 'Se alteró el original'
 Reset-Todo;Assert ($script:subTracksExcluded.Count -eq 0 -and $script:subTrackRows.Count -eq 0) 'Reset conserva la selección'
 Write-Host "SUB_TRACK_SELECTION_OK: GUI, contador, web, pestañas, montaje real y original intacto. $fixture"
}finally{Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue}
