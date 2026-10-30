param([switch]$Baseline)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:HDZ_GUI_TEST='1'
function Assert($ok,$message){if(-not $ok){throw $message}}
try {
    . (Join-Path $root 'HDZ-GUI.ps1')
    $script:ultimoScan=@(1..60 | ForEach-Object {
        $name='Fixture.S01E{0:d2}.mkv' -f $_; $path='C:\Fixture\'+$name
        @{Nombre=$name;Ruta=$path;Video=@{Height=2160;Codec='hevc';EsDV=$true;EsHDR=$true};
          Audios=@(1..12 | ForEach-Object {@{Index=$_;TrackId=$_;Ruta=$path;Lang='eng';Title='';Codec='eac3';Channels=6}});
          Subs=@(13..32 | ForEach-Object {@{Index=$_;TrackId=$_;Ruta=$path;Lang='spa';Title='';EsPGS=$false}})}
    })
    $script:gruposLote=@($script:ultimoScan|ForEach-Object {@{Principal=$_.Nombre;Miembros=@($_.Nombre)}})
    $timings=@(1..5|ForEach-Object {$clock=[Diagnostics.Stopwatch]::StartNew();$state=Componer-EstadoAgente;$clock.Stop();$clock.Elapsed.TotalMilliseconds})
    Write-Host ('STATE_60_FILES_MS: '+(($timings|ForEach-Object {[Math]::Round($_,1)}) -join ', '))
    if($Baseline){return}
    $dto=Componer-EstadoAgente -Snapshot
    Assert ($dto -is [Collections.IDictionary]) 'El hilo UI sigue serializando JSON para el worker'
    $languageRows=@(1..80 | ForEach-Object {@{Archivo='C:\Fixture\multi.mkv';Id=$_;Etiqueta="Pista $_"}})
    Construir-FilasUnd $ui.panUndAudio $languageRows 'Audio'
    $clock=[Diagnostics.Stopwatch]::StartNew();$withLanguages=Componer-EstadoAgente -Snapshot;$clock.Stop()
    Write-Host ("STATE_80_EDITORS_MS: {0:N1}; shared options={1}" -f $clock.Elapsed.TotalMilliseconds,$withLanguages.idiomasPistaOpciones.Count)
    Assert ($withLanguages.undAudioSubs.Count -eq 80 -and $withLanguages.idiomasPistaOpciones.Count -gt 100) 'Faltan pistas o el catálogo compartido de idiomas'
    Assert (-not $withLanguages.undAudioSubs[0].Contains('opciones')) 'Se duplica todo el catálogo en cada pista'
    $first=$script:ultimoScan[0];$name=$first.Nombre
    $script:idiomasManuales["$($first.Ruta)|1|Audio"]='spa'
    $script:seleccion[$name]=$false;$script:episodiosMap[$name]='S02E04'
    $changed=Componer-EstadoAgente -Snapshot
    Assert (($changed.lote[0].badges.t -join ' ') -match 'DD\+ es') 'La caché no refleja una corrección de idioma'
    Assert (-not $changed.lote[0].sel -and $changed.lote[0].ep -eq 'S02E04') 'La caché oculta decisiones nuevas'
    $script:tmdbSearchResults=$null
    $state=Componer-EstadoAgente|ConvertFrom-Json
    Assert ($state.tmdbResults.Count -eq 0) 'Una búsqueda vacía genera una coincidencia TMDB fantasma'
    # Índices originales: ignorar una respuesta inválida no cambia la selección.
    $script:tmdbSearchResults=@($null,@{Id=123;Titulo='Ficha válida';Fecha='2026'})
    $state=Componer-EstadoAgente|ConvertFrom-Json
    Assert ($state.tmdbResults.Count -eq 1 -and $state.tmdbResults[0].i -eq 1) 'Los resultados filtrados apuntan a otra ficha'
    $script:capPreviewSync=@{Done=1;Total=10}
    Actualizar-PanelTareasAux
    $row=$ui.panTareasAux.Children[0]
    Actualizar-PanelTareasAux
    Assert ([object]::ReferenceEquals($row,$ui.panTareasAux.Children[0])) 'El mismo progreso destruye y vuelve a crear los controles'
    $script:capPreviewSync.Done=2
    Actualizar-PanelTareasAux
    Assert ([object]::ReferenceEquals($row,$ui.panTareasAux.Children[0])) 'Cambiar el porcentaje reconstruye los controles'
    Assert ($row.Tag.Bar.Value -eq 20) 'El progreso reutilizado no se actualiza'
    $script:agSync=[hashtable]::Synchronized(@{})
    $script:agSnapshotAt=[datetime]::MinValue
    Update-HdzAgentState
    $snapshot=$script:agSync.Estado
    Update-HdzAgentState
    Assert ([object]::ReferenceEquals($snapshot,$script:agSync.Estado)) 'Los dos temporizadores recomponen el mismo estado'
    $script:observedBusy=$false
    $probe=[Windows.Threading.DispatcherTimer]::new();$probe.Interval=[TimeSpan]::FromMilliseconds(60)
    $probe.Add_Tick({$script:observedBusy=$win.IsEnabled -and -not $ui.upTitulo.IsEnabled;$probe.Stop()})
    $probe.Start()
    Invoke-HdzBackground {Start-Sleep -Milliseconds 250} @{}
    Assert $script:observedBusy 'La espera de red desactiva toda la ventana y bloquea el scroll'
    Assert $ui.upTitulo.IsEnabled 'El editor queda bloqueado después de la espera'
    # El servidor remoto local serializa el DTO en su propio hilo, no en el de la UI.
    $probePort=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probePort.Start();$port=$probePort.LocalEndpoint.Port;$probePort.Stop()
    $script:remoto=@{Enabled=$true;Port=$port;Tokens=@()};$script:agSync=$null
    Start-HdzRemoteServer
    try {
        $limit=[datetime]::UtcNow.AddSeconds(10);while(-not $script:agSync.Listening -and [datetime]::UtcNow -lt $limit){Start-Sleep -Milliseconds 50}
        $script:agSync.Estado=$dto;$script:agSync.EstadoAt=[datetime]::UtcNow
        $token=((Invoke-RestMethod "http://127.0.0.1:$port/api/pair" -Method Post -Body (@{code=$script:agSync.PairCode}|ConvertTo-Json) -ContentType 'application/json').token)
        $sent=(Invoke-RestMethod "http://127.0.0.1:$port/api/state" -Headers @{'X-HDZ-Panel'=$token}).data
        Assert ($sent.lote.Count -eq 60 -and $sent.session -eq $script:agSession) 'El servidor remoto no serializó el DTO de la UI'
    } finally { Stop-HdzRemoteServer }
    Write-Host 'RESPONSIVENESS_OK: snapshot DTO, throttled publication, stable task controls, valid TMDB results.'
} finally {
    Detener-Agente
    if($win){$win.Close()}
    Remove-Item Env:HDZ_GUI_TEST -ErrorAction SilentlyContinue
}
