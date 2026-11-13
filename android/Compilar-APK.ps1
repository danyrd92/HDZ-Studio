# Compila y firma la app Android sin Gradle ni Android Studio. Uso: pwsh -NoProfile -File android/Compilar-APK.ps1
# La clave de firma vive fuera del repo (DPAPI): perderla obliga a desinstalar la app para actualizarla.
param(
    [string]$Sdk = 'C:\android',
    [string]$Jdk = (Join-Path $HOME 'Tools\jdk-21.0.13+9'),
    [string]$BuildTools = '35.0.0',
    [string]$Platform = 'android-35',
    [int]$VersionCode = 2,
    [string]$VersionName = '1.1'
)
$ErrorActionPreference = 'Stop'
function Invoke-Tool([string]$Label, [string]$File, [string[]]$Arguments) {
    $output = & $File @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { $output | ForEach-Object { "$_" } | Write-Host; throw "Falló: $Label" }
}

$here = $PSScriptRoot
$build = Join-Path $here 'build'
$tools = Join-Path $Sdk "build-tools\$BuildTools"
$androidJar = Join-Path $Sdk "platforms\$Platform\android.jar"
$env:JAVA_HOME = $Jdk
$env:PATH = "$Jdk\bin;$env:PATH"
foreach ($required in @($androidJar, "$tools\aapt2.exe", "$tools\d8.bat", "$tools\apksigner.bat", "$Jdk\bin\javac.exe")) {
    if (-not (Test-Path -LiteralPath $required)) { throw "No se encuentra $required" }
}

if (Test-Path -LiteralPath $build) { Remove-Item -LiteralPath $build -Recurse -Force }
$gen = Join-Path $build 'gen'; $classes = Join-Path $build 'classes'; $dex = Join-Path $build 'dex'
foreach ($dir in @($gen, $classes, $dex)) { [void](New-Item -ItemType Directory -Force -Path $dir) }

# Icono: el logo apaisado centrado sobre fondo oscuro cuadrado.
$iconDir = Join-Path $here 'res\drawable-xxxhdpi'
$icon = Join-Path $iconDir 'ic_launcher.png'
if (-not (Test-Path -LiteralPath $icon)) {
    Add-Type -AssemblyName System.Drawing
    [void](New-Item -ItemType Directory -Force -Path $iconDir)
    $logo = [Drawing.Image]::FromFile((Join-Path (Split-Path $here -Parent) 'HDZero New logo.png'))
    $bitmap = [Drawing.Bitmap]::new(192, 192)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.InterpolationMode = 'HighQualityBicubic'
        $graphics.Clear([Drawing.Color]::FromArgb(15, 17, 21))
        $width = 168; $height = [int][Math]::Round($logo.Height * $width / $logo.Width)
        $graphics.DrawImage($logo, [int]((192 - $width) / 2), [int]((192 - $height) / 2), $width, $height)
        $bitmap.Save($icon, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose(); $logo.Dispose() }
}

$compiled = Join-Path $build 'res.zip'
Invoke-Tool 'recursos' "$tools\aapt2.exe" @('compile', '--dir', (Join-Path $here 'res'), '-o', $compiled)
$base = Join-Path $build 'base.apk'
Invoke-Tool 'enlazado' "$tools\aapt2.exe" @('link', '-I', $androidJar, '--manifest', (Join-Path $here 'AndroidManifest.xml'),
    '--min-sdk-version', '29', '--target-sdk-version', '35', '--version-code', "$VersionCode", '--version-name', $VersionName,
    '--java', $gen, '-o', $base, $compiled)

$sources = @(Get-ChildItem -LiteralPath (Join-Path $here 'src'), $gen -Recurse -Filter *.java | ForEach-Object FullName)
Invoke-Tool 'javac' "$Jdk\bin\javac.exe" (@('-nowarn', '-Xlint:-options', '--release', '8', '-encoding', 'UTF-8', '-classpath', $androidJar, '-d', $classes) + $sources)
$classFiles = @(Get-ChildItem -LiteralPath $classes -Recurse -Filter *.class | ForEach-Object FullName)
Invoke-Tool 'd8' "$tools\d8.bat" (@('--release', '--lib', $androidJar, '--min-api', '29', '--output', $dex) + $classFiles)

Copy-Item -LiteralPath (Join-Path $dex 'classes.dex') -Destination (Join-Path $build 'classes.dex')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($base, 'Update')
try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $build 'classes.dex'), 'classes.dex') } finally { $zip.Dispose() }
$aligned = Join-Path $build 'aligned.apk'
Invoke-Tool 'zipalign' "$tools\zipalign.exe" @('-f', '-p', '4', $base, $aligned)

$keyDir = Join-Path $env:APPDATA 'HDZ-Publicacion'
$keystore = Join-Path $keyDir 'android-release.jks'
$passFile = Join-Path $keyDir 'android-release.dpapi'
Add-Type -AssemblyName System.Security
if (-not (Test-Path -LiteralPath $keystore)) {
    [void](New-Item -ItemType Directory -Force -Path $keyDir)
    $random = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($random)
    $password = [Convert]::ToHexString($random)
    $protected = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($password), $null, 'CurrentUser')
    [IO.File]::WriteAllBytes($passFile, $protected)
    $env:HDZ_KEY_PASS = $password
    Invoke-Tool 'clave' "$Jdk\bin\keytool.exe" @('-genkeypair', '-keystore', $keystore, '-storepass:env', 'HDZ_KEY_PASS', '-keypass:env', 'HDZ_KEY_PASS',
        '-alias', 'hdz', '-keyalg', 'RSA', '-keysize', '3072', '-validity', '12000', '-dname', 'CN=HDZ Studio')
} else {
    $env:HDZ_KEY_PASS = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($passFile), $null, 'CurrentUser'))
}
$apk = Join-Path $build "HDZStudio-Remoto-$VersionName.apk"
try {
    Invoke-Tool 'firma' "$tools\apksigner.bat" @('sign', '--ks', $keystore, '--ks-pass', 'env:HDZ_KEY_PASS', '--key-pass', 'env:HDZ_KEY_PASS', '--ks-key-alias', 'hdz', '--out', $apk, $aligned)
} finally { Remove-Item Env:HDZ_KEY_PASS -ErrorAction SilentlyContinue }
Invoke-Tool 'verificación' "$tools\apksigner.bat" @('verify', $apk)
"APK_OK: $apk"
