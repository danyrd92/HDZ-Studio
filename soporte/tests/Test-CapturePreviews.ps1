$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'HDZ-Async.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}
$testRoot=Join-Path $env:TEMP ('hdz_test_previews_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$image=Join-Path $testRoot 'capture.png';$missing=Join-Path $testRoot 'missing.png'
& (Join-Path $root 'bin/ffmpeg.exe') -v error -f lavfi -i 'testsrc=size=1280x720' -frames:v 1 $image
if($LASTEXITCODE -ne 0){throw 'Fixture fallida'}
$hash=(Get-FileHash $image).Hash
$sync=@{Done=0}
$cache=Get-HdzCapturePreviews @($image,$missing) @{} $sync
Assert ($sync.Done -eq 2 -and $cache.Count -eq 2) 'No cuenta imágenes ausentes'
Assert ($cache[$image].Bitmap.IsFrozen -and $cache[$image].Bitmap.PixelWidth -eq 760) 'Bitmap no transferible al hilo UI o tamaño incorrecto'
Assert ($cache[$image].Thumb.StartsWith('data:image/jpeg;base64,') -and $cache[$missing].Error) 'Miniatura remota o error ausente'
$again=Get-HdzCapturePreviews @($image) $cache
Assert ([object]::ReferenceEquals($again[$image].Bitmap,$cache[$image].Bitmap)) 'No reutiliza una imagen sin cambios'
& (Join-Path $root 'bin/ffmpeg.exe') -y -v error -f lavfi -i 'color=c=red:s=1280x720' -frames:v 1 $image
$changed=Get-HdzCapturePreviews @($image) $cache
Assert ($changed[$image].Stamp -ne $cache[$image].Stamp -and $changed[$image].Thumb -ne $cache[$image].Thumb) 'Muestra la miniatura antigua tras reemplazar el archivo'
# La lectura/decodificación no cambia ni retiene un bloqueo en el PNG.
$hash=(Get-FileHash $image).Hash
$null=Get-HdzCapturePreviews @($image)
Assert ((Get-FileHash $image).Hash -eq $hash) 'La miniatura modificó el original'
$stream=[IO.File]::Open($image,'Open','ReadWrite','None');$stream.Dispose()
Write-Host "CAPTURE_PREVIEWS_REGRESSION_OK: $testRoot"
