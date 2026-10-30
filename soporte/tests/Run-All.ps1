param([switch]$IncludeMontaje)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$parseFiles=@(Get-ChildItem -LiteralPath $root -File -Filter '*.ps1')+@(Get-ChildItem -LiteralPath (Join-Path $root 'instalacion') -File -Filter '*.ps1')
$optionalHdrTools=Join-Path $root 'HDR10plus-a-HDR10'
$optionalHdrItem=Get-Item -LiteralPath $optionalHdrTools -Force -ErrorAction SilentlyContinue
if($optionalHdrItem -and (-not $optionalHdrItem.Target -or (Test-Path -LiteralPath $optionalHdrItem.Target -PathType Container))){$parseFiles+=@(Get-ChildItem -LiteralPath $optionalHdrTools -File -Filter '*.ps1')}
foreach($file in $parseFiles){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors);if($errors.Count){throw "Sintaxis incorrecta: $($file.Name): $errors"}}
Write-Host "POWERSHELL_SYNTAX_OK ($($parseFiles.Count) scripts)"
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-PublicSafety.ps1'); if($LASTEXITCODE -ne 0){throw 'Hay datos privados en los archivos publicables'}
# Las pruebas web usan Playwright: HDZ_PLAYWRIGHT, el runtime local de Codex si existe, o el paquete global.
if(-not $env:HDZ_PLAYWRIGHT){
    $codexPlaywright=Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\node_modules\playwright'
    if(Test-Path -LiteralPath $codexPlaywright){$env:HDZ_PLAYWRIGHT=$codexPlaywright}
}
& pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot 'Test-Resolution.ps1'); if($LASTEXITCODE -ne 0){throw 'Falló la clasificación de resolución'}
& pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot 'Test-AudioBitrateNames.ps1'); if($LASTEXITCODE -ne 0){throw 'Falló el bitrate en nombres de audio'}
& pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot 'Test-UpdatePrivileges.ps1'); if($LASTEXITCODE -ne 0){throw 'Falló la actualización con permisos e instalación personal'}
foreach($test in @('Test-Media.ps1','Test-Hybrid.ps1','Test-CaptureHidden.ps1','Test-CapturePreviews.ps1','Test-CaptureTabs.ps1','Test-ImageHosts.ps1','Test-ScreenshotBbcode.ps1','Test-RefreshLogos.ps1','Test-LatestTorrent.ps1','Test-Gui.ps1','Test-VideoSelection.ps1','Test-TorrentLoad.ps1','Test-Updater.ps1','Test-UpdateNetwork.ps1','Test-UpdateButtons.ps1')) {
    & pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot $test)
    if($LASTEXITCODE -ne 0){throw "Falló $test"}
}
& node (Join-Path $PSScriptRoot 'test_web.cjs'); if($LASTEXITCODE -ne 0){throw 'Falló la web'}
& node (Join-Path $PSScriptRoot 'test_web_file_picker.cjs'); if($LASTEXITCODE -ne 0){throw 'Falló el selector de vídeos web'}
& node (Join-Path $PSScriptRoot 'test_web_update.cjs'); if($LASTEXITCODE -ne 0){throw 'Falló el botón de actualización web'}
& node (Join-Path $PSScriptRoot 'test_web_logos.cjs'); if($LASTEXITCODE -ne 0){throw 'Falló la interfaz de logos web'}
& python (Join-Path $PSScriptRoot 'test_transport.py'); if($LASTEXITCODE -ne 0){throw 'Falló el almacén remoto'}
if($IncludeMontaje){& pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot 'Test-Montaje.ps1');if($LASTEXITCODE -ne 0){throw 'Falló el montaje completo'}}
if($IncludeMontaje){foreach($format in @('480i','576i')){& pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot 'Test-Montaje.ps1') -VideoFormat $format;if($LASTEXITCODE -ne 0){throw "Falló el montaje SD $format"}}}
if($IncludeMontaje){foreach($mode in @('INDIVIDUAL','PACK','AMBOS')){& pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot 'Test-Montaje.ps1') -CaptureFailure -TorrentMode $mode;if($LASTEXITCODE -ne 0){throw "Las capturas bloquean el torrent $mode"}}}
& pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot 'Test-TrackLanguages.ps1'); if($LASTEXITCODE -ne 0){throw 'Falló la corrección de idiomas por pista'}
& node (Join-Path $PSScriptRoot 'test_web_languages.cjs'); if($LASTEXITCODE -ne 0){throw 'Falló la corrección de idiomas web'}
& pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot 'Test-AudioTracks.ps1');if($LASTEXITCODE -ne 0){throw 'Falló la selección por pista de audio'}
& pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot 'Test-AudioTracks.ps1') -Remix;if($LASTEXITCODE -ne 0){throw 'Falló la selección por pista en remezcla'}
& node (Join-Path $PSScriptRoot 'test_web_audio_tracks.cjs');if($LASTEXITCODE -ne 0){throw 'Falló la selección por pista web'}
& pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot 'Test-Interface.ps1');if($LASTEXITCODE -ne 0){throw 'Falló la nueva distribución WPF'}
& node (Join-Path $PSScriptRoot 'test_web_interface.cjs');if($LASTEXITCODE -ne 0){throw 'Falló la nueva distribución web'}
& pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot 'Test-Design.ps1');if($LASTEXITCODE -ne 0){throw 'Falló el diseño compartido WPF'}
& node (Join-Path $PSScriptRoot 'test_workspace_visual.cjs');if($LASTEXITCODE -ne 0){throw 'Falló el espacio de trabajo visual'}
& pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot 'Test-Responsiveness.ps1');if($LASTEXITCODE -ne 0){throw 'Falló la fluidez del escritorio'}
& node (Join-Path $PSScriptRoot 'test_responsiveness.cjs');if($LASTEXITCODE -ne 0){throw 'Falló la estabilidad de los controles web'}
Write-Host 'ALL_LOCAL_TESTS_OK'
