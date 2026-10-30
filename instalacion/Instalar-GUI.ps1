# =========================================================================
# Instalar-GUI.ps1  —  Instalador WPF (oscuro, igual que la GUI) de HDZ Studio
# =========================================================================
# Asistente con la MISMA interfaz que el programa (mismos colores/estilos).
# Corre en Windows PowerShell 5.1 (WPF de .NET Framework), porque debe poder
# ejecutarse ANTES de instalar PowerShell 7. No usar sintaxis exclusiva de PS7.
#
# Flujo:
#   1) Bienvenida: elegir carpeta destino (por defecto Archivos de programa).
#   2) Instalar: extrae el payload (HDZpayload.zip que viaja junto a este script),
#      ejecuta Instalar-HDZStudio.ps1 (PS7 offline + herramientas + accesos),
#      y registra el desinstalador en "Agregar o quitar programas".
#   3) Fin: abrir el programa o cerrar.
#
# Lo lanza run.cmd. El propio script se auto-eleva si hace falta (ver bloque más
# abajo). $env:HDZ_SETUP_TEST=1 renderiza las pantallas a PNG sin instalar.
# =========================================================================

$ErrorActionPreference = "Stop"
$script:modoTest = ($env:HDZ_SETUP_TEST -eq "1")

$selfDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadZip = Join-Path $selfDir "HDZpayload.zip"
$icoPath    = Join-Path $selfDir "HDZ.ico"
$destinoDef = Join-Path ${env:ProgramFiles} "HDZ Studio"

# --- Auto-elevación (red de seguridad) ---------------------------------------
# Instalar en "Archivos de programa" requiere administrador. El .exe debería
# elevarse solo por su manifiesto, pero si por cualquier motivo llegamos aquí SIN
# privilegios, nos relanzamos elevados (UAC) y esperamos a que termine. Sin esto,
# CreateDirectory sobre C:\Program Files da "Acceso denegado".
if (-not $script:modoTest) {
    $idActual = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $prActual = New-Object System.Security.Principal.WindowsPrincipal($idActual)
    if (-not $prActual.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)) {
        $scriptPath = $MyInvocation.MyCommand.Path
        try {
            $argsRelanz = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$scriptPath`"")
            Start-Process "powershell.exe" -Verb RunAs -WindowStyle Hidden -ArgumentList $argsRelanz -Wait
        } catch {
            # El usuario canceló el aviso de administrador (UAC): sin permisos no se
            # puede instalar en Archivos de programa. Se sale sin hacer nada.
        }
        return
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

# AppUserModelID propio: desacopla del proceso powershell.exe para que la barra de tareas
# muestre NUESTRO icono (y no el de PowerShell). Debe fijarse antes de crear el HWND.
try {
    Add-Type -Namespace HdzSetup -Name Shell -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError=true)]
public static extern void SetCurrentProcessExplicitAppUserModelID([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string AppID);
'@
    [HdzSetup.Shell]::SetCurrentProcessExplicitAppUserModelID("HDZ.Studio.Setup")
} catch {}
# DWM (barra de título oscura) + icono nativo de ventana (WM_SETICON con los frames reales del .ico)
Add-Type -Namespace HdzSetup -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
'@
Add-Type -Namespace HdzSetup -Name IconApi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr LoadImage(System.IntPtr hinst, string lpszName, uint uType, int cx, int cy, uint fuLoad);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, int Msg, System.IntPtr wParam, System.IntPtr lParam);
'@

# --- XAML: clon del estilo de la GUI (paleta y estilos idénticos) ---------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HD ZERO Studio — Instalador" Width="640" Height="580"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        Background="#0C0C0F" FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush"          Color="#0C0C0F"/>
    <SolidColorBrush x:Key="CardBrush"        Color="#131316"/>
    <SolidColorBrush x:Key="CardBorderBrush"  Color="#242429"/>
    <SolidColorBrush x:Key="FieldBrush"       Color="#0E0E11"/>
    <SolidColorBrush x:Key="FieldBorderBrush" Color="#2E2E35"/>
    <SolidColorBrush x:Key="ChipBrush"        Color="#1A1A1F"/>
    <SolidColorBrush x:Key="ChipBorderBrush"  Color="#2E2E35"/>
    <SolidColorBrush x:Key="TextBrush"        Color="#EDEDEF"/>
    <SolidColorBrush x:Key="SubBrush"         Color="#9C9CA8"/>
    <SolidColorBrush x:Key="MutedBrush"       Color="#5E5E66"/>
    <SolidColorBrush x:Key="AccentBrush"      Color="#D92B2B"/>
    <SolidColorBrush x:Key="AccentHoverBrush" Color="#EF4444"/>
    <SolidColorBrush x:Key="OkBrush"          Color="#86D97C"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource CardBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18,15"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="H" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="D" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource SubBrush}"/>
      <Setter Property="FontSize" Value="12"/><Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,3,0,0"/>
    </Style>
    <Style x:Key="Lbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource SubBrush}"/>
      <Setter Property="FontSize" Value="12"/><Setter Property="Margin" Value="0,0,0,5"/>
    </Style>
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{StaticResource FieldBrush}" BorderBrush="{StaticResource FieldBorderBrush}"
                    BorderThickness="1" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="11,9" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="White"/><Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{StaticResource AccentBrush}" CornerRadius="10" Padding="26,12">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{StaticResource AccentHoverBrush}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#A81E1E"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{StaticResource ChipBrush}" BorderBrush="{StaticResource ChipBorderBrush}"
                    BorderThickness="1" CornerRadius="8" Padding="16,9">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#3A3A42"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Bar" TargetType="ProgressBar">
      <Setter Property="Height" Value="9"/>
      <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
      <Setter Property="Background" Value="#1A1A1F"/><Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border Background="{TemplateBinding Background}" CornerRadius="5">
              <Grid>
                <Border x:Name="PART_Track"/>
                <Border x:Name="PART_Indicator" HorizontalAlignment="Left"
                        Background="{TemplateBinding Foreground}" CornerRadius="5"/>
              </Grid>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="22,20,22,18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Cabecera: logo (mismo wordmark legible que la GUI) + marca -->
    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="2,0,0,16" VerticalAlignment="Center">
      <Image x:Name="imgLogo" MaxHeight="50" VerticalAlignment="Center"
             RenderOptions.BitmapScalingMode="HighQuality"/>
      <!-- Solo se muestra si NO carga el wordmark (reserva con el icono de marca). -->
      <TextBlock x:Name="lblMarca" Text="HD ZERO Studio" Foreground="#EDEDEF" FontSize="21"
                 FontWeight="SemiBold" VerticalAlignment="Center" Margin="14,0,0,0" Visibility="Collapsed"/>
      <TextBlock x:Name="lblSub" Text="Asistente de instalación" Foreground="#9C9CA8"
                 FontSize="12.5" VerticalAlignment="Bottom" Margin="14,0,0,7"/>
    </StackPanel>

    <!-- ZONA CENTRAL (cambia de estado) -->
    <Grid Grid.Row="1">
      <!-- Bienvenida -->
      <StackPanel x:Name="panBienvenida">
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Style="{StaticResource H}" Text="Se instalará en"/>
            <TextBlock Style="{StaticResource D}" Text="El programa, las herramientas (FFmpeg, MKVToolNix, MediaInfo, dovi_tool) y PowerShell 7 se instalan aquí. Todo va incluido: no necesita internet."/>
            <Grid Margin="0,12,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="txtDestino" Grid.Column="0" Style="{StaticResource Input}" IsReadOnly="True"/>
              <Button x:Name="btnExaminar" Grid.Column="1" Style="{StaticResource Ghost}" Content="Examinar" Margin="9,0,0,0"/>
            </Grid>
          </StackPanel>
        </Border>
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Style="{StaticResource H}" Text="Qué hará el instalador"/>
            <TextBlock Style="{StaticResource D}" Text="• Copia el programa a la carpeta elegida.&#10;• Instala PowerShell 7 (incluido, sin internet) si no lo tienes.&#10;• Deja las herramientas listas en «bin».&#10;• Crea el acceso directo «HD ZERO Studio» en el Escritorio y el Menú Inicio.&#10;• Registra el desinstalador en «Agregar o quitar programas»."/>
          </StackPanel>
        </Border>
      </StackPanel>

      <!-- Progreso -->
      <StackPanel x:Name="panProgreso" Visibility="Collapsed" VerticalAlignment="Center">
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock x:Name="lblEstado" Style="{StaticResource H}" Text="Instalando…"/>
            <ProgressBar x:Name="barProg" Style="{StaticResource Bar}" Minimum="0" Maximum="100" Value="0" Margin="0,14,0,8"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="lblArchivo" Grid.Column="0" Style="{StaticResource D}" Margin="0" Text="Preparando…" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="lblPct" Grid.Column="1" Foreground="#EDEDEF" FontSize="12.5" FontWeight="SemiBold" Text="0%"/>
            </Grid>
          </StackPanel>
        </Border>
      </StackPanel>

      <!-- Fin -->
      <StackPanel x:Name="panFin" Visibility="Collapsed" VerticalAlignment="Center">
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="✓  Instalación completada" Foreground="#86D97C" FontSize="16" FontWeight="SemiBold"/>
            <TextBlock x:Name="lblFin" Style="{StaticResource D}" Text="HD ZERO Studio está listo. Puedes abrirlo desde el acceso directo del Escritorio o con el botón de abajo."/>
          </StackPanel>
        </Border>
      </StackPanel>
    </Grid>

    <!-- Barra inferior de botones -->
    <Grid Grid.Row="2" Margin="0,8,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Button x:Name="btnSec" Grid.Column="1" Style="{StaticResource Ghost}" Content="Cancelar" Margin="0,0,10,0"/>
      <Button x:Name="btnPrim" Grid.Column="2" Style="{StaticResource Primary}" Content="Instalar"/>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)
$ui = @{}
foreach ($n in @("imgLogo","lblMarca","lblSub","panBienvenida","txtDestino","btnExaminar","panProgreso","lblEstado",
                 "barProg","lblArchivo","lblPct","panFin","lblFin","btnSec","btnPrim")) { $ui[$n] = $win.FindName($n) }

$ui.txtDestino.Text = $destinoDef

# --- Logo de cabecera: el MISMO wordmark legible que usa la GUI ("HD ZERO Studio") ---
# El icono redondo HDZ.ico tiene texto diminuto dentro y se vuelve ilegible al reducirlo,
# asi que para la cabecera usamos "HDZero New logo.png" (apaisado, se lee perfecto).
# Orden: 1) suelto junto al instalador  2) dentro de HDZpayload.zip  3) reserva = icono.
$logoCargado = $false
try {
    $bytesLogo = $null
    $logoSuelto = Join-Path $selfDir "HDZero New logo.png"
    if (Test-Path -LiteralPath $logoSuelto) {
        $bytesLogo = [System.IO.File]::ReadAllBytes($logoSuelto)
    } elseif (Test-Path -LiteralPath $payloadZip) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($payloadZip)
        try {
            $ent = $zip.Entries | Where-Object { $_.FullName -eq "HDZero New logo.png" } | Select-Object -First 1
            if ($ent) {
                $ms = New-Object System.IO.MemoryStream
                $st = $ent.Open(); $st.CopyTo($ms); $st.Dispose()
                $bytesLogo = $ms.ToArray(); $ms.Dispose()
            }
        } finally { $zip.Dispose() }
    }
    if ($bytesLogo) {
        $bmpLogo = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmpLogo.BeginInit()
        $bmpLogo.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmpLogo.StreamSource = New-Object System.IO.MemoryStream(,$bytesLogo)
        $bmpLogo.EndInit()
        $bmpLogo.Freeze()
        $ui.imgLogo.Source = $bmpLogo
        $logoCargado = $true
    }
} catch {}

# Reserva: si no hubo wordmark, mostramos el icono de marca + el titulo de texto.
if (-not $logoCargado -and (Test-Path -LiteralPath $icoPath)) {
    try {
        $dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create((New-Object System.Uri($icoPath)),
                 [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $ui.imgLogo.Source = ($dec.Frames | Sort-Object PixelWidth -Descending)[0]
        $ui.imgLogo.Width = 50; $ui.imgLogo.Height = 50
        $ui.lblMarca.Visibility = "Visible"
    } catch {}
}

# Icono de la VENTANA y barra de tareas = HDZ.ico (frame mayor), independientemente del logo.
if (Test-Path -LiteralPath $icoPath) {
    try {
        $decW = [System.Windows.Media.Imaging.BitmapDecoder]::Create((New-Object System.Uri($icoPath)),
                 [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $win.Icon = ($decW.Frames | Sort-Object PixelWidth -Descending)[0]
    } catch {}
}

# Barra de título OSCURA (DWM) + icono NATIVO en la barra de tareas (igual que la GUI).
$win.Add_SourceInitialized({
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        $oscuro = 1
        [void][HdzSetup.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$oscuro, 4)
        [void][HdzSetup.Dwm]::DwmSetWindowAttribute($h, 19, [ref]$oscuro, 4)
        if (Test-Path -LiteralPath $icoPath) {
            $IMAGE_ICON = 1; $LR_LOADFROMFILE = 0x10; $WM_SETICON = 0x80
            $hBig   = [HdzSetup.IconApi]::LoadImage([IntPtr]::Zero, $icoPath, $IMAGE_ICON, 64, 64, $LR_LOADFROMFILE)
            $hSmall = [HdzSetup.IconApi]::LoadImage([IntPtr]::Zero, $icoPath, $IMAGE_ICON, 16, 16, $LR_LOADFROMFILE)
            if ($hBig   -ne [IntPtr]::Zero) { [void][HdzSetup.IconApi]::SendMessage($h, $WM_SETICON, [IntPtr]1, $hBig) }
            if ($hSmall -ne [IntPtr]::Zero) { [void][HdzSetup.IconApi]::SendMessage($h, $WM_SETICON, [IntPtr]0, $hSmall) }
        }
    } catch {}
})

# --- Estado de la instalación (compartido con el runspace de trabajo) -----
$script:sync = [hashtable]::Synchronized(@{ Pct=0; Estado="Preparando…"; Archivo=""; Fin=$false; Ok=$false; Error=$null })
$script:psInstall = $null; $script:asyncInstall = $null; $script:timer = $null; $script:vbsFinal = $null

# Trabajo de instalación (corre en un runspace para no bloquear la UI)
$trabajo = {
    param($destino, $zip, $sync)
    try {
        $sync.Estado = "Preparando…"; $sync.Pct = 3
        [void][System.IO.Directory]::CreateDirectory($destino)
        # 1) Extraer el payload con progreso (3% -> 68%)
        $sync.Estado = "Copiando archivos…"
        $arch = [System.IO.Compression.ZipFile]::OpenRead($zip)
        $total = ($arch.Entries | Where-Object { $_.Length -gt 0 -or -not $_.FullName.EndsWith("/") }).Count
        if ($total -lt 1) { $total = 1 }
        $i = 0
        foreach ($e in $arch.Entries) {
            $destFile = Join-Path $destino $e.FullName
            if ($e.FullName.EndsWith("/")) { [void][System.IO.Directory]::CreateDirectory($destFile); continue }
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $destFile))
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $destFile, $true)
            $i++
            $sync.Pct = [int](3 + 65.0 * $i / $total)
            $sync.Archivo = $e.Name
        }
        $arch.Dispose()
        # 2) Herramientas + PS7 (offline) + accesos directos: reutiliza el instalador probado
        $sync.Estado = "Instalando PowerShell 7 y herramientas…"; $sync.Archivo = ""; $sync.Pct = 72
        $inst = Join-Path $destino "instalacion\Instalar-HDZStudio.ps1"
        if (Test-Path -LiteralPath $inst) {
            $p = Start-Process "powershell.exe" -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$inst`"") -WindowStyle Hidden -Wait -PassThru
        }
        $sync.Pct = 92
        # 3) Registrar el desinstalador en "Agregar o quitar programas"
        $sync.Estado = "Registrando…"
        $ver = "1.0.0"; $vf = Join-Path $destino "VERSION.txt"
        if (Test-Path -LiteralPath $vf) { $ver = (Get-Content -LiteralPath $vf -Raw).Trim() }
        $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\HDZ Studio"
        New-Item -Path $key -Force | Out-Null
        $desinst = Join-Path $destino "instalacion\Desinstalar-Completo.ps1"
        Set-ItemProperty -Path $key -Name "DisplayName"     -Value "HD ZERO Studio"
        Set-ItemProperty -Path $key -Name "DisplayVersion"  -Value $ver
        Set-ItemProperty -Path $key -Name "Publisher"       -Value "HD ZERO Studio"
        Set-ItemProperty -Path $key -Name "InstallLocation" -Value $destino
        Set-ItemProperty -Path $key -Name "DisplayIcon"     -Value (Join-Path $destino "HDZ.ico")
        Set-ItemProperty -Path $key -Name "UninstallString" -Value ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $desinst + '"')
        Set-ItemProperty -Path $key -Name "NoModify" -Value 1 -Type DWord
        Set-ItemProperty -Path $key -Name "NoRepair" -Value 1 -Type DWord
        $sync.Pct = 100; $sync.Estado = "Listo"; $sync.Ok = $true
    } catch {
        $sync.Error = $_.Exception.Message
    } finally {
        $sync.Fin = $true
    }
}

function Iniciar-Instalacion {
    $destino = "$($ui.txtDestino.Text)".Trim()
    if ([string]::IsNullOrWhiteSpace($destino)) { return }
    $script:vbsFinal = Join-Path $destino "HDZ Studio.vbs"
    $ui.panBienvenida.Visibility = "Collapsed"
    $ui.panProgreso.Visibility = "Visible"
    $ui.btnPrim.IsEnabled = $false; $ui.btnSec.IsEnabled = $false
    $ui.btnPrim.Content = "Instalando…"

    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = "STA"; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($trabajo.ToString()).AddArgument($destino).AddArgument($payloadZip).AddArgument($script:sync)
    $script:psInstall = $ps; $script:asyncInstall = $ps.BeginInvoke()

    $script:timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $script:timer.Add_Tick({
        $ui.barProg.Value = $script:sync.Pct
        $ui.lblPct.Text   = "$([int]$script:sync.Pct)%"
        $ui.lblEstado.Text = "$($script:sync.Estado)"
        if ($script:sync.Archivo) { $ui.lblArchivo.Text = "$($script:sync.Archivo)" } else { $ui.lblArchivo.Text = "" }
        if ($script:sync.Fin) {
            $script:timer.Stop()
            try { $script:psInstall.EndInvoke($script:asyncInstall) } catch {}
            if ($script:sync.Ok) {
                $ui.panProgreso.Visibility = "Collapsed"; $ui.panFin.Visibility = "Visible"
                $ui.btnSec.Content = "Cerrar"; $ui.btnSec.IsEnabled = $true
                $ui.btnPrim.Content = "Abrir HD ZERO Studio"; $ui.btnPrim.IsEnabled = $true
                $ui.lblSub.Text = "Completado"
                $script:estadoFin = $true
            } else {
                $ui.lblEstado.Text = "Error en la instalación"
                $ui.lblArchivo.Text = "$($script:sync.Error)"
                $ui.btnSec.Content = "Cerrar"; $ui.btnSec.IsEnabled = $true
            }
        }
    })
    $script:timer.Start()
}

$script:estadoFin = $false
$ui.btnExaminar.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Elige dónde instalar HD ZERO Studio"
    if (Test-Path -LiteralPath $ui.txtDestino.Text) { $dlg.SelectedPath = $ui.txtDestino.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ui.txtDestino.Text = (Join-Path $dlg.SelectedPath "HDZ Studio")
    }
})
$ui.btnPrim.Add_Click({
    if ($script:estadoFin) {
        if ($script:vbsFinal -and (Test-Path -LiteralPath $script:vbsFinal)) { Start-Process "wscript.exe" -ArgumentList ('"' + $script:vbsFinal + '"') }
        $win.Close()
    } else { Iniciar-Instalacion }
})
$ui.btnSec.Add_Click({ $win.Close() })

# --- Modo test: renderiza las pantallas a PNG y sale (sin instalar) --------
if ($script:modoTest) {
    try {
        $w = 640; $h = 580; $root = $win.Content
        function Render($nombre) {
            $root.Measure([System.Windows.Size]::new($w,$h)); $root.Arrange([System.Windows.Rect]::new(0,0,$w,$h)); $root.UpdateLayout()
            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w,$h,96,96,([System.Windows.Media.PixelFormats]::Pbgra32))
            $rtb.Render($root)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $png = Join-Path $env:TEMP "hdz_setup_$nombre.png"
            $fs = [System.IO.File]::Open($png,[System.IO.FileMode]::Create); $enc.Save($fs); $fs.Close()
            Write-Host "Captura: $png"
        }
        Render "bienvenida"
        $ui.panBienvenida.Visibility="Collapsed"; $ui.panProgreso.Visibility="Visible"
        $ui.barProg.Value=64; $ui.lblPct.Text="64%"; $ui.lblEstado.Text="Copiando archivos…"; $ui.lblArchivo.Text="ffmpeg.exe"
        Render "progreso"
        $ui.panProgreso.Visibility="Collapsed"; $ui.panFin.Visibility="Visible"
        $ui.btnSec.Content="Cerrar"; $ui.btnPrim.Content="Abrir HD ZERO Studio"; $ui.lblSub.Text="Completado"
        Render "fin"
        Write-Host "Instalador WPF: pantallas renderizadas (modo test)."
    } catch { Write-Host "Error modo test: $($_.Exception.Message)" }
} else {
    [void]$win.ShowDialog()
}
