# Normas de nombrado HDZ: códec en Full/Remux, VC-1/MPEG-2, etiqueta de idioma (VOSE/Latino)
# y modo «tal cual» (sin remux) de punta a punta con vídeos sintéticos.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($ok,$message){if(-not $ok){throw $message}}

# --- Funciones del motor, cargadas sin ejecutarlo ---
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'HDZnew.ps1'),[ref]$tokens,[ref]$errors)
. (Join-Path $root 'HDZ-Core.ps1')
$dictNode=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and "$($n.Left)" -eq '$dictIdiomas'},$true)
. ([scriptblock]::Create($dictNode.Extent.Text))
foreach($name in @('Get-LanguageName','Get-LanguageCode','Get-PesoIdioma','Format-Audios','Get-AudioParaNombreHdz','Get-EtiquetaIdiomaAuto','Resolve-EtiquetaIdioma','Get-CodecTagHdz','Get-NombreFinalHdz')){
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Assert $node "Falta la función $name"
    . ([scriptblock]::Create($node.Extent.Text))
}

# --- Los 10 ejemplos acordados ---
$casos=@(
    @{B='Dune Parte Dos (2024)';T='FISICO';F='UHDRemux';R='2160p';A='TrueHD 7.1 Atmos';H='DV HDR10';C='265';S=$true;L='';E='Dune Parte Dos (2024) UHDRemux 2160p DV HDR10 HEVC TrueHD 7.1 Atmos-HDZ.mkv'},
    @{B='Gladiator (2000)';T='FISICO';F='BDRemux';R='1080p';A='DTS-HD MA 5.1';H='';C='264';S=$true;L='';E='Gladiator (2000) BDRemux 1080p AVC DTS-HD MA 5.1-HDZ.mkv'},
    @{B='Oppenheimer (2023)';T='FISICO';F='UHDFull';R='2160p';A='DTS-HD MA 5.1';H='HDR10';C='265';S=$true;L='';E='Oppenheimer (2023) UHDFull 2160p HDR10 HEVC DTS-HD MA 5.1-HDZ.mkv'},
    @{B='El Padrino (1972)';T='FISICO';F='BDFull';R='1080p';A='DTS-HD MA 5.1';H='';C='264';S=$false;L='';E='El Padrino (1972) BDFull 1080p AVC DTS-HD MA 5.1.mkv'},
    @{B='Parásitos (2019)';T='FISICO';F='BDRemux';R='1080p';A='DTS-HD MA 5.1';H='';C='264';S=$true;L='VOSE';E='Parásitos (2019) BDRemux 1080p VOSE AVC DTS-HD MA 5.1-HDZ.mkv'},
    @{B='Blade Runner (1982)';X='Final Cut';T='FISICO';F='UHDRemux';R='2160p';A='DTS-HD MA 5.1';H='HDR10';C='265';S=$true;L='';E='Blade Runner (1982) Final Cut UHDRemux 2160p HDR10 HEVC DTS-HD MA 5.1-HDZ.mkv'},
    @{B='Interstellar (2014)';T='FISICO';F='UHDRip';R='2160p';A='DD+ 5.1';H='HDR10';C='265';S=$true;L='';E='Interstellar (2014) UHDRip 2160p HDR10 x265 DD+ 5.1-HDZ.mkv'},
    @{B='Drive My Car (2021)';T='FISICO';F='MHD';R='1080p';A='AAC 2.0';H='';C='264';S=$true;L='VOSE';E='Drive My Car (2021) MHD 1080p VOSE x264 AAC 2.0-HDZ.mkv'},
    @{B='Akira (1988)';T='FISICO';F='Remastered';R='2160p';A='TrueHD 5.1';H='HDR10';C='265';S=$true;L='VOSE';E='Akira (1988) Remastered 2160p HDR10 VOSE HEVC TrueHD 5.1-HDZ.mkv'},
    @{B='The Bear (2022) S03E01';T='WEB';F='DSNP';W='WEB-DL';R='2160p';A='DD+ 5.1';H='HDR10';C='265';S=$true;L='VOSE';E='The Bear (2022) S03E01 2160p DSNP WEB-DL DD+ 5.1 HDR10 VOSE H.265-HDZ.mkv'},
    # Extra: Blu-ray antiguo en VC-1 / MPEG-2, Latino, y otra extensión (tal cual).
    @{B='Alien (1979)';T='FISICO';F='BDRemux';R='1080p';A='DTS-HD MA 5.1';H='';C='VC1';S=$true;L='Latino';E='Alien (1979) BDRemux 1080p Latino VC-1 DTS-HD MA 5.1-HDZ.mkv'},
    @{B='Ben-Hur (1959)';T='FISICO';F='BDFull';R='1080p';A='DTS-HD MA 5.1';H='';C='MPEG2';S=$true;L='';X2='.m2ts';E='Ben-Hur (1959) BDFull 1080p MPEG-2 DTS-HD MA 5.1-HDZ.m2ts'},
    @{B='Serie (2020) S01E01';T='WEB';F='NF';W='WEB-DL';R='1080p';A='DD+ 5.1';H='';C='264';S=$false;L='Latino';X2='.MP4';E='Serie (2020) S01E01 1080p NF WEB-DL DD+ 5.1 Latino H.264.mp4'}
)
foreach($c in $casos){
    $ext=if($c.X2){$c.X2}else{'.mkv'}
    $n=Get-NombreFinalHdz -Base $c.B -EtiquetasExtra "$($c.X)" -TipoOrigen $c.T -Resolucion $c.R -PlataformaFormato $c.F -WebTipo "$($c.W)" -Audio $c.A -Hdr $c.H -CodecVideo $c.C -Sufijo $c.S -EtiquetaIdioma $c.L -Extension $ext
    Assert ($n -ceq $c.E) "Nombre incorrecto:`n  obtenido: $n`n  esperado: $($c.E)"
}
$conDosPuntos=Get-NombreFinalHdz -Base 'Underworld: La Rebelión (2009)' -TipoOrigen 'WEB' -Resolucion '1080p' -PlataformaFormato 'AMZN' -WebTipo 'WEB-DL' -Audio 'DD+ 5.1' -CodecVideo '264' -Sufijo $true
Assert ($conDosPuntos -eq 'Underworld La Rebelión (2009) 1080p AMZN WEB-DL DD+ 5.1 H.264-HDZ.mkv') "Caracteres inválidos: $conDosPuntos"

# --- Etiqueta de idioma automática ---
function A($lang,$fmt='E-AC-3',$title=''){$cod=Get-LanguageCode $lang $title;$nom=Get-LanguageName $cod $title;[pscustomobject]@{CodLang=$cod;NomLang=$nom;PesoLang=(Get-PesoIdioma $nom);Format=$fmt;Profile='';Comm='';Chan='6';NomFinal=''}}
function S($lang,[bool]$forced=$false){$cod=Get-LanguageCode $lang '';[pscustomobject]@{CodLang=$cod;NomLang=(Get-LanguageName $cod '');IsForced=$forced}}
Assert ((Get-EtiquetaIdiomaAuto @(A 'eng') @(S 'es')) -eq 'VOSE') 'Inglés + subs castellanos debe ser VOSE'
Assert ((Get-EtiquetaIdiomaAuto @(A 'kor') @(S 'spa')) -eq 'VOSE') 'Coreano + subs castellanos debe ser VOSE'
Assert ((Get-EtiquetaIdiomaAuto @(A 'eng') @(S 'es' $true)) -eq '') 'Solo forzados castellanos no es VOSE'
Assert ((Get-EtiquetaIdiomaAuto @(A 'eng') @(S 'es-419')) -eq '') 'Subs latinos no son VOSE'
Assert ((Get-EtiquetaIdiomaAuto @(A 'eng') @()) -eq '') 'Sin subs castellanos no es VOSE'
Assert ((Get-EtiquetaIdiomaAuto @((A 'spa'),(A 'eng')) @(S 'es')) -eq '') 'Con audio castellano no lleva etiqueta'
# Normas del tracker: doblaje latino + original + subs castellanos = VOSE (la pista latina se queda).
Assert ((Get-EtiquetaIdiomaAuto @((A 'es-419'),(A 'eng')) @(S 'es')) -eq 'VOSE') 'Original + latino + subs castellanos debe ser VOSE'
Assert ((Get-EtiquetaIdiomaAuto @((A 'spa' 'E-AC-3' 'Latino'),(A 'eng')) @(S 'es')) -eq 'VOSE') 'Latino por título de pista + subs castellanos debe ser VOSE'
# Rodada en español latino, sin doblaje al castellano: se sube tal cual, sin etiqueta.
Assert ((Get-EtiquetaIdiomaAuto @(A 'es-419') @()) -eq '') 'Película latina sin castellano no lleva etiqueta'
Assert ((Get-EtiquetaIdiomaAuto @((A 'es-419'),(A 'eng')) @()) -eq '') 'Sin subs castellanos no lleva etiqueta'
Assert ((Get-EtiquetaIdiomaAuto @((A 'es-419'),(A 'es')) @()) -eq '') 'Castellano + latino no lleva etiqueta'
Assert ((Resolve-EtiquetaIdioma 'VOSE' @(A 'spa') @()) -eq 'VOSE') 'VOSE forzada'
Assert ((Resolve-EtiquetaIdioma 'NINGUNA' @(A 'eng') @(S 'es')) -eq '') 'Ninguna forzada'
Assert ((Resolve-EtiquetaIdioma 'LATINO' @(A 'eng') @()) -eq 'Latino') 'Latino forzado'
Assert ((Resolve-EtiquetaIdioma 'AUTO' @(A 'eng') @(S 'es')) -eq 'VOSE') 'Automática'
# Audio del nombre: el mejor DTS del idioma prioritario.
$aud=Format-Audios @((A 'eng' 'E-AC-3'),([pscustomobject]@{CodLang='eng';NomLang='Inglés';PesoLang=3;Format='DTS';Profile='MA / Core';Comm='DTS-HD Master Audio';Chan='8';NomFinal=''}))
Assert ((Get-AudioParaNombreHdz $aud) -eq 'DTS-HD MA 7.1') "Audio del nombre: $(Get-AudioParaNombreHdz $aud)"
Write-Host 'OK nombres: 10 ejemplos + VC-1/MPEG-2 + extensiones + VOSE/Latino'

# --- Modo TAL CUAL de punta a punta (GUI -> motor) ---
$testRoot=Join-Path $env:TEMP ('hdz_test_talcual_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$ff=Join-Path $root 'bin/ffmpeg.exe'
$fuente=Join-Path $testRoot 'Peli.Original.2019.mkv'
$srt=Join-Path $testRoot 'subs.srt'
[IO.File]::WriteAllText($srt,"1`r`n00:00:00,000 --> 00:00:01,500`r`nHola`r`n",[Text.UTF8Encoding]::new($false))
& $ff -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=2' -f lavfi -i 'sine=frequency=440:duration=2' -i $srt -map 0:v -map 1:a -map 2:s -c:v libx264 -preset ultrafast -c:a ac3 -c:s srt -metadata:s:a:0 language=kor -metadata:s:s:0 language=spa -shortest $fuente
Assert ($LASTEXITCODE -eq 0) 'No se pudo crear el vídeo de prueba'
$hashFuente=(Get-FileHash -LiteralPath $fuente).Hash
$env:HDZ_GUI_TEST='1'; $env:HDZ_GUI_TEST_DIR=$testRoot
$env:HDZ_HISTORY_TEST_DIR=Join-Path $testRoot 'history'
try {
    . (Join-Path $root 'HDZ-GUI.ps1')
    Assert ((Get-ChipValor 'modoVideo') -eq 'MONTAJE') 'La GUI no arranca en «Montaje completo»'
    Assert ((Get-ChipValor 'etqIdioma') -eq 'AUTO') 'La etiqueta de idioma no arranca en «Automática»'
    $ui.navProyecto.IsChecked=$true   # el modo test termina en otra sección; el botón vive en «Proyecto»
    Set-ChipValor 'modoVideo' 'TAL_CUAL'
    Assert ("$($ui.cardOriginales.Visibility)" -eq 'Collapsed' -and "$($ui.secHdrAudio.Visibility)" -eq 'Collapsed' -and "$($ui.cardRemezcla.Visibility)" -eq 'Collapsed') 'Tal cual no oculta lo que no aplica'
    Assert ("$($ui.btnIniciar.Content)" -match 'Renombrar') "Botón: $($ui.btnIniciar.Content)"
    $estado=Componer-EstadoAgente | ConvertFrom-Json
    Assert ($estado.opciones.modoVideo -eq 'TAL_CUAL' -and $estado.opciones.etqIdioma -eq 'AUTO') 'La web no recibe los chips nuevos'
    $ui.txtTitulo.Text='Parásitos'; $ui.txtAno.Text='2019'; $ui.swSerie.IsChecked=$false
    Set-ChipValor 'origen' 'FISICO'
    $ui.cmbFormato.SelectedIndex=@($ui.cmbFormato.Items|ForEach-Object{"$_"}).IndexOf('BDRemux')
    Set-ChipValor 'sufijo' $true; Set-ChipValor 'torrent' 'NO'; Set-ChipValor 'capturasProy' 0
    $ui.cfgCarpetaProcesados.Text=''; $ui.cfgCarpetaTorrent.Text=''; $ui.txtAnnounce.Text=''; $ui.txtSalidaArchivo.Text=''
    $script:testJobsMontaje=@()
    Iniciar-Montaje 'unico'
    Assert ($script:testJobsMontaje.Count -eq 1) "La GUI no creó el trabajo: $($ui.lblEstado.Text)"
    $job=$script:testJobsMontaje[0]
    $config=$job.CfgJson|ConvertFrom-Json
    Assert ($config.ModoVideo -eq 'TAL_CUAL' -and $config.EtiquetaIdioma -eq 'AUTO') 'La configuración no lleva el modo ni la etiqueta'
    $config | Add-Member -NotePropertyName NumCapturas -NotePropertyValue 0 -Force
    $config | Add-Member -NotePropertyName ModoTorrent -NotePropertyValue 'NO' -Force
    $config | Add-Member -NotePropertyName AccionOriginales -NotePropertyValue 'BORRAR' -Force   # debe ignorarse
    [IO.File]::WriteAllText($job.CfgPath,($config|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $stdout=Join-Path $testRoot 'engine-stdout.txt'; $stderr=Join-Path $testRoot 'engine-stderr.txt'
    $process=Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$job.LauncherPath+'"')) -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if(-not $process.WaitForExit(60000)){$process.Kill($true);throw "El modo tal cual no terminó en un minuto: $testRoot"}
    Assert ($process.ExitCode -eq 0) "El modo tal cual falló ($($process.ExitCode)). Diagnóstico: $testRoot"
    $esperado=Join-Path $testRoot 'Parásitos (2019) BDRemux 90p VOSE AVC DD 1.0-HDZ.mkv'   # el tono de prueba es mono
    $videos=@(Get-ChildItem -LiteralPath $testRoot -File -Filter '*.mkv' | ForEach-Object Name)
    Assert (Test-Path -LiteralPath $esperado) "No se renombró como se esperaba. Hay: $($videos -join ' | ')"
    Assert (-not (Test-Path -LiteralPath $fuente)) 'El original sigue con su nombre antiguo'
    Assert ($videos.Count -eq 1) "Quedan otros MKV: $($videos -join ' | ')"
    Assert ((Get-FileHash -LiteralPath $esperado).Hash -eq $hashFuente) 'El vídeo se modificó (debía quedar tal cual)'
    Assert (-not (Get-ChildItem -LiteralPath $testRoot -File -Filter '*.procesado')) 'Se aplicó la acción sobre originales'
    Write-Host "OK Test-NombreFinal: tal cual renombra sin tocar el vídeo. $testRoot"
} finally {
    Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_GUI_TEST_DIR,Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
