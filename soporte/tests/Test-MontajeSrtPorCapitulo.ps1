# Serie con SRT sueltos por capítulo ("Show.S01E02.es.srt"): cada capítulo montado debe llevar
# SOLO sus propios subtítulos. Antes cada capítulo recibía los SRT de todos y la deduplicación se
# quedaba con los del primero (Hannah Montana S02: E02 salía con los subs de E01).
param([string]$AppRoot)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if($AppRoot){$root=[IO.Path]::GetFullPath($AppRoot)}
$srtAppRoot=$root
$testRoot=Join-Path $env:TEMP ('hdz_test_srtcap_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$eps=@('01','02','03')
foreach($e in $eps){
    $mkv=Join-Path $testRoot "Show.S01E$e.mkv"
    & (Join-Path $root 'bin/ffmpeg.exe') -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=2' -f lavfi -i 'sine=frequency=440:duration=2' -map 0:v -map 1:a -c:v libx264 -preset ultrafast -c:a aac -metadata:s:a:0 language=eng -shortest $mkv
    if($LASTEXITCODE -ne 0){throw 'No se pudo crear el vídeo de prueba'}
    [IO.File]::WriteAllText((Join-Path $testRoot "Show.S01E$e.es.srt"),"1`r`n00:00:00,100 --> 00:00:01,500`r`nCAPITULO ESPANOL $e`r`n",[Text.UTF8Encoding]::new($false))
    # Uno con muchos sonidos (lo marca SDH por contenido) para reproducir la pista "para sordos" que aparecía.
    $sdh=if($e -eq '03'){"1`r`n00:00:00,100 --> 00:00:00,500`r`n[MUSICA]`r`n`r`n2`r`n00:00:00,600 --> 00:00:01,000`r`n[RISAS]`r`n`r`n3`r`n00:00:01,100 --> 00:00:01,500`r`nENGLISH $e`r`n"}else{"1`r`n00:00:00,100 --> 00:00:01,500`r`nENGLISH $e`r`n"}
    [IO.File]::WriteAllText((Join-Path $testRoot "Show.S01E$e.en.cc.srt"),$sdh,[Text.UTF8Encoding]::new($false))
}
$env:HDZ_GUI_TEST='1'; $env:HDZ_GUI_TEST_DIR=$testRoot
$env:HDZ_HISTORY_TEST_DIR=Join-Path $testRoot 'history'
try {
    . (Join-Path $root 'HDZ-GUI.ps1')
    $ui.txtTitulo.Text='Synthetic Srt'; $ui.txtAno.Text='2026'; $ui.swSerie.IsChecked=$true
    Set-ChipValor 'originales' 'INTACTO'; Set-ChipValor 'torrent' 'NO'; Set-ChipValor 'capturasProy' 'NO'
    $ui.cfgCarpetaProcesados.Text=''; $ui.cfgCarpetaTorrent.Text=''; $ui.txtAnnounce.Text=''
    $ui.txtSalidaArchivo.Text=Join-Path $testRoot 'output'
    Set-ComboValor $ui.cmbNumCapturas 0
    $script:testJobsMontaje=@()
    Iniciar-Montaje 'unico'
    if($script:testJobsMontaje.Count -ne 1){throw "La GUI no creó el trabajo: $($ui.lblEstado.Text)"}
    $job=$script:testJobsMontaje[0]
    $config=$job.CfgJson|ConvertFrom-Json
    $config | Add-Member -NotePropertyName NumCapturas -NotePropertyValue 0 -Force
    $config | Add-Member -NotePropertyName ModoTorrent -NotePropertyValue 'NO' -Force
    $config | Add-Member -NotePropertyName CarpetaProcesados -NotePropertyValue '' -Force
    $config | Add-Member -NotePropertyName AccionOriginales -NotePropertyValue 'INTACTO' -Force
    $config | Add-Member -NotePropertyName TorrentAnnounce -NotePropertyValue '' -Force
    [IO.File]::WriteAllText($job.CfgPath,($config|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $stdout=Join-Path $testRoot 'engine-stdout.txt'; $stderr=Join-Path $testRoot 'engine-stderr.txt'
    $process=Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$job.LauncherPath+'"')) -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if(-not $process.WaitForExit(180000)){$process.Kill($true);throw "El montaje de prueba no terminó: $testRoot"}
    if($process.ExitCode -notin 0,2){throw "Montaje de prueba falló ($($process.ExitCode)). Diagnóstico: $testRoot"}
    $outputs=@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'output') -Recurse -File -Filter '*.mkv')
    if($outputs.Count -ne 3){throw "Esperados 3 MKV, hay $($outputs.Count): $testRoot"}
    foreach($e in $eps){
        $out=@($outputs | Where-Object { $_.Name -match "S01E$e" })
        if($out.Count -ne 1){throw "No hay salida única para E$e"}
        $info=& (Join-Path $srtAppRoot 'bin/mkvmerge.exe') -J $out[0].FullName | Out-String | ConvertFrom-Json
        $subs=@($info.tracks | Where-Object { $_.type -eq 'subtitles' })
        if($subs.Count -ne 2){throw "E${e}: esperados 2 subs (es+en), hay $($subs.Count): $(($subs|ForEach-Object{$_.properties.track_name}) -join ' | ')"}
        foreach($s in $subs){
            $tmp=Join-Path $testRoot "x_E${e}_$($s.id).srt"
            & (Join-Path $srtAppRoot 'bin/mkvextract.exe') $out[0].FullName tracks "$($s.id):$tmp" | Out-Null
            $txt=[IO.File]::ReadAllText($tmp)
            if($txt -notmatch " $e\b"){throw "E${e}: la pista '$($s.properties.track_name)' trae subs de otro capítulo: $txt"}
        }
    }
    Write-Host "MONTAJE_SRT_POR_CAPITULO_OK — cada capítulo lleva solo sus SRT. Prueba: $testRoot"
} finally {
    Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_GUI_TEST_DIR,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue
}
