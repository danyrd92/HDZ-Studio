$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'HDZ-GUI.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Get-CapturaBbcode','Get-HdzLogoPersonalizadoUrl','Add-HdzImageTags','Get-HdzCaptureDescription','Insert-ImagenesEnDescripcion','Rehacer-CapturasDescripcion')){
    $fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    Invoke-Expression $fn.Extent.Text
}
. (Join-Path $root 'HDZ-CapturasContexto.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}
function Actualizar-ContadorCapturas {}
$full='https://iili.io/example.png';$thumb='https://iili.io/example.md.png';$page='https://freeimage.host/i/example'
$expected="[img=350]$full[/img]"
$script:imageHostMeta=@{};$script:imageHostMeta[$full]=@{Thumb=$thumb;Page=$page}
Assert ((Get-CapturaBbcode $full) -eq $expected) 'El escritorio/web no usa solo la imagen original'
Assert ((Get-HdzContextScreenshotBbcode -Full $full) -eq $expected) 'El menú contextual no usa el mismo formato'
Assert (-not (Get-HdzContextScreenshotBbcode '')) 'Genera una etiqueta vacía'
$script:capRows=@([pscustomobject]@{Subida=$full;Check=[pscustomobject]@{IsChecked=$true}})
$script:suprimirRehacerCaps=$false
$other='[url=https://example.com]Otro enlace[/url]'
$banner='[img=700]https://example.com/banner.png[/img]'
$ui=@{upDescripcion=[pscustomobject]@{Text="[center]`n$banner`n$other`n[url=$page][img=350]$thumb[/img][/url]`n[/center]"}}
Rehacer-CapturasDescripcion
Assert ($ui.upDescripcion.Text.Contains($expected) -and -not $ui.upDescripcion.Text.Contains($page) -and -not $ui.upDescripcion.Text.Contains($thumb)) 'No sustituye el formato anterior'
Assert ($ui.upDescripcion.Text.Contains($other) -and $ui.upDescripcion.Text.Contains($banner)) 'Modificó enlaces o banner ajenos a las capturas'
Rehacer-CapturasDescripcion
Assert ([regex]::Matches($ui.upDescripcion.Text,[regex]::Escape($expected)).Count -eq 1) 'Duplica capturas al reconstruir'
$script:capRows[0].Check.IsChecked=$false;Rehacer-CapturasDescripcion
Assert (-not $ui.upDescripcion.Text.Contains($full) -and -not $ui.upDescripcion.Text.Contains('[url=]')) 'No elimina una captura desmarcada'
$script:imageHostMeta=@{}
Assert ((Get-CapturaBbcode $full) -eq $expected) 'Depende de metadatos del host para generar la etiqueta simple'
foreach($bad in @('https://pixhost.to/show/1/file.png','https://freeimage.host/i/example','javascript:alert(1)','https://example.com/page','https://example.com/file.png[/img]')){
    $failed=$false;try{Get-CapturaBbcode $bad | Out-Null}catch{$failed=$true}
    Assert $failed "Aceptó un enlace no directo: $bad"
}
Assert ((Get-HdzLogoPersonalizadoUrl 'https://image.tmdb.org/t/p/original/logo.png') -eq 'https://image.tmdb.org/t/p/original/logo.png') 'No acepta una URL directa de logo de TMDB'
foreach($badLogo in @('http://image.tmdb.org/logo.png','https://example.com/logo.html','https://example.com/logo.png[/img]')){
    $failed=$false;try{Get-HdzLogoPersonalizadoUrl $badLogo | Out-Null}catch{$failed=$true}
    Assert $failed "Aceptó una URL de logo no directa: $badLogo"
}
$manual="[center]`nPrimera línea`n`nSegunda línea`n`n`nTercera línea`n[/center]"
Assert ((Get-HdzCaptureDescription $manual @()) -eq $manual) 'La reconstrucción de capturas altera saltos de línea manuales'
$conCaptura=Add-HdzImageTags $manual @($full)
Assert ($conCaptura.Contains("Segunda línea`n`n`nTercera línea`n[img=350]")) 'Añadir capturas recorta los saltos de línea manuales'
$two=Add-HdzImageTags '[center][/center]' @($full,'https://i.ibb.co/test/second.jpeg')
Assert ($two.Contains('[/img]   [img=350]')) 'No coloca capturas contiguas en la misma fila'
foreach($count in @(1,5,6,10,11)){
    $grouped=Add-HdzImageTags '[center][/center]' @(1..$count | ForEach-Object {"https://i.ibb.co/test/cap-$_.png"})
    $rows=@($grouped -split '\r?\n' | Where-Object {$_ -match '\[img=350\]'})
    Assert ($rows.Count -eq [Math]::Ceiling($count/5)) "Número de filas incorrecto para $count capturas"
    for($i=0;$i -lt $rows.Count;$i++){
        Assert ([regex]::Matches($rows[$i],'\[img=350\]').Count -eq [Math]::Min(5,$count-5*$i)) 'No agrupa en filas de cinco'
    }
    Assert (-not $grouped.Contains("[/img]`n`n[img=350]")) 'Hay una fila en blanco entre grupos'
    $contextRows=Join-HdzContextScreenshotRows @(1..$count | ForEach-Object {Get-HdzContextScreenshotBbcode "https://i.ibb.co/test/cap-$_.png"})
    Assert (($rows -join "`n") -eq ($contextRows -replace "`r`n","`n")) 'El menú contextual no agrupa igual que escritorio/web'
}
Write-Host 'SCREENSHOT_BBCODE_REGRESSION_OK: imagen directa, URL de logo, saltos manuales, escritorio/web/contextual, migración y selección'
