# Pruebas reales con medios sintéticos de dos segundos. No usa archivos del usuario.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:PATH = (Join-Path $root 'bin') + ';' + $env:PATH
. (Join-Path $root 'HDZ-Core.ps1')
. (Join-Path $root 'HDZ-Torrent.ps1')
. (Join-Path $root 'HDZ-Capturas.ps1')
. (Join-Path $root 'HDZ-History.ps1')
$testRoot = Join-Path $env:TEMP ('hdz_test_media_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Must-Throw([scriptblock]$Work, $Message) {
    $thrown = $false; try { & $Work | Out-Null } catch { $thrown = $true }
    Assert $thrown $Message
}
foreach ($pair in @('th:tha','ru:rus','nl:nld','ar:ara','pl:pol','hi:hin','fre:fra','ger:deu','el:ell','uk:ukr')) {
    $p = $pair.Split(':'); Assert ((Convert-HdzLanguage $p[0]) -eq $p[1]) "Idioma: $pair"
}
Assert ((Convert-HdzLanguage '') -eq 'und') 'Idioma vacío'
foreach ($name in @('A.S01E01-E03.1080p.mkv','B S01E01-E02-E03.mkv','C 1x01-03.mkv')) {
    Assert ((Get-HdzEpisodeKey $name) -eq 's1e1-2-3') "Rango: $name"
}
Assert ((Get-HdzEpisodeKey 'B E01.mkv') -eq 's0e1') 'Episodio sin temporada'
Assert ($null -eq (Get-HdzEpisodeKey 'Film 2026 1080p.mkv')) 'Falso positivo de episodio'
Must-Throw { Get-HdzEpisodeKey 'S01E03-E01' } 'Rango descendente aceptado'
Assert (Test-HdzEpisodeMatch 's0e1' 's2e1') 'No empareja E01 con S02E01'
Assert (-not (Test-HdzEpisodeMatch 's1e1' 's2e1')) 'Confunde temporadas conocidas'
Assert (-not (Test-HdzEpisodeMatch 's1e1-2-3' 's1e1')) 'Confunde un rango y un episodio'

$source = Join-Path $testRoot 'source.mkv'
$donor = Join-Path $testRoot 'donor.mkv'
& ffmpeg -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=2' -f lavfi -i 'sine=frequency=440:duration=2' -f lavfi -i 'sine=frequency=880:duration=2' -map 0:v -map 1:a -map 2:a -c:v libx264 -preset ultrafast -c:a aac -metadata:s:a:0 language=eng -metadata:s:a:1 language=tha -shortest $source
Assert ($LASTEXITCODE -eq 0) 'No se pudo crear el medio sintético'
Copy-Item -LiteralPath $source -Destination $donor
$sourceHash = (Get-FileHash -LiteralPath $source).Hash
Assert-HdzMux $source 2 0 $donor
Assert-HdzRemixDurations $source @($donor)
Assert-HdzFreeSpace $testRoot 1MB
Must-Throw { Assert-HdzMux $source 3 0 $donor } 'No detectó una pista ausente'

# Una carátula PNG/JPEG adjunta no es un segundo vídeo, pero tampoco puede
# sustituir al vídeo principal. Fixtures reales: reproduce el fallo de Chompoo.
foreach ($extension in @('png','jpg')) {
    $cover = Join-Path $testRoot "cover.$extension"
    & ffmpeg -v error -f lavfi -i 'color=c=red:s=32x32' -frames:v 1 $cover
    Assert ($LASTEXITCODE -eq 0) "No se pudo crear la carátula $extension"
    $covered = Join-Path $testRoot "covered-$extension.mkv"
    & mkvmerge -q -o $covered $source --attach-file $cover
    Assert ($LASTEXITCODE -eq 0) 'No se pudo adjuntar la carátula'
    $probe = (& ffprobe -v error -show_streams -of json $covered | Out-String) | ConvertFrom-Json
    Assert (@($probe.streams | Where-Object { $_.codec_type -eq 'video' -and $_.disposition.attached_pic -eq 1 }).Count -eq 1) 'El fixture no reproduce una carátula expuesta como vídeo'
    Assert-HdzMux $covered 2 0 $source
    Must-Throw { Assert-HdzMux $covered 3 0 $source } 'La carátula oculta audio ausente'
    Must-Throw { Assert-HdzMux $covered 1 0 $source } 'La carátula oculta audio adicional'
    Must-Throw { Assert-HdzMux $covered 2 1 $source } 'La carátula oculta subtítulos ausentes'
    $coverOnly = Join-Path $testRoot "no-video-$extension.mkv"
    & mkvmerge -q -o $coverOnly --no-video $source --attach-file $cover
    Assert ($LASTEXITCODE -eq 0) 'No se pudo crear el fixture sin vídeo'
    Must-Throw { Assert-HdzMux $coverOnly 2 0 $source } 'La carátula se acepta como vídeo principal'
}
$twoVideos = Join-Path $testRoot 'two-videos.mkv'
& ffmpeg -v error -i $source -map 0:v:0 -map 0:v:0 -map 0:a -c copy $twoVideos
Assert ($LASTEXITCODE -eq 0) 'No se pudo crear el fixture de dos vídeos'
Must-Throw { Assert-HdzMux $twoVideos 2 0 $source } 'Aceptó dos vídeos reales'

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'HDZnew.ps1'), [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'El motor contiene errores de sintaxis'
foreach ($name in @('Invoke-ConversionAudioManual','Get-LanguageCode','Get-LanguageName','Get-PesoIdioma','Get-CfgGui','Test-HdzAudioTrackKept')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Write-DiagPaso { param($text) }
$global:cfgGui=[pscustomobject]@{PistasAudioExcluidas=@([pscustomobject]@{Archivo=$donor;Id=17;Index=2})}
Assert (-not (Test-HdzAudioTrackKept $donor 17)) 'Ignora el ID de mkvmerge'
Assert (Test-HdzAudioTrackKept $donor 2) 'Confunde IDs de ffprobe y mkvmerge'
Assert (-not (Test-HdzAudioTrackKept $donor 2 -FfprobeIndex)) 'Ignora índice ffprobe'
Assert (Test-HdzAudioTrackKept $source 17) 'Exclusión afecta a otro archivo'
$global:cfgGui=$null
$dictIdiomas = @{}; $rutaCarpeta = $testRoot
$conversion = [pscustomobject]@{Index=2;Lang='tha';CodecOrigen='aac';CanalesOrigen=1;CodecDestino='ac3';CanalesDestino=2;BitrateK=192;MantenerOriginal=$false;FuenteExacta=$true;ArchivoFuente=$donor}
$converted = Invoke-ConversionAudioManual @($conversion) (Get-Item -LiteralPath $source)
Assert ($converted.Nuevos.Count -eq 1) 'No creó el audio convertido'
Assert ($converted.PistasAEliminar.Count -eq 1) 'No identificó la sustitución'
Assert ($converted.PistasAEliminar[0].Ruta -eq $donor) 'Marcó la fuente equivocada para eliminar audio'
Assert ($converted.PistasAEliminar[0].Index -eq 2) 'ID de mkvmerge incorrecto'
$conversion.Lang = 'eng'
Must-Throw { Invoke-ConversionAudioManual @($conversion) (Get-Item -LiteralPath $source) } 'Convirtió un idioma distinto'
$conversion.Lang = 'tha'; $conversion.CodecDestino = 'invalid'
Must-Throw { Invoke-ConversionAudioManual @($conversion) (Get-Item -LiteralPath $source) } 'Aceptó códec incorrecto'
$conversion.CodecDestino = 'ac3'
function ffmpeg { $global:LASTEXITCODE = 1 }
Must-Throw { Invoke-ConversionAudioManual @($conversion) (Get-Item -LiteralPath $source) } 'No detuvo el montaje ante conversión fallida'
Remove-Item Function:ffmpeg
Assert ((Get-FileHash -LiteralPath $source).Hash -eq $sourceHash) 'Modificó el vídeo original'
Assert ((Get-FileHash -LiteralPath $donor).Hash -eq $sourceHash) 'Modificó el donante'

$pack = Join-Path $testRoot 'pack'; [void][IO.Directory]::CreateDirectory($pack)
$episode = Join-Path $pack 'episode.mkv'; Copy-Item -LiteralPath $source -Destination $episode
$script:progress = [Collections.Generic.List[int]]::new()
$torrent = New-TorrentPack $pack '' '' $pack { param($p) $script:progress.Add($p) } @($episode)
$first = (Get-Item -LiteralPath $torrent).Length
$torrent = New-TorrentPack $pack '' '' $pack $null @($episode)
Assert ((Get-Item -LiteralPath $torrent).Length -eq $first) 'El torrent ha incluido su propia versión anterior'
Assert ($script:progress.Count -gt 0 -and $script:progress[-1] -eq 100) 'Falta progreso de torrent directo'
Copy-Item -LiteralPath $source -Destination (Join-Path $pack 'unrelated.mkv')
Must-Throw { New-TorrentPack $pack '' '' $pack $null @($episode) } 'El pack aceptó un archivo ajeno'
$captures = New-HdzCapturas -ArchivoVideo $source -NumCapturas 1 -EsHdr $false -DirCapturas $testRoot
Assert ($captures.Capturas.Count -eq 1) 'No creó la captura real'
$captureHash = (Get-FileHash -LiteralPath $captures.Capturas[0]).Hash
function ffmpeg { $global:LASTEXITCODE = 1 }
$failedCaptures = New-HdzCapturas -ArchivoVideo $source -NumCapturas 1 -EsHdr $false -DirCapturas $testRoot
Assert ($failedCaptures.Capturas.Count -eq 0 -and $failedCaptures.Fallos -gt 0) 'Aceptó la captura antigua tras un fallo de FFmpeg'
Assert ((Get-FileHash -LiteralPath $captures.Capturas[0]).Hash -eq $captureHash) 'Borró o cambió la captura antigua en un intento fallido'
Remove-Item Function:ffmpeg
function Get-HdzVideoTrackFromMediaInfo { @{colour_primaries='BT.2020';transfer_characteristics='HLG';BitDepth='10'} }
Assert (Test-HdzVideoHdr $source) 'HLG no detectado'
$script:hdzHistoryTestDirectory = Join-Path $testRoot 'history'
$record = Add-HdzHistory @{kind='test';torrent=$torrent;video=$source;status='Verificado';token='must-not-be-saved'}
Assert ((Get-HdzHistory).Count -eq 1) 'Historial no recuperable'
Assert ((Get-HdzHistoryTorrent $record.id) -eq $torrent) 'Historial no recupera el torrent exacto'
Assert (-not (Get-Content -LiteralPath (Join-Path $script:hdzHistoryTestDirectory ($record.id+'.json')) -Raw).Contains('must-not-be-saved')) 'El historial guardó un secreto'
[IO.File]::AppendAllText($torrent, 'tampered-fixture')
Must-Throw { Get-HdzHistoryTorrent $record.id } 'Historial entrega un torrent modificado como original'
Write-Host "MEDIA_REGRESSION_OK — originales intactos, conversión validada, idiomas, episodios, torrent y progreso. Pruebas: $testRoot"
