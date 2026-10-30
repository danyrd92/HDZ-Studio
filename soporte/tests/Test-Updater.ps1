$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$testRoot = Join-Path $env:TEMP ('hdz_test_updater_' + [guid]::NewGuid().ToString('N'))
$server = Join-Path $testRoot 'server'; $installed = Join-Path $testRoot 'installed'
foreach ($dir in @($server, $installed, (Join-Path $installed 'instalacion'))) { [void][IO.Directory]::CreateDirectory($dir) }
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-Fixture($Path, $Text) { [IO.File]::WriteAllText($Path, $Text, $utf8) }
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$names = @('HDZ-GUI.ps1','HDZnew.ps1','HDZ-Core.ps1','HDZ-Async.ps1','HDZ-Capturas.ps1','HDZ-Torrent.ps1','VERSION.txt')
$hashes = [ordered]@{}
foreach ($name in $names) {
    Write-Fixture (Join-Path $installed $name) $(if($name -eq 'VERSION.txt') {'1.0.0'} else {'# old '+$name})
    Write-Fixture (Join-Path $server $name) $(if($name -eq 'VERSION.txt') {'2.0.0'} else {'# new '+$name})
    $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $server $name)).Hash
}
Write-Fixture (Join-Path $server 'version.json') (@{schema=2;version='2.0.0';archivos=$names;sha256=$hashes}|ConvertTo-Json -Depth 5)
Write-Fixture (Join-Path $installed 'HDZ-update.config.json') '{"baseUrl":"https://invalid.example/"}'
Copy-Item -LiteralPath (Join-Path $root 'instalacion/Actualizar-Seguro.ps1') -Destination (Join-Path $installed 'instalacion/Actualizar-Seguro.ps1')
$rsa = [Security.Cryptography.RSACryptoServiceProvider]::new(2048); $rsa.PersistKeyInCsp = $false
try {
    Write-Fixture (Join-Path $installed 'update-public-key.xml') $rsa.ToXmlString($false)
    $signature = [Convert]::ToBase64String($rsa.SignData([IO.File]::ReadAllBytes((Join-Path $server 'version.json')), 'SHA256'))
    Write-Fixture (Join-Path $server 'version.sig') $signature
    $env:HDZ_UPDATE_BASE = ([Uri]($server + '\')).AbsoluteUri
    $scriptPath = Join-Path $installed 'instalacion/Actualizar-Seguro.ps1'
    # Hash incorrecto: ni un archivo instalado debe cambiar.
    Write-Fixture (Join-Path $server 'HDZ-Core.ps1') '# tampered'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -NoRelanzar 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 1) 'Aceptó una descarga modificada'
    Assert ([IO.File]::ReadAllText((Join-Path $installed 'HDZ-Async.ps1')) -eq '# old HDZ-Async.ps1') 'Cambió archivos antes de verificar todas las descargas'
    Write-Fixture (Join-Path $server 'HDZ-Core.ps1') '# new HDZ-Core.ps1'
    # Firma incorrecta: rechazo antes de descargar componentes.
    Write-Fixture (Join-Path $server 'version.sig') ([Convert]::ToBase64String([byte[]](1,2,3)))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -NoRelanzar 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 1) 'Aceptó una firma falsa'
    Write-Fixture (Join-Path $server 'version.sig') $signature
    # El bloqueo de una DLL/script devuelve TODOS los anteriores a su estado original.
    $locked = [IO.File]::Open((Join-Path $installed 'HDZ-GUI.ps1'), 'Open', 'Read', 'Read')
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -NoRelanzar 2>&1 | Out-Null
        Assert ($LASTEXITCODE -eq 1) 'La actualización ignoró un archivo bloqueado'
    } finally { $locked.Dispose() }
    foreach ($name in $names) { Assert ([IO.File]::ReadAllText((Join-Path $installed $name)) -eq $(if($name -eq 'VERSION.txt') {'1.0.0'} else {'# old '+$name})) "No revirtió $name" }
    # Mismo arranque que la GUI: Start-Process hereda PSModulePath de PS7.
    # El operador & lo sanea al invocar PS5.1 y ocultaba esta regresión.
    $run=Start-Process powershell.exe -WindowStyle Hidden -PassThru -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$scriptPath+'"'),'-NoRelanzar') -RedirectStandardOutput (Join-Path $testRoot 'gui-launch-output.txt') -RedirectStandardError (Join-Path $testRoot 'gui-launch-error.txt')
    Assert ($run.ExitCode -eq 0) "No se pudo instalar desde el entorno real de la GUI: $testRoot"
    foreach ($name in $names) { Assert ((Get-FileHash -LiteralPath (Join-Path $installed $name)).Hash -eq $hashes[$name]) "Hash instalado incorrecto: $name" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -NoRelanzar -Forzar 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Falló la comprobación de una versión ya instalada'
    # Relanzamiento desatendido real con un VBS inocuo: no abre HDZ ni usa la red.
    $marker=Join-Path $installed 'reopened.txt'
    Write-Fixture (Join-Path $installed 'HDZ Studio.vbs') ('CreateObject("Scripting.FileSystemObject").CreateTextFile("' + $marker + '", True).Close')
    function Assert-Reopened {
        $limit=[datetime]::UtcNow.AddSeconds(8)
        while(-not (Test-Path -LiteralPath $marker) -and [datetime]::UtcNow -lt $limit){Start-Sleep -Milliseconds 100}
        Assert (Test-Path -LiteralPath $marker) 'No reabrió después de una petición desatendida'
        # Defender/WSH puede seguir cerrando el fichero al detectarse su existencia.
        # Espera acotada: este bloqueo del fixture no es un fallo del actualizador.
        while(Test-Path -LiteralPath $marker){
            try{Remove-Item -LiteralPath $marker -ErrorAction Stop}catch{
                if([datetime]::UtcNow -ge $limit){throw};Start-Sleep -Milliseconds 100
            }
        }
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WaitForProcessId 2147483647 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Falló la petición que ya estaba actualizada'
    Assert-Reopened
    Write-Fixture (Join-Path $server 'version.sig') ([Convert]::ToBase64String([byte[]](1,2,3)))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WaitForProcessId 2147483647 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 1) 'Aceptó firma falsa en modo desatendido'
    Assert-Reopened
    Assert (-not (Get-Content (Join-Path $installed 'instalacion/ultimo-resultado.json') -Raw | ConvertFrom-Json).ok) 'No conservó el aviso de fallo'
    Write-Fixture (Join-Path $server 'version.sig') $signature
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Forzar -WaitForProcessId 2147483647 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Falló actualización desatendida válida'
    Assert-Reopened
    # Modo GitHub Releases: todo el código en un zip firmado por su huella; una herramienta que
    # ya coincide no se descarga (su URL HTTPS es inalcanzable a propósito).
    $zipServer = Join-Path $testRoot 'github'; $zipContent = Join-Path $testRoot 'zip-content'
    foreach ($dir in @($zipServer, (Join-Path $zipContent 'bin'), (Join-Path $installed 'bin'))) { [void][IO.Directory]::CreateDirectory($dir) }
    Write-Fixture (Join-Path $installed 'bin/tool.exe') 'tool v1'
    $zipHashes = [ordered]@{'bin/tool.exe'=(Get-FileHash -LiteralPath (Join-Path $installed 'bin/tool.exe')).Hash}
    foreach ($name in $names) {
        Write-Fixture (Join-Path $zipContent $name) $(if($name -eq 'VERSION.txt') {'3.0.0'} else {'# zip '+$name})
        $zipHashes[$name] = (Get-FileHash -LiteralPath (Join-Path $zipContent $name)).Hash
    }
    Remove-Item -LiteralPath (Join-Path $zipContent 'bin') -Recurse
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $zipServer 'HDZStudio-3.0.0.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($zipContent, $zipPath)
    function Write-ZipManifest($PackageHash) {
        Write-Fixture (Join-Path $zipServer 'version.json') (@{schema=2;version='3.0.0';archivos=@($zipHashes.Keys);sha256=$zipHashes;paquete=@{nombre='HDZStudio-3.0.0.zip';sha256=$PackageHash};herramientas=@{'bin/tool.exe'='https://invalid.example/tool.exe'}}|ConvertTo-Json -Depth 5)
        Write-Fixture (Join-Path $zipServer 'version.sig') ([Convert]::ToBase64String($rsa.SignData([IO.File]::ReadAllBytes((Join-Path $zipServer 'version.json')), 'SHA256')))
    }
    $env:HDZ_UPDATE_BASE = ([Uri]($zipServer + '\')).AbsoluteUri
    Write-ZipManifest ('0' * 64)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -NoRelanzar 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 1) 'Aceptó un zip cuya huella no coincide con el manifiesto firmado'
    Assert ([IO.File]::ReadAllText((Join-Path $installed 'VERSION.txt')) -eq '2.0.0') 'Cambió archivos con un zip no verificado'
    Write-ZipManifest (Get-FileHash -LiteralPath $zipPath).Hash
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -NoRelanzar 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'No instaló el paquete zip verificado'
    foreach ($name in $names) { Assert ((Get-FileHash -LiteralPath (Join-Path $installed $name)).Hash -eq $zipHashes[$name]) "Hash instalado desde zip incorrecto: $name" }
    Assert ([IO.File]::ReadAllText((Join-Path $installed 'bin/tool.exe')) -eq 'tool v1') 'Tocó una herramienta que ya coincidía'
    # Configuración sin fallbackUrls (la publicada para GitHub): no debe confundirse con una URL no HTTPS.
    Remove-Item Env:HDZ_UPDATE_BASE
    Write-Fixture (Join-Path $installed 'HDZ-update.config.json') '{"baseUrl":"https://127.0.0.1:9/"}'
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -NoRelanzar 2>&1 | Out-String
    Assert ($output -notmatch 'alternativa' -and $output -match 'descargar version\.json') "Una lista de respaldo vacía bloqueó la actualización: $output"
    Write-Host "UPDATER_REGRESSION_OK — PS5.1 desde Start-Process/PS7, firma, SHA256, reversión y actualización acumulativa. Pruebas: $testRoot"
} finally {
    $rsa.Dispose()
    Remove-Item Env:HDZ_UPDATE_BASE -ErrorAction SilentlyContinue
}
