$ErrorActionPreference='Stop'
# Los tests nunca escriben en el historial real (%APPDATA%\HDZ-Studio\Historial).
$historyTestRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($value,$message){if(-not $value){throw $message}}
. (Join-Path $historyTestRoot 'HDZ-History.ps1')
$real=[IO.Path]::GetFullPath((Join-Path $env:APPDATA 'HDZ-Studio\Historial'))
$temp=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
$saved=@{GUI=$env:HDZ_GUI_TEST;DIR=$env:HDZ_HISTORY_TEST_DIR}
$creadas=@()
try {
    # Carpetas de prueba con cualquier nombre dentro de %TEMP% (antes solo hdz_test_*).
    foreach($nombre in 'hdz_bitrate_x','hdz_subtypes_x','hdz_test_x'){
        $dir=Join-Path $temp ($nombre+[guid]::NewGuid().ToString('N')+'\history');$creadas+=Split-Path $dir -Parent
        $env:HDZ_GUI_TEST='1';$env:HDZ_HISTORY_TEST_DIR=$dir
        Assert ((Get-HdzHistoryDirectory) -eq $dir) "No usó la carpeta de prueba $nombre"
    }
    # Fuera de %TEMP% no se acepta; en modo prueba cae en una carpeta temporal, nunca en la real.
    $env:HDZ_HISTORY_TEST_DIR='C:\Windows\hdz-historial'
    $d=[IO.Path]::GetFullPath((Get-HdzHistoryDirectory))
    Assert ($d -ne $real -and $d.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) "Ruta fuera de TEMP en prueba: $d"
    # Modo prueba sin carpeta: tampoco la real.
    Remove-Item Env:HDZ_HISTORY_TEST_DIR
    $d=[IO.Path]::GetFullPath((Get-HdzHistoryDirectory))
    Assert ($d -ne $real -and $d.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) "Modo prueba sin carpeta usó: $d"
    # Uso normal (sin modo prueba): el historial real.
    Remove-Item Env:HDZ_GUI_TEST
    Assert ([IO.Path]::GetFullPath((Get-HdzHistoryDirectory)) -eq $real) 'El uso normal no va al historial real'
    Write-Host 'HISTORY_ISOLATION_OK: carpetas de prueba en TEMP con cualquier nombre, rutas ajenas rechazadas y nunca el historial real en pruebas.'
} finally {
    if($null -ne $saved.GUI){$env:HDZ_GUI_TEST=$saved.GUI}else{Remove-Item Env:HDZ_GUI_TEST -ErrorAction SilentlyContinue}
    if($null -ne $saved.DIR){$env:HDZ_HISTORY_TEST_DIR=$saved.DIR}else{Remove-Item Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue}
    foreach($c in $creadas){Remove-Item -LiteralPath $c -Recurse -Force -ErrorAction SilentlyContinue}
}
