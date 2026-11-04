$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
. (Join-Path $root 'HDZ-Remote.ps1')
$probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
$script:agSession = 'session-test'
$script:remoto = @{Enabled=$true;Port=$port;Tokens=@()}
$base = "http://127.0.0.1:$port"
function Call($Path, $Method = 'GET', $Body, $Token) {
    $headers = @{}; if ($Token) { $headers['X-HDZ-Panel'] = $Token }
    $arguments = @{Uri="$base$Path";Method=$Method;Headers=$headers;SkipHttpErrorCheck=$true;TimeoutSec=10}
    if ($null -ne $Body) { $arguments.Body = ($Body | ConvertTo-Json -Compress); $arguments.ContentType = 'application/json' }
    Invoke-WebRequest @arguments
}
$torrent = Join-Path $env:TEMP ('hdz_remote_' + [guid]::NewGuid().ToString('N') + '.torrent')
try {
    Start-HdzRemoteServer
    $limit = [datetime]::UtcNow.AddSeconds(10)
    while (-not $script:agSync.Listening -and -not $script:agSync.Error -and [datetime]::UtcNow -lt $limit) { Start-Sleep -Milliseconds 50 }
    Assert $script:agSync.Listening "El servidor no escucha: $($script:agSync.Error)"
    $page = Call '/'
    Assert ($page.StatusCode -eq 200 -and "$($page.Content)".Contains('Emparejar con HDZ Studio')) 'No sirve la web con el emparejamiento'
    $logo = Call '/logo.png'
    Assert ($logo.StatusCode -eq 200 -and "$($logo.Headers['Content-Type'])" -eq 'image/png' -and $logo.RawContentLength -gt 1000) 'No sirve el logo de la cabecera'
    Assert ((Call '/api/state').StatusCode -eq 401) 'El estado es accesible sin emparejar'
    Assert ((Call '/api/state' -Token ('0' * 64)).StatusCode -eq 401) 'Aceptó un token desconocido'
    Assert ((Call '/api/pair' 'POST' @{code='WRONG123'}).StatusCode -eq 401) 'Aceptó un código incorrecto'
    $paired = Call '/api/pair' 'POST' @{code=$script:agSync.PairCode.ToLowerInvariant()}
    Assert ($paired.StatusCode -eq 200) 'No emparejó con el código correcto'
    $token = ($paired.Content | ConvertFrom-Json).token
    Assert ($token -match '^[0-9a-f]{64}$' -and $script:agSync.TokensChanged) 'Token de emparejamiento inválido o no persistido'
    # Sin estado reciente de la GUI, las órdenes se rechazan como hacía el relay.
    $command = @{type='ping';requestId=('r' + [guid]::NewGuid().ToString('N'));session='session-test'}
    Assert ((Call '/api/cmd' 'POST' $command $token).StatusCode -eq 409) 'Aceptó órdenes con la GUI sin responder'
    $script:agSync.Estado = '{"protocol":2,"session":"session-test","v":"fixture"}'; $script:agSync.EstadoAt = [datetime]::UtcNow
    $state = (Call '/api/state' -Token $token).Content | ConvertFrom-Json
    Assert ($state.online -and $state.responsive -and $state.data.session -eq 'session-test') 'Estado remoto incorrecto'
    Assert ((Call '/api/cmd' 'POST' @{type='ping';requestId=('r' + [guid]::NewGuid().ToString('N'));session='old'} $token).StatusCode -eq 409) 'Aceptó una orden de otra sesión'
    $accepted = Call '/api/cmd' 'POST' $command $token
    Assert ($accepted.StatusCode -eq 200 -and ($accepted.Content | ConvertFrom-Json).id -eq $command.requestId) 'No aceptó la orden'
    Assert ((Call '/api/cmd' 'POST' $command $token).StatusCode -eq 200 -and $script:agSync.Cmds.Count -eq 1) 'Una orden repetida se encoló dos veces'
    $queued = $script:agSync.Cmds.Dequeue()
    Assert ($queued.type -eq 'ping' -and $queued._id -eq $command.requestId) 'La GUI no recibe la orden con su identificador'
    Assert ((((Call "/api/cmd/status?id=$($command.requestId)" -Token $token).Content) | ConvertFrom-Json).status -eq 'pending') 'La orden no figura pendiente'
    $script:agSync.Acks = @(@{id=$command.requestId;ok=$true;message='hecho'})
    $limit = [datetime]::UtcNow.AddSeconds(5)
    do { Start-Sleep -Milliseconds 100; $status = ((Call "/api/cmd/status?id=$($command.requestId)" -Token $token).Content | ConvertFrom-Json) } while ($status.status -eq 'pending' -and [datetime]::UtcNow -lt $limit)
    Assert ($status.status -eq 'done' -and $status.message -eq 'hecho' -and $command.requestId -in @($script:agSync.LastAckIds)) 'No aplicó la confirmación de la GUI'
    [IO.File]::WriteAllText($torrent, 'd4:infod4:name3:abc12:piece lengthi16384e6:pieces0:ee')
    $published = Register-HdzRemoteTorrent $torrent
    Assert ($published.id -match '^[0-9a-f]{64}$') 'No registró el torrent'
    $download = Call "/api/torrent?id=$($published.id)" -Token $token
    Assert ($download.StatusCode -eq 200 -and [Convert]::ToBase64String($download.Content) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($torrent))) 'El torrent descargado no es el original'
    Assert ((Call "/api/torrent?id=$($published.id)").StatusCode -eq 401) 'El torrent se descarga sin emparejar'
    foreach ($attempt in 1..6) { $last = Call '/api/pair' 'POST' @{code='WRONG123'} }
    Assert ($last.StatusCode -eq 429) 'No limita los intentos de emparejamiento'
    Write-Host 'REMOTE_SERVER_OK: logo, emparejamiento, token, sesión, órdenes idempotentes, confirmaciones, torrents y límite de intentos.'
} finally {
    Stop-HdzRemoteServer
    Remove-Item -LiteralPath $torrent -Force -ErrorAction SilentlyContinue
}
