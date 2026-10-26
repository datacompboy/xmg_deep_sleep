---
name: deep-sleep-forensics
description: Subagent guide for target discovery, crash log extraction, live ACPI table dumping, and baseline testing on clean factory firmware.
---

# Deep Sleep Forensics & Baseline Characterization Subskill

## Overview

This subskill covers **Stage 1 (Setup & Baseline)** and **Step 1 (Analyze Previous Result)** of the debugging loop.

It extracts diagnostic information from the target machine before writing patches, helping you isolate the exact conditions needed to reproduce the issue.

> [!NOTE]
> **Scope Boundary:**
> `deep-sleep-forensics` is strictly responsible for **empirical telemetry extraction and hardware audit** (decoding SleepStudy, minidumps, event logs, registry interrupt modes, and dumping live ACPI tables). It does **not** simulate ACPI control flow or re-validate previous ASL code. Downstream static evaluation of previous firmware versions against updated design scenarios is handled in **Step 3** by [`acpi-static-verifier`](../acpi-static-verifier/SKILL.md).

---

## 1. Diagnostic Scripts

The helper scripts live in [`scripts/`](../scripts/):
* [`sleepstudy-reader.py`](../scripts/sleepstudy-reader.py): Parses SleepStudy HTML reports, WinEvents text files, and crash minidumps.
* [`parse_minidump.py`](../scripts/parse_minidump.py): Dissects Windows 64-bit kernel crash dumps (`.dmp`).

### Quick Commands:
```bash
# Analyze SleepStudy or WinEvents export:
python3 skill/scripts/sleepstudy-reader.py sleepstudy.html
python3 skill/scripts/sleepstudy-reader.py winevents.txt

# Parse a crash dump:
python3 skill/scripts/sleepstudy-reader.py crash.dmp
# Or standalone:
python3 skill/scripts/parse_minidump.py minidump.dmp

# Scan a folder of logs and crash dumps:
python3 skill/scripts/sleepstudy-reader.py reports/
```

---

## 2. Key Telemetry Dimensions to Check

When reviewing crash logs or test results, look at these operational factors:

1. **External Displays:** Was an external monitor connected? If so, external display routing, discrete GPU power state, and display audio are relevant. If not, the dGPU may be powered down completely.
2. **Power Source (`OnAc`):** Was the system plugged in or on battery? Power plans apply more aggressive PCIe ASPM and shorter runtime D3 timeouts on battery.
3. **Trigger (`EntryReason`):**
   * `Screen Off Request` (Forced Sleep / Lid Close): The OS attempts full system sleep (S0ix). Apps are suspended, audio streams are stopped.
   * `Video Idle Timeout` (Display Idle): The system is still **running actively in S0**. User apps and audio services are alive in D0. Never cut power rails or assert reset during display idle.
4. **Logon State:** Was a user logged in, or was the machine at the pre-logon lock screen? Background daemons and GPU containers run only in active user sessions.
5. **Standby Duration & Failure Timing:**
   * $0\text{--}5\text{s}$: Failure during initial display turn-off / shallow D3hot.
   * $30\text{--}45\text{s}$: Failure during display DPMS standby / deep D3cold / PCIe link power-down.
   * $40\text{--}50\text{s}$: Modern Standby background maintenance query (Dark Wake).
   * $\approx 115\text{--}120\text{s}$: OS Power Watchdog timeout (driver stuck on a pending power IRP).
   * $> 3\text{h}$: S0ix to S4 (Hibernate) transition failure.
6. **Lid State:** Opened vs closed.
7. **Blocker Devices (`BlockerGroups`):** Shows which devices or drivers delayed or prevented sleep.

---

## 3. Auditing the Target Hardware & Drivers

Inspect the target system directly rather than making assumptions:

### 3.1 Interrupt Mode (MSI vs Legacy Line Interrupts)
Query the Windows Registry for the peripheral or secondary audio device:
```powershell
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Enum\PCI\<Target_Device_ID>\*\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties" -Name MSISupported
```
* **If `MSISupported == 0`:** The device uses **legacy pin interrupts (INTx lines)**.
  * *Important:* Never set Bit 10 (`Interrupt Disable = 1`) in the PCI Command register. Setting Bit 10 disables legacy line interrupts, causing driver threads to spin at 100% CPU waiting for interrupts that never arrive.
* **If `MSISupported == 1`:** The device uses Message Signaled Interrupts (MSI / MSI-X).

### 3.2 Multi-Function Devices & Power Resources
* Inspect dumped ACPI tables for secondary functions sharing the same physical link:
  * Does the secondary function have its own Power Resources (`_PR0..3`)?
  * If `_PR0..3` is missing, OSPM does not track its power state and will not re-enumerate or restore its BARs across D3cold wake. Firmware must restore them explicitly.
  * Check if hardware clears secondary function enable straps across D3cold. Firmware must set the strap in ACPI wake before returning control to the OS.

### 3.3 Live ACPI Table Extraction
Dump tables directly from the running system:
* **Windows:** `acpidump.exe -b` (dumps binary `.dat` tables).
* **Linux:** `acpidump -b` or `cp /sys/firmware/acpi/tables/* .`

---

## 4. Testing Baseline on Clean Stock Firmware

Before testing any patch, run this sweep on **clean factory firmware**:

1. Configure a 1-minute display idle timeout:
   ```cmd
   powercfg /change monitor-timeout-ac 1
   ```
2. Run the 6 basic test scenarios:

| Test ID | Trigger Mode | Logon Context | Hold Duration | Hardware State Tested | Expected Baseline Result |
|:---:|:---:|:---:|:---:|:---:|:---|
| **T1** | Forced Sleep | Lock Screen | 10–15 s | Shallow D3hot wake | Pass (<1s wake) |
| **T2** | Forced Sleep | Lock Screen | 40–60 s | Deep D3cold / Power-off | Pass (<1s wake) |
| **T3** | Idle Standby | Lock Screen | 70 s (1m timer) | S0 Display Idle | Pass (<1s wake) |
| **T4** | Forced Sleep | Active Desktop | 10–15 s | Shallow D3hot wake | Pass (<1s wake) |
| **T5** | Forced Sleep | Active Desktop | 40–60 s | Deep D3cold wake | **Failure Point (Hang / Reboot)** |
| **T6** | Idle Standby | Active Desktop | 70 s (1m timer) | S0 Display Idle with peripherals | **Failure Point (Hang / Reboot)** |

### Pruning the Testing Loop
* Any test that passes 100% on stock firmware does not need to be re-run on every single patch.
* Focus active patch testing strictly on the **failing subset** (`T5` and `T6`), cutting test time down to a few minutes per iteration.

---

## 5. Symptom to Hardware Cause Quick-Reference

| Observed Symptom | Underlying Hardware Cause | What Is Happening |
|:---|:---|:---|
| **Silent Freeze / Black Screen / Fans Run** | Unbounded while-loop in ACPI | Reading an unpowered/training link returns `0xFFFFFFFF`; while-loop spins forever. |
| **Instant Cold Reboot Back to POST** | PCIe Completer Abort / Bus Error | Writing to an unpowered/reset endpoint or issuing unaligned writes to Host Bridge ECAM. |
| **30s Watchdog BugCheck (`0x19C 0x50`)** | Unmapped MMIO / Zeroed BARs | Device wake failed to restore BARs or left Command MSE cleared; display driver timed out. |
| **40s–50s Standby Auto-Reboot** | Dark Wake Rail Hijack | Device `_PS0` powered on rails during a display-off background maintenance window without `_PR0` refcount. |
| **115s–120s Delayed Watchdog Reboot** | Asymmetric Power Gating | Power-gating cut power or asserted reset during S0 display idle while audio/services were in D0. |
| **Audio Distortion / High CPU Spin** | Interrupt Mismatch | Command register disabled interrupts (Bit 10 = 1) on an endpoint using legacy INTx lines. |
