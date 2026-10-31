# Una sola lectura del origen para varias pistas (DTS -> E-AC3 y PGS): mismo resultado que
# una pasada por pista. Solo medios sintéticos en una carpeta temporal propia.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:PATH = (Join-Path $root 'bin') + ';' + $env:PATH
function Assert($ok, $message) { if (-not $ok) { throw $message } }
. (Join-Path $root 'HDZ-Core.ps1')
$engine = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'HDZnew.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Invoke-ConversionDTSMultiidioma', 'Invoke-ExtraccionPGS', 'Get-LanguageCode')) {
    $node = $engine.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Assert $node "No se encuentra $name"
    . ([scriptblock]::Create($node.Extent.Text))
}
function Write-DiagPaso($t) {}
function Write-DiagLinea($t) {}
function Test-HdzAudioTrackKept { $true }
function Get-MediainfoJson($r) { $null }
function Get-MkvmergeTrackIdMap($r) { @{} }
$global:undPistasGui = @{}

$testRoot = Join-Path $env:TEMP ('hdz_singlepass_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$rutaCarpeta = $testRoot
try {
    # Dos DTS de idiomas distintos (uno con retardo de inicio) y un AC3: se convierten ambos DTS.
    $source = Join-Path $testRoot 'Source.mkv'
    & ffmpeg -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=4' -f lavfi -i 'sine=frequency=440:duration=4' -itsoffset 0.5 -f lavfi -i 'sine=frequency=660:duration=3.5' -f lavfi -i 'sine=frequency=880:duration=4' `
        -map 0:v -map 1:a -map 2:a -map 3:a -c:v libx264 -preset ultrafast -c:a:0 dca -c:a:1 dca -c:a:2 ac3 -strict -2 -ac 2 `
        -metadata:s:a:0 language=eng -metadata:s:a:1 language=fre -metadata:s:a:2 language=spa $source
    Assert ($LASTEXITCODE -eq 0) 'No se pudo crear el origen sintético'
    $sourceHash = (Get-FileHash -LiteralPath $source).Hash
    $generados = @(Invoke-ConversionDTSMultiidioma @($source) 'SIEMPRE' @{})
    Assert ($generados.Count -eq 2) "Se esperaban 2 E-AC3 y hay $($generados.Count)"
    foreach ($out in $generados) {
        $lang = if ($out -match '_audio_eng\.eac3$') { 'eng' } elseif ($out -match '_audio_fre\.eac3$') { 'fre' } else { throw "Nombre inesperado: $out" }
        $index = if ($lang -eq 'eng') { 1 } else { 2 }
        # Referencia: la orden anterior, una pasada por pista.
        $reference = Join-Path $testRoot "ref_$lang.eac3"
        $start = 0.0; [void][double]::TryParse("$(ffprobe -v error -select_streams $index -show_entries stream=start_time -of csv=p=0 $source)", [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$start)
        $delay = [int][Math]::Round($start * 1000)
        if ($delay -gt 0) { & ffmpeg -i $source -map "0:$index" -af "adelay=${delay}:all=1" -c:a eac3 -b:a 1024k $reference -y -v error }
        else { & ffmpeg -i $source -map "0:$index" -c:a eac3 -b:a 1024k $reference -y -v error }
        $got = & ffmpeg -v error -i $out -map 0:a -f hash -hash sha256 -
        $want = & ffmpeg -v error -i $reference -map 0:a -f hash -hash sha256 -
        Assert ($got -eq $want) "El E-AC3 de '$lang' difiere de la conversión pista a pista"
    }
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $sourceHash) 'Se modificó el origen'

    # PGS: FFmpeg no codifica PGS, así que se simulan ffprobe/ffmpeg y se comprueba que todas
    # las pistas elegidas salen de UNA sola invocación (y que el filtro de idiomas se respeta).
    $global:pgsCalls = [Collections.Generic.List[object]]::new()
    function ffprobe { '{"streams":[{"index":3,"codec_name":"hdmv_pgs_subtitle","tags":{"language":"spa"}},{"index":4,"codec_name":"subrip","tags":{"language":"eng"}},{"index":5,"codec_name":"hdmv_pgs_subtitle","tags":{"language":"eng"}},{"index":6,"codec_name":"hdmv_pgs_subtitle","tags":{"language":"ger"}}]}' }
    function ffmpeg { $global:pgsCalls.Add(@($args)); $global:LASTEXITCODE = 0 }
    $count = Invoke-ExtraccionPGS 'X:\fake.mkv' @('__CAST_ENG__') 'Peli'
    Assert ($count -eq 2) "Se esperaban 2 PGS extraídos y hay $count"
    Assert ($global:pgsCalls.Count -eq 1) "Se lanzaron $($global:pgsCalls.Count) FFmpeg en lugar de uno"
    $call = "$($global:pgsCalls[0])"
    Assert ($call -match '-map 0:3 -c copy -y Peli_sub_3_spa\.sup' -and $call -match '-map 0:5 -c copy -y Peli_sub_5_eng\.sup' -and $call -notmatch '0:6|0:4') "Argumentos PGS inesperados: $call"
    # Si la pasada conjunta falla, se repite pista a pista.
    $global:pgsCalls.Clear()
    function ffmpeg { $global:pgsCalls.Add(@($args)); $global:LASTEXITCODE = $(if ($global:pgsCalls.Count -eq 1) { 1 } else { 0 }) }
    [void](Invoke-ExtraccionPGS 'X:\fake.mkv' @('__CAST_ENG__') 'Peli')
    Assert ($global:pgsCalls.Count -eq 3) 'No se repitió pista a pista tras el fallo conjunto'
    Write-Host "SINGLE_PASS_OK: DTS multi-idioma idéntico a pista a pista (con retardo), PGS en una pasada y respaldo. $testRoot"
} finally {
    Remove-Item Function:ffmpeg, Function:ffprobe -ErrorAction SilentlyContinue
}
