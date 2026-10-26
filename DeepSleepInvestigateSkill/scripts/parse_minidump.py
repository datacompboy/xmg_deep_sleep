#!/usr/bin/env python3
"""
Windows Kernel Crash Dump (Minidump/Triage Dump) Parser
Specialized for Modern Standby, Display/Graphics, and ACPI Power Debugging.
"""

import sys
import os
import glob
import struct
import re
from typing import Dict, List, Optional, Tuple

# Common Windows Bug Check code definitions
BUGCHECK_NAMES = {
    0x19C: "WIN32K_POWER_WATCHDOG_TIMEOUT",
    0x9F:  "DRIVER_POWER_STATE_FAILURE",
    0xA0:  "INTERNAL_POWER_ERROR",
    0x15F: "CONNECTED_STANDBY_WATCHDOG_TIMEOUT_LIVEDUMP",
    0x133: "DPC_WATCHDOG_VIOLATION",
    0x10E: "VIDEO_MEMORY_MANAGEMENT_INTERNAL",
    0x116: "VIDEO_TDR_FAILURE",
    0x117: "VIDEO_TDR_TIMEOUT_DETECTED",
    0x119: "VIDEO_SCHEDULER_INTERNAL_ERROR",
    0x50:  "PAGE_FAULT_IN_NONPAGED_AREA",
    0xD1:  "DRIVER_IRQL_NOT_LESS_OR_EQUAL",
    0x7E:  "SYSTEM_THREAD_EXCEPTION_NOT_HANDLED",
    0x3B:  "SYSTEM_SERVICE_EXCEPTION",
    0x1E:  "KMODE_EXCEPTION_NOT_HANDLED",
    0x7F:  "UNEXPECTED_KERNEL_MODE_TRAP",
    0x0A:  "IRQL_NOT_LESS_OR_EQUAL",
    0x124: "WHEA_UNCORRECTABLE_ERROR",
}

# Subcode explanations for 0x19C (WIN32K_POWER_WATCHDOG_TIMEOUT)
WIN32K_POWER_WATCHDOG_SUBCODES = {
    0x10: "The power request queue is not making progress",
    0x20: "Calling PO (Power Engine Plugin) to set power state",
    0x30: "Calling GDI to power on",
    0x40: "Calling DWM to render",
    0x50: "Calling monitor driver to power on (display / GPU driver wake timeout)",
}

def parse_minidump(filepath: str) -> None:
    if not os.path.isfile(filepath):
        print(f"Error: File not found: {filepath}")
        return

    file_size = os.path.getsize(filepath)
    with open(filepath, "rb") as f:
        data = f.read()

    print("=" * 80)
    print(f"File: {filepath} ({file_size:,} bytes)")
    print("=" * 80)

    if len(data) < 0x2000:
        print("Error: File too small to be a valid Windows kernel dump.")
        return

    # Check 64-bit Windows dump header (DUMP_HEADER64)
    sig = data[:4]
    val = data[4:8]
    if sig != b"PAGE" or val != b"DU64":
        print(f"Warning: Unexpected signature {sig}{val} (Expected PAGEDU64)")

    # DUMP_HEADER64 layout
    # 0x08: MajorVersion (ULONG)
    # 0x0c: MinorVersion (ULONG) - Build number
    # 0x10: DirectoryTableBase (ULONG64)
    # 0x18: PfnDataBase (ULONG64)
    # 0x20: PsLoadedModuleList (ULONG64)
    # 0x28: PsActiveProcessHead (ULONG64)
    # 0x30: MachineImageType (ULONG)
    # 0x34: NumberProcessors (ULONG)
    # 0x38: BugCheckCode (ULONG64 or ULONG in lower 32-bits)
    # 0x40: BugCheckParameter1..4 (ULONG64 * 4)
    # 0x80: KdDebuggerDataBlock (ULONG64)
    # 0xf8: DumpType (ULONG)

    major_ver, minor_ver = struct.unpack_from("<II", data, 0x08)
    dtb, pfn_db, mod_list, proc_head = struct.unpack_from("<QQQQ", data, 0x10)
    mach, num_proc = struct.unpack_from("<II", data, 0x30)
    bug_code_raw = struct.unpack_from("<Q", data, 0x38)[0]
    # In Windows triage dumps, bug_code lower 32 bits contains the actual code
    bug_code = bug_code_raw & 0xFFFFFFFF
    p1, p2, p3, p4 = struct.unpack_from("<QQQQ", data, 0x40)
    dump_type = struct.unpack_from("<I", data, 0xf8)[0]

    mach_str = "x86_64 (AMD64)" if mach == 0x8664 else f"0x{mach:x}"
    code_name = BUGCHECK_NAMES.get(bug_code, "UNKNOWN_BUGCHECK")

    print(f"Windows Build: {minor_ver} (Major: {major_ver})")
    print(f"Architecture:  {mach_str}, CPUs: {num_proc}")
    print(f"Dump Type:     0x{dump_type:x} ({'Triage/Minidump' if dump_type == 0x100000 else 'Kernel Dump'})")
    print(f"BugCheck Code: 0x{bug_code:X} ({code_name})")
    print(f"Parameters:    P1 = 0x{p1:X}")
    print(f"               P2 = 0x{p2:X}")
    print(f"               P3 = 0x{p3:X}")
    print(f"               P4 = 0x{p4:X}")

    # Specific BugCheck breakdowns
    if bug_code == 0x19C:
        subcode_desc = WIN32K_POWER_WATCHDOG_SUBCODES.get(p1, "Unknown subcode")
        print("\n[+] 0x19C WIN32K_POWER_WATCHDOG_TIMEOUT Breakdown:")
        print(f"    Subcode (P1): 0x{p1:X} -> {subcode_desc}")
        print(f"    Context (P2): 0x{p2:X} -> Power request worker thread / KTHREAD")
        if p1 == 0x50:
            print("    Analysis: System stalled while turning ON or changing display power state.")
            print("              Display driver (dxgkrnl / nvlddmkm) did not complete monitor power-on within 180s.")

    elif bug_code == 0x9F:
        print("\n[+] 0x9F DRIVER_POWER_STATE_FAILURE Breakdown:")
        subcodes_9f = {
            0x1: "Device object being freed has pending Power IRPs",
            0x2: "Driver failed to set device power state in requested time",
            0x3: "Subordinate device failed to complete power IRP in required time",
            0x4: "Power transition timed out calling driver entry point",
        }
        print(f"    Subcode (P1): 0x{p1:X} -> {subcodes_9f.get(p1, 'Unknown subcode')}")
        print(f"    Device Object (P2): 0x{p2:X}")
        print(f"    IRP / Context (P3): 0x{p3:X}")

    # Search for Triage Dump Components
    triage_components = []
    known_components = [
        b"POP_WATCHDOG_TRIAGE_DUMP_COMPONENT",
        b"POWD",
        b"DxgKrnlTriageDump",
        b"DxkW",
        b"DxgK",
        b"HDAudBus",
        b"pci.sys",
        b"ACPI.sys",
        b"nvlddmkm",
        b"amdfendrmgr",
        b"NetAdapterCx",
    ]
    for comp in known_components:
        count = len(re.findall(re.escape(comp), data))
        if count > 0:
            triage_components.append(f"{comp.decode('ascii', errors='ignore')} ({count}x)")

    if triage_components:
        print("\n[+] Triage Dump Components Found:")
        for c in triage_components:
            print(f"    - {c}")

    # Search for occurrences of target thread / context (P2)
    if p2 != 0:
        p2_bytes = struct.pack("<Q", p2)
        p2_offsets = [m.start() for m in re.finditer(re.escape(p2_bytes), data)]
        print(f"\n[+] References to P2 Context (0x{p2:X}): {len(p2_offsets)} occurrences in memory")
        for off in p2_offsets[:8]:
            print(f"    - Offset in dump: 0x{off:X}")
        if len(p2_offsets) > 8:
            print(f"    ... and {len(p2_offsets) - 8} more")

    # Extract loaded drivers (.sys modules)
    sys_unicode = set(re.findall(rb'(?:[a-zA-Z0-9_\-]\x00){3,30}\.\x00s\x00y\x00s\x00', data))
    sys_ascii = set(re.findall(rb'([a-zA-Z0-9_\-]{3,30}\.sys)\x00', data))

    all_drivers = set()
    for s in sys_unicode:
        try:
            all_drivers.add(s.decode("utf-16le").lower())
        except Exception:
            pass
    for s in sys_ascii:
        try:
            all_drivers.add(s.decode("ascii").lower())
        except Exception:
            pass

    key_drivers = ["nvlddmkm.sys", "dxgkrnl.sys", "hdaudbus.sys", "pci.sys", "acpi.sys", "watchdog.sys", "win32k.sys", "win32kbase.sys"]
    found_key = [d for d in key_drivers if d in all_drivers]
    if found_key:
        print(f"\n[+] Key Power/Graphics/Audio Drivers Present ({len(found_key)}):")
        print(f"    {', '.join(sorted(found_key))}")

    print(f"\n[+] Total Driver Signatures Detected in Dump: {len(all_drivers)}")
    print()

def main():
    if len(sys.argv) < 2:
        # Default behavior: scan all minidump directories in current folder
        dumps = sorted(glob.glob("minidump*/*.dmp"))
        if not dumps:
            dumps = sorted(glob.glob("*.dmp"))
        if not dumps:
            print("Usage: python3 parse_minidump.py <path_to_minidump.dmp | directory | glob>")
            sys.exit(1)
    else:
        arg = sys.argv[1]
        if os.path.isdir(arg):
            dumps = sorted(glob.glob(os.path.join(arg, "*.dmp")))
        else:
            dumps = sorted(glob.glob(arg))

    if not dumps:
        print(f"No minidump files matched: {sys.argv[1]}")
        sys.exit(1)

    print(f"Parsing {len(dumps)} minidump file(s)...\n")
    for dmp in dumps:
        parse_minidump(dmp)

if __name__ == "__main__":
    main()
