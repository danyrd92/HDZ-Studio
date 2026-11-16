# Idiomas de audio mal etiquetados (coreano, vietnamita…) corregidos a uno solo: el filtro de idiomas
# desaparece y no debe quedar un chip oculto sin idioma que bloquee «Procesar».
$ErrorActionPreference='Stop'
$appRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture=Join-Path $env:TEMP ('hdz_audio_corregido_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
$sources=@();$i=0
foreach($lang in @('kor','vie','jpn')){
    $i++;$s=Join-Path $fixture "Serie # Episodio $i# Titulo HD.mkv"
    & "$appRoot/bin/ffmpeg.exe" -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=1' -f lavfi -i 'sine=frequency=440:duration=1' -map 0:v -map 1:a -c:v libx264 -preset ultrafast -c:a aac -metadata:s:a:0 language=$lang -shortest $s
    if($LASTEXITCODE -ne 0){throw 'Cannot create fixture'}
    $sources+=$s
}
$env:HDZ_GUI_TEST='1';$env:HDZ_HISTORY_TEST_DIR=Join-Path $fixture 'history'
function Assert($condition,$message){if(-not $condition){throw $message}}
try {
    . "$appRoot/HDZ-GUI.ps1"
    $ui.txtCarpeta.Text=$fixture;$rows=@(& $scanWorker $sources);$script:ultimoScan=$rows
    $script:seleccion=@{};foreach($r in $rows){$script:seleccion[$r.Nombre]=$true}
    Construir-Adaptacion $rows
    Assert (@($script:chipsIdiomasAudio).Count -eq 3) 'Faltan los chips de los idiomas detectados'
    # El usuario quita todos los idiomas detectados (aviso correcto) y luego los corrige a Castellano.
    foreach($c in $script:chipsIdiomasAudio){$c.IsChecked=$false;$script:idiomasAudioSeleccionUsuario=$true;Sync-HdzFilasConFiltro 'Audio' "$($c.Tag)"}
    foreach($r in $rows){foreach($a in $r.Audios){$id=if($null -ne $a.TrackId){$a.TrackId}else{$a.Index};$script:idiomasManuales["$($r.Ruta)|$id|Audio"]='es'}}
    Actualizar-IdiomasManuales
    Assert (@($script:chipsIdiomasAudio).Count -eq 0) "Queda un chip oculto: [$(@($script:chipsIdiomasAudio|ForEach-Object {"$($_.Tag)"}) -join ',')]"
    Assert ("$($ui.cardFiltroAudio.Visibility)" -ne 'Visible') 'Con un solo idioma no debe mostrarse el filtro'
    $ui.txtTitulo.Text='Audio Corregido';$ui.txtAno.Text='2026';$ui.swSerie.IsChecked=$true
    # Con todas las pistas aún desmarcadas, procesar dejaría los vídeos mudos: debe bloquearse.
    $script:testJobsMontaje=@();Iniciar-Montaje 'unico'
    Assert ($script:testJobsMontaje.Count -eq 0) 'Deja procesar vídeos sin ninguna pista de audio'
    Assert ("$($ui.lblEstado.Text)" -match 'sin audio') "Aviso inesperado: $($ui.lblEstado.Text)"
    foreach($row in @((Get-HdzTrackState 'Audio').Rows)){if(-not [bool]$row.Choice.IsChecked){Set-HdzTrackSelected 'Audio' $row $true}}
    $script:testJobsMontaje=@();Iniciar-Montaje 'unico'
    Assert ($script:testJobsMontaje.Count -eq 1) "No deja procesar: $($ui.lblEstado.Text)"
    $config=$script:testJobsMontaje[0].CfgJson|ConvertFrom-Json
    Assert (-not $config.IdiomasAudioMantener) "Filtro de idiomas inesperado: $(@($config.IdiomasAudioMantener) -join ',')"
    Write-Host "AUDIO_IDIOMA_CORREGIDO_OK: sin chip oculto, filtro oculto y trabajo creado. $fixture"
} finally { Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue }
