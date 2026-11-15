$ErrorActionPreference='Stop'
$appRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture=Join-Path $env:TEMP ('hdz_filtro_filas_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
# Dos audios (castellano, inglés) y cuatro subtítulos: castellano forzado, castellano, inglés e inglés SDH.
$srtDir=Join-Path $fixture 'srt';[void][IO.Directory]::CreateDirectory($srtDir);$srts=@()
foreach($n in 1..4){$srt=Join-Path $srtDir "$n.srt";[IO.File]::WriteAllText($srt,"1`r`n00:00:00,100 --> 00:00:01,500`r`nTexto $n`r`n`r`n",[Text.UTF8Encoding]::new($false));$srts+=$srt}
$source=Join-Path $fixture 'Source.mkv'
& "$appRoot/bin/ffmpeg.exe" -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=2' -f lavfi -i 'sine=frequency=440:duration=2' -i $srts[0] -i $srts[1] -i $srts[2] -i $srts[3] `
  -map 0:v -map 1:a -map 1:a -map 2 -map 3 -map 4 -map 5 -c:v libx264 -preset ultrafast -c:a aac -c:s srt `
  -metadata:s:a:0 language=spa -metadata:s:a:1 language=eng `
  -metadata:s:s:0 language=spa -metadata:s:s:0 title=Forced -disposition:s:0 forced `
  -metadata:s:s:1 language=spa -metadata:s:s:2 language=eng -metadata:s:s:3 language=eng -metadata:s:s:3 title=SDH -shortest $source
if($LASTEXITCODE -ne 0){throw 'Cannot create fixture'}
$env:HDZ_GUI_TEST='1';$env:HDZ_HISTORY_TEST_DIR=Join-Path $fixture 'history'
function Assert($condition,$message){if(-not $condition){throw $message}}
function Click($control){$control.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))}
function Toggle($chip){$chip.IsChecked=-not $chip.IsChecked;Click $chip}
function Marcadas($rows){@($rows|Where-Object {$_.Choice.IsChecked}|ForEach-Object {"$($_.Id)"}) -join ','}
try {
 . "$appRoot/HDZ-GUI.ps1"
 $ui.txtCarpeta.Text=$fixture;$rows=@(& $scanWorker @($source));$script:ultimoScan=$rows;$script:seleccion=@{$rows[0].Nombre=$true};Construir-Adaptacion $rows
 Assert ($script:audioTrackRows.Count -eq 2 -and $script:subTrackRows.Count -eq 4) "Pistas: $($script:audioTrackRows.Count) audio, $($script:subTrackRows.Count) subs"
 $aEs=@($script:audioTrackRows|Where-Object {$_.Etiqueta -match 'Castellano'})[0];$aEn=@($script:audioTrackRows|Where-Object {$_.Etiqueta -match 'Inglés'})[0]
 $sForz=@($script:subTrackRows|Where-Object TipoSub -eq 'Forzados')[0];$sSdh=@($script:subTrackRows|Where-Object TipoSub -eq 'SDH')[0]
 $sEs=@($script:subTrackRows|Where-Object {$_.TipoSub -eq 'Completos' -and $_.Etiqueta -match 'Castellano'})[0];$sEn=@($script:subTrackRows|Where-Object {$_.TipoSub -eq 'Completos' -and $_.Etiqueta -match 'Inglés'})[0]
 Assert ($aEs -and $aEn -and $sForz -and $sSdh -and $sEs -and $sEn) 'No identifica las filas del fixture'

 # Audio: desmarcar el chip de inglés desmarca su pista, y volver a marcarlo la recupera.
 $chipEng=@($script:chipsIdiomasAudio|Where-Object {"$($_.Tag)" -eq 'eng'})[0];Assert $chipEng 'Falta el chip de audio inglés'
 Toggle $chipEng
 Assert ((-not $aEn.Choice.IsChecked) -and $aEs.Choice.IsChecked) 'Chip de audio no desmarca su pista'
 Assert ($script:audioTracksExcluded.Count -eq 1 -and "$($ui.bdgAudioTracks.Text)" -match '^1 de 2') "Exclusión/contador de audio: $($ui.bdgAudioTracks.Text)"
 Toggle $chipEng;Assert ($aEn.Choice.IsChecked -and $script:audioTracksExcluded.Count -eq 0) 'Chip de audio no vuelve a marcar su pista'
 Aplicar-ComandoAgente ([pscustomobject]@{type='set_audio_lang';code='es';value=$false;session=$script:agSession;projectTab=$script:tabProyActual})
 Assert ((-not $aEs.Choice.IsChecked) -and $aEn.Choice.IsChecked) 'Orden web de idioma de audio no desmarca la pista'
 Aplicar-ComandoAgente ([pscustomobject]@{type='set_audio_lang';code='es';value=$true;session=$script:agSession;projectTab=$script:tabProyActual})
 Assert $aEs.Choice.IsChecked 'Orden web de idioma de audio no marca la pista'

 # Subtítulos, tipo: desmarcar SDH solo toca la fila SDH; una fila desmarcada a mano no vuelve sola.
 Set-HdzTrackSelected 'Sub' $sEs $false
 $chipSdh=@($script:chipsTiposSub|Where-Object {"$($_.Tag)" -eq 'SDH'})[0];$chipForz=@($script:chipsTiposSub|Where-Object {"$($_.Tag)" -eq 'Forzados'})[0]
 Toggle $chipSdh;Assert ((Marcadas $script:subTrackRows) -eq (Marcadas @($sForz,$sEn))) "Tipo SDH: $(Marcadas $script:subTrackRows)"
 Toggle $chipSdh;Assert ($sSdh.Choice.IsChecked -and -not $sEs.Choice.IsChecked) 'Tipo SDH no recupera su fila o pisa la elección manual'
 Aplicar-ComandoAgente ([pscustomobject]@{type='set_sub_tipo';code='Forzados';value=$false;session=$script:agSession;projectTab=$script:tabProyActual})
 Assert (-not $sForz.Choice.IsChecked) 'Orden web de tipo no desmarca la fila'
 Aplicar-ComandoAgente ([pscustomobject]@{type='set_sub_tipo';code='Forzados';value=$true;session=$script:agSession;projectTab=$script:tabProyActual})
 Assert $sForz.Choice.IsChecked 'Orden web de tipo no marca la fila'
 Set-HdzTrackSelected 'Sub' $sEs $true

 # Subtítulos, modo: «Personalizada» con solo inglés deja las filas inglesas (con tipo permitido).
 $radio=@($script:gruposChips['filtro']|Where-Object Valor -eq 'PERSONALIZADA')[0].Radio;$radio.IsChecked=$true;Click $radio
 Assert ((Marcadas $script:subTrackRows) -eq '') "Personalizada sin idiomas: $(Marcadas $script:subTrackRows)"
 $chipSubEng=@($script:chipsIdiomas|Where-Object {"$($_.Tag)" -eq 'eng'})[0];Assert $chipSubEng 'Falta el chip de subtítulo inglés'
 Toggle $chipSubEng;Assert ((Marcadas $script:subTrackRows) -eq (Marcadas @($sEn,$sSdh))) "Idioma inglés: $(Marcadas $script:subTrackRows)"
 Toggle $chipSdh;Assert ((Marcadas $script:subTrackRows) -eq "$($sEn.Id)") 'Tipo e idioma no se combinan'
 Aplicar-ComandoAgente ([pscustomobject]@{type='set_sub_lang';code='es';value=$true;session=$script:agSession;projectTab=$script:tabProyActual})
 Assert ((Marcadas $script:subTrackRows) -eq (Marcadas @($sForz,$sEs,$sEn))) "Orden web de idioma: $(Marcadas $script:subTrackRows)"
 Aplicar-ComandoAgente ([pscustomobject]@{type='set_chip';grupo='filtro';value='TODOS';session=$script:agSession;projectTab=$script:tabProyActual})
 Assert ((Marcadas $script:subTrackRows) -eq (Marcadas @($sForz,$sEs,$sEn))) "Mantener todos (sin SDH): $(Marcadas $script:subTrackRows)"
 Toggle $chipSdh;Assert ($script:subTracksExcluded.Count -eq 0) 'No vuelve a todas'

 # Pestañas: restaurar no pasa por la sincronización y conserva una fila desmarcada a mano.
 Set-HdzTrackSelected 'Sub' $sEn $false
 $snapshot=Snapshot-DecisionesTab;Construir-Adaptacion $rows;Restore-DecisionesTab $snapshot
 Assert (@($script:subTrackRows|Where-Object {-not $_.Choice.IsChecked}).Count -eq 1) 'Restaurar la pestaña pisa la selección manual'
 Write-Host "FILTRO_FILAS_OK: chips de idioma y tipo (GUI y web) sincronizan las filas de audio y subtítulos. $fixture"
}finally{Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue}
