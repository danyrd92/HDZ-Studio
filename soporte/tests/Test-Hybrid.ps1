# Medios sintéticos: ninguna lectura/escritura sobre películas ni configuración del usuario.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:PATH=(Join-Path $root 'bin')+';'+$env:PATH
$ProgressPreference='SilentlyContinue'
function Assert($condition,$message) { if(-not $condition) { throw $message } }
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'HDZnew.ps1'),[ref]$tokens,[ref]$parseErrors)
Assert ($parseErrors.Count -eq 0) 'Sintaxis del motor'
foreach($name in @('Write-ProgresoGui','Set-ProgresoGui2','Set-ProgresoFusion','Invoke-ProcesoMonitorizado','Invoke-HdzRpuPipe','Invoke-FusionDolbyVision')) {
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Invoke-Expression $fn.Extent.Text
}
$testRoot=Join-Path $env:TEMP ('hdz_hybrid_'+[guid]::NewGuid().ToString('N'))
$rutaCarpeta=Join-Path $testRoot 'Pareja híbrida & 100% (prueba)'
[void][IO.Directory]::CreateDirectory($rutaCarpeta)
$global:rutaProgreso=Join-Path $testRoot 'progress.json'
$global:pctBaseGui=0; $global:pctPasoGui=100; $global:idxGrupoGui=1; $global:totalGruposGui=1
$global:gArchivo='Synthetic hybrid';$global:gPct=15;$global:gPct2=-1;$global:gFase='';$global:gFase2=''
$script:events=[Collections.Generic.List[object]]::new()
$script:writeActual=(Get-Item Function:Write-ProgresoGui).ScriptBlock
function Write-ProgresoGui([bool]$fin=$false) {
    & $script:writeActual $fin
    $script:events.Add((Get-Content -LiteralPath $global:rutaProgreso -Raw | ConvertFrom-Json))
}
$base=Join-Path $rutaCarpeta 'base original.hevc'
$rpu=Join-Path $rutaCarpeta 'metadata original.rpu'
$dv=Join-Path $rutaCarpeta 'DV original.hevc'
$hdrMkv=Join-Path $rutaCarpeta 'Synthetic HDR10.mkv'
$dvMkv=Join-Path $rutaCarpeta 'Synthetic Dolby Vision.mkv'
& ffmpeg -v error -f lavfi -i 'testsrc2=s=640x360:r=24:d=3' -vf 'noise=alls=30:allf=t,format=yuv420p10le' -c:v libx265 -preset ultrafast -crf 12 -x265-params 'pools=2:frame-threads=2:log-level=error:repeat-headers=1' -an $base
Assert ($LASTEXITCODE -eq 0 -and (Get-Item -LiteralPath $base).Length -gt 1MB) 'Fixture HEVC insuficiente'
& dovi_tool generate -j (Join-Path $PSScriptRoot 'fixtures/hybrid-rpu.json') -o $rpu
Assert ($LASTEXITCODE -eq 0) 'Generación RPU sintética'
& dovi_tool inject-rpu --rpu-in $rpu $base -o $dv
Assert ($LASTEXITCODE -eq 0) 'Inyección DV sintética'
& mkvmerge -q -o $hdrMkv --default-duration '0:24fps' $base
Assert ($LASTEXITCODE -eq 0) 'Fixture HDR10 MKV'
& mkvmerge -q -o $dvMkv --default-duration '0:24fps' $dv
Assert ($LASTEXITCODE -eq 0) 'Fixture DV MKV'
$before=@{};foreach($file in @($hdrMkv,$dvMkv)) { $before[$file]=(Get-FileHash -LiteralPath $file).Hash }

# Extracción real por canal binario con rutas Unicode/espacios/metacaracteres.
$pipeRpu=Join-Path $rutaCarpeta 'pipe metadata.rpu'
$pipeResult=Invoke-HdzRpuPipe $dvMkv $pipeRpu 3
Assert ($pipeResult -is [bool] -and $pipeResult) 'Falla el método rápido con espacios'
$referenceRpu=Join-Path $rutaCarpeta 'reference.rpu'
& dovi_tool -m 3 extract-rpu $dv -o $referenceRpu
Assert ($LASTEXITCODE -eq 0) 'Extracción de referencia'
Assert ((Get-FileHash -LiteralPath $pipeRpu).Hash -eq (Get-FileHash -LiteralPath $referenceRpu).Hash) 'El canal binario alteró los metadatos'

$realPipe=(Get-Item Function:Invoke-HdzRpuPipe).ScriptBlock
try {
    foreach($mode in @('pipe','fallback')) {
        if($mode -eq 'fallback') { Set-Item Function:Invoke-HdzRpuPipe { return $false } }
        $script:events.Clear()
        $result=Invoke-FusionDolbyVision (Get-Item -LiteralPath $dvMkv) (Get-Item -LiteralPath $hdrMkv)
        Assert ($result -and (Test-Path -LiteralPath $result.VideoFusionado)) "Fusión $mode falló"
        Assert (-not (Test-Path -LiteralPath (Join-Path $rutaCarpeta "tmp_dv_raw_$PID.hevc"))) "Temporal DV sobrante: $mode"
        $extracted=Join-Path $rutaCarpeta "result-$mode.rpu"
        & dovi_tool extract-rpu $result.VideoFusionado -o $extracted
        Assert ($LASTEXITCODE -eq 0) "Resultado sin RPU: $mode"
        Assert ((Get-FileHash -LiteralPath $extracted).Hash -eq (Get-FileHash -LiteralPath $referenceRpu).Hash) "RPU final alterada: $mode"
        foreach($step in @('Paso 1/3','Paso 2/3','Paso 3/3')) {
            Assert (@($script:events | Where-Object {$_.fase2 -like "$step*"}).Count -gt 0) "Falta progreso $step en $mode"
        }
        Assert (@($script:events | Where-Object {$_.pct -gt 15 -and $_.pct -lt 40}).Count -gt 0) "Barra principal inmóvil: $mode"
        Assert (@($script:events | Where-Object {$_.pct2 -eq 100}).Count -eq 1) "Fin prematuro o inexistente: $mode"
        Assert ($script:events[-1].pct2 -eq -1 -and $script:events[-1].pct -eq 40) "Detalle sin limpiar: $mode"
        Write-Host "HYBRID_$($mode.ToUpper())_OK"
    }
} finally { Set-Item Function:Invoke-HdzRpuPipe $realPipe }
# Fallos reales de entrada/DV: nunca éxito aparente ni herramientas huérfanas.
Assert (-not (Invoke-HdzRpuPipe (Join-Path $rutaCarpeta 'missing.mkv') (Join-Path $rutaCarpeta 'bad.rpu') 3)) 'Entrada ausente aceptada'
Assert (-not (Invoke-HdzRpuPipe $hdrMkv (Join-Path $rutaCarpeta 'no-dv.rpu') 3)) 'Vídeo sin DV aceptado'
$children=@(Get-CimInstance Win32_Process | Where-Object {$_.ParentProcessId -eq $PID -and $_.Name -in @('ffmpeg.exe','dovi_tool.exe')})
Assert ($children.Count -eq 0) 'Herramientas huérfanas tras fallo'
foreach($file in @($hdrMkv,$dvMkv)) { Assert ((Get-FileHash -LiteralPath $file).Hash -eq $before[$file]) 'Original modificado' }
$global:pctBaseGui=50;$global:pctPasoGui=50;$global:idxGrupoGui=2;$global:totalGruposGui=2
Set-ProgresoFusion 40 'Lote de prueba'
Assert ($script:events[-1].pct -eq 62 -and $script:events[-1].fase -like '*2/2') 'Porcentaje de lote incorrecto'
Write-Host "HYBRID_REGRESSION_OK: canal binario, respaldo, metadatos idénticos, progreso JSON, errores, originales intactos. $testRoot"
