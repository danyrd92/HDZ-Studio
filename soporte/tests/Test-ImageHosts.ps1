# Pruebas aisladas: ningún servidor externo recibe archivos de esta suite.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'HDZ-ImageHosts.ps1')
function Assert($v,$m){if(-not $v){throw $m}}
$testRoot=Join-Path $env:TEMP ('hdz_image_hosts_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$a=Join-Path $testRoot 'a.png';$b=Join-Path $testRoot 'b.png'
& (Join-Path $root 'bin/ffmpeg.exe') -v error -f lavfi -i 'testsrc=size=1280x720' -frames:v 1 $a
Assert ($LASTEXITCODE -eq 0) 'No se pudo crear la imagen de prueba'
& (Join-Path $root 'bin/ffmpeg.exe') -v error -f lavfi -i 'color=c=red:s=1280x720' -frames:v 1 $b
$hash=(Get-FileHash $a).Hash
$settings=@{ImgbbKey='';ImgboxUser='';ImgboxPass='secret-test-password'}
$script:attempts=[Collections.Generic.List[string]]::new();$script:mode='fallback';$script:downloads=0
function Get-HdzImageBytes($Url) {
    $script:downloads++
    throw 'La subida no debe descargar ninguna imagen remota'
}
function Invoke-HdzHostUpload($Provider,$Path,$Settings,$Title,$Context) {
    $leaf=Split-Path $Path -Leaf;$script:attempts.Add("${leaf}:$Provider")
    Assert ($Provider -in @('IMGBOX','IMGBB')) "Se intentó un servidor retirado: $Provider"
    if($script:mode -eq 'allfail'){throw 'HTTP 503 synthetic outage'}
    if($script:mode -eq 'partial' -and $leaf -eq 'b.png'){throw 'HTTP 400 synthetic rejection'}
    if($script:mode -eq 'fallback' -and $Provider -eq 'IMGBOX'){throw 'HTTP 503 synthetic outage'}
    if($script:mode -eq 'transient' -and $script:attempts.Count -eq 1){throw 'HTTP 503 synthetic outage'}
    if($script:mode -eq 'size' -and $Provider -eq 'IMGBOX' -and $leaf -eq 'a.png'){throw 'HTTP 413 synthetic image too large'}
    if($script:mode -eq 'directonly'){return @{Ruta=$Path;Full="https://i.ibb.co/fixture/$leaf";Host=$Provider;Error=$null}}
    if($script:mode -eq 'invalid'){return @{Ruta=$Path;Full='https://imgbox.com/show/123/picture';Host=$Provider}}
    if($script:mode -eq 'retired'){return @{Ruta=$Path;Full='https://iili.io/picture.png';Host=$Provider}}
    return @{Ruta=$Path;Full="https://images2.imgbox.com/$leaf";Thumb="https://thumbs2.imgbox.com/thumb-$leaf";Page="https://imgbox.com/$leaf";Host=$Provider;Error=$null}
}
$cache=Join-Path $testRoot 'cache';$sync=@{}
# Solo imgbox e imgbb; sin clave de imgbb no hay respaldo posible.
$script:mode='allfail'
$r=Invoke-HdzImageUploadBatch @($a,$b) IMGBOX $settings 'outage' @{} -CacheDirectory $cache
Assert ($r.Error -and @($r.Items|Where-Object Full).Count -eq 0 -and $script:attempts.Count -eq 2) 'Éxito falso o reintentos sin límite'
Assert (@($script:attempts|Where-Object {$_ -like '*IMGBB'}).Count -eq 0) 'Intentó imgbb sin clave'
# Respaldo a imgbb (con clave) si imgbox falla; una preferencia antigua (freeimage) empieza por imgbox.
$settings.ImgbbKey='synthetic-key';$script:attempts.Clear();$script:mode='fallback'
$r=Invoke-HdzImageUploadBatch @($a,$b) FREEIMAGE $settings 'batch' $sync -CacheDirectory $cache
Assert (-not $r.Error -and $r.Items.Count -eq 2) 'No recuperó el lote por respaldo'
Assert ($r.Items[0].Host -eq 'IMGBB' -and $r.Items[1].Ruta -eq $b) 'Se perdió el orden o servidor real'
Assert ($script:attempts[0] -eq 'a.png:IMGBOX') 'Una preferencia retirada no pasó a imgbox'
Assert ($r.Aviso -and $sync.Done -eq 2) 'No informó del respaldo/progreso'
$script:attempts.Clear();$script:mode='allfail'
$again=Invoke-HdzImageUploadBatch @($a,$b) IMGBOX $settings 'batch' @{} -CacheDirectory $cache
Assert (-not $again.Error -and $script:attempts.Count -eq 0) 'Volvió a subir imágenes completadas'
$script:mode='partial';$settings.ImgbbKey=''
$partial=Invoke-HdzImageUploadBatch @($a,$b) IMGBOX $settings 'partial' @{} -CacheDirectory $cache
Assert ($partial.Error -and $partial.Items[0].Full -and $partial.Items[1].Error) 'Perdió un éxito parcial'
$script:attempts.Clear();$script:mode='ok'
$resume=Invoke-HdzImageUploadBatch @($a,$b) IMGBOX $settings 'partial' @{} -CacheDirectory $cache
Assert (-not $resume.Error -and $script:attempts.Count -eq 1 -and $script:attempts[0] -eq 'b.png:IMGBOX') 'Reintento duplicó éxitos o cambió índices'
$script:attempts.Clear();$script:mode='transient'
$r=Invoke-HdzImageUploadBatch @($a) IMGBOX $settings 'retry' @{} -CacheDirectory $cache
Assert (-not $r.Error -and $script:attempts.Count -eq 2 -and $r.Items[0].Host -eq 'IMGBOX') 'No reintentó fallo transitorio'
$script:mode='size';$script:attempts.Clear();$settings.ImgbbKey='synthetic-key'
$r=Invoke-HdzImageUploadBatch @($a,$b) IMGBOX $settings 'size' @{} -CacheDirectory $cache
Assert (-not $r.Error -and $r.Items[0].Host -eq 'IMGBB' -and $r.Items[1].Host -eq 'IMGBOX') 'Un rechazo de una imagen deshabilitó el servidor para las demás'
$script:mode='directonly';$script:attempts.Clear();$settings.ImgbbKey='synthetic-key'
$ten=@(1..10|ForEach-Object {$file=Join-Path $testRoot "capture-$_.png";[IO.File]::WriteAllText($file,"mock-upload-fixture-$_");$file})
$r=Invoke-HdzImageUploadBatch $ten IMGBB $settings 'ten-originals' @{} -CacheDirectory $cache
Assert (-not $r.Error -and $r.Items.Count -eq 10) 'Rechazó originales sin miniatura ni página'
Assert ($script:attempts.Count -eq 10 -and @($r.Items|Where-Object Host -ne 'IMGBB').Count -eq 0) 'Duplicó subidas o cambió de host después de éxitos'
Assert ($script:downloads -eq 0) 'Volvió a descargar imágenes para verificarlas'
$script:mode='allfail';$script:attempts.Clear()
$again=Invoke-HdzImageUploadBatch $ten IMGBB $settings 'ten-originals' @{} -CacheDirectory $cache
Assert (-not $again.Error -and $script:attempts.Count -eq 0 -and $script:downloads -eq 0) 'La caché provoca nuevas subidas o descargas'
$script:mode='invalid'
$r=Invoke-HdzImageUploadBatch @($a) IMGBOX $settings 'invalid-original' @{} -CacheDirectory $cache
Assert ($r.Error) 'Aceptó una página de visor como imagen directa'
$script:mode='retired'
$r=Invoke-HdzImageUploadBatch @($a) IMGBOX $settings 'retired-host' @{} -CacheDirectory $cache
Assert ($r.Error) 'Aceptó un enlace de iili.io (freeimage), que el proxy del tracker no muestra'
foreach($url in @('https://iili.io/a.png','https://img100.pixhost.to/images/1/a.png','http://imgbox.com/a','https://localhost/a','https://imgbox.com.evil.test/a','https://user:pass@imgbox.com/a','https://imgbox.com/a[img]')){
    $failed=$false;try{ConvertTo-HdzImageUrl $url|Out-Null}catch{$failed=$true};Assert $failed 'Aceptó URL insegura'
}
Assert ((Get-FileHash $a).Hash -eq $hash) 'Modificó el original'
Write-Host "IMAGE_HOSTS_REGRESSION_OK: $testRoot"
