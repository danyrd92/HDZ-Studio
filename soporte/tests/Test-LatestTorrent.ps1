$ErrorActionPreference='Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'HDZ-History.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}
$testRoot=Join-Path $env:TEMP ('hdz_test_latest_'+[guid]::NewGuid().ToString('N'))
$script:hdzHistoryTestDirectory=Join-Path $testRoot 'history'
$out=Join-Path $testRoot 'configured'
[void][IO.Directory]::CreateDirectory($out)
$old=Join-Path $out 'older.torrent';$new=Join-Path $testRoot 'latest.torrent'
[IO.File]::WriteAllText($old,'fixture-old');[IO.File]::WriteAllText($new,'fixture-new')
$originalHash=(Get-FileHash $new).Hash
$older=Add-HdzHistory @{kind='torrent';status='Creado';torrent=$old}
$newer=Add-HdzHistory @{kind='montaje';status='Verificado';torrent=$new}
# Fecha del registro, no fecha de modificación de su JSON ni de otro .torrent.
$olderPath=Join-Path $script:hdzHistoryTestDirectory ($older.id+'.json')
$r=Get-Content $olderPath -Raw | ConvertFrom-Json
$r.date=[DateTime]::UtcNow.AddDays(-1).ToString('o')
[IO.File]::WriteAllText($olderPath,($r|ConvertTo-Json))
Assert ((Get-HdzLatestCreatedTorrent) -eq $new) 'No encuentra el historial sin carpetas de proyecto'
Assert ((Get-HdzLatestCreatedTorrent @($out)) -eq $new) 'Una carpeta sustituyó al historial más reciente'
[void](Add-HdzHistory @{kind='tracker';status='Subido';torrent=$old})
[void](Add-HdzHistory @{kind='montaje';status='Fallido';torrent=$old})
[void](Add-HdzHistory @{kind='pack';status='Pack creado';torrent=(Join-Path $testRoot 'missing.torrent')})
Assert ((Get-HdzLatestCreatedTorrent) -eq $new) 'Confunde tracker, fallo o ruta desaparecida con el último creado'
[IO.File]::Move($new,($new+'.moved'))
Assert ((Get-HdzLatestCreatedTorrent) -eq $old) 'No pasa al siguiente registro disponible'
[IO.File]::Move(($new+'.moved'),$new)
Assert ((Get-FileHash $new).Hash -eq $originalHash) 'La búsqueda modificó el archivo'
# Fallback recursivo en carpeta configurada; el historial ya no tiene archivos disponibles.
$script:hdzHistoryTestDirectory=Join-Path $testRoot 'empty-history'
$nested=Join-Path $out 'pack'
[void][IO.Directory]::CreateDirectory($nested)
$pack=Join-Path $nested 'pack.torrent';[IO.File]::WriteAllText($pack,'fixture-pack')
(Get-Item $old).LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-1)
Assert ((Get-HdzLatestCreatedTorrent @('',(Join-Path $testRoot 'missing-dir'),$out,$out)) -eq $pack) 'No busca en la carpeta configurada y sus subcarpetas'
Assert (-not (Get-HdzLatestCreatedTorrent @((Join-Path $testRoot 'missing-dir')))) 'Devuelve un éxito sin archivos'
# Un torrent histórico alterado no puede reaparecer como válido mediante el fallback.
[void](Add-HdzHistory @{kind='torrent';status='Creado';torrent=$pack})
[IO.File]::WriteAllText($pack,'modified fixture')
Assert (-not (Get-HdzLatestCreatedTorrent @($nested))) 'Acepta un torrent alterado después de registrarse'
# Regresión real: días >12 desaparecían y 10/09 se interpretaba como 09/10.
$script:hdzHistoryTestDirectory=Join-Path $testRoot 'dated-history'
$dated=@()
foreach($fixture in @(@('chompoo','2026-09-10T16:26:09.9697182Z'),@('kingsman','2026-09-13T16:06:43.3233396Z'),@('sherlock','2026-09-16T06:47:35.7621738Z'))){
    $path=Join-Path $testRoot ($fixture[0]+'.torrent');[IO.File]::WriteAllText($path,$fixture[0])
    $entry=Add-HdzHistory @{kind='torrent';status='Creado';torrent=$path}
    $file=Join-Path $script:hdzHistoryTestDirectory ($entry.id+'.json')
    $r=Get-Content $file -Raw | ConvertFrom-Json;$r.date=$fixture[1]
    [IO.File]::WriteAllText($file,($r | ConvertTo-Json));$dated+=@{File=$file;Path=$path;Hash=(Get-FileHash $path).Hash}
}
$cultureBefore=[Threading.Thread]::CurrentThread.CurrentCulture
try {
    foreach($culture in @('es-ES','en-US','en-GB','de-DE')){
        [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
        Assert ((Get-HdzLatestCreatedTorrent) -eq $dated[2].Path) "Fecha mal ordenada o descartada en $culture"
    }
    # Comparar instantes, no fechas de texto ni la última modificación del JSON.
    $r=Get-Content $dated[1].File -Raw | ConvertFrom-Json;$r.date='2026-09-16T09:00:00+02:00'
    [IO.File]::WriteAllText($dated[1].File,($r|ConvertTo-Json))
    Assert ((Get-HdzLatestCreatedTorrent) -eq $dated[1].Path) 'No compara correctamente las zonas horarias'
    $r.date='fecha-invalida';[IO.File]::WriteAllText($dated[1].File,($r|ConvertTo-Json))
    Assert ((Get-HdzLatestCreatedTorrent) -eq $dated[2].Path) 'Una fecha corrupta impide elegir el último válido'
    foreach($item in $dated){Assert ((Get-FileHash $item.Path).Hash -eq $item.Hash) 'Modificó un torrent al ordenar fechas'}
} finally {[Threading.Thread]::CurrentThread.CurrentCulture=$cultureBefore}
Write-Host "LATEST_TORRENT_REGRESSION_OK: $testRoot"
