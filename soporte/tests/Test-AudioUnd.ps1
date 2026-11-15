# Quitar las pistas de audio sin idioma ('und') con el chip «Sin idioma (und)» del filtro de idiomas:
# la GUI no lo envía en IdiomasAudioMantener, el motor quita la pista y no anota ninguna incidencia.
$ErrorActionPreference='Stop'
$undAppRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture=Join-Path $env:TEMP ('hdz_audio_und_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
$source=Join-Path $fixture 'Serie.S01E01.mkv'
& "$undAppRoot/bin/ffmpeg.exe" -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=2' -f lavfi -i 'sine=frequency=440:duration=2' -map 0:v -map 1:a -map 1:a -c:v libx264 -preset ultrafast -c:a aac -metadata:s:a:0 language=spa -metadata:s:a:1 language=und -shortest $source
if($LASTEXITCODE -ne 0){throw 'Cannot create fixture'}
$hash=(Get-FileHash -LiteralPath $source).Hash
$env:HDZ_GUI_TEST='1';$env:HDZ_HISTORY_TEST_DIR=Join-Path $fixture 'history'
function Assert($condition,$message){if(-not $condition){throw $message}}
try {
 . "$undAppRoot/HDZ-GUI.ps1"
 $ui.txtCarpeta.Text=$fixture;$rows=@(& $scanWorker @($source));$script:ultimoScan=$rows;$script:seleccion=@{$rows[0].Nombre=$true};Construir-Adaptacion $rows
 $chipUnd=@($script:chipsIdiomasAudio|Where-Object {"$($_.Tag)" -eq 'und'})[0]
 Assert $chipUnd 'No hay chip para el audio sin idioma'
 Assert ("$($chipUnd.Content)" -match '^Sin idioma \(und\)') "Etiqueta del chip: $($chipUnd.Content)"
 $chipUnd.IsChecked=$false;$script:idiomasAudioSeleccionUsuario=$true
 $ui.txtTitulo.Text='Audio Und Audit';$ui.txtAno.Text='2026';$ui.swSerie.IsChecked=$true
 Set-ChipValor 'originales' 'INTACTO';Set-ChipValor 'torrent' 'NO';Set-ChipValor 'capturasProy' 0
 $ui.cfgCarpetaProcesados.Text='';$ui.cfgCarpetaTorrent.Text='';$ui.txtAnnounce.Text='';$ui.txtSalidaArchivo.Text=Join-Path $fixture 'output'
 $script:testJobsMontaje=@();Iniciar-Montaje 'unico';Assert ($script:testJobsMontaje.Count -eq 1) "No crea trabajo: $($ui.lblEstado.Text)"
 $job=$script:testJobsMontaje[0];$config=$job.CfgJson|ConvertFrom-Json
 Assert (@($config.IdiomasAudioMantener).Count -eq 1 -and @($config.IdiomasAudioMantener) -notcontains 'und') "IdiomasAudioMantener: $(@($config.IdiomasAudioMantener) -join ',')"
 $stdout=Join-Path $fixture 'stdout.txt'
 $p=Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-File',('"'+$job.LauncherPath+'"')) -RedirectStandardOutput $stdout -RedirectStandardError (Join-Path $fixture 'stderr.txt')
 if(-not $p.WaitForExit(60000)){$p.Kill($true);throw 'Timeout'}
 # 0 = sin incidencias: la pista 'und' quitada no debe avisar.
 Assert ($p.ExitCode -eq 0) "Motor terminó con $($p.ExitCode) (2 = incidencias): $fixture"
 Assert ((Get-Content -LiteralPath $stdout -Raw) -notmatch "Audio 'und' sin idioma") "Anotó la incidencia del audio quitado: $fixture"
 $out=@(Get-ChildItem -LiteralPath (Join-Path $fixture 'output') -Recurse -Filter '*.mkv')[0]
 $probe=& "$undAppRoot/bin/ffprobe.exe" -v error -show_streams -of json $out.FullName | Out-String | ConvertFrom-Json
 $audios=@($probe.streams|Where-Object codec_type -eq audio)
 Assert ($audios.Count -eq 1 -and $audios[0].tags.language -eq 'spa') "Audios finales: $(@($audios|ForEach-Object {$_.tags.language}) -join ',')"
 Assert ((Get-FileHash -LiteralPath $source).Hash -eq $hash) 'Se alteró el original'
 Write-Host "AUDIO_UND_OK: chip «Sin idioma», filtro enviado, pista quitada sin incidencia y original intacto. $fixture"
}finally{Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue}
