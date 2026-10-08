param([Parameter(Mandatory=$true)][string]$CommandLine)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class MmryJobCount {
  [StructLayout(LayoutKind.Sequential)] struct STARTUPINFO { public int cb; public IntPtr r1, d, t; public int x,y,xs,ys,xc,yc,fa,flags; public short sw, r2; public IntPtr r3, hi, ho, he; }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int pid, tid; }
  [StructLayout(LayoutKind.Sequential)] struct ACCT { public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime; public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses; }
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool CreateProcess(string app, System.Text.StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a, string name);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
  [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr t);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int cls, out ACCT info, int len, IntPtr ret);
  public static string Run(string cmdline) {
    IntPtr job = CreateJobObject(IntPtr.Zero, null);
    var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si);
    PROCESS_INFORMATION pi;
    // CREATE_SUSPENDED: nothing runs, so nothing can start a child, until the process is in the job.
    if (!CreateProcess(null, new System.Text.StringBuilder(cmdline), IntPtr.Zero, IntPtr.Zero, true, 0x4, IntPtr.Zero, null, ref si, out pi)) throw new Exception("CreateProcess " + Marshal.GetLastWin32Error());
    if (!AssignProcessToJobObject(job, pi.hProcess)) throw new Exception("Assign " + Marshal.GetLastWin32Error());
    ResumeThread(pi.hThread);
    WaitForSingleObject(pi.hProcess, 120000);
    // Children may outlive the parent briefly; wait until the job has no live process left.
    ACCT a = new ACCT();
    for (int i = 0; i < 600; i++) { QueryInformationJobObject(job, 1, out a, Marshal.SizeOf(a), IntPtr.Zero); if (a.ActiveProcesses == 0) break; System.Threading.Thread.Sleep(50); }
    uint code; GetExitCodeProcess(pi.hProcess, out code);
    return "PROCESSES=" + a.TotalProcesses + " EXIT=" + code;
  }
}
"@
[MmryJobCount]::Run($CommandLine)
