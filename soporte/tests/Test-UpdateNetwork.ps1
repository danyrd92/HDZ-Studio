$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($value,$message){if(-not $value){throw $message}}
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'instalacion/Actualizar-Seguro.ps1'),[ref]$tokens,[ref]$errors)
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Download-UpdateFile'},$true)
. ([scriptblock]::Create($node.Extent.Text))
$testRoot=Join-Path $env:TEMP ('hdz_test_update_network_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$dest=Join-Path $testRoot 'payload'
$bases=@('https://primary.invalid/','https://backup.invalid/')
$script:downloadPreferredBase=$null; $script:requests=[Collections.Generic.List[string]]::new(); $script:allFail=$false
function Invoke-WebRequest {
    param($Uri,$OutFile)
    $script:requests.Add($Uri)
    [IO.File]::WriteAllText($OutFile,'partial')
    if($Uri -like '*primary.invalid*' -or $script:allFail){throw 'Synthetic network failure'}
    [IO.File]::WriteAllText($OutFile,'verified-fixture')
}
try {
    Download-UpdateFile 'file with spaces.bin' $dest
    Assert ($script:requests.Count -eq 3) 'No reintentó y cambió a la segunda conexión'
    Assert ($script:requests[2] -eq 'https://backup.invalid/file%20with%20spaces.bin') 'Ruta mal codificada'
    Assert ([IO.File]::ReadAllText($dest) -eq 'verified-fixture') 'Dejó la descarga parcial'
    $script:requests.Clear()
    Download-UpdateFile 'next.bin' $dest
    Assert ($script:requests.Count -eq 1 -and $script:requests[0] -like '*backup.invalid*') 'No conservó la conexión operativa'
    $script:allFail=$true; $script:requests.Clear(); $failed=$false
    try {Download-UpdateFile 'failed.bin' $dest} catch {$failed=$true}
    Assert ($failed -and $script:requests.Count -eq 4) 'No acotó el fallo de ambas conexiones'
    Assert (-not(Test-Path -LiteralPath $dest)) 'Dejó un parcial tras agotar conexiones'
} finally {Remove-Item Function:Invoke-WebRequest}

$gui=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'HDZ-GUI.ps1'),[ref]$tokens,[ref]$errors)
$check=$gui.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Iniciar-ChequeoActualizacion'},$true)
$assignment=$check.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$worker'},$true)
$worker=[scriptblock]::Create($assignment.Right.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
function Invoke-RestMethod {
    param($Uri)
    $script:requests.Add($Uri)
    if($Uri -like '*primary.invalid*' -or $script:allFail){throw 'Synthetic unavailable endpoint'}
    return [pscustomobject]@{version='9.9.9'}
}
try {
    $script:allFail=$false; $script:requests.Clear(); $sync=@{Hecho=$false;Json=$null;Error=$null}
    & $worker $bases $sync
    Assert ($sync.Hecho -and $sync.Json.version -eq '9.9.9' -and -not $sync.Error) 'El chequeo GUI no usó el respaldo'
    Assert ($script:requests.Count -eq 3) 'Reintentos GUI incorrectos'
    $script:allFail=$true; $sync=@{Hecho=$false;Json=$null;Error=$null}
    & $worker $bases $sync
    Assert ($sync.Hecho -and $sync.Error -and -not $sync.Json) 'El chequeo GUI oculta el fallo total'
} finally {Remove-Item Function:Invoke-RestMethod}
Write-Host 'UPDATE_NETWORK_REGRESSION_OK: retries, fallback, partial cleanup and visible GUI failure'
