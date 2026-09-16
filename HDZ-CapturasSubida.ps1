#requires -Version 7.0
# =========================================================================
# HDZ-CapturasSubida.ps1 — worker aislado de subida de capturas
# =========================================================================
# Se ejecuta como proceso hijo desde la cuadrícula del menú contextual. Usa
# el mismo protocolo de HDZ Studio, pero escribe progreso/resultados a disco
# para que la ventana WPF nunca quede atada al runspace de la subida.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [Parameter(Mandatory)][string]$ProgressFile,
    [Parameter(Mandatory)][string]$ResultFile
)

$ErrorActionPreference = 'Stop'

function Write-HdzUploadJsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Data)
    $tmp = "$Path.$PID.tmp"
    $json = $Data | ConvertTo-Json -Depth 12 -Compress
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            [System.IO.File]::WriteAllText($tmp, $json, $utf8)
            Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
            return
        } catch {
            Start-Sleep -Milliseconds 40
        }
    }
    throw "No se pudo escribir '$Path'."
}

function Set-HdzUploadProgress {
    param([hashtable]$State)
    Write-HdzUploadJsonAtomic -Path $ProgressFile -Data $State
}

$state = [ordered]@{
    Done     = 0
    Total    = 0
    Fase     = 'Preparando subida…'
    Error    = $null
    Finished = $false
}
$items = @()
$result = [ordered]@{ Items=@(); Error=$null; Aviso=$null; Gal=$null }

try {
    if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) { throw 'No se recibió la lista de capturas.' }
    $request = Get-Content -LiteralPath $InputFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $rutas = @($request.Rutas | ForEach-Object { "$_" } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $hostType = "$($request.Host)".Trim().ToUpperInvariant()
    if ($hostType -notin @('FREEIMAGE','IMGBB','IMGBOX','PIXHOST')) { throw 'Host de imágenes no válido.' }
    if ($rutas.Count -eq 0) { throw 'No hay capturas seleccionadas para subir.' }

    $state.Total = $rutas.Count
    Set-HdzUploadProgress $state

    # Se lee la configuración en el proceso hijo para no dejar claves o
    # contraseñas descifradas en los archivos temporales de progreso.
    . (Join-Path $PSScriptRoot 'HDZ-CapturasContexto.ps1')
    $settings = Get-HdzContextUploadSettings

    . (Join-Path $PSScriptRoot 'HDZ-ImageHosts.ps1')
    $rc=Invoke-HdzImageUploadBatch -Paths $rutas -Preferred $hostType -Settings $settings -Title "$($request.GalleryTitle)" -Sync $state -OnProgress {param($s) Set-HdzUploadProgress $s}
    $items=@($rc.Items); $result.Aviso=$rc.Aviso; $result.Gal=$rc.Gal
    $state.Error=$rc.Error
    $state.Fase=if($rc.Error){'Subida con capturas pendientes.'}else{'Subida verificada.'}
    Set-HdzUploadProgress $state
} catch {
    $state.Error = "Error preparando la subida: $($_.Exception.Message)"
    $state.Fase = 'Subida detenida.'
    try { Set-HdzUploadProgress $state } catch {}
} finally {
    $result.Items = @($items)
    if (-not $result.Error -and $state.Error) { $result.Error = $state.Error }
    try { Write-HdzUploadJsonAtomic -Path $ResultFile -Data $result } catch {}
    $state.Finished = $true
    if (-not $state.Fase) { $state.Fase = 'Subida finalizada.' }
    try { Set-HdzUploadProgress $state } catch {}
}
