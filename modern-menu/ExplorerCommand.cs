using System.Diagnostics;
using Microsoft.Win32;
using System.Runtime.InteropServices;

namespace HDZStudioModernMenu;

internal static class HResult
{
    public const int S_OK = 0;
    public const int E_FAIL = unchecked((int)0x80004005);
    public const int E_NOTIMPL = unchecked((int)0x80004001);
    public const int E_INVALIDARG = unchecked((int)0x80070057);
}

public enum Sigdn : uint
{
    FileSystemPath = 0x80058000
}

public enum ExplorerCommandState : uint
{
    Enabled = 0x00000000,
    Disabled = 0x00000001,
    Hidden = 0x00000002
}

[ComVisible(true)]
[Guid("A08CE4D0-FA25-44AB-B57C-C7B1C323E0B9")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IExplorerCommand
{
    [PreserveSig]
    int GetTitle(IShellItemArray? items, [MarshalAs(UnmanagedType.LPWStr)] out string? title);

    [PreserveSig]
    int GetIcon(IShellItemArray? items, [MarshalAs(UnmanagedType.LPWStr)] out string? icon);

    [PreserveSig]
    int GetToolTip(IShellItemArray? items, [MarshalAs(UnmanagedType.LPWStr)] out string? tooltip);

    [PreserveSig]
    int GetCanonicalName(out Guid commandName);

    [PreserveSig]
    int GetState(IShellItemArray? items, [MarshalAs(UnmanagedType.Bool)] bool okToBeSlow,
        out ExplorerCommandState state);

    [PreserveSig]
    int Invoke(IShellItemArray? items, IntPtr bindContext);

    [PreserveSig]
    int GetFlags(out uint flags);

    [PreserveSig]
    int EnumSubCommands(out IEnumExplorerCommand? commands);
}

[ComVisible(true)]
[Guid("B63EA76D-1F85-456F-A19C-48159EFA858B")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellItemArray
{
    [PreserveSig] int BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppvOut);
    [PreserveSig] int GetPropertyStore(uint flags, ref Guid riid, out IntPtr ppv);
    [PreserveSig] int GetPropertyDescriptionList(ref IntPtr keyType, ref Guid riid, out IntPtr ppv);
    [PreserveSig] int GetAttributes(uint attribFlags, uint sfgaoMask, out uint sfgaoAttribs);
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetItemAt(uint index, out IShellItem item);
    [PreserveSig] int EnumItems(out IntPtr enumShellItems);
}

[ComVisible(true)]
[Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellItem
{
    [PreserveSig] int BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
    [PreserveSig] int GetParent(out IShellItem parent);
    [PreserveSig] int GetDisplayName(Sigdn sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string? name);
    [PreserveSig] int GetAttributes(uint mask, out uint attributes);
    [PreserveSig] int Compare(IShellItem item, uint hint, out int order);
}

[ComVisible(true)]
[Guid("A88826F8-186F-4987-AADE-EA0CEF8FBFE8")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IEnumExplorerCommand
{
    [PreserveSig] int Next(uint count, [MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] IExplorerCommand[] commands,
        out uint fetched);
    [PreserveSig] int Skip(uint count);
    [PreserveSig] int Reset();
    [PreserveSig] int Clone(out IEnumExplorerCommand? enumerator);
}

[ComVisible(true)]
[Guid("1A5C3DBA-0D08-4F09-9A80-0B0B0C2C0B0D")]
[ClassInterface(ClassInterfaceType.None)]
public sealed class HdzCaptureExplorerCommand : IExplorerCommand
{
    private const string Title = "Hacer capturas de pantalla";
    private const string InstallRootRegistryKey = @"Software\HDZEROStudio\ContextMenu";
    private static readonly Guid CanonicalCommand = new("1A5C3DBA-0D08-4F09-9A80-0B0B0C2C0B0D");
    private static readonly string? ConfiguredInstallRoot = ReadConfiguredInstallRoot();

    public int GetTitle(IShellItemArray? items, out string? title)
    {
        title = Title;
        return HResult.S_OK;
    }

    public int GetIcon(IShellItemArray? items, out string? icon)
    {
        try
        {
            icon = FindIconPath();
        }
        catch
        {
            // El icono nunca debe impedir que Explorer muestre el comando.
            icon = "shell32.dll,-167";
        }
        return HResult.S_OK;
    }

    public int GetToolTip(IShellItemArray? items, out string? tooltip)
    {
        tooltip = "Generar capturas de pantalla con el método de HDZ Studio";
        return HResult.S_OK;
    }

    public int GetCanonicalName(out Guid commandName)
    {
        commandName = CanonicalCommand;
        return HResult.S_OK;
    }

    public int GetState(IShellItemArray? items, bool okToBeSlow, out ExplorerCommandState state)
    {
        // El manifiesto limita el comando a extensiones de vídeo. Mantener esta
        // llamada rápida es importante porque Explorer la hace en su hilo de UI.
        state = ExplorerCommandState.Enabled;
        return HResult.S_OK;
    }

    public int Invoke(IShellItemArray? items, IntPtr bindContext)
    {
        try
        {
            var paths = GetSelectedPaths(items);
            if (paths.Count == 0)
            {
                return HResult.E_INVALIDARG;
            }

            // La interfaz y el núcleo de trabajo siguen siendo los de
            // Capturas-MenuContextual.ps1; aquí solo se cruza el puente COM.
            string launcher = FindLauncherPath();
            if (!File.Exists(launcher))
            {
                return HResult.E_FAIL;
            }

            string wscript = Path.Combine(Environment.SystemDirectory, "wscript.exe");
            var startInfo = new ProcessStartInfo
            {
                FileName = wscript,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            startInfo.ArgumentList.Add(launcher);
            foreach (string path in paths)
            {
                startInfo.ArgumentList.Add(path);
            }
            Process.Start(startInfo);
            return HResult.S_OK;
        }
        catch
        {
            return HResult.E_FAIL;
        }
    }

    public int GetFlags(out uint flags)
    {
        flags = 0;
        return HResult.S_OK;
    }

    public int EnumSubCommands(out IEnumExplorerCommand? commands)
    {
        commands = null;
        return HResult.E_NOTIMPL;
    }

    private static List<string> GetSelectedPaths(IShellItemArray? items)
    {
        var result = new List<string>();
        if (items is null || items.GetCount(out uint count) != HResult.S_OK)
        {
            return result;
        }

        for (uint i = 0; i < count; i++)
        {
            if (items.GetItemAt(i, out IShellItem item) != HResult.S_OK || item is null)
            {
                continue;
            }

            if (item.GetDisplayName(Sigdn.FileSystemPath, out string? path) == HResult.S_OK &&
                !string.IsNullOrWhiteSpace(path))
            {
                result.Add(path);
            }
        }

        return result;
    }

    private static string FindLauncherPath()
    {
        string assemblyDirectory = Path.GetDirectoryName(typeof(HdzCaptureExplorerCommand).Assembly.Location) ?? AppContext.BaseDirectory;
        string localLauncher = Path.Combine(assemblyDirectory, "Capturas-MenuContextual.vbs");
        if (File.Exists(localLauncher))
        {
            return localLauncher;
        }

        return FindInstalledFile("Capturas-MenuContextual.vbs") ??
            Path.Combine(AppContext.BaseDirectory, "Capturas-MenuContextual.vbs");
    }

    private static string FindIconPath()
    {
        string assemblyDirectory = Path.GetDirectoryName(typeof(HdzCaptureExplorerCommand).Assembly.Location) ?? AppContext.BaseDirectory;
        string localIcon = Path.Combine(assemblyDirectory, "HDZ.ico");
        if (File.Exists(localIcon))
        {
            return localIcon;
        }

        return FindInstalledFile("HDZ.ico") ?? "shell32.dll,-167";
    }

    private static string? FindInstalledFile(string fileName)
    {
        var starts = new List<DirectoryInfo>();
        if (!string.IsNullOrWhiteSpace(ConfiguredInstallRoot) && Directory.Exists(ConfiguredInstallRoot))
        {
            starts.Add(new DirectoryInfo(ConfiguredInstallRoot));
        }
        string? assemblyDirectory = Path.GetDirectoryName(typeof(HdzCaptureExplorerCommand).Assembly.Location);
        if (!string.IsNullOrWhiteSpace(assemblyDirectory))
        {
            starts.Add(new DirectoryInfo(assemblyDirectory));
        }
        starts.Add(new DirectoryInfo(AppContext.BaseDirectory));

        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var start in starts)
        {
            var directory = start;
            for (int level = 0; level < 6 && directory is not null; level++)
            {
                if (!visited.Add(directory.FullName))
                {
                    directory = directory.Parent;
                    continue;
                }

                string candidate = Path.Combine(directory.FullName, fileName);
                if (File.Exists(candidate))
                {
                    return candidate;
                }

                directory = directory.Parent;
            }
        }

        return null;
    }

    private static string? ReadConfiguredInstallRoot()
    {
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            try
            {
                using var key = hive.OpenSubKey(InstallRootRegistryKey, writable: false);
                var value = key?.GetValue("InstallPath") as string;
                if (!string.IsNullOrWhiteSpace(value) && Directory.Exists(value))
                {
                    return value;
                }
            }
            catch
            {
                // El comando debe seguir apareciendo aunque el registro no esté disponible.
            }
        }

        return null;
    }
}
