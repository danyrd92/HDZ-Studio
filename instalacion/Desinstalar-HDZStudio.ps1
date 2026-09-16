# Desinstalar-HDZStudio.ps1 — quita accesos directos, el lanzador .vbs y (opcional) bin\.
# NO desinstala PowerShell 7 ni borra los scripts del programa ni tus ajustes/credenciales.
param([switch]$Interactivo, [switch]$BorrarHerramientas)
$ErrorActionPreference = "Stop"
$instalDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $instalDir
if (-not (Test-Path -LiteralPath (Join-Path $appRoot "HDZ-GUI.ps1"))) { throw 'No se reconoce la instalación. No se borra nada.' }

$instMenuCapturas = Join-Path $appRoot "instalacion\Instalar-menu-capturas.ps1"
if (Test-Path -LiteralPath $instMenuCapturas) {
    try { & $instMenuCapturas -Desinstalar } catch {}
}

Write-Host "Quitando accesos directos y lanzador…" -ForegroundColor Cyan
Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath("Desktop")) "HDZ Studio.lnk") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath("Programs")) "HDZ Studio.lnk") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $appRoot "HDZ Studio.vbs") -Force -ErrorAction SilentlyContinue

$bin = Join-Path $appRoot "bin"
if ((Test-Path -LiteralPath $bin) -and ($Interactivo -or $BorrarHerramientas)) {
    $r = if ($BorrarHerramientas) { 's' } else { Read-Host "¿Borrar tambien las herramientas descargadas (bin\)? [s/N]" }
    if ($r -eq "s" -or $r -eq "S") { Remove-Item -LiteralPath $bin -Recurse -Force; Write-Host "  bin\ borrada." -ForegroundColor Green }
    else { Write-Host "  Se conserva bin\." -ForegroundColor Gray }
}
Write-Host "Hecho. (PowerShell 7, los scripts y tus ajustes NO se han tocado.)" -ForegroundColor Green
