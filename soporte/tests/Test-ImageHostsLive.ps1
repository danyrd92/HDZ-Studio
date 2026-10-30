# Prueba manual: publica únicamente una imagen sintética en los hosts indicados.
param([string[]]$Providers=@('FREEIMAGE','IMGBOX','PIXHOST'))
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'HDZ-ImageHosts.ps1')
$testRoot=Join-Path $env:TEMP ('hdz_image_live_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$file=Join-Path $testRoot 'HDZ-connectivity-test.png'
& (Join-Path $root 'bin/ffmpeg.exe') -v error -f lavfi -i 'testsrc=size=1280x720' -frames:v 1 $file
if($LASTEXITCODE -ne 0){throw 'No se pudo generar fixture'}
$expected=(Get-FileHash $file).Hash
$settings=@{ImgbbKey='';ImgboxUser='';ImgboxPass=''}
$results=@()
foreach($provider in $Providers) {
    $context=@{Gal=$null;Notices=[Collections.Generic.List[string]]::new()}
    Write-Host "LIVE_TEST_START: $provider"
    try {
        $item=Invoke-HdzHostUpload $provider $file $settings 'HDZ connectivity test' $context
        Assert-HdzHostedImage $item $expected
        $results+=@{Host=$provider;OK=$true;Full=$item.Full;Thumb=$item.Thumb;Page=$item.Page}
        Write-Host "LIVE_TEST_OK: $provider — original idéntico y miniatura proporcional"
    } catch {
        $errorText=Get-HdzUploadError $_ $settings
        Write-Host "LIVE_TEST_FAILED: $provider — $errorText"
        if($_.ErrorDetails.Message){Write-Host (($_.ErrorDetails.Message -replace '(?i)((?:key|token|password|secret)["'']?\s*[:=]\s*["'']?)[^&\s,"'']+','$1[OCULTO]').Substring(0,[Math]::Min(500,$_.ErrorDetails.Message.Length)))}
        $results+=@{Host=$provider;OK=$false;Error=$errorText}
    }
}
[IO.File]::WriteAllText((Join-Path $testRoot 'results.json'),($results|ConvertTo-Json -Depth 5))
Write-Host "LIVE_TEST_RESULTS: $testRoot"
