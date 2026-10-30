$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:HDZ_GUI_TEST = '1'
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
try {
    . (Join-Path $root 'HDZ-GUI.ps1')
    $state = Componer-EstadoAgente | ConvertFrom-Json
    Assert ($state.protocol -eq 2) 'Falta el protocolo de confirmaciones'
    Assert ($state.session -eq $script:agSession) 'Sesión remota incorrecta'
    foreach($webUrl in @('https://tracker.test/torrents/123','https://tracker.test/torrents/456','')) {
        $script:urlTorrentWeb=$webUrl
        $webState=Componer-EstadoAgente | ConvertFrom-Json
        Assert ($webState.torrentWebUrl -eq $webUrl) 'La web no recibe el enlace de la subida activa'
    }
    $browse = Listar-CarpetaAgente (Join-Path $root 'soporte/tests') 'video'
    Assert ($null -ne $browse) 'Navegador remoto vacío'
    Assert (-not $script:networkBusy) 'La navegación dejó el bloqueo activo'
    # Ruta inexistente: ejercita el módulo real en segundo plano sin subir nada a Internet.
    $missing=Join-Path $env:TEMP ('hdz_missing_'+[guid]::NewGuid().ToString('N')+'.png')
    $imageResult=Send-Imagenes @($missing)
    Assert ($imageResult.Error -and $imageResult.Items.Count -eq 1 -and $imageResult.Items[0].Ruta -eq $missing) 'El lote previo al tracker perdió el error o la ruta'
    Assert (-not $script:networkBusy -and -not $script:subSync -and $ui.panSubProgreso.Visibility -eq 'Collapsed') 'La subida dejó la interfaz bloqueada'
    $imageSync=[hashtable]::Synchronized(@{Fin=$false;Done=0;Total=1})
    & $subidaWorker @($missing) 'PIXHOST' '' $imageSync '' '' 'fixture' $null $script:imageHostModulePath
    Assert ($imageSync.Fin -and $imageSync.Error -and $imageSync.Items.Count -eq 1) 'El worker del escritorio/web no completó el error'
    . (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'HDZ-CapturasContexto.ps1')
    $imageSync=[hashtable]::Synchronized(@{Fin=$false;Done=0;Total=1})
    & $script:hdzContextUploadWorker @($missing) 'PIXHOST' '' '' '' 'fixture' $script:hdzContextImageModule $imageSync
    Assert ($imageSync.Fin -and $imageSync.Error -and $imageSync.Items.Count -eq 1) 'El worker del menú contextual no completó el error'
    # Dos fuentes con el mismo índice de audio: deben seguir siendo opciones distintas.
    $ui.swRemezcla.IsChecked=$true
    Construir-Conversor @(@{Ruta='C:\fixture\video.mkv';Audios=@(@{Index=1;Lang='eng';Codec='aac';Channels=2;Title='';Profile='';HdzSource='C:\fixture\video.mkv'},@{Index=1;Lang='tha';Codec='aac';Channels=2;Title='';Profile='';HdzSource='C:\fixture\donor.mkv'})})
    [void](Add-FilaConv)
    $script:convRows[0].CmbOrigen.SelectedIndex=1
    $selected=@(Leer-ConversionesActuales)
    Assert ($selected.Count -eq 1 -and $selected[0].ArchivoFuente -eq 'C:\fixture\donor.mkv' -and $selected[0].Index -eq 1) 'El conversor confundió índices iguales de archivos distintos'
    Reconstruir-FilasConv $selected
    Assert ((Leer-ConversionesActuales).ArchivoFuente -eq 'C:\fixture\donor.mkv') 'Se perdió la fuente al restaurar una conversión'
    $ui.swRemezcla.IsChecked=$false
    $script:agCompleted = [ordered]@{}
    Aplicar-ComandoAgente ([pscustomobject]@{type='set_input';name='titulo';value='Primer título';_id='test-command-00001';session=$script:agSession})
    Assert ($script:agCompleted['test-command-00001'].ok) 'La orden no se confirmó'
    Assert ($ui.txtTitulo.Text -eq 'Primer título') 'La orden no cambió el campo'
    Aplicar-ComandoAgente ([pscustomobject]@{type='set_input';name='titulo';value='Duplicado';_id='test-command-00001';session=$script:agSession})
    Assert ($ui.txtTitulo.Text -eq 'Primer título') 'Se repitió una orden confirmada'
    Aplicar-ComandoAgente ([pscustomobject]@{type='set_input';name='txtTitulo';value='Obsoleto';_id='test-command-00002';session='sesion-antigua'})
    Assert (-not $script:agCompleted['test-command-00002'].ok) 'Se aceptó una sesión antigua'
    Aplicar-ComandoAgente ([pscustomobject]@{type='set_input';name='upTitulo';value='Otra ficha';_id='test-command-00003';session=$script:agSession;subidaTab=999})
    Assert (-not $script:agCompleted['test-command-00003'].ok) 'Se aceptó una pestaña incorrecta'
    $ui.btnCapGenerar.IsEnabled = $false
    Aplicar-ComandoAgente ([pscustomobject]@{type='click';name='btnCapGenerar';_id='test-command-00004';session=$script:agSession})
    Assert (-not $script:agCompleted['test-command-00004'].ok) 'Se accionó un botón deshabilitado'
    $script:rutaProgreso = 'old-progress.json'; $script:rutaResultados = 'old-results.json'
    $script:timerProgreso = [Windows.Threading.DispatcherTimer]::new(); $script:timerProgreso.Start()
    $ui.upTitulo.Text = 'Ficha anterior'; $ui.txtAno.Text = '2026'
    $script:urlTorrentWeb='https://tracker.test/torrents/789'
    Reset-Todo
    Assert (-not $script:timerProgreso.IsEnabled) 'Sigue activo el lector del montaje'
    Assert (-not $script:rutaProgreso -and -not $script:rutaResultados) 'Quedan resultados antiguos conectados'
    Assert ($script:gruposLanzados -is [hashtable]) 'El reinicio rompe el inventario de lotes'
    Assert (-not $ui.txtTitulo.Text -and -not $ui.txtAno.Text -and -not $ui.upTitulo.Text) 'Quedan datos visibles tras reiniciar'
    Assert ($script:ultimoScan.Count -eq 0 -and $script:remezclaCarpetas.Count -eq 0) 'Quedan vídeos tras reiniciar'
    $state = Componer-EstadoAgente | ConvertFrom-Json
    Assert ($state.torrentWebUrl -eq '') 'El enlace del tracker sobrevive al reinicio'
    Assert (@($state._acks).Count -eq 4) 'Se perdieron las confirmaciones al reiniciar'
    # Último creado: mismo botón local y remoto, sin abrir ni subir torrents reales.
    $latestTestRoot=Join-Path $env:TEMP ('hdz_test_latest_gui_'+[guid]::NewGuid().ToString('N'))
    $savedHistoryEnv=$env:HDZ_HISTORY_TEST_DIR
    $savedAddTorrent=(Get-Item Function:Anadir-SubidaAuto).ScriptBlock
    try {
        $env:HDZ_HISTORY_TEST_DIR=Join-Path $latestTestRoot 'history'
        [void][IO.Directory]::CreateDirectory($latestTestRoot)
        $latestFixture=Join-Path $latestTestRoot 'latest.torrent'
        [IO.File]::WriteAllText($latestFixture,'fixture')
        [void](Add-HdzHistory @{kind='torrent';status='Creado';torrent=$latestFixture})
        Set-Item Function:Anadir-SubidaAuto {param($torrent) $script:testLatestOpened=$torrent}
        $ui.btnTorrentUltimo.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert ($script:testLatestOpened -eq $latestFixture) 'El botón local no consulta el historial tras reiniciar'
        $script:testLatestOpened=$null
        Aplicar-ComandoAgente ([pscustomobject]@{type='click';name='btnTorrentUltimo';_id='test-command-latest';session=$script:agSession})
        Assert ($script:testLatestOpened -eq $latestFixture) 'El botón remoto no usa la misma búsqueda'
        Assert (-not $script:networkBusy) 'La búsqueda dejó la interfaz bloqueada'
    } finally {
        Set-Item Function:Anadir-SubidaAuto $savedAddTorrent
        $env:HDZ_HISTORY_TEST_DIR=$savedHistoryEnv
    }
    # Una orden que espera no debe impedir que el otro temporizador publique estado.
    $savedSync=$script:agSync
    try {
        $script:agSync=[hashtable]::Synchronized(@{Estado=$null;PushNow=$false})
        Start-HdzAgentStateTimer
        $frame=[Windows.Threading.DispatcherFrame]::new()
        $commandTimer=[Windows.Threading.DispatcherTimer]::new()
        $commandTimer.Interval=[TimeSpan]::FromMilliseconds(50)
        $script:busyStatePublished=$false
        $commandTimer.Add_Tick({
            $commandTimer.Stop()
            Invoke-HdzBackground {Start-Sleep -Milliseconds 1700} @{}
            $stateDuringWait=$script:agSync.Estado
            $script:busyStatePublished=[bool]$stateDuringWait.busy
            $frame.Continue=$false
        })
        $commandTimer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)
        Assert ($script:busyStatePublished) 'El estado remoto dejó de publicarse mientras se ejecutaba la orden'
    } finally {$commandTimer.Stop();$script:agStateTimer.Stop();$script:agSync=$savedSync}
    Write-Host 'GUI_REGRESSION_OK — construcción WPF, navegación asíncrona, confirmaciones, sesión, pestañas, reinicio y estado durante órdenes.'
} finally {
    Remove-Item Env:HDZ_GUI_TEST -ErrorAction SilentlyContinue
}
