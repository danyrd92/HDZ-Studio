# Solo genera un paquete local. No publica ni reinicia instalaciones/servicios.
param([string]$Version = '1.17.0', [string]$OutputDirectory, [string]$Notes = 'Revisión de integridad, control remoto y distribución verificada.')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root ('distribucion\release-' + $Version + '-' + (Get-Date -Format yyyyMMdd-HHmmss)) }
$stage = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $stage) { throw 'La carpeta de publicación ya existe. Usa una carpeta nueva.' }
if ($Version -ne (Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -Raw).Trim()) { throw 'VERSION.txt no coincide con la publicación.' }
$scripts = @(
    'HDZ-GUI.ps1','HDZ-Interface.ps1','HDZ-Design.ps1','HDZ-Remote.ps1','web/index.html','HDZnew.ps1','HDZ-Core.ps1','HDZ-Async.ps1','HDZ-Capturas.ps1','HDZ-ImageHosts.ps1','HDZ-Torrent.ps1','HDZ-History.ps1','HDZ-Jobs.ps1',
    'HDZ-CapturasContexto.ps1','HDZ-CapturasSubida.ps1','Capturas-MenuContextual.ps1','Capturas-MenuContextual.vbs',
    'HDZ Studio.cmd','HDZ Studio.vbs','HDZ-update.config.json','VERSION.txt','HDZ.ico','hdz_logo_r.png','HDZero New logo.png','HDZStudio.png','AppxManifest.xml',
    'instalacion/Actualizar HDZ Studio.cmd','instalacion/Actualizar-HDZStudio.ps1','instalacion/Actualizar-Seguro.ps1',
    'instalacion/Desinstalar HDZ Studio.cmd','instalacion/Desinstalar-HDZStudio.ps1','instalacion/Desinstalar-Completo.ps1',
    'instalacion/Limpiar-Instalacion.ps1','instalacion/Instalar HDZ Studio.cmd','instalacion/Instalar-HDZStudio.ps1',
    'instalacion/Instalar-menu-capturas.ps1','instalacion/Instalar-RuntimeMenu.ps1','instalacion/LEEME.txt','instalacion/LICENCIAS.txt',
    'modern-menu/AppxManifest.xml','modern-menu/Capturas-MenuContextual.vbs','modern-menu/HDZ.ico',
    'modern-menu/HDZEROStudio.ContextMenu.cer','modern-menu/HDZEROStudio.ContextMenu.identity.msix',
    'modern-menu/HDZStudioModernMenu.comhost.dll','modern-menu/HDZStudioModernMenu.deps.json',
    'modern-menu/HDZStudioModernMenu.dll','modern-menu/HDZStudioModernMenu.runtimeconfig.json','modern-menu/HDZStudioModernMenu.X.manifest'
)
$toolNames = @('ffmpeg.exe','ffprobe.exe','mkvmerge.exe','mkvextract.exe','mkvpropedit.exe','MediaInfo.exe','dovi_tool.exe','PowerShell-7.6.3-win-x64.msi')
$toolFiles = @($toolNames | ForEach-Object { $file=Join-Path $root ('bin/' + $_); @{name=$_;sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $file).Length} })
foreach ($name in $scripts) { if (-not (Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf)) { throw "Falta $name" } }
# La clave privada no entra en el workspace: DPAPI para el usuario publicador.
$privateRoot = Join-Path $env:APPDATA 'HDZ-Publicacion'
[void][IO.Directory]::CreateDirectory($privateRoot)
$privatePath = Join-Path $privateRoot 'release-signing.dpapi'
Add-Type -AssemblyName System.Security
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 4096
$rsa.PersistKeyInCsp = $false
try {
    if (Test-Path -LiteralPath $privatePath) {
        $clear = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($privatePath), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { $rsa.FromXmlString([Text.Encoding]::UTF8.GetString($clear)) } finally { [Array]::Clear($clear,0,$clear.Length) }
    } else {
        $clear = [Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
        try { [IO.File]::WriteAllBytes($privatePath, [Security.Cryptography.ProtectedData]::Protect($clear,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)) } finally { [Array]::Clear($clear,0,$clear.Length) }
    }
    $utf8 = New-Object Text.UTF8Encoding $false
    [void][IO.Directory]::CreateDirectory($stage)
    foreach ($name in $scripts + @($toolNames | ForEach-Object { 'bin/' + $_ })) {
        $dest = Join-Path $stage $name
        [void][IO.Directory]::CreateDirectory((Split-Path $dest -Parent))
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination $dest
        # Windows PowerShell 5.1 necesita BOM para interpretar correctamente el español.
        if ($name -like 'instalacion/*.ps1') { [IO.File]::WriteAllText($dest,[IO.File]::ReadAllText($dest),[Text.UTF8Encoding]::new($true)) }
    }
    [IO.File]::WriteAllText((Join-Path $stage 'tools.lock.json'), (@{schema=1;version=$Version;files=$toolFiles}|ConvertTo-Json -Depth 5), $utf8)
    [IO.File]::WriteAllText((Join-Path $stage 'update-public-key.xml'), $rsa.ToXmlString($false), $utf8)
    $hashes = [ordered]@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName)) {
        $rel = $file.FullName.Substring($stage.Length).TrimStart('\','/').Replace('\','/')
        $hashes[$rel] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $manifest = [ordered]@{schema=2;version=$Version;fecha=(Get-Date -Format yyyy-MM-dd);notas=$Notes;archivos=@($hashes.Keys);sha256=$hashes}
    # GitHub Releases: el código va en un zip (sin herramientas) junto a version.json/sig, en una
    # carpeta hermana «-github». Las herramientas viven en la release «herramientas»; el
    # actualizador solo las descarga si su SHA256 no coincide con el instalado.
    $repo = "$((Get-Content -LiteralPath (Join-Path $root 'HDZ-update.config.json') -Raw | ConvertFrom-Json).repo)"
    if ($repo -notmatch '^[\w.-]+/[\w.-]+$') { throw 'HDZ-update.config.json no indica el repositorio de GitHub.' }
    $github = $stage + '-github'
    if (Test-Path -LiteralPath $github) { throw 'La carpeta de GitHub ya existe. Usa una carpeta nueva.' }
    $packageSource = Join-Path $github 'contenido'
    foreach ($name in @($hashes.Keys | Where-Object { $_ -notlike 'bin/*' })) {
        $dest = Join-Path $packageSource $name
        [void][IO.Directory]::CreateDirectory((Split-Path $dest -Parent))
        Copy-Item -LiteralPath (Join-Path $stage $name) -Destination $dest
    }
    $packageName = "HDZStudio-$Version.zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($packageSource, (Join-Path $github $packageName), [IO.Compression.CompressionLevel]::Optimal, $false)
    Remove-Item -LiteralPath $packageSource -Recurse -Force
    $manifest.paquete = [ordered]@{nombre=$packageName;sha256=(Get-FileHash -LiteralPath (Join-Path $github $packageName) -Algorithm SHA256).Hash.ToLowerInvariant()}
    $manifest.herramientas = [ordered]@{}
    foreach ($tool in $toolNames) { $manifest.herramientas['bin/' + $tool] = "https://github.com/$repo/releases/download/herramientas/$tool" }
    $manifestPath = Join-Path $stage 'version.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest|ConvertTo-Json -Depth 5), $utf8)
    $signature = $rsa.SignData([IO.File]::ReadAllBytes($manifestPath),'SHA256')
    [IO.File]::WriteAllText((Join-Path $stage 'version.sig'), [Convert]::ToBase64String($signature), $utf8)
    if (-not $rsa.VerifyData([IO.File]::ReadAllBytes($manifestPath),'SHA256',$signature)) { throw 'No se verifica la firma generada.' }
    foreach ($name in @('version.json','version.sig')) { Copy-Item -LiteralPath (Join-Path $stage $name) -Destination $github }
    Write-Host "PAQUETE_VERIFICADO: $stage ($($hashes.Count) archivos, sin configuración personal)"
    Write-Host "GITHUB_RELEASE: $github ($packageName, version.json, version.sig)"
} finally { $rsa.Dispose() }
