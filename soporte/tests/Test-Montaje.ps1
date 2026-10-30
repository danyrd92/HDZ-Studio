# Recorrido GUI -> configuración -> motor -> MKV validado, con fuentes sintéticas.
param([string]$AppRoot,[switch]$CaptureFailure,[ValidateSet('INDIVIDUAL','PACK','AMBOS')][string]$TorrentMode='INDIVIDUAL',[ValidateSet('Tiny','480i','576i')][string]$VideoFormat='Tiny')
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if($AppRoot){$root=[IO.Path]::GetFullPath($AppRoot)}
$montageAppRoot=$root
$testRoot=Join-Path $env:TEMP ('hdz_test_montaje_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$source=Join-Path $testRoot 'Synthetic.S01E01.mkv'
$size=if($VideoFormat -eq '480i'){'720x480'}elseif($VideoFormat -eq '576i'){'720x576'}else{'160x90'}
$encoder=if($VideoFormat -eq 'Tiny'){@('-c:v','libx264','-preset','ultrafast')}else{@('-c:v','mpeg2video','-flags','+ilme+ildct','-top','1')}
& (Join-Path $root 'bin/ffmpeg.exe') -v error -f lavfi -i "color=c=blue:s=${size}:r=24:d=2" -f lavfi -i 'sine=frequency=440:duration=2' -map 0:v -map 1:a @encoder -c:a aac -metadata:s:a:0 language=tha -shortest $source
if($LASTEXITCODE -ne 0){throw 'No se pudo crear el vídeo de prueba'}
$sourceHash=(Get-FileHash -LiteralPath $source).Hash
$env:HDZ_GUI_TEST='1'; $env:HDZ_GUI_TEST_DIR=$testRoot
$env:HDZ_HISTORY_TEST_DIR=Join-Path $testRoot 'history'
try {
    . (Join-Path $root 'HDZ-GUI.ps1')
    $ui.txtTitulo.Text='Synthetic Audit'; $ui.txtAno.Text='2026'; $ui.swSerie.IsChecked=$true
    Set-ChipValor 'originales' 'INTACTO'; Set-ChipValor 'torrent' 'NO'; Set-ChipValor 'capturasProy' 'NO'
    $ui.cfgCarpetaProcesados.Text=''; $ui.cfgCarpetaTorrent.Text=''; $ui.txtAnnounce.Text=''
    $ui.txtSalidaArchivo.Text=Join-Path $testRoot 'output'
    Set-ComboValor $ui.cmbNumCapturas 0
    $script:testJobsMontaje=@()
    Iniciar-Montaje 'unico'
    if($script:testJobsMontaje.Count -ne 1){throw "La GUI no creó el trabajo: $($ui.lblEstado.Text)"}
    $job=$script:testJobsMontaje[0]
    # Contrato conservador para esta prueba; no crear capturas ni torrents.
    $config=$job.CfgJson|ConvertFrom-Json
    $config | Add-Member -NotePropertyName NumCapturas -NotePropertyValue 0 -Force
    $config | Add-Member -NotePropertyName ModoTorrent -NotePropertyValue 'NO' -Force
    $config | Add-Member -NotePropertyName CarpetaProcesados -NotePropertyValue '' -Force
    $config | Add-Member -NotePropertyName AccionOriginales -NotePropertyValue 'INTACTO' -Force
    $config | Add-Member -NotePropertyName TorrentAnnounce -NotePropertyValue '' -Force
    if($CaptureFailure){
        # Un archivo donde se necesita una carpeta reproduce CreateDirectory fallido,
        # sin depender de unidades de red ni modificar rutas reales del usuario.
        $blocked=Join-Path $testRoot 'blocked-captures'
        [IO.File]::WriteAllText($blocked,'fixture: not a directory')
        $config.NumCapturas=1;$config.ModoTorrent=$TorrentMode
        $config.CarpetaProcesados=$blocked
        $config.TorrentAnnounce='https://tracker.invalid/announce'
        $config | Add-Member -NotePropertyName CarpetaTorrent -NotePropertyValue (Join-Path $testRoot 'torrents') -Force
    }
    [IO.File]::WriteAllText($job.CfgPath,($config|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $stdout=Join-Path $testRoot 'engine-stdout.txt'; $stderr=Join-Path $testRoot 'engine-stderr.txt'
    $process=Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$job.LauncherPath+'"')) -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if(-not $process.WaitForExit(60000)){$process.Kill($true);throw "El montaje de prueba no terminó en un minuto: $testRoot"}
    $expectedExit=if($CaptureFailure){2}else{0}
    if($process.ExitCode -ne $expectedExit){throw "Montaje de prueba falló ($($process.ExitCode), esperado $expectedExit). Diagnóstico: $testRoot"}
    $outputs=@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'output') -Recurse -File -Filter '*.mkv')
    if($outputs.Count -ne 1){throw 'No quedó un único MKV en el destino solicitado'}
    Assert-HdzMux $outputs[0].FullName 1 0 $source
    $expectedResolution=if($VideoFormat -eq 'Tiny'){'90p'}else{$VideoFormat}
    if($outputs[0].Name -notmatch "\b$expectedResolution\b"){throw "Nombre con resolución errónea: $($outputs[0].Name)"}
    $sourceVideo=(& (Join-Path $montageAppRoot 'bin/ffprobe.exe') -v error -select_streams v:0 -show_entries stream=width,height,field_order -of json $source | Out-String | ConvertFrom-Json).streams[0]
    $finalVideo=(& (Join-Path $montageAppRoot 'bin/ffprobe.exe') -v error -select_streams v:0 -show_entries stream=width,height,field_order -of json $outputs[0].FullName | Out-String | ConvertFrom-Json).streams[0]
    if($sourceVideo.width -ne $finalVideo.width -or $sourceVideo.height -ne $finalVideo.height -or (Get-HdzVideoResolution $sourceVideo) -ne (Get-HdzVideoResolution $finalVideo)){throw 'El montaje cambió dimensiones o entrelazado'}
    # ffprobe puede normalizar tb -> tt al pasar de Matroska/FFmpeg a mkvmerge.
    # La prueba fuerte es conservar los paquetes de vídeo codificados, no ese flag de contenedor.
    $sourceVideoHash=& (Join-Path $montageAppRoot 'bin/ffmpeg.exe') -v error -i $source -map 0:v:0 -c copy -f hash -hash sha256 -
    if($LASTEXITCODE -ne 0){throw 'No se pudo verificar el vídeo de entrada'}
    $finalVideoHash=& (Join-Path $montageAppRoot 'bin/ffmpeg.exe') -v error -i $outputs[0].FullName -map 0:v:0 -c copy -f hash -hash sha256 -
    if($LASTEXITCODE -ne 0 -or $sourceVideoHash -ne $finalVideoHash){throw 'Cambió el contenido de vídeo codificado'}
    if((Get-FileHash -LiteralPath $source).Hash -ne $sourceHash){throw 'Cambió el archivo original'}
    if($CaptureFailure){
        $torrents=@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'torrents') -Recurse -File -Filter '*.torrent')
        $expectedCount=if($TorrentMode -eq 'AMBOS'){2}else{1}
        if($torrents.Count -ne $expectedCount){throw "Faltan torrents tras el fallo de capturas: $testRoot"}
        $transcript=Get-Content -LiteralPath $stdout -Raw
        if($transcript -notmatch 'No se pudieron generar las capturas' -or $transcript -match 'EXCEPCIÓN procesando el grupo'){throw 'El fallo de capturas no quedó aislado'}
        $records=@(Get-ChildItem -LiteralPath $env:HDZ_HISTORY_TEST_DIR -File -Filter '*.json' | ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json})
        if(-not @($records|Where-Object {$_.status -eq 'Con incidencias' -and @($_.captures).Count -eq 0}).Count){throw 'El historial no conserva el aviso de capturas pendientes'}
        if(-not @($records|Where-Object {$_.torrent -and @($_.captures).Count -eq 0}).Count){throw 'El historial no conserva el torrent sin capturas'}
        Write-Host "CAPTURE_FAILURE_TORRENT_OK: $TorrentMode, MKV válido, torrent creado, aviso conservado y original intacto. $testRoot"
    }
    Write-Host "MONTAJE_END_TO_END_OK — GUI, motor, audio tailandés, carpeta final y originales intactos. Prueba: $testRoot"
} finally {
    Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_GUI_TEST_DIR,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue
}
