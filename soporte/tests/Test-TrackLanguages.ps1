# Correcciones por pista: GUI/web -> configuración -> MKV, sin usar medios reales.
$ErrorActionPreference = 'Stop'
$languageAppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$languageTestRoot = Join-Path $env:TEMP ('hdz_languages_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($languageTestRoot)
function Assert($ok, $msg) { if (-not $ok) { throw $msg } }
$fixtureDir = Join-Path $languageTestRoot 'fixtures'
[void][IO.Directory]::CreateDirectory($fixtureDir)
$srt = Join-Path $fixtureDir 'input.eng.srt'
[IO.File]::WriteAllText($srt, "1`n00:00:00,000 --> 00:00:01,500`nLanguage test`n")
$source = Join-Path $languageTestRoot 'Language.Test.2026.mkv'
& (Join-Path $languageAppRoot 'bin/ffmpeg.exe') -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=2' -f lavfi -i 'sine=frequency=440:duration=2' -i $srt -map 0:v -map 1:a -map 1:a -map 1:a -map 2:s -c:v libx264 -preset ultrafast -c:a aac -c:s srt -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa -metadata:s:a:1 title='Latino incorrecto' -metadata:s:a:2 language=eng -metadata:s:s:0 language=eng -shortest $source
Assert ($LASTEXITCODE -eq 0) 'No se pudo generar la fuente sintética'
$sourceHash = (Get-FileHash -LiteralPath $source).Hash
$env:HDZ_GUI_TEST = '1'; $env:HDZ_HISTORY_TEST_DIR = Join-Path $languageTestRoot 'history'
try {
    . (Join-Path $languageAppRoot 'HDZ-GUI.ps1')
    $ui.txtCarpeta.Text = $languageTestRoot
    $rows = @(& $scanWorker @($source))
    Assert (-not $rows[0].Error) "Análisis: $($rows[0].Error)"
    $script:ultimoScan = $rows
    $script:seleccion = @{ $rows[0].Nombre = $true }
    Construir-Adaptacion $rows
    Assert ($script:undRows.Count -eq 4) 'No se muestran todas las pistas con idioma definido'
    $audio = @($script:undRows | Where-Object Tipo -eq Audio)
    $sub = @($script:undRows | Where-Object Tipo -eq Sub)[0]
    # Dos pistas del mismo archivo/código reciben idiomas distintos. Otra queda automática.
    Set-ComboValor $audio[0].Combo 'tha'
    Set-ComboValor $audio[1].Combo 'es'
    Aplicar-ComandoAgente ([pscustomobject]@{type='set_und';archivo=$sub.Archivo;id=$sub.Id;tipo='Sub';value='es';_id='languages-web-1';session=$script:agSession})
    Actualizar-IdiomasManuales
    Assert ((Get-IdiomaPistaGui $rows[0].Audios[0] 'Audio') -eq 'tha') 'No se aplica el idioma de audio'
    Assert ((Get-IdiomaPistaGui $rows[0].Audios[1] 'Audio') -eq 'es') 'El título Latino prevalece sobre la corrección manual'
    Assert ((Get-IdiomaPistaGui $rows[0].Audios[2] 'Audio') -eq 'eng') 'Se cambió otra pista por error'
    $state = Componer-EstadoAgente | ConvertFrom-Json
    Assert ($state.undAudioSubs.Count -eq 4) 'La web no recibe todas las pistas'
    Assert (@($state.undAudioSubs | Where-Object valor -eq 'tha').Count -eq 1) 'La web no conserva la elección'
    # Restablecer una pista no elimina las correcciones de las otras.
    $first = @($script:undRows | Where-Object { $_.Tipo -eq 'Audio' -and $_.Id -eq $audio[0].Id })[0]
    Set-ComboValor $first.Combo 'AUTO'
    Actualizar-IdiomasManuales
    Assert ((Get-IdiomaPistaGui $rows[0].Audios[0] 'Audio') -eq 'eng') 'Automático no restaura el idioma original'
    $first = @($script:undRows | Where-Object { $_.Tipo -eq 'Audio' -and $_.Id -eq $audio[0].Id })[0]
    Set-ComboValor $first.Combo 'tha'
    Actualizar-IdiomasManuales
    $ui.txtTitulo.Text = 'Language Audit'; $ui.txtAno.Text = '2026'
    $ui.swSerie.IsChecked = $false
    Set-ChipValor 'originales' 'INTACTO'; Set-ChipValor 'torrent' 'NO'; Set-ChipValor 'capturasProy' 0
    Set-ChipValor 'filtro' 'TODOS'
    $ui.cfgCarpetaProcesados.Text = ''; $ui.cfgCarpetaTorrent.Text = ''; $ui.txtAnnounce.Text = ''
    $ui.txtSalidaArchivo.Text = Join-Path $languageTestRoot 'output'
    $script:testJobsMontaje = @()
    Iniciar-Montaje 'unico'
    Assert ($script:testJobsMontaje.Count -eq 1) "No se creó el trabajo: $($ui.lblEstado.Text)"
    $job = $script:testJobsMontaje[0]
    $cfg = $job.CfgJson | ConvertFrom-Json
    Assert ($cfg.IdiomasUndPistas.Count -eq 3) 'La configuración altera pistas automáticas o pierde correcciones'
    $stdout = Join-Path $languageTestRoot 'stdout.txt'; $stderr = Join-Path $languageTestRoot 'stderr.txt'
    $p = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-File',('"'+$job.LauncherPath+'"')) -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (-not $p.WaitForExit(60000)) { $p.Kill($true); throw "Montaje bloqueado: $languageTestRoot" }
    Assert ($p.ExitCode -eq 0) "Motor falló: $languageTestRoot"
    $out = @(Get-ChildItem -LiteralPath (Join-Path $languageTestRoot 'output') -Filter '*.mkv')[0]
    Assert ($null -ne $out) 'Falta el resultado'
    $probe = & (Join-Path $languageAppRoot 'bin/ffprobe.exe') -v error -show_streams -of json $out.FullName | Out-String | ConvertFrom-Json
    $a = @($probe.streams | Where-Object codec_type -eq audio)
    $s = @($probe.streams | Where-Object codec_type -eq subtitle)
    Assert ($a.Count -eq 3 -and $s.Count -eq 1) 'Se perdieron pistas'
    Assert (@($a | Where-Object { $_.tags.language -eq 'tha' }).Count -eq 1) 'Falta audio tailandés corregido'
    Assert (@($a | Where-Object { $_.tags.language -eq 'spa' -and $_.tags.title -match 'Castellano' }).Count -eq 1) 'El castellano quedó como latino'
    Assert (@($a | Where-Object { $_.tags.language -eq 'eng' }).Count -eq 1) 'No se conservó el audio automático'
    Assert ($s[0].tags.language -eq 'spa') 'No se corrigió el subtítulo'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $sourceHash) 'El original fue modificado'
    Reset-Todo
    Assert ($script:idiomasManuales.Count -eq 0) 'Las correcciones sobreviven a Empezar de Zero'
    Write-Host "TRACK_LANGUAGES_END_TO_END_OK: $languageTestRoot"
} finally {
    Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue
}
