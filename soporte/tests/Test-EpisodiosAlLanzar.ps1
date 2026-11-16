$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# Serie cuyos nombres no traen SxxEyy («Episodio 3#»): si se pulsa Procesar sin «Aplicar numeración
# a la lista», antes se enviaba al motor sin episodios y todos acababan con el mismo nombre + «(2)».
$testRoot=Join-Path $env:TEMP ('hdz_ep_lanzar_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$names=@(1..12 | ForEach-Object { "MAÑANAS DE SÁBADO MINION # Episodio $_# Título HD.mkv" })
$paths=@($names | ForEach-Object {Join-Path $testRoot $_})
& (Join-Path $root 'bin/ffmpeg.exe') -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=1' -f lavfi -i 'sine=d=1' -c:v libx264 -preset ultrafast -c:a aac -shortest $paths[0]
if($LASTEXITCODE -ne 0){throw 'Fixture de episodios falló'}
foreach($p in $paths[1..11]){Copy-Item -LiteralPath $paths[0] -Destination $p}
function Assert($ok,$message){if(-not $ok){throw $message}}
$env:HDZ_GUI_TEST='1';$env:HDZ_GUI_TEST_DIR=$testRoot
try {
    . (Join-Path $root 'HDZ-GUI.ps1')
    Set-VideosElegidos @($paths[0..9])
    $ui.swSerie.IsChecked=$true
    $ui.txtTitulo.Text='Saturday Morning Minions'; $ui.txtAno.Text='2021'
    $ui.txtTemporadaEp.Text='2'; $ui.txtPrimerEp.Text='1'
    Set-ChipValor 'originales' 'INTACTO'; Set-ChipValor 'torrent' 'NO'; Set-ChipValor 'capturasProy' 0
    Assert ($script:episodiosMap.Count -eq 0) 'El mapa de episodios no empieza vacío'

    # 1) Ninguno tiene episodio: se numera solo con los valores del bloque, en orden natural.
    $script:testJobsMontaje=@()
    Iniciar-Montaje 'unico'
    Assert ($script:testJobsMontaje.Count -eq 1) "No se lanzó el montaje: $($ui.lblEstado.Text)"
    $cfg=$script:testJobsMontaje[0].CfgJson | ConvertFrom-Json
    foreach($i in 1..10){
        $nm="MAÑANAS DE SÁBADO MINION # Episodio $i# Título HD.mkv"
        $esperado='S02E{0:D2}' -f $i
        Assert ($cfg.EpisodiosPorArchivo.$nm -eq $esperado) "Episodio $i enviado como '$($cfg.EpisodiosPorArchivo.$nm)' en vez de $esperado"
    }

    # 2) Unos con episodio y otros sin él: no se adivina, se bloquea el lanzamiento.
    $script:gruposLanzados=@{}
    $script:episodiosMap[$names[4]]=''
    $script:testJobsMontaje=@()
    Iniciar-Montaje 'unico'
    Assert ($script:testJobsMontaje.Count -eq 0) 'Se lanzó con un vídeo sin episodio'
    Assert ($ui.lblEstado.Text -match 'no tienen episodio') "Mensaje inesperado: $($ui.lblEstado.Text)"
    Write-Host 'OK Test-EpisodiosAlLanzar'
} finally {
    Remove-Item Env:\HDZ_GUI_TEST,Env:\HDZ_GUI_TEST_DIR -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
