# Si un episodio falla DESPUÉS de ensamblar (la verificación final rechaza el MKV), el temporal
# «Ensamblaje_*.mkv» no debe quedarse junto a los originales, y los originales siguen intactos.
$ErrorActionPreference='Stop'
$appRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture=Join-Path $env:TEMP ('hdz_temporal_fallido_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
$source=Join-Path $fixture 'Serie.S01E01.mkv'
# Vídeo de 2 s y audio de 10 s: sin el audio, el MKV final dura 2 s frente a los 10 s del original.
& "$appRoot/bin/ffmpeg.exe" -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=2' -f lavfi -i 'sine=frequency=440:duration=10' -map 0:v -map 1:a -c:v libx264 -preset ultrafast -c:a aac -metadata:s:a:0 language=spa $source
if($LASTEXITCODE -ne 0){throw 'Cannot create fixture'}
$hash=(Get-FileHash -LiteralPath $source).Hash
$env:HDZ_GUI_TEST='1';$env:HDZ_HISTORY_TEST_DIR=Join-Path $fixture 'history'
function Assert($condition,$message){if(-not $condition){throw $message}}
try {
    . "$appRoot/HDZ-GUI.ps1"
    $ui.txtCarpeta.Text=$fixture;$rows=@(& $scanWorker @($source));$script:ultimoScan=$rows;$script:seleccion=@{$rows[0].Nombre=$true};Construir-Adaptacion $rows
    $ui.txtTitulo.Text='Temporal Audit';$ui.txtAno.Text='2026';$ui.swSerie.IsChecked=$true
    Set-ChipValor 'originales' 'BORRAR';Set-ChipValor 'torrent' 'NO';Set-ChipValor 'capturasProy' 0
    $ui.cfgCarpetaProcesados.Text='';$ui.cfgCarpetaTorrent.Text='';$ui.txtAnnounce.Text='';$ui.txtSalidaArchivo.Text=Join-Path $fixture 'output'
    $script:testJobsMontaje=@();Iniciar-Montaje 'unico';Assert ($script:testJobsMontaje.Count -eq 1) "No crea trabajo: $($ui.lblEstado.Text)"
    $job=$script:testJobsMontaje[0]
    # Se quita la pista de audio directamente en la configuración (la GUI ya no deja un vídeo mudo).
    $config=$job.CfgJson|ConvertFrom-Json
    $audio=$rows[0].Audios[0];$audioId=if($null -ne $audio.TrackId){$audio.TrackId}else{$audio.Index}
    $config|Add-Member -NotePropertyName PistasAudioExcluidas -NotePropertyValue @(@{Archivo=$source;Id=$audioId;Index=$audio.Index}) -Force
    [IO.File]::WriteAllText($job.CfgPath,($config|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $stdout=Join-Path $fixture 'stdout.txt'
    $p=Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-File',('"'+$job.LauncherPath+'"')) -RedirectStandardOutput $stdout -RedirectStandardError (Join-Path $fixture 'stderr.txt')
    if(-not $p.WaitForExit(90000)){$p.Kill($true);throw 'Timeout'}
    Assert ($p.ExitCode -eq 2) "Se esperaba terminar con incidencias (2) y terminó con $($p.ExitCode): $fixture"
    Assert ((Get-Content -LiteralPath $stdout -Raw) -match 'duración final difiere') "El fallo no fue el de la verificación: $fixture"
    $huerfanos=@(Get-ChildItem -LiteralPath $fixture -Recurse -Filter 'Ensamblaje_*')
    Assert ($huerfanos.Count -eq 0) "Quedan temporales: $(@($huerfanos.FullName) -join ', ')"
    Assert ((Test-Path -LiteralPath $source) -and (Get-FileHash -LiteralPath $source).Hash -eq $hash) 'El original se tocó pese al fallo'
    Write-Host "TEMPORAL_FALLIDO_OK: verificación rechazada, sin Ensamblaje_ huérfano y original intacto (con «Borrarlos»). $fixture"
} finally { Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue }
