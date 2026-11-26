# Tipo e idioma de cada subtítulo: detectados al analizar (también si es el único de su idioma y si es
# un .srt suelto), corregibles uno a uno o todos a la vez (GUI y web), y respetados por el motor.
param([string]$AppRoot)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if($AppRoot){$root=[IO.Path]::GetFullPath($AppRoot)}
$tiposAppRoot=$root
function Assert($ok,$msg){if(-not $ok){throw $msg}}
function New-Srt([string[]]$lineas){
    $sb=[Text.StringBuilder]::new()
    for($i=0;$i -lt $lineas.Count;$i++){
        $ini=[TimeSpan]::FromMilliseconds(100+$i*1400);$fin=$ini.Add([TimeSpan]::FromMilliseconds(1200))
        [void]$sb.Append("$($i+1)`r`n$($ini.ToString('hh\:mm\:ss\,fff')) --> $($fin.ToString('hh\:mm\:ss\,fff'))`r`n$($lineas[$i])`r`n`r`n")
    }
    $sb.ToString()
}
$latino=@('¿Ustedes ya vieron mi celular?','[APLAUSOS]','Qué lindo está el carro.','[RISAS]','Ahorita voy, no estés enojado.','¿Ustedes quieren jugo?','[MÚSICA ALEGRE]','Está muy lindo, la verdad.','Vamos a manejar hasta allá.','[PUERTA SE CIERRA]')
$cast=@('¿Vosotros venís a la fiesta?','Habéis visto mi móvil, tío.','Vale, os lo digo luego.','¿Dónde estáis ahora?','Tenéis que venir, de verdad.','Os quiero mucho a los dos.','Vuestro coche es genial.','¿Sabéis qué hora es?','Vale, vale, ya voy.','No podéis entrar aquí.')
$ingles=@('Where is my phone?','I hate flag football.','You want to know why?','Because you stink.','That is a good save.','We are late again.','Come on, let us go.','I will call you later.','This is not fair.','See you tomorrow.')
$testRoot=Join-Path $env:TEMP ('hdz_test_subtipos_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$utf8=[Text.UTF8Encoding]::new($false)
foreach($e in '01','02'){
    $mkv=Join-Path $testRoot "Show.S01E$e.mkv"
    $ffArgs=@('-v','error','-f','lavfi','-i','color=c=blue:s=160x90:r=24:d=60','-f','lavfi','-i','sine=frequency=440:duration=60')
    if($e -eq '01'){
        # Sub interno en castellano peninsular sin título: el texto decide «Castellano».
        $srtInt=Join-Path $testRoot 'interno.tmp.srt';[IO.File]::WriteAllText($srtInt,(New-Srt ($cast*4)),$utf8)
        $ffArgs+=@('-i',$srtInt,'-map','0:v','-map','1:a','-map','2:s','-c:s','srt','-metadata:s:s:0','language=spa')
    } else { $ffArgs+=@('-map','0:v','-map','1:a') }
    $ffArgs+=@('-c:v','libx264','-preset','ultrafast','-c:a','aac','-metadata:s:a:0','language=eng','-shortest',$mkv)
    & (Join-Path $tiposAppRoot 'bin/ffmpeg.exe') @ffArgs
    Assert ($LASTEXITCODE -eq 0) 'No se pudo crear el vídeo de prueba'
    [IO.File]::WriteAllText((Join-Path $testRoot "Show.S01E$e.es.srt"),(New-Srt ($latino*4)),$utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot "Show.S01E$e.en.srt"),(New-Srt ($ingles*4)),$utf8)
}
Remove-Item -LiteralPath (Join-Path $testRoot 'interno.tmp.srt') -Force
$env:HDZ_GUI_TEST='1'; $env:HDZ_GUI_TEST_DIR=$testRoot
$env:HDZ_HISTORY_TEST_DIR=Join-Path $testRoot 'history'
try {
    . (Join-Path $tiposAppRoot 'HDZ-GUI.ps1')
    $ui.txtCarpeta.Text=$testRoot
    $videos=@(Get-ChildItem -LiteralPath $testRoot -Filter '*.mkv' | Sort-Object Name | ForEach-Object FullName)
    $rows=@(& $scanWorker $videos (Join-Path $tiposAppRoot 'HDZ-Core.ps1'))
    $script:ultimoScan=$rows;$script:seleccion=@{};foreach($r in $rows){$script:seleccion[$r.Nombre]=$true}
    Construir-Adaptacion $rows
    # --- Detección al analizar ---
    $e1=$rows[0];$e2=$rows[1]
    $esExt=@($e1.Subs|Where-Object{$_.Externo -and $_.Nombre -like '*.es.srt'})[0]
    $enExt=@($e1.Subs|Where-Object{$_.Externo -and $_.Nombre -like '*.en.srt'})[0]
    $int=@($e1.Subs|Where-Object{-not $_.Externo})[0]
    Assert (@($e1.Subs|Where-Object Externo).Count -eq 2) "E01 debe ver solo sus 2 .srt: $(@($e1.Subs|Where-Object Externo|ForEach-Object Nombre) -join ', ')"
    Assert ($esExt.TipoAuto -eq 'SDH' -and $esExt.TipoFuente -eq 'contenido') "El .es.srt con [SONIDOS] no sale SDH: $($esExt.TipoAuto)/$($esExt.TipoFuente)"
    Assert ($esExt.LangAuto -eq 'es-419') "El .es.srt con vocabulario latino no sale latino: '$($esExt.LangAuto)'"
    Assert ((Get-IdiomaPistaGui $esExt 'Sub') -eq 'es-419') 'La GUI no aplica el latino detectado'
    Assert ($enExt.TipoAuto -eq 'Completos' -and $enExt.TipoFuente -eq 'contenido') "El inglés limpio no sale Completos: $($enExt.TipoAuto)"
    Assert ($int -and $int.TipoAuto -eq 'Completos' -and $int.LangAuto -eq 'es') "El interno castellano no se detecta: $($int.TipoAuto)/$($int.LangAuto)"
    Assert ($script:subTrackRows.Count -eq 5) "La lista debe tener 5 subtítulos (3 en E01, 2 en E02): $($script:subTrackRows.Count)"
    Assert (@($script:subTrackRows|Where-Object{$_.ComboTipo}).Count -eq 5) 'Cada fila debe tener su desplegable de tipo'
    Assert (@($script:subsAmbiguos).Count -eq 0 -and $ui.cardSubsUnicos.Visibility -ne 'Visible') 'La tarjeta antigua de sub único no debe salir'
    # --- Cambio en bloque y uno a uno ---
    foreach($r in @($script:subTrackRows)){Set-HdzTipoSubFila $r 'Completos'}
    Assert (@($script:subTrackRows|Where-Object{$_.TipoSub -ne 'Completos'}).Count -eq 0) 'El cambio de todos no se aplica'
    $rowEsE1=@($script:subTrackRows|Where-Object{$_.Archivo -eq $esExt.Ruta})[0]
    Set-HdzTipoSubFila $rowEsE1 'SDH'
    $rowEnE2=@($script:subTrackRows|Where-Object{$_.Archivo -like '*S01E02.en.srt'})[0]
    Aplicar-ComandoAgente ([pscustomobject]@{type='set_sub_type';archivo=$rowEnE2.Archivo;id=$rowEnE2.Id;value='Forzados';_id='subtipos-web-1';session=$script:agSession})
    Assert ($rowEnE2.TipoSub -eq 'Forzados' -and (Get-ComboValor $rowEnE2.ComboTipo) -eq 'Forzados') 'La orden de la web no cambia el tipo'
    $state=Componer-EstadoAgente|ConvertFrom-Json
    Assert (@($state.subTracks|Where-Object{$_.tipo -eq 'Forzados'}).Count -eq 1) 'La web no recibe el tipo de cada subtítulo'
    # Con varios archivos la lista de pistas (y cada archivo) arranca plegada; los controles «de todos»
    # quedan a la vista. Lo que abre el usuario se mantiene al reconstruir la lista.
    Assert ($ui.bodySubTracks.Visibility -ne 'Visible' -and $ui.bodyAudioTracks.Visibility -ne 'Visible') 'Las listas de pistas deben empezar plegadas con varios archivos'
    Assert (@($ui.panSubBulk.Children).Count -eq 1) 'Faltan los controles «de todos» a la vista'
    $grupos=@($ui.panSubTracks.Children|Where-Object{$_ -is [Windows.Controls.StackPanel]})
    Assert ($grupos.Count -eq 2 -and @($grupos|Where-Object{$_.Visibility -eq 'Visible'}).Count -eq 0) 'Cada archivo debe ser un grupo plegado'
    $script:pistasAbiertas['Sub']=$true
    # Español de todos a castellano (web, sin archivo) y luego E02 de vuelta a latino (web, una pista).
    Aplicar-ComandoAgente ([pscustomobject]@{type='set_sub_espanol';value='es';_id='subtipos-web-2';session=$script:agSession})
    Assert (@($script:subTrackRows|Where-Object{(Get-IdiomaPistaGui $_.Pista 'Sub') -eq 'es-419'}).Count -eq 0) 'Español de todos no deja todo en castellano'
    Assert ($ui.bodySubTracks.Visibility -eq 'Visible') 'Al reconstruir se cierra la lista que el usuario abrió'
    $rowEsE2=@($script:subTrackRows|Where-Object{$_.Archivo -like '*S01E02.es.srt'})[0]
    Assert ($rowEsE2.ComboEspanol -and (Get-ComboValor $rowEsE2.ComboEspanol) -eq 'es') 'La fila en español no tiene su desplegable castellano/latino'
    Aplicar-ComandoAgente ([pscustomobject]@{type='set_sub_espanol';archivo=$rowEsE2.Archivo;id=$rowEsE2.Id;value='es-419';_id='subtipos-web-3';session=$script:agSession})
    $state=Componer-EstadoAgente|ConvertFrom-Json
    Assert (@($state.subTracks|Where-Object{$_.idioma -eq 'es-419'}).Count -eq 1) "La web no refleja castellano/latino por pista: $(@($state.subTracks|ForEach-Object idioma) -join ',')"
    Assert ((@($script:subTrackRows|Where-Object{$_.Archivo -like '*S01E02.en.srt'})[0]).TipoSub -eq 'Forzados') 'Al reconstruir la lista se pierde el tipo elegido'
    # --- Montaje ---
    $ui.txtTitulo.Text='Synthetic Tipos'; $ui.txtAno.Text='2026'; $ui.swSerie.IsChecked=$true
    Set-ChipValor 'originales' 'INTACTO'; Set-ChipValor 'torrent' 'NO'; Set-ChipValor 'capturasProy' 'NO'; Set-ChipValor 'filtro' 'TODOS'
    $ui.cfgCarpetaProcesados.Text=''; $ui.cfgCarpetaTorrent.Text=''; $ui.txtAnnounce.Text=''
    $ui.txtSalidaArchivo.Text=Join-Path $testRoot 'output'
    Set-ComboValor $ui.cmbNumCapturas 0
    $script:testJobsMontaje=@()
    Iniciar-Montaje 'unico'
    Assert ($script:testJobsMontaje.Count -eq 1) "La GUI no creó el trabajo: $($ui.lblEstado.Text)"
    $job=$script:testJobsMontaje[0]
    $config=$job.CfgJson|ConvertFrom-Json
    Assert (@($config.TiposSubsPistas).Count -ge 5) "Faltan tipos por pista en la configuración: $(@($config.TiposSubsPistas).Count)"
    Assert (@($config.IdiomasUndPistas|Where-Object{$_.Archivo -like '*S01E02.es.srt' -and $_.Idioma -eq 'es-419'}).Count -eq 1) 'No se envía el latino de E02'
    Assert (@($config.IdiomasUndPistas|Where-Object{$_.Archivo -like '*S01E01.es.srt' -and $_.Idioma -eq 'es'}).Count -eq 1) 'No se envía el castellano de E01'
    $config | Add-Member -NotePropertyName NumCapturas -NotePropertyValue 0 -Force
    $config | Add-Member -NotePropertyName ModoTorrent -NotePropertyValue 'NO' -Force
    $config | Add-Member -NotePropertyName CarpetaProcesados -NotePropertyValue '' -Force
    $config | Add-Member -NotePropertyName AccionOriginales -NotePropertyValue 'INTACTO' -Force
    $config | Add-Member -NotePropertyName TorrentAnnounce -NotePropertyValue '' -Force
    [IO.File]::WriteAllText($job.CfgPath,($config|ConvertTo-Json -Depth 10),$utf8)
    $stdout=Join-Path $testRoot 'engine-stdout.txt'; $stderr=Join-Path $testRoot 'engine-stderr.txt'
    $process=Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$job.LauncherPath+'"')) -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if(-not $process.WaitForExit(240000)){$process.Kill($true);throw "El montaje de prueba no terminó: $testRoot"}
    Assert ($process.ExitCode -in 0,2) "Montaje de prueba falló ($($process.ExitCode)). Diagnóstico: $testRoot"
    $outputs=@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'output') -Recurse -File -Filter '*.mkv' | Sort-Object Name)
    Assert ($outputs.Count -eq 2) "Esperados 2 MKV, hay $($outputs.Count): $testRoot"
    $pistas=@{}
    foreach($o in $outputs){
        $info=& (Join-Path $tiposAppRoot 'bin/mkvmerge.exe') -J $o.FullName|Out-String|ConvertFrom-Json
        $pistas[$(if($o.Name -match 'S01E01'){'E01'}else{'E02'})]=@($info.tracks|Where-Object type -eq 'subtitles'|ForEach-Object{"$($_.properties.track_name)|$($_.properties.language_ietf)|$([bool]$_.properties.flag_hearing_impaired)|$([bool]$_.properties.forced_track)"})
    }
    $t1=$pistas['E01'] -join ' ; ';$t2=$pistas['E02'] -join ' ; '
    Assert ($pistas['E01'].Count -eq 3) "E01 debe llevar 3 subs: $t1"
    Assert ($t1 -match 'Castellano SDH[^|]*\|es(-ES)?\|True') "E01: el .es.srt corregido a castellano y SDH: $t1"
    Assert ($t1 -match 'Castellano Completos[^|]*\|es') "E01: el interno castellano completo: $t1"
    Assert ($t1 -match 'Ingl[eé]s Completos') "E01: inglés completos: $t1"
    Assert ($pistas['E02'].Count -eq 2) "E02 debe llevar 2 subs: $t2"
    Assert ($t2 -match 'Latino Completos[^|]*\|es-419') "E02: el .es.srt devuelto a latino en su fila, completos (cambio en bloque): $t2"
    Assert ($t2 -match 'Ingl[eé]s Forzados[^|]*\|en[^|]*\|False\|True') "E02: inglés forzado elegido desde la web: $t2"
    Write-Host "SUB_TIPOS_PISTA_OK — tipo e idioma detectados, cambio en bloque, uno a uno y desde la web; motor respeta la elección. Prueba: $testRoot"
} finally {
    Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_GUI_TEST_DIR,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue
}
