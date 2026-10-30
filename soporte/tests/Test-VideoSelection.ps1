$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$testRoot=Join-Path $env:TEMP ('hdz_video_selection_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$names=@('First.S01E01.mkv','Second.S01E02-HDZ [Castellano].mkv','Third.S01E03-HDZ.mkv')
$paths=@($names | ForEach-Object {Join-Path $testRoot $_})
& (Join-Path $root 'bin/ffmpeg.exe') -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=1' -c:v libx264 -preset ultrafast $paths[0]
if($LASTEXITCODE -ne 0){throw 'Fixture de selección falló'}
Copy-Item -LiteralPath $paths[0] -Destination $paths[1]
Copy-Item -LiteralPath $paths[0] -Destination $paths[2]
function Assert($condition,$message){if(-not $condition){throw $message}}
$env:HDZ_GUI_TEST='1';$env:HDZ_GUI_TEST_DIR=$testRoot
try {
    . (Join-Path $root 'HDZ-GUI.ps1')
    Assert ((Componer-EstadoAgente | ConvertFrom-Json).selectVideos) 'Falta capacidad remota'
    Set-VideosElegidos @($paths[0],$paths[2])
    Assert ($script:ultimoScan.Count -eq 2) 'Se analizaron vídeos ajenos a la selección local'
    Assert ($script:seleccion[$names[0]] -and -not $script:seleccion[$names[1]] -and $script:seleccion[$names[2]]) 'Selección local no excluye el resto'
    # El móvil usa la misma operación, incluso al cambiar de un lote multitemporada.
    $extra=Join-Path $testRoot 'Otra temporada';[void][IO.Directory]::CreateDirectory($extra)
    Copy-Item -LiteralPath $paths[0] -Destination (Join-Path $extra $names[0])
    Set-CarpetasTemporadas @($testRoot,$extra)
    Aplicar-ComandoAgente ([pscustomobject]@{type='set_videos';paths=@($paths[1]);_id='choose-videos-test';session=$script:agSession;projectTab=$script:tabProyActual})
    Assert ($script:agCompleted['choose-videos-test'].ok) 'Orden remota sin confirmar'
    Assert ($script:ultimoScan.Count -eq 1 -and $script:ultimoScan[0].Nombre -eq $names[1]) 'La web analizó toda la carpeta'
    Assert (@(Get-CarpetasEntrada).Count -eq 1) 'Quedan temporadas ajenas'
    Assert (-not $script:seleccion[$names[0]] -and $script:seleccion[$names[1]] -and -not $script:seleccion[$names[2]]) 'Selección remota incorrecta'
    # Refrescar el análisis no debe seleccionar otra vez los vídeos no elegidos.
    Refrescar-Adaptacion
    Lanzar-Escaneo
    Assert ($script:ultimoScan.Count -eq 1 -and $script:ultimoScan[0].Nombre -eq $names[1]) 'Reescanear pierde las rutas exactas'
    Assert (-not $script:seleccion[$names[0]] -and $script:seleccion[$names[1]]) 'Selección perdida al refrescar'
    $cases=@(@(),@((Join-Path $testRoot 'missing.mkv')),@($paths[0],(Join-Path $extra $names[0])))
    $i=0
    foreach($badPaths in $cases){
        $i++;$id="bad-videos-$i"
        Aplicar-ComandoAgente ([pscustomobject]@{type='set_videos';paths=$badPaths;_id=$id;session=$script:agSession})
        Assert (-not $script:agCompleted[$id].ok) 'Selección inválida aceptada'
        Assert ($script:seleccion[$names[1]] -and -not $script:seleccion[$names[0]]) 'El fallo cambió la selección anterior'
    }
    $ui.txtTitulo.Text='Selection Test'; $ui.txtAno.Text='2026'
    Set-ChipValor 'originales' 'INTACTO'; Set-ChipValor 'torrent' 'NO'; Set-ChipValor 'capturasProy' 0
    $script:testJobsMontaje=@()
    Iniciar-Montaje 'unico'
    Assert ($script:testJobsMontaje.Count -eq 1) 'No se generó el trabajo de montaje'
    $selectionCfg=$script:testJobsMontaje[0].CfgJson | ConvertFrom-Json
    Assert (@($selectionCfg.ArchivosSeleccionados).Count -eq 1 -and $selectionCfg.ArchivosSeleccionados[0] -eq $names[1]) 'El motor podría procesar el resto de la carpeta'
    Set-CarpetasTemporadas @($testRoot)
    Lanzar-Escaneo
    Assert ($script:ultimoScan.Count -eq 3) 'Elegir carpeta no restaura el análisis completo'
    Assert (-not $ui.ContainsKey('cardReprocesar')) 'Sigue existiendo la decisión de reprocesado'
    Assert (-not ((Componer-EstadoAgente | ConvertFrom-Json).PSObject.Properties.Name -contains 'reprocesarVisible')) 'Se sigue anunciando reprocesado a la web'
    # Ejecutar el bloque real de descubrimiento del motor, sin montar ningún vídeo.
    $engine=Get-Content -LiteralPath (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'HDZnew.ps1') -Raw
    $start=$engine.IndexOf('$todosLosArchivos = @(Get-ChildItem -Include')
    $end=$engine.IndexOf('# Agrupamos archivos ignorando etiquetas',$start)
    Assert ($start -ge 0 -and $end -gt $start) 'No se encuentra el descubrimiento del motor'
    function Get-CfgGui($key){if($key -eq 'ArchivosSeleccionados'){return $script:engineSelection};if($key -eq 'ReprocesarHDZ'){throw 'El motor consulta la decisión retirada'}}
    $global:remixActivo=$false
    Push-Location -LiteralPath $testRoot
    try {
        foreach($selection in @(@($names[1]),@($names[2]),@($names[0],$names[1]),@())){
            $script:engineSelection=$selection
            . ([scriptblock]::Create($engine.Substring($start,$end-$start)))
            $expected=if($selection.Count){$selection.Count}else{3}
            Assert ($todosLosArchivos.Count -eq $expected) 'El motor descartó una release -HDZ o incluyó vídeos no seleccionados'
            foreach($name in $selection){Assert ($todosLosArchivos.Name -contains $name) "Selección perdida: $name"}
        }
    } finally {Pop-Location}
    Write-Host "VIDEO_SELECTION_OK: análisis exacto local/remoto, refresco y montaje restringido. $testRoot"
}finally{Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_GUI_TEST_DIR -ErrorAction SilentlyContinue}
