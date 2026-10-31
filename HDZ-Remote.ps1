# Control remoto local: HDZ Studio sirve la web en la red de casa, sin relay ni dominio externo.
# Mismo protocolo que usaba el relay (/api/state, /api/cmd, /api/cmd/status, /api/torrent), así
# que la web y la cola de órdenes de la GUI (Aplicar-ComandoAgente) no cambian. Los dispositivos
# se emparejan una vez con un código de 8 caracteres y luego envían su token en X-HDZ-Panel.
# El servidor corre en un runspace aparte: nunca toca WPF, solo el hashtable sincronizado.

$script:remoteServerWorker = {
    param($sync)
    $utf8 = [Text.UTF8Encoding]::new($false)
    $stale = 8
    function Send-Response($stream, [int]$code, [string]$type, [byte[]]$body, [hashtable]$extra = @{}) {
        $reason = @{200='OK';204='No Content';400='Bad Request';401='Unauthorized';404='Not Found';409='Conflict';413='Payload Too Large';429='Too Many Requests';500='Internal Server Error'}[$code]
        $head = "HTTP/1.1 $code $reason`r`nContent-Length: $($body.Length)`r`nConnection: close`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`nX-Frame-Options: DENY`r`n"
        if ($type) { $head += "Content-Type: $type`r`n" }
        foreach ($key in $extra.Keys) { $head += "${key}: $($extra[$key])`r`n" }
        $bytes = $utf8.GetBytes($head + "`r`n")
        $stream.Write($bytes, 0, $bytes.Length)
        if ($body.Length) { $stream.Write($body, 0, $body.Length) }
    }
    function Send-Json($stream, [int]$code, $data) {
        $json = if ($data -is [string]) { $data } else { ConvertTo-Json -InputObject $data -Depth 8 -Compress }
        Send-Response $stream $code 'application/json; charset=utf-8' $utf8.GetBytes($json)
    }
    function Update-Commands {
        # Las confirmaciones (_acks) que publica la GUI cierran las órdenes pendientes.
        $ids = @()
        foreach ($ack in @($sync.Acks)) {
            if (-not $ack -or -not $ack.id) { continue }
            $ids += "$($ack.id)"
            $entry = $sync.Commands["$($ack.id)"]
            if ($entry -and $entry.Status -eq 'pending') {
                $entry.Status = if ($ack.ok -eq $true) { 'done' } else { 'failed' }
                $entry.Message = "$($ack.message)".Substring(0, [Math]::Min(500, "$($ack.message)".Length))
            }
        }
        $sync.LastAckIds = $ids
        $now = [datetime]::UtcNow
        foreach ($key in @($sync.Commands.Keys)) {
            $entry = $sync.Commands[$key]
            if ($entry.Status -eq 'pending' -and ($now - $entry.Created).TotalSeconds -gt 300) { $entry.Status = 'failed'; $entry.Message = 'Orden caducada; vuelve a intentarlo' }
            elseif ($entry.Status -ne 'pending' -and ($now - $entry.Created).TotalHours -gt 2) { $sync.Commands.Remove($key) }
        }
    }
    function Test-Same([string]$Left, [string]$Right) {
        # Comparación en tiempo constante (FixedTimeEquals usa Span, no accesible desde PowerShell).
        if ($Left.Length -ne $Right.Length) { return $false }
        $difference = 0
        for ($i = 0; $i -lt $Left.Length; $i++) { $difference = $difference -bor ([int]$Left[$i] -bxor [int]$Right[$i]) }
        return $difference -eq 0
    }
    function Test-Rate([string]$ip) {
        $now = [datetime]::UtcNow
        $hits = @(@($sync.PairHits[$ip]) | Where-Object { $_ -is [datetime] -and ($now - $_).TotalSeconds -lt 60 })
        $sync.PairHits[$ip] = @($hits) + $now
        # Sin esto el registro crece con cada IP que haya intentado emparejar alguna vez.
        foreach ($other in @($sync.PairHits.Keys)) {
            if (-not @(@($sync.PairHits[$other]) | Where-Object { $_ -is [datetime] -and ($now - $_).TotalSeconds -lt 60 }).Count) { $sync.PairHits.Remove($other) }
        }
        return $hits.Count -lt 5
    }
    $listener = $null
    try {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, [int]$sync.Port)
        $listener.Start()
        $sync.Listening = $true; $sync.Error = $null
    } catch {
        $sync.Listening = $false; $sync.Error = "No se pudo abrir el puerto $($sync.Port): $($_.Exception.Message)"
        return
    }
    try {
        while (-not $sync.Stop) {
            try { Update-Commands } catch {}
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 40; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $client.ReceiveTimeout = 5000; $client.SendTimeout = 15000
                $ip = "$(([Net.IPEndPoint]$client.Client.RemoteEndPoint).Address)"
                $stream = $client.GetStream()
                # Cabeceras (máx. 16 KB) y cuerpo por Content-Length (máx. 512 KB).
                # El servidor atiende de una en una: un plazo total evita que un cliente que envía
                # byte a byte (cada lectura dentro de ReceiveTimeout) lo deje bloqueado indefinidamente.
                $deadline = [datetime]::UtcNow.AddSeconds(15)
                $buffer = [IO.MemoryStream]::new(); $chunk = [byte[]]::new(8192); $headerEnd = -1
                while ($headerEnd -lt 0 -and [datetime]::UtcNow -lt $deadline) {
                    $read = $stream.Read($chunk, 0, $chunk.Length)
                    if ($read -le 0) { break }
                    $buffer.Write($chunk, 0, $read)
                    $headerEnd = [Text.Encoding]::ASCII.GetString($buffer.ToArray()).IndexOf("`r`n`r`n")
                    if ($buffer.Length -gt 16384 -and $headerEnd -lt 0) { break }
                }
                if ($headerEnd -lt 0) { Send-Json $stream 400 @{ok=$false;error='Petición inválida'}; continue }
                $raw = $buffer.ToArray()
                $lines = [Text.Encoding]::ASCII.GetString($raw, 0, $headerEnd).Split("`r`n")
                $first = $lines[0].Split(' ')
                if ($first.Count -lt 3) { Send-Json $stream 400 @{ok=$false;error='Petición inválida'}; continue }
                $method = $first[0].ToUpperInvariant(); $target = $first[1]
                $headers = @{}
                foreach ($line in @($lines | Select-Object -Skip 1)) { $colon = $line.IndexOf(':'); if ($colon -gt 0) { $headers[$line.Substring(0, $colon).Trim().ToLowerInvariant()] = $line.Substring($colon + 1).Trim() } }
                $length = 0; [void][int]::TryParse("$($headers['content-length'])", [ref]$length)
                if ($length -gt 512KB) { Send-Json $stream 413 @{ok=$false;error='Orden demasiado grande'}; continue }
                $bodyBytes = [IO.MemoryStream]::new()
                $already = $raw.Length - ($headerEnd + 4)
                if ($already -gt 0) { $bodyBytes.Write($raw, $headerEnd + 4, [Math]::Min($already, $length)) }
                while ($bodyBytes.Length -lt $length -and [datetime]::UtcNow -lt $deadline) {
                    $read = $stream.Read($chunk, 0, [Math]::Min($chunk.Length, $length - $bodyBytes.Length))
                    if ($read -le 0) { break }
                    $bodyBytes.Write($chunk, 0, $read)
                }
                if ($bodyBytes.Length -lt $length) { Send-Json $stream 400 @{ok=$false;error='Petición incompleta'}; continue }
                $body = $utf8.GetString($bodyBytes.ToArray())
                $path = $target.Split('?')[0]
                $query = @{}
                if ($target.Contains('?')) { foreach ($pair in $target.Substring($target.IndexOf('?') + 1).Split('&')) { $kv = $pair.Split('=', 2); if ($kv.Count -eq 2) { $query[[Uri]::UnescapeDataString($kv[0])] = [Uri]::UnescapeDataString($kv[1]) } } }

                if ($method -eq 'GET' -and $path -in @('/', '/index.html')) {
                    Send-Response $stream 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($sync.WebPath)); continue
                }
                if ($path -eq '/favicon.ico') { Send-Response $stream 204 '' ([byte[]]@()); continue }
                if ($method -eq 'POST' -and $path -eq '/api/pair') {
                    if (-not (Test-Rate $ip)) { Send-Json $stream 429 @{ok=$false;error='Demasiados intentos. Espera un minuto.'}; continue }
                    $code = ''; try { $code = "$(($body | ConvertFrom-Json).code)".Trim().ToUpperInvariant() } catch {}
                    $expected = "$($sync.PairCode)"
                    $valid = $expected.Length -eq 8 -and (Test-Same $code $expected)
                    if (-not $valid) {
                        $sync.PairFailures = [int]$sync.PairFailures + 1
                        # Tras 20 fallos el código deja de valer hasta que se genere otro en el PC.
                        if ($sync.PairFailures -ge 20) { $sync.PairCode = '' }
                        Send-Json $stream 401 @{ok=$false;error='Código incorrecto. Míralo en HDZ Studio › Ajustes › Control remoto.'}; continue
                    }
                    $tokenBytes = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
                    $token = [Convert]::ToHexString($tokenBytes).ToLowerInvariant()
                    $sync.Tokens = @(@($sync.Tokens) + $token | Select-Object -Last 5)
                    $sync.TokensChanged = $true; $sync.PairFailures = 0
                    Send-Json $stream 200 @{ok=$true;token=$token}; continue
                }
                if (-not $path.StartsWith('/api/')) { Send-Json $stream 404 @{ok=$false;error='No encontrado'}; continue }
                $presented = "$($headers['x-hdz-panel'])"
                $authorized = $false
                foreach ($token in @($sync.Tokens)) { if ($presented.Length -eq 64 -and (Test-Same $presented "$token")) { $authorized = $true } }
                if (-not $authorized) { Send-Json $stream 401 @{ok=$false;error='Empareja este dispositivo con el código de HDZ Studio.'}; continue }

                $responsive = $sync.EstadoAt -and ([datetime]::UtcNow - $sync.EstadoAt).TotalSeconds -lt $stale
                if ($method -eq 'GET' -and $path -eq '/api/state') {
                    $state = $sync.Estado
                    $data = if ($null -eq $state) { '{}' } elseif ($state -is [string]) { $state } else { ConvertTo-Json -InputObject $state -Depth 8 -Compress }
                    $ts = if ($sync.EstadoAt) { ([DateTimeOffset]$sync.EstadoAt).ToUnixTimeMilliseconds() / 1000 } else { 0 }
                    $json = '{"online":true,"responsive":' + "$([bool]$responsive)".ToLowerInvariant() + ',"ts":' + $ts.ToString([Globalization.CultureInfo]::InvariantCulture) + ',"data":' + $data + '}'
                    Send-Json $stream 200 $json; continue
                }
                if ($method -eq 'POST' -and $path -eq '/api/cmd') {
                    $command = $null; try { $command = $body | ConvertFrom-Json } catch {}
                    if (-not $command -or $command.type -isnot [string]) { Send-Json $stream 400 @{ok=$false;error='Orden inválida'}; continue }
                    if (-not $responsive) { Send-Json $stream 409 @{ok=$false;error='Actualiza o abre HDZ Studio; el programa no está listo.'}; continue }
                    if ("$($command.session)" -ne "$($sync.Session)") { Send-Json $stream 409 @{ok=$false;error='La sesión ha cambiado; recarga el panel.'}; continue }
                    $id = "$($command.requestId)"
                    if ($id -notmatch '^[A-Za-z0-9_-]{16,80}$') { Send-Json $stream 400 @{ok=$false;error='Identificador de orden inválido'}; continue }
                    $existing = $sync.Commands[$id]
                    if ($existing) {
                        if ($existing.Payload -ne $body) { Send-Json $stream 400 @{ok=$false;error='El identificador ya pertenece a otra orden'}; continue }
                        Send-Json $stream 200 @{ok=$true;id=$id}; continue
                    }
                    if (@($sync.Commands.Values | Where-Object Status -eq 'pending').Count -ge 100) { Send-Json $stream 409 @{ok=$false;error='Demasiadas órdenes pendientes; espera a que responda el programa'}; continue }
                    $sync.Commands[$id] = [hashtable]::Synchronized(@{Payload=$body;Status='pending';Message='';Created=[datetime]::UtcNow})
                    $command | Add-Member -NotePropertyName _id -NotePropertyValue $id -Force
                    [void]$sync.Cmds.Enqueue($command)
                    Send-Json $stream 200 @{ok=$true;id=$id}; continue
                }
                if ($method -eq 'GET' -and $path -eq '/api/cmd/status') {
                    $entry = $sync.Commands["$($query.id)"]
                    if (-not $entry) { Send-Json $stream 404 @{ok=$false;error='Orden desconocida'}; continue }
                    Send-Json $stream 200 @{status=$entry.Status;message=$entry.Message}; continue
                }
                if ($method -eq 'GET' -and $path -eq '/api/torrent') {
                    $item = $sync.Torrents["$($query.id)"]
                    if (-not $item) { Send-Json $stream 404 @{ok=$false;error='Torrent no disponible; vuelve a publicarlo desde su archivo original.'}; continue }
                    $ascii = ($item.Name -replace '[^\x20-\x7E]', '_') -replace '["\\]', '_'
                    Send-Response $stream 200 'application/x-bittorrent' $item.Data @{'Content-Disposition'="attachment; filename=`"$ascii`"; filename*=UTF-8''$([Uri]::EscapeDataString($item.Name))"}
                    continue
                }
                Send-Json $stream 404 @{ok=$false;error='No encontrado'}
            } catch {
                $sync.LastError = "$($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)"
                try { Send-Json $client.GetStream() 500 @{ok=$false;error='Error interno del control remoto'} } catch {}
            } finally { $client.Close() }
        }
    } finally {
        $listener.Stop(); $sync.Listening = $false
    }
}

function New-HdzPairingCode {
    # Sin caracteres ambiguos (0/O, 1/I/L) para dictarlo o teclearlo en el móvil.
    $alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
    # GetInt32 reparte uniformemente; «byte % 31» favorecía las 8 primeras letras.
    return -join (1..8 | ForEach-Object { $alphabet[[Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)] })
}

function Get-HdzLanAddresses {
    $addresses = foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($unicast in $nic.GetIPProperties().UnicastAddresses) {
            if ($unicast.Address.AddressFamily -eq 'InterNetwork' -and -not $unicast.Address.ToString().StartsWith('169.254.')) { $unicast.Address.ToString() }
        }
    }
    return @($addresses | Select-Object -Unique)
}

function Get-HdzRemoteSettings([string]$Path) {
    $settings = @{Enabled=$false;Port=8787;Tokens=@()}
    try {
        $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $saved.RemotoActivo) { $settings.Enabled = [bool]$saved.RemotoActivo }
        $port = 0; if ([int]::TryParse("$($saved.RemotoPuerto)", [ref]$port) -and $port -ge 1024 -and $port -le 65535) { $settings.Port = $port }
        if ("$($saved.RemotoTokens)") { $settings.Tokens = @((Unprotect-Texto "$($saved.RemotoTokens)") | ConvertFrom-Json | Where-Object { "$_" -match '^[0-9a-f]{64}$' }) }
    } catch {}
    return $settings
}

function Start-HdzRemoteServer {
    if ($script:agSync -and -not $script:agSync.Stop) { return }
    $script:agSync = [hashtable]::Synchronized(@{
        Estado = $null; EstadoAt = $null; Online = $true; Stop = $false; PushNow = $false; Listening = $false; Error = $null
        Cmds = [Collections.Queue]::Synchronized([Collections.Queue]::new())
        Commands = [hashtable]::Synchronized(@{}); Torrents = [hashtable]::Synchronized(@{}); PairHits = [hashtable]::Synchronized(@{})
        Acks = @(); LastAckIds = @(); Session = $script:agSession
        Port = $script:remoto.Port; Tokens = @($script:remoto.Tokens); TokensChanged = $false
        PairCode = (New-HdzPairingCode); PairFailures = 0
        WebPath = (Join-Path $PSScriptRoot 'web\index.html')
    })
    $runspace = [powershell]::Create()
    [void]$runspace.AddScript($script:remoteServerWorker.ToString()).AddArgument($script:agSync)
    $script:agPSAsync = $runspace.BeginInvoke(); $script:agPS = $runspace
}

function Stop-HdzRemoteServer {
    if ($script:agSync) { $script:agSync.Stop = $true }
    if ($script:agPS) {
        try { [void]$script:agPSAsync.AsyncWaitHandle.WaitOne(2000); $script:agPS.Dispose() } catch {}
        $script:agPS = $null
    }
}

function Register-HdzRemoteTorrent([string]$Path) {
    # Sustituye la subida al relay: el móvil descarga el .torrent original desde este PC.
    if (-not $script:agSync -or -not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $data = [IO.File]::ReadAllBytes($Path)
    if ($data.Length -eq 0 -or $data.Length -gt 16MB -or $data[0] -ne [byte][char]'d') { return $null }
    $id = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $name = Split-Path $Path -Leaf
    $script:agSync.Torrents[$id] = @{Name=$name;Data=$data;Added=[datetime]::UtcNow}
    # Máximo 128 MB en memoria: se descartan los más antiguos.
    while ($script:agSync.Torrents.Count -gt 1 -and ((@($script:agSync.Torrents.Values) | ForEach-Object { $_.Data.Length } | Measure-Object -Sum).Sum -gt 128MB)) {
        $oldest = @($script:agSync.Torrents.GetEnumerator() | Sort-Object { $_.Value.Added } | Select-Object -First 1)[0]
        $script:agSync.Torrents.Remove($oldest.Key)
    }
    return [pscustomobject]@{ok=$true;id=$id;name=$name}
}

function Update-HdzRemotePanel {
    if (-not $script:remotePanel) { return }
    $sync = $script:agSync
    $script:remotePanel.Status.Text = if (-not $script:remoto.Enabled) { 'Desactivado. Actívalo para controlar HDZ Studio desde el móvil o la tablet.' }
        elseif ($sync -and $sync.Error) { $sync.Error }
        elseif ($sync -and $sync.Listening) {
            $urls = @(Get-HdzLanAddresses | ForEach-Object { "http://${_}:$($script:remoto.Port)" })
            $code = if ($sync.PairCode) { $sync.PairCode } else { '(bloqueado: genera otro)' }
            "Abre en el móvil, conectado a la misma red:`n$($urls -join "`n")`n`nCódigo de emparejamiento: $code`nDispositivos emparejados: $(@($sync.Tokens).Count)"
        } else { 'Iniciando…' }
    $script:remotePanel.NewCode.IsEnabled = [bool]($sync -and $sync.Listening)
    $script:remotePanel.Forget.IsEnabled = [bool]($sync -and @($sync.Tokens).Count)
    if ($sync -and $sync.TokensChanged) { $sync.TokensChanged = $false; $script:remoto.Tokens = @($sync.Tokens); Guardar-Ajustes }
}

function Initialize-HdzRemote([string]$SettingsPath) {
    $script:remoto = Get-HdzRemoteSettings $SettingsPath
    $section = New-HdzUiSection 'Control remoto (móvil y tablet)'
    $enable = [Windows.Controls.CheckBox]::new()
    $enable.Content = 'Permitir el control desde otros dispositivos de mi red'; $enable.Foreground = $win.Resources['TextBrush']; $enable.Margin = '12,8,12,4'
    $enable.IsChecked = $script:remoto.Enabled
    $status = [Windows.Controls.TextBlock]::new(); $status.TextWrapping = 'Wrap'; $status.Foreground = $win.Resources['TextBrush']; $status.Margin = '12,6,12,6'
    $buttons = [Windows.Controls.StackPanel]::new(); $buttons.Orientation = 'Horizontal'; $buttons.Margin = '12,4,12,4'
    $newCode = [Windows.Controls.Button]::new(); $newCode.Content = 'Nuevo código'; $newCode.Style = $win.Resources['GhostMini']
    $forget = [Windows.Controls.Button]::new(); $forget.Content = 'Olvidar dispositivos'; $forget.Style = $win.Resources['GhostMini']; $forget.Margin = '10,0,0,0'
    [void]$buttons.Children.Add($newCode); [void]$buttons.Children.Add($forget)
    $note = [Windows.Controls.TextBlock]::new(); $note.TextWrapping = 'Wrap'; $note.Foreground = $win.Resources['SubBrush']; $note.Margin = '12,6,12,8'
    $note.Text = 'Funciona en la red de casa sin servidores externos. La primera vez Windows puede pedir permiso en el cortafuegos: permite solo redes privadas. En la red local el tráfico no va cifrado; para usarlo fuera de casa conecta el móvil y el PC con Tailscale u otra VPN propia y abre la dirección del PC en esa red.'
    foreach ($control in @($enable, $status, $buttons, $note)) { [void]$section.Content.Children.Add($control) }
    [void]$ui.panAjustes.Children.Add($section)
    $script:remotePanel = @{Status=$status;NewCode=$newCode;Forget=$forget}
    $enable.Add_Click({
        param($sender)
        $script:remoto.Enabled = [bool]$sender.IsChecked
        if ($script:remoto.Enabled) { Iniciar-Agente } else { Detener-Agente }
        Guardar-Ajustes; Update-HdzRemotePanel
    })
    $newCode.Add_Click({ if ($script:agSync) { $script:agSync.PairCode = New-HdzPairingCode; $script:agSync.PairFailures = 0 }; Update-HdzRemotePanel })
    $forget.Add_Click({
        if ($script:agSync) { $script:agSync.Tokens = @(); $script:agSync.TokensChanged = $true }
        $script:remoto.Tokens = @(); Guardar-Ajustes; Update-HdzRemotePanel
    })
    $script:remotePanelTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:remotePanelTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:remotePanelTimer.Add_Tick({ Update-HdzRemotePanel })
    $script:remotePanelTimer.Start()
    Update-HdzRemotePanel
}
