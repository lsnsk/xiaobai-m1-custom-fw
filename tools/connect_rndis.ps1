$ErrorActionPreference = "Stop"

# Auto-elevate to Administrator if needed
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# Remove 192.168.0.2 from any wrong adapter first
Get-NetIPAddress -IPAddress "192.168.0.2" -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "Looking for Peephole USB RNDIS device (VID_1D6B&PID_0104&MI_00)..." -ForegroundColor Cyan
$dev = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "USB\VID_1D6B&PID_0104&MI_00*" } | Select-Object -First 1
if (-not $dev) {
    Write-Host "ERROR: USB\VID_1D6B&PID_0104&MI_00 not found! Make sure the peephole is connected via USB." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ("Found device: " + $dev.InstanceId + " (Status: " + $dev.Status + ")") -ForegroundColor Yellow

$code = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class RndisInstaller {
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SetupDiGetClassDevsW(IntPtr ClassGuid, string Enumerator, IntPtr hwndParent, uint Flags);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetupDiOpenDeviceInfoW(IntPtr DeviceInfoSet, string DeviceInstanceId, IntPtr hwndParent, uint OpenFlags, ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, uint Property, byte[] PropertyBuffer, uint PropertyBufferSize);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetupDiGetDeviceInstallParamsW(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, ref SP_DEVINSTALL_PARAMS_W DeviceInstallParams);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetupDiSetDeviceInstallParamsW(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, ref SP_DEVINSTALL_PARAMS_W DeviceInstallParams);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiBuildDriverInfoList(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, uint DriverType);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetupDiEnumDriverInfoW(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, uint DriverType, uint MemberIndex, ref SP_DRVINFO_DATA_W DriverInfoData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetupDiSetSelectedDriverW(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, ref SP_DRVINFO_DATA_W DriverInfoData);

    [DllImport("newdev.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool DiInstallDevice(IntPtr hwndParent, IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, ref SP_DRVINFO_DATA_W DriverInfoData, uint Flags, out bool NeedReboot);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVINFO_DATA {
        public uint cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SP_DEVINSTALL_PARAMS_W {
        public uint cbSize;
        public uint Flags;
        public uint FlagsEx;
        public IntPtr hwndParent;
        public IntPtr InstallMsgHandler;
        public IntPtr InstallMsgHandlerContext;
        public IntPtr FileQueue;
        public IntPtr ClassInstallReserved;
        public uint Reserved;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string DriverPath;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SP_DRVINFO_DATA_W {
        public uint cbSize;
        public uint DriverType;
        public IntPtr Reserved;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string Description;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string MfgName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string ProviderName;
        public System.Runtime.InteropServices.ComTypes.FILETIME DriverDate;
        public ulong DriverVersion;
    }

    public static bool InstallRndis(string instanceId) {
        IntPtr hDevInfo = SetupDiGetClassDevsW(IntPtr.Zero, null, IntPtr.Zero, 6);
        if (hDevInfo == new IntPtr(-1)) return false;
        try {
            SP_DEVINFO_DATA devData = new SP_DEVINFO_DATA();
            devData.cbSize = (uint)Marshal.SizeOf(devData);
            if (!SetupDiOpenDeviceInfoW(hDevInfo, instanceId, IntPtr.Zero, 0, ref devData)) {
                Console.WriteLine("SetupDiOpenDeviceInfoW failed: " + Marshal.GetLastWin32Error());
                return false;
            }

            // Set ClassGUID to Net {4d36e972-e325-11ce-bfc1-08002be10318} (SPDRP_CLASSGUID = 8)
            string netGuidStr = "{4d36e972-e325-11ce-bfc1-08002be10318}\0";
            byte[] guidBytes = Encoding.Unicode.GetBytes(netGuidStr);
            SetupDiSetDeviceRegistryPropertyW(hDevInfo, ref devData, 8, guidBytes, (uint)guidBytes.Length);
            devData.ClassGuid = new Guid("4d36e972-e325-11ce-bfc1-08002be10318");

            SP_DEVINSTALL_PARAMS_W instParams = new SP_DEVINSTALL_PARAMS_W();
            instParams.cbSize = (uint)Marshal.SizeOf(instParams);
            SetupDiGetDeviceInstallParamsW(hDevInfo, ref devData, ref instParams);
            instParams.Flags |= 0x00010000; // DI_ENUMSINGLEINF
            instParams.FlagsEx |= 0x00000800; // DI_FLAGSEX_ALLOWEXCLUDEDDRVS
            instParams.DriverPath = @"C:\Windows\INF\rndiscmp.inf";
            SetupDiSetDeviceInstallParamsW(hDevInfo, ref devData, ref instParams);

            if (!SetupDiBuildDriverInfoList(hDevInfo, ref devData, 1)) {
                Console.WriteLine("SetupDiBuildDriverInfoList failed: " + Marshal.GetLastWin32Error());
                return false;
            }

            SP_DRVINFO_DATA_W drvData = new SP_DRVINFO_DATA_W();
            drvData.cbSize = (uint)Marshal.SizeOf(drvData);
            if (!SetupDiEnumDriverInfoW(hDevInfo, ref devData, 1, 0, ref drvData)) {
                Console.WriteLine("SetupDiEnumDriverInfoW failed: " + Marshal.GetLastWin32Error());
                return false;
            }

            Console.WriteLine("Selected driver: " + drvData.Description + " (" + drvData.MfgName + ")");
            SetupDiSetSelectedDriverW(hDevInfo, ref devData, ref drvData);

            bool reboot = false;
            if (!DiInstallDevice(IntPtr.Zero, hDevInfo, ref devData, ref drvData, 0, out reboot)) {
                Console.WriteLine("DiInstallDevice returned error: " + Marshal.GetLastWin32Error());
                return false;
            }
            Console.WriteLine("DiInstallDevice succeeded!");
            return true;
        } finally {
            SetupDiDestroyDeviceInfoList(hDevInfo);
        }
    }
}
"@

Add-Type -TypeDefinition $code
if ($dev.Status -ne "OK") {
    Write-Host "Installing Microsoft Remote NDIS driver via DiInstallDevice..." -ForegroundColor Cyan
    [RndisInstaller]::InstallRndis($dev.InstanceId) | Out-Null
    Start-Sleep -Seconds 3
}

$net = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "NDIS" } | Select-Object -First 1
if (-not $net) {
    Write-Host "ERROR: RNDIS Network Adapter still not found in Get-NetAdapter!" -ForegroundColor Red
    Get-PnpDevice -InstanceId $dev.InstanceId | Format-List
    Read-Host "Press Enter to close"
    exit 1
}

Write-Host ("SUCCESS! RNDIS Adapter is active: " + $net.Name + " (" + $net.InterfaceDescription + ", ifIndex=" + $net.ifIndex + ")") -ForegroundColor Green
Write-Host "Configuring IP 192.168.0.2/24 and direct host route to 192.168.0.1/32 over USB RNDIS..." -ForegroundColor Cyan
Remove-NetIPAddress -InterfaceIndex $net.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceIndex $net.ifIndex -IPAddress "192.168.0.2" -PrefixLength 24 -ErrorAction SilentlyContinue | Out-Null
Remove-NetRoute -DestinationPrefix "192.168.0.1/32" -Confirm:$false -ErrorAction SilentlyContinue
New-NetRoute -DestinationPrefix "192.168.0.1/32" -InterfaceIndex $net.ifIndex -NextHop "0.0.0.0" -RouteMetric 1 -ErrorAction SilentlyContinue | Out-Null
arp.exe -d 192.168.0.1 2>$null

Start-Sleep -Seconds 2
Write-Host "Testing Telnet port 23 on Peephole (192.168.0.1:23)..." -ForegroundColor Cyan
$tcp = New-Object System.Net.Sockets.TcpClient
try {
    $tcp.Connect("192.168.0.1", 23)
    Write-Host "CONNECTED TO PEEPHOLE TELNET (192.168.0.1:23)!" -ForegroundColor Green
    $tcp.Close()
} catch {
    Write-Host ("Telnet connect error: " + $_.Exception.Message) -ForegroundColor Red
}

Read-Host "Press Enter to close"
