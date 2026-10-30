$ErrorActionPreference='Stop'
$captureTestRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($value,$message){if(-not $value){throw $message}}
function Count-Caps($text){[regex]::Matches("$text",'\[img=350\]').Count}
$env:HDZ_GUI_TEST='1'
$temp=Join-Path $env:TEMP ('hdz_capture_tabs_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    . (Join-Path $captureTestRoot 'HDZ-GUI.ps1')
    # Imágenes sintéticas existentes: no vídeo real ni subidas de red.
    $paths=@(1..10 | ForEach-Object {$p=Join-Path $temp ("capture-$_.png");Copy-Item (Join-Path $captureTestRoot 'HDZStudio.png') $p;$p})
    Set-Item Function:Start-SubidaAsync {param($rutas,$onComplete,$botones) $script:testCallback=$onComplete;$script:testPaths=@($rutas)}
    $ui.upTitulo.Text='Película A';$banner='[img=700]https://example.com/banner.png[/img]'
    $ui.upDescripcion.Text="[center]$banner[/center]"
    Construir-Capturas $paths
    $idA=$script:subidaTabId
    Insertar-CapturasSeleccionadas
    $callbackA=$script:testCallback
    Nueva-Tab
    $ui.upTitulo.Text='Película B';$idB=$script:subidaTabId
    $descB="$($ui.upDescripcion.Text)"
    $urlsA=@(1..10 | ForEach-Object {"https://i.ibb.co/test/a-$_.png"})
    & $callbackA $urlsA
    Assert ($script:subidaTabId -eq $idB -and $ui.upDescripcion.Text -eq $descB) 'Una subida de A modificó B'
    Assert ((Count-Caps $script:tabs[0].Descripcion) -eq 10) 'No añadió las diez capturas a la pestaña inactiva'
    Assert (@($script:tabs[0].Caps | Where-Object {$_.Subida}).Count -eq 10) 'No guardó los enlaces de A'
    Cambiar-Tab 0
    Assert ((Count-Caps $ui.upDescripcion.Text) -eq 10) 'Al volver a A perdió capturas'
    $remoteState=Componer-EstadoAgente | ConvertFrom-Json
    Assert ((Count-Caps $remoteState.inputs.upDescripcion) -eq 10 -and @($remoteState.capturas | Where-Object {$_.subida}).Count -eq 10) 'La web no recibió la descripción o los enlaces del escritorio'
    Assert ($ui.upDescripcion.Text.Contains($banner)) 'Perdió el logo'
    $script:capRows[0].Check.IsChecked=$false
    Assert ((Count-Caps $ui.upDescripcion.Text) -eq 9) 'Desmarcar una captura no actualizó la descripción'
    Cambiar-Tab 1;Cambiar-Tab 0
    Assert ((Count-Caps $ui.upDescripcion.Text) -eq 9 -and -not $script:capRows[0].Check.IsChecked) 'Restaurar disparó eventos que borraron capturas o selección'
    Construir-Capturas $paths
    Assert (@($script:capRows | Where-Object {$_.Subida}).Count -eq 10 -and -not $script:capRows[0].Check.IsChecked) 'Reconstruir miniaturas perdió enlaces o selección'
    Insertar-CapturasSeleccionadas
    Assert ((Count-Caps $ui.upDescripcion.Text) -eq 9) 'Reinsertar caché duplicó capturas'
    # Segunda subida: cambiar A -> B -> A antes de completar recrea los controles.
    Cambiar-Tab 1;Construir-Capturas @($paths[0]);Insertar-CapturasSeleccionadas
    $callbackB=$script:testCallback
    Cambiar-Tab 0;Cambiar-Tab 1
    & $callbackB @('https://i.ibb.co/test/b.png')
    Assert ((Count-Caps $ui.upDescripcion.Text) -eq 1 -and $script:capRows[0].Subida -eq 'https://i.ibb.co/test/b.png') 'La subida usó controles destruidos al volver a la misma pestaña'
    # El índice cambia al cerrar otra pestaña, pero la identidad de B se conserva.
    Nueva-Tab;$idC=$script:subidaTabId;$ui.upTitulo.Text='Película C'
    Cerrar-Tab 0
    Complete-HdzDescriptionImages $idB @('https://i.ibb.co/test/manual.jpeg')
    Assert ($script:subidaTabId -eq $idC -and (Count-Caps $ui.upDescripcion.Text) -eq 0) 'Imágenes manuales mezcladas con C'
    Assert ($script:tabs[0].Id -eq $idB -and $script:tabs[0].Descripcion.Contains('manual.jpeg')) 'Confundió identidad con índice'
    Cerrar-Tab 0
    $failed=$false;try{Complete-HdzCaptureInsertion $idB @($paths[0]) @('https://i.ibb.co/test/late.png')}catch{$failed=$true}
    Assert $failed 'Una pestaña cerrada recibió capturas en otra película'
    Assert ((Count-Caps $ui.upDescripcion.Text) -eq 0) 'Contaminó la pestaña restante'
    $failed=$false;try{Complete-HdzCaptureInsertion $idC @($paths[0]) @()}catch{$failed=$true}
    Assert $failed 'Anunció éxito con enlaces incompletos'
    Write-Host 'CAPTURE_TABS_OK: diez capturas, pestaña inactiva, ida/vuelta, reconstrucción, selección, identidad estable, pestaña cerrada y BBCode directo.'
} finally {Remove-Item Env:HDZ_GUI_TEST -ErrorAction SilentlyContinue}
