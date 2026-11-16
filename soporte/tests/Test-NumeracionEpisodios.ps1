$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:HDZ_GUI_TEST='1'
function Assert($ok,$message){if(-not $ok){throw $message}}
try {
    . (Join-Path $root 'HDZ-GUI.ps1')
    # Nombres sin SxxEyy y con «Episodio 10#»: en orden de texto el 10 caía justo detrás del 1.
    $nombres=@(10,3,1,9,2,8,4,7,5,6 | ForEach-Object { "MAÑANAS DE SÁBADO MINION # Episodio $_# Título HD.mkv" })
    $script:gruposLote=@($nombres | ForEach-Object {@{Principal=$_;Miembros=@($_)}})
    $script:seleccion=@{}; $script:episodiosMap=@{}; $script:epTextboxes=@{}
    $ui.txtTemporadaEp.Text='1'; $ui.txtPrimerEp.Text='1'; $ui.cmbEpsPorVideo.SelectedIndex=0
    Aplicar-NumeracionEpisodios
    foreach($i in 1..10){
        $nm="MAÑANAS DE SÁBADO MINION # Episodio $i# Título HD.mkv"
        $esperado='S01E{0:D2}' -f $i
        Assert ($script:episodiosMap[$nm] -eq $esperado) "Episodio $i numerado como $($script:episodiosMap[$nm]) en vez de $esperado"
    }
    Write-Host 'OK Test-NumeracionEpisodios'
} finally { Remove-Item Env:\HDZ_GUI_TEST -ErrorAction SilentlyContinue }
