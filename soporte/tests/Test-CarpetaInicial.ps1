$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# Al arrancar, la carpeta de vídeos debe estar vacía. Antes se rellenaba con la carpeta de
# trabajo (la instalación) y «Añadir temporada» creaba un lote de 2 con una sola temporada elegida.
function Assert($ok,$message){if(-not $ok){throw $message}}
$testRoot=Join-Path $env:TEMP ('hdz_carpeta_inicial_'+[guid]::NewGuid().ToString('N'))
$cwd=Join-Path $testRoot 'instalacion'; $s01=Join-Path $testRoot 'Serie S01'
foreach($d in @($cwd,$s01)){[void][IO.Directory]::CreateDirectory($d)}
$env:HDZ_GUI_TEST='1'
Remove-Item Env:\HDZ_GUI_TEST_DIR,Env:\HDZ_GUI_TEST_TEMPORADAS -ErrorAction SilentlyContinue
Push-Location $cwd
try {
    . (Join-Path $root 'HDZ-GUI.ps1')
    Assert ([string]::IsNullOrWhiteSpace($ui.txtCarpeta.Text)) "Arranca con la carpeta '$($ui.txtCarpeta.Text)'"
    Assert (@(Get-CarpetasEntrada).Count -eq 0) 'Arranca con una carpeta en el lote'
    # Lo mismo que hace «Añadir temporada» al elegir la primera carpeta.
    Set-CarpetasTemporadas (@(Get-CarpetasEntrada) + @($s01))
    $cs=@(Get-CarpetasEntrada)
    Assert ($cs.Count -eq 1 -and $cs[0] -eq $s01) "Lote inesperado: $($cs -join ' | ')"
    Assert ($ui.lblCarpetaDesc.Text -notmatch 'Lote de') "Descripción de lote con una sola temporada: $($ui.lblCarpetaDesc.Text)"
    Write-Host 'OK Test-CarpetaInicial'
} finally {
    Pop-Location
    Remove-Item Env:\HDZ_GUI_TEST -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
