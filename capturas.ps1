# Capturas manuales de HDZ Studio para todos los vídeos de una carpeta.
# Usa el mismo núcleo que HDZnew.ps1 y el menú contextual.
param(
    [string]$CarpetaVideos = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$rutaBinHDZ = Join-Path $PSScriptRoot 'bin'
if ((Test-Path -LiteralPath $rutaBinHDZ) -and ($env:PATH -notlike "*$rutaBinHDZ*")) {
    $env:PATH = "$rutaBinHDZ;$env:PATH"
}
. (Join-Path $PSScriptRoot 'HDZ-Capturas.ps1')

if (-not (Test-Path -LiteralPath $CarpetaVideos -PathType Container)) {
    Write-Host "No existe la carpeta: $CarpetaVideos" -ForegroundColor Red
    return
}

$videos = @(Get-ChildItem -LiteralPath $CarpetaVideos -File | Where-Object {
    $_.Extension -match '(?i)^\.(mkv|mp4|avi|mov|m4v|ts|m2ts|webm|wmv|flv|iso)$'
})
if ($videos.Count -eq 0) {
    Write-Host 'No se encontraron vídeos en la ruta.' -ForegroundColor Yellow
    return
}

$inputCapturas = Read-Host 'Introduce el número de capturas que quieres por cada vídeo'
$numCapturas = 0
if (-not [int]::TryParse($inputCapturas, [ref]$numCapturas) -or $numCapturas -le 0) {
    Write-Host 'Error: introduce un número entero mayor que cero.' -ForegroundColor Red
    return
}

foreach ($video in $videos) {
    Write-Host "`nProcesando: $($video.Name)" -ForegroundColor Cyan
    try {
        $esHdr = Test-HdzVideoHdr $video.FullName
        $resultado = New-HdzCapturas -ArchivoVideo $video.FullName -NombreFinal $video.Name `
            -NumCapturas $numCapturas -EsHdr $esHdr -DirCapturas $CarpetaVideos
        Write-Host "  Resumen: $($resultado.Capturas.Count) capturas creadas, $($resultado.Fallos) fallidas" -ForegroundColor Yellow
    } catch {
        Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n¡Proceso finalizado!" -ForegroundColor Green
