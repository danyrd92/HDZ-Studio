# El motor y sus hijos se detienen si desaparece la GUI: no quedan montajes huérfanos.
function Protect-HdzChildProcess([Diagnostics.Process]$Process) {
    if (-not ('HdzJobs.Lifetime' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace HdzJobs {
  public static class Lifetime {
    [StructLayout(LayoutKind.Sequential)] struct Basic {
      public long PerProcessTime, PerJobTime; public uint LimitFlags;
      public UIntPtr MinimumWorkingSet, MaximumWorkingSet; public uint ActiveProcessLimit;
      public UIntPtr Affinity; public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct Io { public ulong R1,R2,R3,R4,R5,R6; }
    [StructLayout(LayoutKind.Sequential)] struct Extended {
      public Basic Basic; public Io Io; public UIntPtr ProcessMemory,JobMemory,PeakProcess,PeakJob;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateJobObject(IntPtr attr, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(SafeFileHandle job, int type, ref Extended info, uint length);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
    public static SafeFileHandle Protect(IntPtr process) {
      var job=CreateJobObject(IntPtr.Zero,null);
      if(job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
      var info=new Extended(); info.Basic.LimitFlags=0x2000;
      if(!SetInformationJobObject(job,9,ref info,(uint)Marshal.SizeOf<Extended>()) || !AssignProcessToJobObject(job,process)) {
        int code=Marshal.GetLastWin32Error(); job.Dispose(); throw new Win32Exception(code);
      }
      return job;
    }
  }
}
'@
    }
    return [HdzJobs.Lifetime]::Protect($Process.Handle)
}

function Remove-HdzJobConfig($Jobs) {
    $temporaryRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    foreach ($job in @($Jobs)) {
        if (-not $job.CfgPath) { continue }
        $target = [IO.Path]::GetFullPath($job.CfgPath)
        if (-not $target.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $target -Leaf) -notmatch '^hdz_gui_config_[A-Za-z0-9_-]+\.json$') { throw 'Ruta de configuración temporal no reconocida; no se borra.' }
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    }
}
