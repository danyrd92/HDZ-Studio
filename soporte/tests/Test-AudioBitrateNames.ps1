# Bitrate por pista en los nombres finales; medios sintéticos, originales intactos.
$ErrorActionPreference='Stop'
$bitrateAppRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $bitrateAppRoot 'HDZ-Core.ps1')
function Assert($ok,$message){if(-not $ok){throw $message}}
$bitrateCases=@(
    @(@{BitRate='768000'},'768 kb/s'), @(@{BitRate=640000},'640 kb/s'),
    @(@{BitRate='1 536 000'},'1536 kb/s'), @(@{BitRate='1509750'},'1510 kb/s'),
    @(@{BitRate='320500'},'321 kb/s'), @(@{BitRate='128499'},'128 kb/s'),
    @(@{BitRate='2112000';BitRate_Maximum='6000000'},'2112 kb/s'),
    @(@{StreamSize='2000000';Duration='10'},'1600 kb/s'),
    @(@{BitRate='Unknown / 1509750';StreamSize='2000000';Duration='10'},'1600 kb/s'),
    @(@{BitRate='0';StreamSize='102400';Duration='3.2'},'256 kb/s'),
    @(@{BitRate='NaN';StreamSize='100000';Duration='5'},'160 kb/s'),
    @(@{BitRate='Infinity'},'bitrate no disponible'),
    @(@{BitRate_Nominal='768000';BitRate_Maximum='1500000'},'bitrate no disponible'),
    @(@{StreamSize='1000000';Duration='0'},'bitrate no disponible'),
    @(@{BitRate='-100'},'bitrate no disponible'), @($null,'bitrate no disponible')
)
foreach($case in $bitrateCases){Assert ((Get-HdzAudioBitrateLabel $case[0]) -eq $case[1]) "Bitrate incorrecto: $($case[0]|ConvertTo-Json -Compress)"}
Assert ((Add-HdzAudioBitrateToName 'Castellano DD+ 5.1 Atmos' @{BitRate=768000}) -eq 'Castellano DD+ 5.1 Atmos @ 768 kb/s') 'Pierde idioma, formato o Atmos'
Assert ((Add-HdzAudioBitrateToName 'Inglés AAC 2.0 @ 999 kb/s' @{BitRate=128000}) -eq 'Inglés AAC 2.0 @ 128 kb/s') 'Duplica un bitrate anterior'
Assert ((Add-HdzAudioBitrateToName 'Francés FLAC 2.0 @ bitrate no disponible' @{BitRate=500000}) -eq 'Francés FLAC 2.0 @ 500 kb/s') 'No reemplaza el marcador sin datos'
$bitrateTestRoot=Join-Path $env:TEMP ('hdz_bitrate_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($bitrateTestRoot)
$bitrateSource=Join-Path $bitrateTestRoot 'Source.mkv'
$bitrateExternal=Join-Path $bitrateTestRoot 'bonus_eng.eac3'
& "$bitrateAppRoot/bin/ffmpeg.exe" -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=3' -f lavfi -i 'sine=frequency=440:duration=3' -map 0:v -map 1:a -map 1:a -map 1:a -c:v libx264 -preset ultrafast -c:a:0 ac3 -b:a:0 192k -ac:a:0 2 -c:a:1 aac -b:a:1 64k -c:a:2 flac -metadata:s:a:0 language=spa -metadata:s:a:0 title='Castellano viejo @ 999 kb/s' -metadata:s:a:1 language=eng -metadata:s:a:2 language=fra -shortest $bitrateSource
Assert ($LASTEXITCODE -eq 0) 'No se pudo crear el fixture de audios'
& "$bitrateAppRoot/bin/ffmpeg.exe" -v error -f lavfi -i 'sine=frequency=880:duration=3' -c:a eac3 -b:a 160k $bitrateExternal
Assert ($LASTEXITCODE -eq 0) 'No se pudo crear el audio externo'
$bitrateSourceHash=(Get-FileHash -LiteralPath $bitrateSource).Hash
$bitrateExternalHash=(Get-FileHash -LiteralPath $bitrateExternal).Hash
$env:HDZ_GUI_TEST='1';$env:HDZ_HISTORY_TEST_DIR=Join-Path $bitrateTestRoot 'history'
try {
    . "$bitrateAppRoot/HDZ-GUI.ps1"
    $ui.txtCarpeta.Text=$bitrateTestRoot
    $bitrateScan=@(& $scanWorker @($bitrateSource));$script:ultimoScan=$bitrateScan
    $script:seleccion=@{$bitrateScan[0].Nombre=$true};Construir-Adaptacion $bitrateScan
    $ui.txtTitulo.Text='Bitrate Audit';$ui.txtAno.Text='2026';$ui.swSerie.IsChecked=$false
    Set-ChipValor 'originales' 'INTACTO';Set-ChipValor 'torrent' 'NO';Set-ChipValor 'capturasProy' 0
    $ui.cfgCarpetaProcesados.Text='';$ui.cfgCarpetaTorrent.Text='';$ui.txtAnnounce.Text=''
    $ui.txtSalidaArchivo.Text=Join-Path $bitrateTestRoot 'output'
    $script:testJobsMontaje=@();Iniciar-Montaje 'unico'
    Assert ($script:testJobsMontaje.Count -eq 1) 'No se creó el trabajo de prueba'
    $bitrateJob=$script:testJobsMontaje[0];$bitrateConfig=$bitrateJob.CfgJson|ConvertFrom-Json
    $bitrateConfig|Add-Member -Force -NotePropertyName ConversionesAudioManual -NotePropertyValue @(@{Index=2;CodecDestino='eac3';CanalesDestino=1;BitrateK=96;Lang='eng';MantenerOriginal=$true;FuenteExacta=$true;ArchivoFuente=$bitrateSource})
    [IO.File]::WriteAllText($bitrateJob.CfgPath,($bitrateConfig|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $bitrateProcess=Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-File',('"'+$bitrateJob.LauncherPath+'"')) -RedirectStandardOutput (Join-Path $bitrateTestRoot 'stdout.txt') -RedirectStandardError (Join-Path $bitrateTestRoot 'stderr.txt')
    if(-not $bitrateProcess.WaitForExit(60000)){$bitrateProcess.Kill($true);throw "Timeout: $bitrateTestRoot"}
    Assert ($bitrateProcess.ExitCode -eq 0) "Falló el montaje: $bitrateTestRoot"
    $bitrateOutput=@(Get-ChildItem -LiteralPath (Join-Path $bitrateTestRoot 'output') -Filter '*.mkv')[0]
    Assert ($null -ne $bitrateOutput) 'No se produjo el MKV final'
    $bitrateProbe=& "$bitrateAppRoot/bin/ffprobe.exe" -v error -show_streams -of json $bitrateOutput.FullName | Out-String | ConvertFrom-Json
    $bitrateAudios=@($bitrateProbe.streams|Where-Object codec_type -eq audio)
    Assert ($bitrateAudios.Count -eq 5) 'Se perdieron pistas internas, externas o convertidas'
    foreach($audio in $bitrateAudios){
        Assert ($audio.tags.title -match ' @ \d+ kb/s$') "Pista sin bitrate: $($audio.tags.title)"
        Assert (([regex]::Matches($audio.tags.title,' @ ')).Count -eq 1) 'Bitrate duplicado'
    }
    Assert (@($bitrateAudios|Where-Object {$_.codec_name -eq 'ac3' -and $_.tags.language -eq 'spa' -and $_.tags.title -eq 'Castellano DD 2.0 @ 192 kb/s'}).Count -eq 1) 'Bitrate CBR interno incorrecto'
    Assert (@($bitrateAudios|Where-Object {$_.codec_name -eq 'eac3' -and $_.tags.title -match '^Inglés DD\+ 1.0 @ 160 kb/s$'}).Count -eq 1) 'Bitrate del audio externo incorrecto'
    Assert (@($bitrateAudios|Where-Object {$_.codec_name -eq 'eac3' -and $_.tags.title -match '^Inglés DD\+ 1.0 @ 96 kb/s$'}).Count -eq 1) 'Usa el bitrate original en lugar del convertido'
    foreach($audio in @($bitrateAudios|Where-Object {$_.codec_name -in @('aac','flac')})){
        $packets=& "$bitrateAppRoot/bin/ffprobe.exe" -v error -select_streams ([string]$audio.index) -show_packets -show_entries packet=size,duration_time -of json $bitrateOutput.FullName | Out-String | ConvertFrom-Json
        $bytes=0.0;$seconds=0.0
        foreach($packet in $packets.packets){$bytes+=[double]$packet.size;$seconds+=[double]::Parse($packet.duration_time,[Globalization.CultureInfo]::InvariantCulture)}
        $average=$bytes*8/$seconds/1000
        $displayed=[int]([regex]::Match($audio.tags.title,'@ (\d+) kb/s$').Groups[1].Value)
        Assert ([Math]::Abs($displayed-$average) -le [Math]::Max(2,$average*0.04)) "Promedio VBR/sin pérdida incorrecto: $displayed vs $average"
        Assert ($audio.tags.title -match $(if($audio.codec_name -eq 'flac'){'^Francés FLAC'}else{'^Inglés AAC'})) 'Cambió el idioma o el códec'
    }
    Assert ((Get-FileHash -LiteralPath $bitrateSource).Hash -eq $bitrateSourceHash) 'Se modificó el original'
    Assert ((Get-FileHash -LiteralPath $bitrateExternal).Hash -eq $bitrateExternalHash) 'Se modificó el audio externo'
    # El cambio es solo de etiquetas: se conservan los paquetes de cada audio original.
    $bitrateOriginalProbe=& "$bitrateAppRoot/bin/ffprobe.exe" -v error -show_streams -of json $bitrateSource | Out-String | ConvertFrom-Json
    foreach($audio in @($bitrateOriginalProbe.streams|Where-Object codec_type -eq audio)){
        $target=@($bitrateAudios|Where-Object {$_.codec_name -eq $audio.codec_name -and (Convert-HdzLanguage $_.tags.language) -eq (Convert-HdzLanguage $audio.tags.language)})[0]
        Assert ($null -ne $target) 'No se puede identificar la pista original en el resultado'
        $sourcePacketsHash=& "$bitrateAppRoot/bin/ffmpeg.exe" -v error -i $bitrateSource -map "0:$($audio.index)" -c copy -f hash -hash sha256 -
        $targetPacketsHash=& "$bitrateAppRoot/bin/ffmpeg.exe" -v error -i $bitrateOutput.FullName -map "0:$($target.index)" -c copy -f hash -hash sha256 -
        Assert ($LASTEXITCODE -eq 0 -and $sourcePacketsHash -eq $targetPacketsHash) 'Se recodificó un audio que debía conservarse'
    }
    Write-Host "AUDIO_BITRATE_NAMES_OK: $($bitrateCases.Count) casos, CBR, VBR, FLAC, externo, convertido y paquetes originales idénticos. $bitrateTestRoot"
    $bitrateAudios|ForEach-Object {Write-Host $_.tags.title}
}finally{Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue}
