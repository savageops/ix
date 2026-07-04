Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class CpuSetInterop
{
    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_CPU_SET_INFORMATION
    {
        public Int32 Size;
        public Int32 Type;
        public UInt32 Id;
        public UInt16 Group;
        public byte LogicalProcessorIndex;
        public byte CoreIndex;
        public byte LastLevelCacheIndex;
        public byte NumaNodeIndex;
        public byte EfficiencyClass;
        public byte AllFlags;
        public UInt32 Reserved;
        public UInt64 AllocationTag;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetSystemCpuSetInformation(
        IntPtr information,
        Int32 bufferLength,
        out Int32 returnedLength,
        IntPtr process,
        UInt32 flags
    );
}
"@

$needed = 0
[CpuSetInterop]::GetSystemCpuSetInformation([IntPtr]::Zero, 0, [ref]$needed, [IntPtr]::Zero, 0) | Out-Null

if ($needed -le 0) {
    throw "GetSystemCpuSetInformation returned an empty topology buffer."
}

$buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($needed)
try {
    if (-not [CpuSetInterop]::GetSystemCpuSetInformation($buffer, $needed, [ref]$needed, [IntPtr]::Zero, 0)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "GetSystemCpuSetInformation failed with Win32 error $errorCode."
    }

    $offset = 0
    $rows = @()
    while ($offset -lt $needed) {
        $ptr = [IntPtr]::Add($buffer, $offset)
        $entry = [Runtime.InteropServices.Marshal]::PtrToStructure(
            $ptr,
            [type][CpuSetInterop+SYSTEM_CPU_SET_INFORMATION]
        )

        if ($entry.Size -le 0) {
            throw "GetSystemCpuSetInformation returned a zero-sized entry."
        }

        if ($entry.Type -eq 0) {
            $flags = [int]$entry.AllFlags
            $rows += [pscustomobject]@{
                id = [uint32]$entry.Id
                group = [int]$entry.Group
                logicalProcessorIndex = [int]$entry.LogicalProcessorIndex
                coreIndex = [int]$entry.CoreIndex
                lastLevelCacheIndex = [int]$entry.LastLevelCacheIndex
                numaNodeIndex = [int]$entry.NumaNodeIndex
                efficiencyClass = [int]$entry.EfficiencyClass
                parked = (($flags -band 0x1) -ne 0)
                allocated = (($flags -band 0x2) -ne 0)
                allocatedToTargetProcess = (($flags -band 0x4) -ne 0)
                realTime = (($flags -band 0x8) -ne 0)
                allocationTag = [uint64]$entry.AllocationTag
            }
        }

        $offset += $entry.Size
    }

    $rows | ConvertTo-Json -Compress -Depth 5
} finally {
    if ($buffer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
    }
}
