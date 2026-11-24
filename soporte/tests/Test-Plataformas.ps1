# Plataformas WEB: «Sin plataforma», lista ampliada, detección por nombre y nombre final.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($condition,$message){if(-not $condition){throw $message}}
$tokens=$null;$errors=$null
$gui=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'HDZ-GUI.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Get-CodigoPlataforma','ConvertTo-RegexAlias','Detectar-Plataforma')){
    Invoke-Expression ($gui.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)).Extent.Text
}
foreach($var in @('plataformasGui','platDefs')){
    $assign=$gui.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and "$($n.Left)" -match "^\`$(script:)?$var$"},$true)
    Invoke-Expression ('$script:'+$var+' = '+$assign.Right.Extent.Text)
}
# Lista: «Sin plataforma» primero y vacía; Netflix en el índice 1 (el valor por defecto); códigos únicos.
Assert ((Get-CodigoPlataforma $plataformasGui[0]) -eq '') '«Sin plataforma» debe dar código vacío'
Assert ((Get-CodigoPlataforma $plataformasGui[1]) -eq 'NF') 'Netflix debe seguir en el índice 1 (por defecto)'
$codes=@($plataformasGui | Select-Object -Skip 1 | ForEach-Object { Get-CodigoPlataforma $_ })
Assert ($codes.Count -ge 30) "Lista corta: $($codes.Count)"
Assert (@($codes | Group-Object -CaseSensitive | Where-Object Count -gt 1).Count -eq 0) 'Códigos de plataforma repetidos'
foreach($c in $codes){Assert (@($platDefs | Where-Object { $_.Cod -ceq $c }).Count -eq 1) "Sin definición de detección: $c"}
# Detección por nombre de archivo.
$casos=[ordered]@{
    'Show.S01E01.1080p.PMTP.WEB-DL.DDP5.1.H.264'='PMTP'
    'Show.S01E01.1080p.PCOK.WEB-DL.DDP5.1.H.264'='PCOK'
    'Pelicula.2024.2160p.MAX.WEB-DL.DDP5.1.HEVC'='MAX'
    'Pelicula.2024.2160p.HMAX.WEB-DL.DDP5.1.HEVC'='HMAX'
    'Mad.Max.2015.1080p.BluRay.x264'=$null
    'Serie.S01E01.1080p.ATRESplayer.WEB-DL.AAC2.0'='ATRP'
    'Serie.S01E01.1080p.Sky.Showtime.WEB-DL.DDP5.1'='SKST'
    'Serie.S01E01.1080p.Showtime.WEB-DL.DDP5.1'='SHO'
    'Drama.S01E01.1080p.Rakuten.Viki.WEB-DL.AAC'='VIKI'
    'Pelicula.2024.1080p.Rakuten.WEB-DL.DD5.1'='RKTN'
    'Anime.S01E01.1080p.CR.WEB-DL.AAC2.0.H.264'='CR'
    'Pelicula.2024.1080p.Paramount+.WEB-DL.DDP5.1'='PMTP'
    'Pelicula.2024.1080p.WEB-DL.DDP5.1.H.264'=$null
    'Pelicula.2024.1080p.NF.WEB-DL.DDP5.1.H.264'='NF'
}
foreach($k in $casos.Keys){$got=Detectar-Plataforma $k;Assert ("$got" -ceq "$($casos[$k])") "Detección '$k': '$got', esperado '$($casos[$k])'"}
# Nombre final sin plataforma: sin hueco ni espacio doble.
$eng=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'HDZnew.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Get-CodecTagHdz','Get-NombreFinalHdz')){
    Invoke-Expression ($eng.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)).Extent.Text
}
$nombre=Get-NombreFinalHdz -Base 'Película (2024)' -TipoOrigen 'WEB' -Resolucion '1080p' -PlataformaFormato '' -WebTipo 'WEB-DL' -Audio 'DD+ 5.1' -CodecVideo '264' -Sufijo $true
Assert ($nombre -ceq 'Película (2024) 1080p WEB-DL DD+ 5.1 H.264-HDZ.mkv') "Nombre sin plataforma: $nombre"
Write-Host 'OK Test-Plataformas'
