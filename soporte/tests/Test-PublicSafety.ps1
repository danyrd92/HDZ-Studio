# Impide publicar datos privados del autor (dominios, claves, rutas personales).
# Los patrones viven FUERA del repositorio, en %APPDATA%\HDZ-Publicacion\patrones-privados.txt
# (una expresión regular por línea; '#' comenta). Sin ese archivo la prueba se omite, salvo con
# -Required (hook pre-push del publicador).
#   (sin parámetros) archivos que git publicaría: versionados + nuevos no ignorados
#   -Path <carpeta>   todos los archivos de una carpeta (instantáneas antes de versionarlas)
#   -History          todos los objetos de todo el historial del repositorio (-Repo para otro)
param([string]$Path, [switch]$History, [string]$Repo, [switch]$Required, [string]$PatternsFile = (Join-Path $env:APPDATA 'HDZ-Publicacion\patrones-privados.txt'))
$ErrorActionPreference = 'Stop'
$root = if ($Repo) { [IO.Path]::GetFullPath($Repo) } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
if (-not (Test-Path -LiteralPath $PatternsFile -PathType Leaf)) {
    if ($Required) { throw "Falta $PatternsFile; no se puede comprobar la publicación." }
    Write-Host 'PUBLIC_SAFETY_SKIPPED (sin lista de patrones privados en este equipo)'
    exit 0
}
$patterns = @(Get-Content -LiteralPath $PatternsFile -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { [regex]::new($_, 'IgnoreCase') })
if (-not $patterns.Count) { throw 'La lista de patrones privados está vacía.' }
# Latin1 conserva cada byte: los patrones ASCII se encuentran también en binarios y en UTF-8/UTF-16LE.
$latin1 = [Text.Encoding]::Latin1
function Find-Private([string]$Name, [byte[]]$Bytes) {
    $texts = @($latin1.GetString($Bytes))
    if ($Bytes.Length -gt 1 -and $Bytes -contains 0) { $texts += [Text.Encoding]::Unicode.GetString($Bytes) }
    # Se informa el número de patrón, nunca su texto: puede ser una clave.
    for ($i = 0; $i -lt $patterns.Count; $i++) {
        if ($patterns[$i].IsMatch($Name)) { return "nombre de archivo (patrón $($i+1))" }
        foreach ($text in $texts) { if ($patterns[$i].IsMatch($text)) { return "contenido (patrón $($i+1))" } }
    }
}
$found = [Collections.Generic.List[string]]::new()
if ($Path) {
    $base = [IO.Path]::GetFullPath($Path)
    foreach ($file in @(Get-ChildItem -LiteralPath $base -File -Recurse -Force)) {
        $hit = Find-Private $file.FullName.Substring($base.Length) ([IO.File]::ReadAllBytes($file.FullName))
        if ($hit) { $found.Add("$($file.FullName.Substring($base.Length).TrimStart('\')): $hit") }
    }
} elseif ($History) {
    $objects = @(git -C $root rev-list --objects --all)
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo leer el historial.' }
    foreach ($line in $objects) {
        $parts = $line.Split(' ', 2)
        if ((git -C $root cat-file -t $parts[0]) -ne 'blob') { continue }
        $temporary = [IO.Path]::GetTempFileName()
        try {
            $process = Start-Process git -ArgumentList @('-C', "`"$root`"", 'cat-file', 'blob', $parts[0]) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $temporary
            if ($process.ExitCode -ne 0) { throw "No se pudo leer el objeto $($parts[0])." }
            $hit = Find-Private "$($parts[1])" ([IO.File]::ReadAllBytes($temporary))
            if ($hit) { $found.Add("$($parts[1]) [$($parts[0].Substring(0,8))]: $hit") }
        } finally { Remove-Item -LiteralPath $temporary -Force }
    }
    foreach ($message in @(git -C $root log --all --format='%H %an %ae %cn %ce %B')) {
        foreach ($pattern in $patterns) { if ($pattern.IsMatch($message)) { $found.Add("mensaje o autor de commit: $($message.Substring(0,[Math]::Min(12,$message.Length)))") } }
    }
} else {
    $files = @(git -C $root ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'No es un repositorio git.' }
    foreach ($relative in $files) {
        $full = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $hit = Find-Private $relative ([IO.File]::ReadAllBytes($full))
        if ($hit) { $found.Add("${relative}: $hit") }
    }
}
if ($found.Count) {
    $found | Select-Object -Unique | ForEach-Object { Write-Host "PRIVADO: $_" -ForegroundColor Red }
    throw "Se encontraron $($found.Count) datos privados. No se publica nada."
}
Write-Host 'PUBLIC_SAFETY_OK'
