$ErrorActionPreference='Stop'
$env:HDZ_GUI_TEST='1'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($condition,$message){if(-not $condition){throw $message}}
try {
    . (Join-Path $root 'HDZ-GUI.ps1')
    Assert ($ui.panGeneral.Visibility -eq 'Visible') 'Entrada plegada al abrir'
    Assert ($ui.panTabsGen.Parent -eq $ui.panCrear) 'Selector de trabajos dentro de una sección plegable'
    foreach($panel in @($ui.panProyTabs,$ui.panProyTabsA,$ui.panProyTabsS)){Assert ($panel.Visibility -eq 'Collapsed') 'Selector duplicado visible'}
    Mostrar-Panel 'panAjustes'
    Assert ($ui.btnIniciar.Visibility -eq 'Collapsed' -and $ui.btnSubir.Visibility -eq 'Collapsed') 'Acciones incorrectas en Ajustes'
    Assert ($script:barraEntrada.Visibility -eq 'Collapsed') 'Carpeta visible en Ajustes'
    Mostrar-Panel 'panSubida'
    Assert ($ui.btnSubir.Visibility -eq 'Visible' -and $ui.btnIniciar.Visibility -eq 'Collapsed') 'Acciones incorrectas en Subida'
    $ui.cfgTrackerToken.Text='fixture-secret';$ui.cfgTmdbKey.Text='fixture-tmdb'
    Aplicar-ComandoAgente ([pscustomobject]@{type='set_input';name='cfgTrackerToken';value='';session=$script:agSession})
    Assert ($ui.cfgTrackerToken.Text -eq 'fixture-secret') 'Campo vacío borró una credencial'
    $json=Componer-EstadoAgente
    Assert (-not $json.Contains('fixture-secret') -and -not $json.Contains('fixture-tmdb')) 'Estado remoto revela secretos'
    $state=$json|ConvertFrom-Json
    Assert ($state.interfaz.credentials.cfgTrackerToken) 'Falta el estado de credenciales'
    Assert (-not $state.interfaz.actions.subir.enabled) 'Subida habilitada sin torrent'
    $ui.txtLogoPersonalizado.Text='https://example.test/logo.png'
    Reset-Todo
    Assert (-not $ui.txtLogoPersonalizado.Text) 'Logo personalizado sobrevive al reinicio'
    Assert ($ui.cfgTrackerToken.Text -eq 'fixture-secret') 'Reinicio borra ajustes'
    $fixture=Join-Path $env:TEMP ('hdz_layout_series_'+[guid]::NewGuid().ToString('N'))
    $base=Join-Path $fixture 'video';$donor=Join-Path $fixture 'audio'
    [void][IO.Directory]::CreateDirectory($base);[void][IO.Directory]::CreateDirectory($donor)
    foreach($name in @('Title.S01E01.mkv','Title.S01E02.mkv')){[IO.File]::WriteAllText((Join-Path $base $name),'fixture')}
    foreach($name in @('Other.S01E01.mkv','Other.S01E03.mkv')){[IO.File]::WriteAllText((Join-Path $donor $name),'fixture')}
    $ui.swRemezcla.IsChecked=$true
    Add-FilaRemezcla $base '';Add-FilaRemezcla $donor ''
    $script:remezclaCarpetas[0].Video.IsChecked=$true;$script:remezclaCarpetas[1].Video.IsChecked=$false;$script:remezclaCarpetas[1].Audio.IsChecked=$true
    $script:remixPresentationKey=$null
    $rows=@(Get-HdzRemixPresentation)
    Assert (@($rows|Where-Object estado -eq 'Emparejado').Count -eq 1) 'Emparejado por episodio incorrecto'
    Assert (@($rows|Where-Object estado -eq 'Sin pareja').Count -eq 1) 'No muestra episodio sin audio'
    Assert (@($rows|Where-Object estado -eq 'Donante sin pareja').Count -eq 1) 'No muestra donante sobrante'
    Assert (($rows|Where-Object estado -eq 'Emparejado').pistas -eq 'Other.S01E01.mkv') 'No muestra nombre del donante'
    Show-HdzRemixPairs
    Assert ($script:remixPairsPanel.Children.Count -gt 0) 'No se muestran las parejas en escritorio'
    Reset-Todo
    Assert ($script:remixPairsPanel.Children.Count -eq 0 -and -not $script:remixPresentationKey) 'Reinicio conserva parejas temporales'
    Write-Host 'INTERFACE_REGRESSION_OK: WPF contexts, selector, credentials, reset and episode-pair presentation.'
} finally {Remove-Item Env:HDZ_GUI_TEST -ErrorAction SilentlyContinue}
