# Solo medios sintéticos, en una carpeta única local o de red.
param([string]$BaseDirectory = $env:TEMP)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:PATH = (Join-Path $root 'bin') + ';' + $env:PATH
. (Join-Path $root 'HDZ-Capturas.ps1')
function Assert($Value, $Message) { if (-not $Value) { throw $Message } }
$testRoot = Join-Path $BaseDirectory ('hdz_test_hidden_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$global:hdzCaptureTestBinary = Join-Path $root 'bin\ffmpeg.exe'
$source = Join-Path $testRoot 'source.mkv'
& $global:hdzCaptureTestBinary -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=2' -c:v libx264 -preset ultrafast $source
Assert ($LASTEXITCODE -eq 0) 'No se pudo crear vídeo sintético'
$sourceHash = (Get-FileHash -LiteralPath $source).Hash

# Fuerza Hidden incluso en disco local para que la regresión no dependa de SMB.
$global:hdzCaptureHiddenPaths = [Collections.Generic.List[string]]::new()
function ffmpeg {
    # PowerShell separa -frames:v al enlazar una función, no un ejecutable.
    $nativeArgs = for ($i=0; $i -lt $args.Count; $i++) {
        if ("$($args[$i])" -eq '-frames:' -and $i+1 -lt $args.Count) {
            '-frames:' + $args[++$i]
        } else { $args[$i] }
    }
    & $global:hdzCaptureTestBinary @nativeArgs
    $code = $LASTEXITCODE
    foreach ($arg in $args) {
        if ("$arg" -match '\.hdz_cap_\w+\.png$' -and [IO.File]::Exists("$arg")) {
            [IO.File]::SetAttributes("$arg", ([IO.File]::GetAttributes("$arg") -bor [IO.FileAttributes]::Hidden))
            $global:hdzCaptureHiddenPaths.Add("$arg")
        }
    }
    $global:LASTEXITCODE = $code
}
try {
    $result = New-HdzCapturas -ArchivoVideo $source -NumCapturas 1 -EsHdr $false -DirCapturas $testRoot
    Assert ($global:hdzCaptureHiddenPaths.Count -eq 1) 'No se reprodujo el temporal Hidden'
    Assert ($result.Capturas.Count -eq 1 -and $result.Fallos -eq 0) 'Captura oculta descartada'
    $capture = $result.Capturas[0]
    $global:hdzCaptureKnownPng = $capture
    Assert ((Get-Item -LiteralPath $capture).Length -gt 8) 'Captura final no visible'
    Assert (-not ([IO.File]::GetAttributes($capture) -band [IO.FileAttributes]::Hidden)) 'Captura final quedó oculta'
    Assert (-not (Test-Path -LiteralPath $global:hdzCaptureHiddenPaths[0])) 'Temporal no renombrado'
    $captureHash = (Get-FileHash -LiteralPath $capture).Hash
} finally { Remove-Item Function:ffmpeg }

# Un código de error sigue rechazando el PNG aunque exista, sea válido y esté oculto.
function ffmpeg {
    foreach ($arg in $args) {
        if ("$arg" -match '\.hdz_cap_\w+\.png$') {
            Copy-Item -LiteralPath $global:hdzCaptureKnownPng -Destination "$arg"
            [IO.File]::SetAttributes("$arg", [IO.FileAttributes]::Hidden)
        }
    }
    $global:LASTEXITCODE = 1
}
try {
    $failed = New-HdzCapturas -ArchivoVideo $source -NumCapturas 1 -EsHdr $false -DirCapturas $testRoot
    Assert ($failed.Capturas.Count -eq 0 -and $failed.Fallos -eq 1) 'Se aceptó una captura de FFmpeg fallido'
    Assert ((Get-FileHash -LiteralPath $capture).Hash -eq $captureHash) 'Se cambió la captura válida anterior'
    Assert (@(Get-ChildItem -LiteralPath $testRoot -Force -Filter '.hdz_cap_*').Count -eq 0) 'Temporal fallido no limpiado'
} finally { Remove-Item Function:ffmpeg }
Assert ((Get-FileHash -LiteralPath $source).Hash -eq $sourceHash) 'Se modificó el vídeo sintético'
# Ruta completa sin interceptar FFmpeg: incluye HDR y tonemapping en SMB.
$hdrSource = Join-Path $testRoot 'hdr.mkv'
& $global:hdzCaptureTestBinary -v error -f lavfi -i 'color=c=blue:s=160x90:r=24:d=2' -pix_fmt yuv420p10le -c:v libx265 -preset ultrafast -x265-params 'log-level=error:colorprim=9:transfer=16:colormatrix=9' $hdrSource
Assert ($LASTEXITCODE -eq 0) 'No se pudo crear el vídeo HDR sintético'
$hdr = New-HdzCapturas -ArchivoVideo $hdrSource -NumCapturas 1 -EsHdr $true -DirCapturas $testRoot
Assert ($hdr.Capturas.Count -eq 1 -and $hdr.Fallos -eq 0) 'Falló la captura HDR real'
Assert ((Get-Item -LiteralPath $hdr.Capturas[0]).Length -gt 8) 'Captura HDR oculta o vacía'
Write-Host "HIDDEN_CAPTURE_REGRESSION_OK: $testRoot"
