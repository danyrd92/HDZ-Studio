# Resolución compartida: datos reales, sin tocar medios del usuario.
$ErrorActionPreference='Stop'
$resolutionAppRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $resolutionAppRoot 'HDZ-Core.ps1')
function Assert($ok,$message){if(-not $ok){throw $message}}
$cases=@(
    @(720,480,'Interlaced','', '480i',9), @(720,576,'Interlaced','', '576i',7),
    @(720,480,'Progressive','', '480p',8), @(720,576,'Progressive','', '576p',6),
    @(704,480,'','tt', '480i',9), @(720,576,'','bb', '576i',7),
    @(1920,1080,'MBAFF','', '1080i',4), @(1440,1080,'Interlaced','', '1080i',4),
    @(1920,1080,'','tb', '1080i',4), @(1920,1080,'','bt', '1080i',4),
    @(1280,720,'Progressive','', '720p',5), @(1280,536,'Progressive','', '720p',5),
    @(1920,800,'Progressive','', '1080p',3), @(1920,1088,'Progressive','', '1080p',3),
    @(2048,858,'Progressive','', '1080p',3), @(3840,1600,'Progressive','', '2160p',2),
    @(3840,2160,'Progressive','', '2160p',2), @(4096,1716,'Progressive','', '2160p',2),
    @(7680,4320,'Progressive','', '4320p',1), @(2560,1440,'Progressive','', '1440p',10),
    @(160,90,'Progressive','', '90p',10), @(0,0,'','', '',$null),
    @(720,480,'Progressive','tt', '480p',8), @(720,480,'','unknown', '480p',8)
)
foreach($case in $cases){
    $video=@{Width=$case[0];Height=$case[1];ScanType=$case[2];field_order=$case[3]}
    $label=Get-HdzVideoResolution $video
    Assert ($label -ceq $case[4]) "Resolución incorrecta: $($case -join ',') -> $label"
    Assert ((Get-HdzResolutionTrackerId $label) -eq $case[5]) "ID del tracker incorrecto: $label"
}
Assert ((Get-HdzVideoResolution $null) -eq '') 'Se inventa una resolución sin vídeo'
Assert ((Get-HdzVideoResolution @{Height='incorrecto'}) -eq '') 'Se inventa HD con dimensiones inválidas'
Assert ((Get-HdzVideoResolution @{Height=720}) -eq '720p') 'Compatibilidad de escaneos sin anchura'
$resolutionTestRoot=Join-Path $env:TEMP ('hdz_resolution_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($resolutionTestRoot)
$env:HDZ_GUI_TEST='1';$env:HDZ_GUI_TEST_DIR=$resolutionTestRoot
try {
    . (Join-Path $resolutionAppRoot 'HDZ-GUI.ps1')
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $resolutionAppRoot 'HDZnew.ps1'),[ref]$tokens,[ref]$errors)
    foreach($name in @('Get-MediainfoJson','Get-DatosTecnicosMkv')) {
        $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $cacheMediainfo=@{}
    $fixtures=@(@(720,480,$true,'480i',9),@(720,576,$true,'576i',7),@(720,480,$false,'480p',8),@(1280,720,$false,'720p',5))
    foreach($fixture in $fixtures){
        $path=Join-Path $resolutionTestRoot ("Resolution.$($fixture[3]).mkv")
        $encode=@('-c:v','mpeg2video')
        if($fixture[2]){$encode+=@('-flags','+ilme+ildct','-top','1')}
        & (Join-Path $resolutionAppRoot 'bin/ffmpeg.exe') -v error -f lavfi -i "color=c=blue:s=$($fixture[0])x$($fixture[1]):r=25:d=0.4" @encode $path
        Assert ($LASTEXITCODE -eq 0) 'Falló el fixture de resolución'
        $originalHash=(Get-FileHash -LiteralPath $path).Hash
        $scan=@(& $scanWorker @($path))
        Assert ($scan.Count -eq 1 -and -not $scan[0].Error) 'El escaneo no puede analizar el fixture'
        Assert ((Get-HdzVideoResolution $scan[0].Video) -eq $fixture[3]) 'ffprobe y MediaInfo discrepan'
        Assert ((Get-DatosTecnicosMkv $path).Resolucion -eq $fixture[3]) 'El motor etiqueta mal el vídeo'
        Assert ((Get-SpecsVideo $path).Resolucion -eq $fixture[4]) 'La subida propone una resolución errónea'
        Set-VideosElegidos @($path)
        $state=Componer-EstadoAgente | ConvertFrom-Json
        Assert (($state.lote[0].badges.t -join ' ') -match [regex]::Escape($fixture[3])) 'La web recibe una resolución errónea'
        Assert ((Get-FileHash -LiteralPath $path).Hash -eq $originalHash) 'Se modificó el vídeo al analizarlo'
    }
    $cacheMediainfo['missing-fixture']=$null
    Assert ((Get-DatosTecnicosMkv 'missing-fixture').Resolucion -eq '') 'El motor inventa 1080p al fallar MediaInfo'
    Write-Host "RESOLUTION_REGRESSION_OK: $($cases.Count) casos, MPEG-2 real 480i/576i/480p/720p, motor, tracker y web. $resolutionTestRoot"
} finally {
    Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_GUI_TEST_DIR -ErrorAction SilentlyContinue
}
