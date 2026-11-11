$ErrorActionPreference='Stop'
# Reproduce el cruce de capturas de ¡A por Jiro! E05/E06 (2026-11-11):
#  1) un torrent que termina con OTRA pestaña activa se cargaba en esa pestaña;
#  2) cambiar de pestaña mientras se cargaban miniaturas (PushFrame) dejaba la rejilla en la pestaña equivocada.
$tabTestRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($value,$message){if(-not $value){throw $message}}
$env:HDZ_GUI_TEST='1'
$temp=Join-Path $env:TEMP ('hdz_tab_crossing_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    . (Join-Path $tabTestRoot 'HDZ-GUI.ps1')
    $capsA=@(1..3 | ForEach-Object {$p=Join-Path $temp ("E05_cap_$_.png");Copy-Item (Join-Path $tabTestRoot 'HDZStudio.png') $p;$p})
    $capsB=@(1..3 | ForEach-Object {$p=Join-Path $temp ("E07_cap_$_.png");Copy-Item (Join-Path $tabTestRoot 'HDZStudio.png') $p;$p})

    # --- Caso 1: torrent creado con la pestaña de origen en segundo plano ---
    $ui.upTitulo.Text='E07';Construir-Capturas $capsB;$ui.txtTorrentSubir.Text='C:\x\E07.torrent'
    $idE07=$script:subidaTabId
    Nueva-Tab;$ui.upTitulo.Text='E05';Construir-Capturas $capsA
    $idE05=$script:subidaTabId
    $script:torTabInicio=$idE05
    Cambiar-Tab 0
    Assert ($script:subidaTabId -eq $idE07) 'No volvió a la pestaña E07'
    Aplicar-TorrentCreadoEnPestana $script:torTabInicio 'C:\x\E05.torrent' $null @()
    Assert ($ui.txtTorrentSubir.Text -eq 'C:\x\E07.torrent') 'El torrent de E05 pisó la pestaña E07 visible'
    Assert (@($script:capRows | Where-Object {$_.Ruta -like '*E07_cap*'}).Count -eq 3) 'La rejilla de E07 cambió'
    Assert ($script:tabs[1].TorrentRuta -eq 'C:\x\E05.torrent') 'La pestaña E05 no recibió su torrent'
    Cambiar-Tab 1
    Assert ($ui.txtTorrentSubir.Text -eq 'C:\x\E05.torrent' -and @($script:capRows | Where-Object {$_.Ruta -like '*E05_cap*'}).Count -eq 3) 'Al volver a E05 no tiene su torrent y sus capturas'

    # --- Caso 1b: volver a una pestaña ya vista no relee las miniaturas (cambio inmediato) ---
    $orig=${function:Invoke-HdzBackground};$cnt=@{n=0}
    Set-Item Function:Invoke-HdzBackground ({param($Work,$Arguments) $cnt.n++; & $orig $Work $Arguments}.GetNewClosure())
    $reloj=[Diagnostics.Stopwatch]::StartNew()
    Cambiar-Tab 0;Cambiar-Tab 1;Cambiar-Tab 0;Cambiar-Tab 1
    $reloj.Stop()
    Assert ($cnt.n -eq 0) "Cambiar de pestaña volvió a cargar miniaturas ($($cnt.n) veces)"
    Assert (@($script:capRows | Where-Object {$_.Ruta -like '*E05_cap*'}).Count -eq 3) 'Al alternar pestañas E05 perdió capturas'
    Write-Host "Cuatro cambios de pestaña: $($reloj.ElapsedMilliseconds) ms"
    Olvidar-PrevisualizacionesCaptura @($capsA[0])
    Cambiar-Tab 0;Cambiar-Tab 1
    Assert ($cnt.n -eq 1) 'Una captura regenerada no volvió a leer su miniatura'
    Set-Item Function:Invoke-HdzBackground $orig

    # --- Caso 2: clic de pestaña mientras hay una operación en segundo plano ---
    $antes=$script:subidaTabId
    $script:networkBusy=$true
    try {
        Cambiar-Tab 0
        Assert ($script:subidaTabId -eq $antes -and $script:tabActual -eq 1) 'Cambió de pestaña con una operación en curso'
        $n=@($script:tabs).Count;Nueva-Tab;Assert (@($script:tabs).Count -eq $n) 'Creó pestaña con una operación en curso'
        Cerrar-Tab 0;Assert (@($script:tabs).Count -eq $n) 'Cerró pestaña con una operación en curso'
    } finally {$script:networkBusy=$false}
    Cambiar-Tab 0
    Assert ($script:subidaTabId -eq $idE07) 'Tras terminar la operación no deja cambiar de pestaña'
    Assert (@($script:capRows | Where-Object {$_.Ruta -like '*E07_cap*'}).Count -eq 3) 'E07 perdió sus capturas'
    Write-Host 'TAB_CROSSING_OK: torrent a su pestaña de origen y pestañas bloqueadas durante operaciones en curso.'
} finally {
    Remove-Item Env:HDZ_GUI_TEST -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
