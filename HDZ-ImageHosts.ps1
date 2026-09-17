#requires -Version 7.0
# Subida compartida: original directo, preferencia, respaldo y reanudación.
function ConvertTo-HdzImageUrl([string]$Value) {
    $u=$null
    if (-not [Uri]::TryCreate($Value,[UriKind]::Absolute,[ref]$u) -or $u.Scheme -ne 'https' -or $u.UserInfo -or -not $u.IsDefaultPort -or $Value -match '[\[\]\x00-\x20]') { throw 'El servidor devolvió un enlace de imagen no válido.' }
    $allowed=@('imgbox.com','freeimage.host','iili.io','imgbb.com','ibb.co','pixhost.to','pixhost.cc')
    if (-not @($allowed|Where-Object { $u.DnsSafeHost -eq $_ -or $u.DnsSafeHost.EndsWith('.'+$_) }).Count) { throw 'El servidor devolvió un dominio de imagen no reconocido.' }
    return $u.AbsoluteUri
}
# Comprobación local del enlace, sin solicitudes ni descarga de imágenes.
function Assert-HdzDirectImageLink($Item) {
    $Item.Full=ConvertTo-HdzImageUrl "$($Item.Full)"
    $uri=[Uri]$Item.Full
    if($uri.AbsolutePath -notmatch '(?i)\.(png|jpe?g)$' -or ($uri.Host -match '(^|\.)pixhost\.(to|cc)$' -and $uri.AbsolutePath -like '/show/*')) {
        throw 'El servidor no devolvió un enlace directo al original PNG o JPEG.'
    }
}
# Herramientas de diagnóstico explícito; no se usan durante una subida normal.
function Get-HdzImageBytes([string]$Url) {
    $safe=ConvertTo-HdzImageUrl $Url
    $handler=[Net.Http.HttpClientHandler]::new()
    # Validar cada redirección antes de seguirla; no enviar claves a los CDN.
    $handler.AllowAutoRedirect=$false
    $client=[Net.Http.HttpClient]::new($handler); $client.Timeout=[TimeSpan]::FromSeconds(25)
    try {
        for($redirect=0;$redirect -lt 4;$redirect++) {
            $response=$client.GetAsync($safe,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            try {
                if([int]$response.StatusCode -in @(301,302,303,307,308)) {
                    $safe=ConvertTo-HdzImageUrl ([Uri]::new([Uri]$safe,$response.Headers.Location).AbsoluteUri)
                    continue
                }
                [void]$response.EnsureSuccessStatusCode()
                if("$($response.Content.Headers.ContentType.MediaType)" -notmatch '^image/') { throw 'El enlace devuelve una página en lugar de una imagen.' }
                if($response.Content.Headers.ContentLength -gt 70MB) { throw 'Imagen remota demasiado grande.' }
                $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $memory=[IO.MemoryStream]::new(); $cancel=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))
                try {
                    $buffer=[byte[]]::new(65536)
                    while(($n=$stream.ReadAsync($buffer,0,$buffer.Length,$cancel.Token).GetAwaiter().GetResult()) -gt 0) {
                        $memory.Write($buffer,0,$n)
                        if($memory.Length -gt 70MB){throw 'Imagen remota demasiado grande.'}
                    }
                    return ,$memory.ToArray()
                } finally { $cancel.Dispose(); $stream.Dispose(); $memory.Dispose() }
            } finally { $response.Dispose() }
        }
        throw 'Demasiadas redirecciones al comprobar la imagen.'
    } finally { $client.Dispose(); $handler.Dispose() }
}
function Get-HdzImageSize([byte[]]$Bytes) {
    Add-Type -AssemblyName System.Drawing
    $stream=[IO.MemoryStream]::new($Bytes,$false)
    try {
        $image=[Drawing.Image]::FromStream($stream,$false,$true)
        try { return @{Width=$image.Width;Height=$image.Height} } finally { $image.Dispose() }
    } finally { $stream.Dispose() }
}
function Assert-HdzHostedImage($Item,[string]$ExpectedHash) {
    foreach($field in @('Full','Thumb','Page')) { $Item.$field=ConvertTo-HdzImageUrl "$($Item.$field)" }
    $bytes=Get-HdzImageBytes $Item.Full
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash=[Convert]::ToHexString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
    if($hash -ne $ExpectedHash) { throw 'El servidor ha alterado o reducido la imagen original.' }
    $fullSize=Get-HdzImageSize $bytes
    $thumbBytes=if($Item.Thumb -eq $Item.Full){$bytes}else{Get-HdzImageBytes $Item.Thumb}
    $thumbSize=Get-HdzImageSize $thumbBytes
    if($thumbSize.Width -lt [Math]::Min(300,$fullSize.Width) -or [Math]::Abs(($thumbSize.Width/$thumbSize.Height)/($fullSize.Width/$fullSize.Height)-1) -gt .03) {
        throw 'La miniatura es demasiado pequeña o recorta la imagen.'
    }
}
function Invoke-HdzHostUpload([string]$Provider,[string]$Path,$Settings,[string]$Title,$Context) {
    $item=@{Ruta=$Path;Full=$null;Thumb=$null;Page=$null;Host=$Provider;Error=$null}
    switch($Provider) {
        'IMGBOX' {
            $r=Invoke-ImgboxLote @($Path) $Title $Settings.ImgboxUser $Settings.ImgboxPass $Context.Gal $null
            if($r.Aviso){$Context.Notices.Add("$($r.Aviso)")}
            if($r.Gal){$Context.Gal=$r.Gal}
            $first=@($r.Items)[0]
            if(-not $first -or $first.Error){throw "imgbox: $($first.Error)"}
            foreach($k in @('Full','Thumb','Page')){$item[$k]="$($first[$k])"}
        }
        'FREEIMAGE' {
            # Clave pública del servicio, no una credencial del usuario.
            $form=@{key='6d207e02198a847aa98d0a2a901485a5';action='upload';format='json';source=(Get-Item -LiteralPath $Path -Force)}
            $r=Invoke-RestMethod 'https://freeimage.host/api/1/upload' -Method Post -Form $form -TimeoutSec 60 -ErrorAction Stop
            if("$($r.status_code)" -ne '200'){throw "freeimage: estado $($r.status_code)"}
            $item.Full="$($r.image.url)"; $item.Page="$($r.image.url_viewer)"
            $item.Thumb=if($r.image.medium.url){"$($r.image.medium.url)"}else{"$($r.image.thumb.url)"}
        }
        'IMGBB' {
            if(-not $Settings.ImgbbKey){throw 'imgbb: falta la clave API.'}
            # La clave viaja en el cuerpo, no en la URL ni en los mensajes de error.
            $form=@{key="$($Settings.ImgbbKey)";image=(Get-Item -LiteralPath $Path -Force)}
            $r=Invoke-RestMethod 'https://api.imgbb.com/1/upload' -Method Post -Form $form -TimeoutSec 60 -ErrorAction Stop
            if(-not $r.success){throw 'imgbb no aceptó la imagen.'}
            $item.Full="$($r.data.url)"; $item.Page="$($r.data.url_viewer)"
            $item.Thumb=if($r.data.medium.url){"$($r.data.medium.url)"}else{"$($r.data.thumb.url)"}
        }
        'PIXHOST' {
            if((Get-Item -LiteralPath $Path -Force).Length -gt 10MB){throw 'Pixhost admite imágenes de hasta 10 MB; no se reducirá el original.'}
            $form=@{img=(Get-Item -LiteralPath $Path -Force);content_type='0';max_th_size='350';optimize_for_web='0'}
            $r=Invoke-RestMethod 'https://api.pixhost.to/images' -Method Post -Form $form -Headers @{Accept='application/json'} -TimeoutSec 60 -ErrorAction Stop
            $item.Page=ConvertTo-HdzImageUrl "$($r.show_url)"; $item.Thumb="$($r.th_url)"
            # La API publica página y miniatura. Resolver la imagen desde la página,
            # sin inventar direcciones del CDN ni activar optimización con pérdida.
            $html=(Invoke-WebRequest $item.Page -TimeoutSec 25 -ErrorAction Stop).Content
            $tag=[regex]::Match($html,'(?is)<img\b[^>]*\bid=["'']image["''][^>]*>')
            $src=[regex]::Match($tag.Value,'(?i)\bsrc=["'']([^"'']+)["'']')
            if(-not $src.Success){throw 'Pixhost no devolvió el enlace de la imagen original.'}
            $item.Full=ConvertTo-HdzImageUrl ([Net.WebUtility]::HtmlDecode($src.Groups[1].Value))
        }
        default {throw 'Servidor de imágenes desconocido.'}
    }
    return $item
}
function Get-HdzUploadError($ErrorRecord,$Settings) {
    $text="$($ErrorRecord.Exception.Message)"
    try {
        $details=$ErrorRecord.ErrorDetails.Message|ConvertFrom-Json -ErrorAction Stop
        if($details.error.message){$text+=" $($details.error.message)"}
    } catch { }
    foreach($secret in @($Settings.ImgbbKey,$Settings.ImgboxPass)) {if($secret){$text=$text.Replace("$secret",'[OCULTO]')}}
    $text=$text -replace '(?i)((?:key|token|password|secret)=)[^&\s]+','$1[OCULTO]'
    return $text.Substring(0,[Math]::Min($text.Length,300))
}
function Invoke-HdzImageUploadBatch {
    param([string[]]$Paths,[string]$Preferred='FREEIMAGE',$Settings,[string]$Title='HD ZERO',$Sync=$null,$Gallery=$null,[string]$CacheDirectory,[scriptblock]$OnProgress)
    $ErrorActionPreference='Stop'
    if(@($Paths).Count -eq 0){throw 'No hay imágenes seleccionadas para subir.'}
    $providers=@('FREEIMAGE','IMGBOX','PIXHOST','IMGBB')
    if($Preferred -notin $providers){throw 'Servidor preferido no reconocido.'}
    $order=@(@($Preferred)+$providers|Select-Object -Unique)
    if(-not $Settings.ImgbbKey){$order=@($order|Where-Object {$_ -ne 'IMGBB'})}
    if(-not $CacheDirectory){$CacheDirectory=Join-Path $env:APPDATA 'HDZ-Studio\ImageUploads'}
    try {[void][IO.Directory]::CreateDirectory($CacheDirectory)}catch {$CacheDirectory=$null}
    $items=[Collections.Generic.List[object]]::new(); $events=[Collections.Generic.List[string]]::new()
    $context=@{Gal=$Gallery;Notices=[Collections.Generic.List[string]]::new()}; $unavailable=@{}
    if($Sync){$Sync.Done=0;$Sync.Total=@($Paths).Count}
    foreach($path in @($Paths)) {
        $item=$null; $cachePath=$null
        try {
            if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'No se encuentra la captura local; no se enviará otro archivo en su lugar.'}
            $expected=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $keyBytes=[Text.Encoding]::UTF8.GetBytes("$expected|$Preferred|$Title")
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$cacheKey=[Convert]::ToHexString($sha.ComputeHash($keyBytes))}finally{$sha.Dispose()}
            if($CacheDirectory){$cachePath=Join-Path $CacheDirectory ($cacheKey+'.json')}
            if($cachePath -and (Test-Path -LiteralPath $cachePath)) {
                try {
                    if($Sync){$Sync.Fase="Recuperando enlace de captura ya subida $($items.Count+1)/$(@($Paths).Count)…";if($OnProgress){& $OnProgress $Sync}}
                    $saved=Get-Content -LiteralPath $cachePath -Raw|ConvertFrom-Json -AsHashtable
                    Assert-HdzDirectImageLink $saved
                    $item=$saved; $item.Ruta=$path
                } catch {$item=$null}
            }
            if(-not $item) {
                foreach($provider in $order) {
                    if($unavailable.ContainsKey($provider)){continue}
                    for($attempt=1;$attempt -le 2;$attempt++) {
                        if($Sync){$Sync.Fase="Subiendo $($items.Count+1)/$(@($Paths).Count) · $provider (intento $attempt/2)"; if($OnProgress){& $OnProgress $Sync}}
                        try {
                            $candidate=Invoke-HdzHostUpload $provider $path $Settings $Title $context
                            # La API ya aceptó el original. No descargarlo de nuevo ni
                            # exigir miniaturas: solo necesitamos su enlace directo.
                            Assert-HdzDirectImageLink $candidate
                            $item=$candidate
                            if($provider -ne $Preferred){$events.Add("$([IO.Path]::GetFileName($path)): guardada en $provider (preferido: $Preferred).")}
                            break
                        } catch {
                            $reason=Get-HdzUploadError $_ $Settings
                            $events.Add("$provider, intento ${attempt}: $reason")
                            # Errores de petición/autorización/tamaño no mejoran repitiéndolos.
                            if($reason -match '\b(400|401|403|413|429)\b|hasta 10 MB'){break}
                        }
                    }
                    if($item){break}
                    # Un rechazo por tamaño/contenido afecta a esta imagen, no al resto del lote.
                    if($reason -notmatch '\b(400|413)\b|hasta 10 MB'){$unavailable[$provider]=$true}
                    if($Sync){$Sync.Fase="$provider no disponible; probando otro servidor…"}
                }
            }
            if(-not $item){throw 'Ningún servidor disponible devolvió el enlace de la captura original. Las subidas completadas se conservan para reintentar.'}
            if($cachePath) {
                $tmp=$cachePath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
                try {
                    [IO.File]::WriteAllText($tmp,($item|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
                    [IO.File]::Move($tmp,$cachePath,$true)
                } catch {$events.Add('No se pudo guardar la caché de una subida; sus enlaces siguen disponibles en la sesión.')}
                finally {if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}
            }
        } catch {$item=@{Ruta=$path;Full=$null;Thumb=$null;Page=$null;Host=$null;Error=(Get-HdzUploadError $_ $Settings)}}
        $items.Add($item)
        if($Sync){$Sync.Done=$items.Count; if($OnProgress){& $OnProgress $Sync}}
    }
    $failed=@($items|Where-Object {$_.Error})
    $hosts=@($items|Where-Object {$_.Full}|ForEach-Object {$_.Host}|Select-Object -Unique)
    $aviso=if(@($hosts|Where-Object {$_ -ne $Preferred}).Count){"Se usaron servidores alternativos: $($hosts -join ', '). Tu preferencia sigue siendo $Preferred."}else{$null}
    return @{Items=@($items.ToArray());Gal=$context.Gal;Aviso=$aviso;Events=@($events.ToArray())+@($context.Notices.ToArray());Error=$(if($failed.Count){"$($failed.Count) captura(s) pendiente(s). $($failed[0].Error)"}else{$null})}
}
function Invoke-ImgboxLote {
    param($rutas, $galTitulo, $usuario, $clave, $galExistente, $syncProg)
    $ErrorActionPreference = "Stop"
    Add-Type -AssemblyName System.Net.Http | Out-Null
    $ch = New-Object System.Net.CookieContainer
    $hd = New-Object System.Net.Http.HttpClientHandler
    $hd.CookieContainer = $ch
    $hd.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $cli = New-Object System.Net.Http.HttpClient($hd)
    $cli.Timeout = [TimeSpan]::FromSeconds(45)
    $cli.DefaultRequestHeaders.Add("User-Agent","Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
    $cli.DefaultRequestHeaders.Add("Accept","application/json, text/javascript, */*; q=0.01")
    try {
    # No encadenar «.Result.Content.ReadAsStringAsync()»: cuando una tarea HTTP falla,
    # PowerShell puede dejar $null y el error visible acaba siendo el engañoso
    # «You cannot call a method on a null-valued expression». GetAwaiter().GetResult()
    # conserva la causa real (timeout, DNS, TLS, estado HTTP, etc.).
    function _await($task, [string]$contexto) {
        try { return $task.GetAwaiter().GetResult() }
        catch { throw "${contexto}: $($_.Exception.Message)" }
    }
    function _respuestaTexto($task, [string]$contexto) {
        $resp = _await $task $contexto
        if ($null -eq $resp) { throw "${contexto}: imgbox no devolvio respuesta" }
        try {
            $txt = _await ($resp.Content.ReadAsStringAsync()) "$contexto (leyendo respuesta)"
            if (-not $resp.IsSuccessStatusCode) {
                throw "${contexto}: HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase)"
            }
            return $txt
        } finally { $resp.Dispose() }
    }
    function _csrf($html) {
        if ($html -match '<meta[^>]*name="csrf-token"[^>]*content="([^"]+)"') { return $matches[1] }
        if ($html -match '<meta[^>]*content="([^"]+)"[^>]*name="csrf-token"') { return $matches[1] }
        return $null
    }
    $homeHtml = _await ($cli.GetStringAsync("https://imgbox.com/")) "No se pudo conectar con imgbox"
    $csrf = _csrf $homeHtml
    $aviso = $null; $cuentaOk = $false
    if (-not [string]::IsNullOrWhiteSpace($usuario) -and -not [string]::IsNullOrWhiteSpace($clave)) {
        try {
            $lb = "authenticity_token=" + [Uri]::EscapeDataString("$csrf") +
                  "&user%5Blogin%5D=" + [Uri]::EscapeDataString($usuario) +
                  "&user%5Bpassword%5D=" + [Uri]::EscapeDataString($clave)
            $lreq = New-Object System.Net.Http.HttpRequestMessage("Post","https://imgbox.com/login")
            $lreq.Content = New-Object System.Net.Http.StringContent($lb,[System.Text.Encoding]::UTF8,"application/x-www-form-urlencoded")
            $lreq.Headers.Referrer = [Uri]"https://imgbox.com/login"
            $lresp = _await ($cli.SendAsync($lreq)) "Fallo iniciando sesion en imgbox"
            try { [void](_await ($lresp.Content.ReadAsStringAsync()) "Fallo leyendo el inicio de sesion de imgbox") }
            finally { $lresp.Dispose() }
            $chk = _await ($cli.GetStringAsync("https://imgbox.com/")) "Fallo comprobando la sesion de imgbox"
            $c2 = _csrf $chk; if ($c2) { $csrf = $c2 }
            if ($chk -match '/logout') { $cuentaOk = $true }
        } catch {}
        if (-not $cuentaOk) { $aviso = "No se pudo entrar en tu cuenta imgbox; las galerias se suben de forma anonima." }
    }
    $gid = "null"; $gsec = "null"
    if ($galExistente -and $galExistente.Id -and ($galExistente.Titulo -eq $galTitulo)) {
        $gid = $galExistente.Id; $gsec = $galExistente.Secret
    }
    $tokBody = if ($gid -eq "null") { "gallery=true&gallery_title=" + [Uri]::EscapeDataString("$galTitulo") + "&comments_enabled=0" } else { "" }
    $treq = New-Object System.Net.Http.HttpRequestMessage("Post","https://imgbox.com/ajax/token/generate")
    if ($tokBody) { $treq.Content = New-Object System.Net.Http.StringContent($tokBody,[System.Text.Encoding]::UTF8,"application/x-www-form-urlencoded") }
    else { $treq.Content = New-Object System.Net.Http.StringContent("") }
    if ($csrf) { $treq.Headers.Add("X-CSRF-Token","$csrf") }
    $treq.Headers.Add("X-Requested-With","XMLHttpRequest")
    $treq.Headers.Referrer = [Uri]"https://imgbox.com/"
    $tjson = _respuestaTexto ($cli.SendAsync($treq)) "Fallo solicitando el token de subida a imgbox"
    $tok = $tjson | ConvertFrom-Json
    if ($gid -eq "null" -and ($tok.PSObject.Properties.Name -contains 'gallery_id') -and $tok.gallery_id) {
        $gid = "$($tok.gallery_id)"; $gsec = "$($tok.gallery_secret)"
    }
    $items = @()
    foreach ($ruta in @($rutas)) {
        $res = @{ Ruta=$ruta; Full=$null; Thumb=$null; Page=$null; Error=$null }
        try {
            $imgBytes = [System.IO.File]::ReadAllBytes($ruta)
            $nombre = [System.IO.Path]::GetFileName($ruta)
            $ext = ([System.IO.Path]::GetExtension($ruta)).TrimStart('.').ToLower()
            $mime = switch ($ext) { "png" { "image/png" } "gif" { "image/gif" } "webp" { "image/webp" } default { "image/jpeg" } }
            $boundary = "----WebKitFormBoundary" + ([guid]::NewGuid().ToString("N").Substring(0,16))
            $enc = [System.Text.Encoding]::UTF8
            $campos = [ordered]@{ token_id="$($tok.token_id)"; token_secret="$($tok.token_secret)"; content_type="1"; thumbnail_size="350r"; gallery_id="$gid"; gallery_secret="$gsec"; comments_enabled="0" }
            $sb = New-Object System.Text.StringBuilder
            foreach ($k in $campos.Keys) { [void]$sb.Append("--$boundary`r`nContent-Disposition: form-data; name=`"$k`"`r`n`r`n$($campos[$k])`r`n") }
            [void]$sb.Append("--$boundary`r`nContent-Disposition: form-data; name=`"files[]`"; filename=`"$nombre`"`r`nContent-Type: $mime`r`n`r`n")
            $preB = $enc.GetBytes($sb.ToString()); $postB = $enc.GetBytes("`r`n--$boundary--`r`n")
            $body = New-Object byte[] ($preB.Length + $imgBytes.Length + $postB.Length)
            [Array]::Copy($preB,0,$body,0,$preB.Length)
            [Array]::Copy($imgBytes,0,$body,$preB.Length,$imgBytes.Length)
            [Array]::Copy($postB,0,$body,$preB.Length+$imgBytes.Length,$postB.Length)
            $ureq = New-Object System.Net.Http.HttpRequestMessage("Post","https://imgbox.com/upload/process")
            $bc = New-Object System.Net.Http.ByteArrayContent(,$body)
            $bc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]"multipart/form-data; boundary=$boundary"
            $ureq.Content = $bc
            if ($csrf) { $ureq.Headers.Add("X-CSRF-Token","$csrf") }
            $ureq.Headers.Add("X-Requested-With","XMLHttpRequest")
            $ureq.Headers.Referrer = [Uri]"https://imgbox.com/"
            $ubody = _respuestaTexto ($cli.SendAsync($ureq)) "Fallo subiendo '$nombre' a imgbox"
            $f = ($ubody | ConvertFrom-Json).files[0]
            if ($f.error) { $res.Error = "imgbox: $($f.error)" }
            elseif ($f.original_url) { $res.Full = "$($f.original_url)"; $res.Thumb = "$($f.thumbnail_url)"; $res.Page = "$($f.url)" }
            else { $res.Error = "imgbox no devolvio URL" }
        } catch { $res.Error = $_.Exception.Message }
        $items += $res
        if ($syncProg) { $syncProg.Done = $syncProg.Done + 1 }
    }
    return @{ Gal=@{ Id=$gid; Secret=$gsec; Titulo=$galTitulo }; Items=$items; Aviso=$aviso; CuentaOk=$cuentaOk }
    } finally { $cli.Dispose(); $hd.Dispose() }
}
