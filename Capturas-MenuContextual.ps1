#requires -Version 7.0
# =========================================================================
# Capturas-MenuContextual.ps1 — capturas de un vídeo desde Explorer
# =========================================================================
# La ejecución normal muestra un popup para pedir el número de capturas, una
# segunda ventana con progreso y después la cuadrícula de selección/subida.
# El modo -Worker lo utiliza esa ventana para ejecutar el núcleo compartido sin
# mostrar una consola.
# =========================================================================
[CmdletBinding()]
param(
    [string]$Video,
    [int]$NumCapturas = 0,
    [string]$ProgressFile,
    [string]$ResultFile,
    [switch]$Worker
)

$ErrorActionPreference = 'Stop'
$rutaBinHDZ = Join-Path $PSScriptRoot 'bin'
if ((Test-Path -LiteralPath $rutaBinHDZ) -and ($env:PATH -notlike "*$rutaBinHDZ*")) {
    $env:PATH = "$rutaBinHDZ;$env:PATH"
}
. (Join-Path $PSScriptRoot 'HDZ-Capturas.ps1')

function Write-HdzJsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Data
    )
    try {
        $tmp = "$Path.$PID.tmp"
        $json = $Data | ConvertTo-Json -Depth 8 -Compress
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        [void](Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction SilentlyContinue)
    } catch {}
}

function Read-HdzJson {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) { return $raw | ConvertFrom-Json }
        }
    } catch {}
    return $null
}

function Get-HdzPwshPath {
    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidatos = @()
    if ($env:ProgramFiles) { $candidatos += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe') }
    if (${env:ProgramFiles(x86)}) { $candidatos += (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe') }
    foreach ($p in $candidatos) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Show-HdzMessage {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Title = 'HDZ Studio',
        [System.Windows.MessageBoxImage]$Image = [System.Windows.MessageBoxImage]::Information
    )
    $accent = switch ($Image) {
        ([System.Windows.MessageBoxImage]::Error) { '#FF6B81'; break }
        ([System.Windows.MessageBoxImage]::Warning) { '#F2C94C'; break }
        default { '#D92B2B' }
    }
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HDZ Studio" Width="560" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        Background="#0C0C0F" Foreground="#EDEDEF"
        FontFamily="Segoe UI" FontSize="13" ShowInTaskbar="True"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  $HdzStudioThemeXaml
  <Border Background="{StaticResource BgBrush}" Padding="24">
    <StackPanel>
      <Grid Margin="0,0,0,18">
        <Grid.ColumnDefinitions><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="$accent" CornerRadius="2" Height="30" VerticalAlignment="Top"/>
        <StackPanel Grid.Column="1" Margin="12,0,0,0">
          <TextBlock x:Name="lblHeading" Text="HDZ Studio" FontSize="21" FontWeight="Bold"/>
          <TextBlock Text="HDZ Studio · Capturas" Style="{StaticResource D}"/>
        </StackPanel>
      </Grid>
      <Border Style="{StaticResource Card}" Margin="0,0,0,18">
        <TextBlock x:Name="lblText" TextWrapping="Wrap" Foreground="{StaticResource SubBrush}" FontSize="13"/>
      </Border>
      <Button x:Name="btnAceptar" Content="Aceptar" Style="{StaticResource Primary}" MinWidth="112"
              HorizontalAlignment="Right" IsDefault="True" IsCancel="True"/>
    </StackPanel>
  </Border>
</Window>
"@
    $window = ConvertFrom-HdzXaml $xaml
    $window.Title = $Title
    $window.FindName('lblText').Text = $Text
    $btnAceptar = $window.FindName('btnAceptar')
    $btnAceptar.Add_Click({ $window.Close() }.GetNewClosure())
    $window.Add_ContentRendered({ $btnAceptar.Focus() }.GetNewClosure())
    [void]$window.ShowDialog()
}

try {
    Add-Type -Namespace HdzNative -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
'@
} catch {}
try {
    Add-Type -Namespace HdzNative -Name IconApi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr LoadImage(System.IntPtr hinst, string lpszName, uint uType, int cx, int cy, uint fuLoad);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, int Msg, System.IntPtr wParam, System.IntPtr lParam);
'@
} catch {}

function Set-HdzWindowChrome {
    param([Parameter(Mandatory)][System.Windows.Window]$Window)

    try { $Window.ResizeMode = [System.Windows.ResizeMode]::CanMinimize } catch {}
    $Window.Add_SourceInitialized({
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
            if ($hwnd -eq [IntPtr]::Zero) { return }

            $dark = 1
            [void][HdzNative.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$dark, 4)
            [void][HdzNative.Dwm]::DwmSetWindowAttribute($hwnd, 19, [ref]$dark, 4)

            $iconPath = Join-Path $PSScriptRoot 'HDZ.ico'
            if (Test-Path -LiteralPath $iconPath) {
                $imageIcon = 1; $loadFromFile = 0x10; $wmSetIcon = 0x80
                $big = [HdzNative.IconApi]::LoadImage([IntPtr]::Zero, $iconPath, $imageIcon, 64, 64, $loadFromFile)
                $small = [HdzNative.IconApi]::LoadImage([IntPtr]::Zero, $iconPath, $imageIcon, 16, 16, $loadFromFile)
                if ($big -ne [IntPtr]::Zero) { [void][HdzNative.IconApi]::SendMessage($hwnd, $wmSetIcon, [IntPtr]1, $big) }
                if ($small -ne [IntPtr]::Zero) { [void][HdzNative.IconApi]::SendMessage($hwnd, $wmSetIcon, [IntPtr]0, $small) }
            }
        } catch {}
    }.GetNewClosure())
}

function ConvertFrom-HdzXaml {
    param([Parameter(Mandatory)][string]$Text)
    $xml = [xml]$Text
    $reader = [System.Xml.XmlNodeReader]::new($xml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    Set-HdzWindowChrome $window
    return $window
}

# Tema compartido con HDZ-GUI.ps1: fondo negro, tarjetas oscuras, borde
# degradado, acento rojo y los mismos botones redondeados.
$HdzStudioThemeXaml = @'
<Window.Resources>
  <SolidColorBrush x:Key="BgBrush" Color="#0C0C0F"/>
  <SolidColorBrush x:Key="CardBrush" Color="#131316"/>
  <SolidColorBrush x:Key="CardBorderBrush" Color="#242429"/>
  <SolidColorBrush x:Key="FieldBrush" Color="#0E0E11"/>
  <SolidColorBrush x:Key="FieldBorderBrush" Color="#2E2E35"/>
  <SolidColorBrush x:Key="ChipBrush" Color="#1A1A1F"/>
  <SolidColorBrush x:Key="ChipBorderBrush" Color="#2E2E35"/>
  <SolidColorBrush x:Key="TextBrush" Color="#EDEDEF"/>
  <SolidColorBrush x:Key="SubBrush" Color="#9C9CA8"/>
  <SolidColorBrush x:Key="MutedBrush" Color="#5E5E66"/>
  <SolidColorBrush x:Key="AccentBrush" Color="#D92B2B"/>
  <SolidColorBrush x:Key="AccentHoverBrush" Color="#EF4444"/>
  <SolidColorBrush x:Key="ErrBrush" Color="#FF6B81"/>
  <SolidColorBrush x:Key="OkBrush" Color="#86D97C"/>
  <SolidColorBrush x:Key="WarnBrush" Color="#F2C94C"/>
  <SolidColorBrush x:Key="AccentSoftBrush" Color="#271013"/>
  <SolidColorBrush x:Key="HoverBgBrush" Color="#1F1F26"/>
  <LinearGradientBrush x:Key="CardBgGrad" StartPoint="0,0" EndPoint="0,1">
    <GradientStop Color="#17171C" Offset="0"/><GradientStop Color="#101014" Offset="1"/>
  </LinearGradientBrush>
  <LinearGradientBrush x:Key="CardBorderGrad" StartPoint="0,0" EndPoint="1,1">
    <GradientStop Color="#2C2C34" Offset="0"/><GradientStop Color="#1F1F25" Offset="1"/>
  </LinearGradientBrush>
  <LinearGradientBrush x:Key="AccentGrad" StartPoint="0,0" EndPoint="1,1">
    <GradientStop Color="#EF4444" Offset="0"/><GradientStop Color="#D92B2B" Offset="1"/>
  </LinearGradientBrush>
  <LinearGradientBrush x:Key="AccentGradHover" StartPoint="0,0" EndPoint="1,1">
    <GradientStop Color="#F75B5B" Offset="0"/><GradientStop Color="#E23838" Offset="1"/>
  </LinearGradientBrush>

  <Style x:Key="Card" TargetType="Border">
    <Setter Property="Background" Value="{StaticResource CardBgGrad}"/>
    <Setter Property="BorderBrush" Value="{StaticResource CardBorderGrad}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="13"/>
    <Setter Property="Padding" Value="18,15"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <Style x:Key="H" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
    <Setter Property="FontSize" Value="14.5"/>
    <Setter Property="FontWeight" Value="Bold"/>
  </Style>
  <Style x:Key="D" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource SubBrush}"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
    <Setter Property="Margin" Value="0,3,0,0"/>
  </Style>
  <Style x:Key="Lbl" TargetType="TextBlock">
    <Setter Property="Foreground" Value="#B4B4BE"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Margin" Value="0,12,0,5"/>
  </Style>
  <Style x:Key="Input" TargetType="TextBox">
    <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
    <Setter Property="CaretBrush" Value="White"/>
    <Setter Property="Background" Value="{StaticResource FieldBrush}"/>
    <Setter Property="BorderBrush" Value="{StaticResource FieldBorderBrush}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="10,7"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#56565E"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Primary" TargetType="Button">
    <Setter Property="Foreground" Value="White"/>
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="bd" Background="{StaticResource AccentGrad}" CornerRadius="10" Padding="26,12"
                  BorderBrush="#F25555" BorderThickness="0,1,0,0">
            <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{StaticResource AccentGradHover}"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#A81E1E"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Ghost" TargetType="Button">
    <Setter Property="Foreground" Value="#C8C8CE"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="bd" Background="{StaticResource ChipBrush}" BorderBrush="{StaticResource ChipBorderBrush}"
                  BorderThickness="1" CornerRadius="8" Padding="16,8">
            <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
              <Setter TargetName="bd" Property="Background" Value="{StaticResource HoverBgBrush}"/>
              <Setter Property="Foreground" Value="White"/>
            </Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="{StaticResource AccentSoftBrush}"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ProgressBar">
    <Setter Property="Background" Value="#26262C"/>
    <Setter Property="Foreground" Value="{StaticResource AccentGrad}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ProgressBar">
          <Grid>
            <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="4"/>
            <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="4" HorizontalAlignment="Left"/>
          </Grid>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</Window.Resources>
'@

. (Join-Path $PSScriptRoot 'HDZ-CapturasContexto.ps1')

function Show-HdzCountDialog {
    param([Parameter(Mandatory)][string]$VideoPath)

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HDZ Studio · Capturas" Width="560" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        Background="#0C0C0F" Foreground="#EDEDEF"
        FontFamily="Segoe UI" FontSize="13" ShowInTaskbar="True"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  $HdzStudioThemeXaml
  <Border Background="{StaticResource BgBrush}" Padding="24">
    <StackPanel>
      <Grid Margin="0,0,0,18">
        <Grid.ColumnDefinitions><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="{StaticResource AccentBrush}" CornerRadius="2" Height="30" VerticalAlignment="Top"/>
        <StackPanel Grid.Column="1" Margin="12,0,0,0">
          <TextBlock Text="Hacer capturas de pantalla" FontSize="21" FontWeight="Bold"/>
          <TextBlock Text="HDZ Studio · Capturas" Style="{StaticResource D}"/>
        </StackPanel>
      </Grid>
      <Border Style="{StaticResource Card}">
        <StackPanel>
          <TextBlock Text="Archivo de vídeo" Style="{StaticResource Lbl}" Margin="0,0,0,5"/>
          <TextBlock x:Name="lblVideo" Style="{StaticResource H}" TextWrapping="Wrap"/>
          <TextBlock Text="El vídeo original se conserva sin modificaciones." Style="{StaticResource D}"/>
        </StackPanel>
      </Border>
      <Border Style="{StaticResource Card}">
        <StackPanel>
          <TextBlock Text="Número de capturas" Style="{StaticResource Lbl}" Margin="0,0,0,5"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="108"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBox x:Name="txtNumero" Grid.Column="0" Text="6" FontSize="18" Style="{StaticResource Input}"
                     HorizontalContentAlignment="Center" MaxLength="3"/>
            <TextBlock Grid.Column="1" Text="imágenes PNG a resolución original" VerticalAlignment="Center" Margin="13,0,0,0" Style="{StaticResource D}"/>
          </Grid>
          <TextBlock Text="Puedes elegir entre 1 y 999 capturas." Style="{StaticResource D}"/>
          <TextBlock x:Name="lblError" Margin="0,10,0,0" TextWrapping="Wrap"
                     Foreground="{StaticResource ErrBrush}" Visibility="Collapsed"/>
        </StackPanel>
      </Border>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,5,0,0">
        <Button x:Name="btnCancelar" Content="Cancelar" Style="{StaticResource Ghost}" MinWidth="106" Margin="0,0,8,0"
                IsCancel="True"/>
        <Button x:Name="btnAceptar" Content="Continuar" Style="{StaticResource Primary}" MinWidth="120" IsDefault="True"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
    $window = ConvertFrom-HdzXaml $xaml
    $lblVideo = $window.FindName('lblVideo')
    $txtNumero = $window.FindName('txtNumero')
    $lblError = $window.FindName('lblError')
    $btnAceptar = $window.FindName('btnAceptar')
    $btnCancelar = $window.FindName('btnCancelar')
    $lblVideo.Text = [System.IO.Path]::GetFileName($VideoPath)

    $answer = [hashtable]::Synchronized(@{ Value = $null })
    $btnAceptar.Add_Click({
        $n = 0
        if ([int]::TryParse("$($txtNumero.Text)", [ref]$n) -and $n -ge 1 -and $n -le 999) {
            $answer.Value = $n
            $window.DialogResult = $true
            $window.Close()
        } else {
            $lblError.Text = 'Escribe un número entero entre 1 y 999.'
            $lblError.Visibility = 'Visible'
            $txtNumero.Focus()
            $txtNumero.SelectAll()
        }
    }.GetNewClosure())
    $btnCancelar.Add_Click({
        $answer.Value = 0
        $window.DialogResult = $false
        $window.Close()
    }.GetNewClosure())
    $window.Add_ContentRendered({ $txtNumero.Focus(); $txtNumero.SelectAll() }.GetNewClosure())
    [void]$window.ShowDialog()
    return [int]$answer.Value
}

function Start-HdzCaptureWorker {
    param(
        [Parameter(Mandatory)][string]$VideoPath,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][string]$ProgressPath,
        [Parameter(Mandatory)][string]$ResultPath
    )

    $incidencias = @()
    try {
        $esHdr = Test-HdzVideoHdr $VideoPath
        Write-HdzJsonAtomic $ProgressPath ([ordered]@{
            estado = 'running'; pct = 0; hecho = 0; total = $Count
            fase = if ($esHdr) { 'Vídeo HDR: preparando tonemapping…' } else { 'Vídeo SDR: preparando capturas…' }
        })

        $resultado = New-HdzCapturas -ArchivoVideo $VideoPath -NombreFinal ([System.IO.Path]::GetFileName($VideoPath)) `
            -NumCapturas $Count -EsHdr $esHdr -DirCapturas (Split-Path -Parent $VideoPath) `
            -OnProgress {
                param($pct, $fase)
                $hecho = 0
                if ("$fase" -match '\((\d+)\/(\d+)\)') { $hecho = [int]$Matches[1] }
                Write-HdzJsonAtomic $ProgressPath ([ordered]@{
                    estado = 'running'; pct = [int]$pct; hecho = $hecho; total = $Count; fase = "$fase"
                })
            }.GetNewClosure() `
            -OnIncident {
                param($archivo, $mensaje)
                $incidencias += "${archivo}: $mensaje"
            }.GetNewClosure()

        $payload = [ordered]@{
            estado = 'ok'
            capturas = @($resultado.Capturas)
            solicitadas = [int]$resultado.Solicitadas
            fallos = [int]$resultado.Fallos
            duracion = [double]$resultado.Duracion
            esHdr = [bool]$resultado.EsHdr
            incidencias = @($incidencias)
        }
        Write-HdzJsonAtomic $ResultPath $payload
        Write-HdzJsonAtomic $ProgressPath ([ordered]@{
            estado = 'finished'; pct = 100; hecho = @($resultado.Capturas).Count
            total = $Count; fase = "Terminado: $(@($resultado.Capturas).Count)/$Count capturas"
        })
        exit 0
    } catch {
        $mensaje = $_.Exception.Message
        Write-HdzJsonAtomic $ResultPath ([ordered]@{ estado = 'error'; mensaje = $mensaje; incidencias = @($incidencias) })
        Write-HdzJsonAtomic $ProgressPath ([ordered]@{ estado = 'error'; pct = 0; hecho = 0; total = $Count; fase = $mensaje })
        exit 1
    }
}

function Start-HdzCaptureProcess {
    param(
        [Parameter(Mandatory)][string]$VideoPath,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][string]$ProgressPath,
        [Parameter(Mandatory)][string]$ResultPath
    )
    $pwsh = Get-HdzPwshPath
    if (-not $pwsh) { throw 'No encuentro PowerShell 7 (pwsh.exe).' }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    foreach ($arg in @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
        '-Worker', '-Video', $VideoPath, '-NumCapturas', "$Count",
        '-ProgressFile', $ProgressPath, '-ResultFile', $ResultPath
    )) { [void]$psi.ArgumentList.Add($arg) }
    return [System.Diagnostics.Process]::Start($psi)
}

function Show-HdzCaptureProgress {
    param(
        [Parameter(Mandatory)][string]$VideoPath,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][string]$ProgressPath,
        [Parameter(Mandatory)][string]$ResultPath
    )

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HDZ Studio · Capturas" Width="600" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        Background="#0C0C0F" Foreground="#EDEDEF"
        FontFamily="Segoe UI" FontSize="13" ShowInTaskbar="True"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  $HdzStudioThemeXaml
  <Border Background="{StaticResource BgBrush}" Padding="24">
    <StackPanel>
      <Grid Margin="0,0,0,18">
        <Grid.ColumnDefinitions><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="{StaticResource AccentBrush}" CornerRadius="2" Height="30" VerticalAlignment="Top"/>
        <StackPanel Grid.Column="1" Margin="12,0,0,0">
          <TextBlock Text="Generando capturas…" FontSize="21" FontWeight="Bold"/>
          <TextBlock Text="HDZ Studio · Progreso" Style="{StaticResource D}"/>
        </StackPanel>
      </Grid>
      <Border Style="{StaticResource Card}">
        <StackPanel>
          <TextBlock Text="Archivo de vídeo" Style="{StaticResource Lbl}" Margin="0,0,0,5"/>
          <TextBlock x:Name="lblVideo" Style="{StaticResource H}" TextWrapping="Wrap"/>
          <TextBlock Text="El vídeo original se conserva sin modificaciones." Style="{StaticResource D}"/>
        </StackPanel>
      </Border>
      <Border Style="{StaticResource Card}">
        <StackPanel>
          <ProgressBar x:Name="bar" Height="14" Minimum="0" Maximum="100" Value="0"/>
          <TextBlock x:Name="lblFase" Margin="0,12,0,0" TextWrapping="Wrap" Style="{StaticResource H}"/>
          <TextBlock Text="Puedes cancelar sin modificar el vídeo original." Style="{StaticResource D}"/>
        </StackPanel>
      </Border>
      <Button x:Name="btnCancelar" Content="Cancelar" Style="{StaticResource Ghost}" MinWidth="106"
              HorizontalAlignment="Right" Margin="0,5,0,0"/>
    </StackPanel>
  </Border>
</Window>
"@
    $window = ConvertFrom-HdzXaml $xaml
    $lblVideo = $window.FindName('lblVideo')
    $bar = $window.FindName('bar')
    $lblFase = $window.FindName('lblFase')
    $btnCancelar = $window.FindName('btnCancelar')
    $lblVideo.Text = [System.IO.Path]::GetFileName($VideoPath)

    Write-HdzJsonAtomic $ProgressPath ([ordered]@{ estado = 'starting'; pct = 0; hecho = 0; total = $Count; fase = 'Iniciando…' })
    $proc = Start-HdzCaptureProcess -VideoPath $VideoPath -Count $Count -ProgressPath $ProgressPath -ResultPath $ResultPath
    $box = [hashtable]::Synchronized(@{ Cancelled = $false; Result = $null })
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        $state = Read-HdzJson $ProgressPath
        if ($state) {
            if ($null -ne $state.pct) { $bar.Value = [Math]::Max(0, [Math]::Min(100, [double]$state.pct)) }
            if ($state.fase) { $lblFase.Text = "$($state.fase)" }
        }
        if ($proc.HasExited) {
            $res = Read-HdzJson $ResultPath
            if ($res) {
                $box.Result = $res
                $timer.Stop()
                $window.Close()
            } elseif ($proc.ExitCode -ne 0) {
                $box.Result = [pscustomobject]@{ estado = 'error'; mensaje = "El proceso terminó con código $($proc.ExitCode)." }
                $timer.Stop()
                $window.Close()
            }
        }
    }.GetNewClosure())
    $btnCancelar.Add_Click({
        $box.Cancelled = $true
        if (-not $proc.HasExited) {
            try { $proc.Kill(); $proc.WaitForExit(3000) } catch {}
        }
        $timer.Stop()
        $window.Close()
    }.GetNewClosure())
    $window.Add_Closing({
        if (-not $box.Result -and -not $box.Cancelled -and -not $proc.HasExited) {
            $box.Cancelled = $true
            try { $proc.Kill(); $proc.WaitForExit(3000) } catch {}
        }
    }.GetNewClosure())
    $timer.Start()
    [void]$window.ShowDialog()
    $timer.Stop()
    if (-not $proc.HasExited -and $box.Cancelled) {
        try { $proc.Kill(); $proc.WaitForExit(3000) } catch {}
    }
    return $box
}

try {
    if ($Worker) {
        Start-HdzCaptureWorker -VideoPath $Video -Count $NumCapturas -ProgressPath $ProgressFile -ResultPath $ResultFile
        exit 0
    }

    Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
    if ([string]::IsNullOrWhiteSpace($Video) -or -not (Test-Path -LiteralPath $Video -PathType Leaf)) {
        Show-HdzMessage 'No se ha encontrado el archivo de vídeo seleccionado.' 'HDZ Studio' ([System.Windows.MessageBoxImage]::Error)
        exit 1
    }
    $videoPath = (Resolve-Path -LiteralPath $Video).Path
    $count = Show-HdzCountDialog $videoPath
    if ($count -le 0) { exit 0 }

    $id = [Guid]::NewGuid().ToString('N')
    $progressPath = Join-Path $env:TEMP "hdz_capturas_$id.progress.json"
    $resultPath = Join-Path $env:TEMP "hdz_capturas_$id.result.json"
    try {
        $state = Show-HdzCaptureProgress -VideoPath $videoPath -Count $count -ProgressPath $progressPath -ResultPath $resultPath
        if ($state.Cancelled) { exit 0 }
        $result = $state.Result
        if (-not $result -or "$($result.estado)" -eq 'error') {
            $msg = if ($result.mensaje) { "$($result.mensaje)" } else { 'No se pudo completar la generación de capturas.' }
            Show-HdzMessage $msg 'HDZ Studio · Error' ([System.Windows.MessageBoxImage]::Error)
            exit 1
        }
        $nOk = @($result.capturas).Count
        $nFail = if ($null -ne $result.fallos) { [int]$result.fallos } else { [Math]::Max(0, $count - $nOk) }
        if ($nOk -gt 0) {
            Show-HdzCaptureGrid -VideoPath $videoPath -Captures @($result.capturas)
        } else {
        $texto = "Se han creado $nOk de $count capturas en:`n$([System.IO.Path]::GetDirectoryName($videoPath))"
        if ($nFail -gt 0) { $texto += "`n`nAviso: $nFail no se pudieron generar." }
        Show-HdzMessage $texto 'HDZ Studio · Proceso terminado' $(if ($nFail -gt 0) { [System.Windows.MessageBoxImage]::Warning } else { [System.Windows.MessageBoxImage]::Information })
        }
    } finally {
        Remove-Item -LiteralPath $progressPath, $resultPath -Force -ErrorAction SilentlyContinue
    }
} catch {
    try {
        Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase -ErrorAction SilentlyContinue
        Show-HdzMessage $_.Exception.Message 'HDZ Studio · Error' ([System.Windows.MessageBoxImage]::Error)
    } catch {
        Write-Error $_.Exception.Message
    }
    exit 1
}
