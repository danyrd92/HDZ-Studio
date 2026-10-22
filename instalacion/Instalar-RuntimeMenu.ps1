# Runtime fijado de Microsoft para el componente COM del menú moderno.
$ErrorActionPreference = 'Stop'
$programFilesNative = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$dotnet = Join-Path $programFilesNative 'dotnet\dotnet.exe'
if ((Test-Path -LiteralPath $dotnet) -and (& $dotnet --list-runtimes | Select-String '^Microsoft.NETCore.App 8\.0\.')) { return }
$expected = '2dc2f346a4bcb53ab15ab6ab84348c02eb31b0a3d4e8e06aac73b4c89f1b001af01943ed4c5735fa5585f1dd731a942d2034577dfe937f4454367ff2d6edf929'
$path = Join-Path $env:TEMP ('hdz_net8_' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    try { $client.DownloadFile('https://builds.dotnet.microsoft.com/dotnet/Runtime/8.0.31/dotnet-runtime-8.0.31-win-x64.exe', $path) } finally { $client.Dispose() }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA512).Hash -ne $expected) { throw 'El runtime descargado no coincide con el publicado por Microsoft.' }
    if ((Get-AuthenticodeSignature -LiteralPath $path).Status -ne 'Valid') { throw 'Firma de Microsoft no válida.' }
    $process = Start-Process -FilePath $path -ArgumentList '/install /quiet /norestart' -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -notin @(0,3010)) { throw "No se pudo instalar .NET 8 (código $($process.ExitCode))." }
    if (-not (Test-Path -LiteralPath $dotnet) -or -not (& $dotnet --list-runtimes | Select-String '^Microsoft.NETCore.App 8\.0\.')) { throw 'No se encuentra .NET 8 después de instalarlo.' }
} finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
