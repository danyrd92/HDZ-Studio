# Bloquear editores y acciones durante una espera conserva el contexto de la
# petición sin desactivar el ScrollViewer ni la navegación entre pantallas.
function Get-HdzBusyEditors($node) {
    if($node -is [Windows.Controls.Primitives.TextBoxBase] -or
       $node -is [Windows.Controls.PasswordBox] -or $node -is [Windows.Controls.ComboBox] -or
       $node -is [Windows.Controls.Primitives.ButtonBase]) {
        if($node.Name -notin @('navProyecto','navSubida','navAjustes','btnToggleSidebar','btnConsola')){$node}
        return
    }
    foreach($child in [Windows.LogicalTreeHelper]::GetChildren($node)){
        if($child -is [Windows.DependencyObject]){Get-HdzBusyEditors $child}
    }
}
function Invoke-HdzBackground([scriptblock]$Work, [hashtable]$Arguments) {
    if ($script:networkBusy) { throw 'Ya hay una operación externa en curso.' }
    $script:networkBusy = $true
    $editors=@()
    $pipeline = [powershell]::Create()
    $timer = $null
    try {
        if ($win) {
            $editors=@(Get-HdzBusyEditors $win.Content | Where-Object IsEnabled | ForEach-Object {
                @{Control=$_;Local=$_.ReadLocalValue([Windows.UIElement]::IsEnabledProperty)}
            })
            foreach($editor in $editors){$editor.Control.SetCurrentValue([Windows.UIElement]::IsEnabledProperty,$false)}
        }
        [void]$pipeline.AddScript($Work.ToString()).AddArgument($Arguments)
        $running = $pipeline.BeginInvoke()
        if (-not $running.IsCompleted) {
            $frame = [Windows.Threading.DispatcherFrame]::new()
            $timer = [Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(100)
            $timer.Add_Tick({ if ($running.IsCompleted) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            [Windows.Threading.Dispatcher]::PushFrame($frame)
        }
        $result = $pipeline.EndInvoke($running)
        if ($pipeline.HadErrors) { throw ($pipeline.Streams.Error | Select-Object -First 1) }
        return $result
    } finally {
        if ($timer) { $timer.Stop() }
        $pipeline.Dispose()
        $script:networkBusy = $false
        foreach($editor in $editors){
            if($editor.Local -eq [Windows.DependencyProperty]::UnsetValue){$editor.Control.ClearValue([Windows.UIElement]::IsEnabledProperty)}
            else{$editor.Control.SetCurrentValue([Windows.UIElement]::IsEnabledProperty,$true)}
        }
    }
}

function Get-HdzCapturePreviews([string[]]$Paths,$Cache=@{},$Sync=$null) {
    Add-Type -AssemblyName PresentationCore
    $result=@{}
    foreach($path in $Paths){
        try {
            $file=Get-Item -LiteralPath $path -Force -ErrorAction Stop
            $stamp="$($file.LastWriteTimeUtc.Ticks)|$($file.Length)"
            if($Cache.ContainsKey($path) -and $Cache[$path].Stamp -eq $stamp){$result[$path]=$Cache[$path];continue}
            # WIC sobre un FileStream/URI hace miles de lecturas pequeñas en SMB.
            # Leer secuencialmente una vez y decodificar en memoria evita esa demora.
            $bytes=[IO.File]::ReadAllBytes($path)
            $stream=[IO.MemoryStream]::new($bytes,$false)
            try {
                $bitmap=[Windows.Media.Imaging.BitmapImage]::new()
                $bitmap.BeginInit();$bitmap.StreamSource=$stream;$bitmap.DecodePixelWidth=760
                $bitmap.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bitmap.EndInit();$bitmap.Freeze()
            } finally {$stream.Dispose()}
            $scale=[Math]::Min(1,384/$bitmap.PixelWidth)
            $small=[Windows.Media.Imaging.TransformedBitmap]::new($bitmap,[Windows.Media.ScaleTransform]::new($scale,$scale))
            $small.Freeze()
            $encoder=[Windows.Media.Imaging.JpegBitmapEncoder]::new();$encoder.QualityLevel=68
            $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($small))
            $output=[IO.MemoryStream]::new()
            try{$encoder.Save($output);$thumb='data:image/jpeg;base64,'+[Convert]::ToBase64String($output.ToArray())}finally{$output.Dispose()}
            $result[$path]=@{Stamp=$stamp;Bitmap=$bitmap;Thumb=$thumb}
        } catch {
            # Una miniatura ilegible no impide abrir el torrent ni seleccionar el archivo.
            $result[$path]=@{Stamp='';Bitmap=$null;Thumb='';Error=$_.Exception.Message}
        } finally {if($Sync){$Sync.Done=[int]$Sync.Done+1}}
    }
    return $result
}

function Invoke-HdzRestMethod {
    [CmdletBinding()]
    param($Uri, $Method='Get', $Body, $Headers, $Form, $ContentType, [int]$TimeoutSec=60, $OutFile, [switch]$UseBasicParsing)
    $arguments = @{}; foreach ($key in $PSBoundParameters.Keys) { $arguments[$key] = $PSBoundParameters[$key] }
    $arguments.ErrorAction = 'Stop'
    if (-not $arguments.ContainsKey('TimeoutSec')) { $arguments.TimeoutSec = 60 }
    Invoke-HdzBackground { param($parameters) Microsoft.PowerShell.Utility\Invoke-RestMethod @parameters } $arguments
}

function Invoke-HdzWebRequest {
    [CmdletBinding()]
    param($Uri, $Method='Get', $Body, $Headers, $Form, $ContentType, [int]$TimeoutSec=60, $OutFile, [switch]$UseBasicParsing)
    $arguments = @{}; foreach ($key in $PSBoundParameters.Keys) { $arguments[$key] = $PSBoundParameters[$key] }
    $arguments.ErrorAction = 'Stop'
    if (-not $arguments.ContainsKey('TimeoutSec')) { $arguments.TimeoutSec = 60 }
    Invoke-HdzBackground { param($parameters) Microsoft.PowerShell.Utility\Invoke-WebRequest @parameters } $arguments
}
