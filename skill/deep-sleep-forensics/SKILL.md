---
name: deep-sleep-forensics
description: Subagent runbook for target discovery, incident forensics, telemetry ingestion, live ACPI extraction, and baseline characterization. Ingests SleepStudy, WinEvents, and Minidumps, audits OS registry driver contracts, and executes the 3D factorial baseline matrix.
---

# Deep Sleep Forensics & Target Characterization Subskill

## Overview

This subskill provides the operational protocol for **Stage 1 (Initial Setup & Forensics)** and **Stage 2 Step 1 (Analyze Previous Attempt)** of the Modern Standby debugging methodology.

It extracts ground-truth facts from the target machine before any firmware code is written or modified, eliminating speculation and identifying the precise conditions required for bug reproduction.

---

## 1. Unified Diagnostic Ingestion

The diagnostic tools live in [`skill/scripts/`](file:///home/datacompboy/fun/xmg/skill/scripts/):
* [`sleepstudy-reader.py`](file:///home/datacompboy/fun/xmg/skill/scripts/sleepstudy-reader.py): Unified extractor for SleepStudy HTML, WinEvents TXT, and Crash Dumps.
* [`parse_minidump.py`](file:///home/datacompboy/fun/xmg/skill/scripts/parse_minidump.py): Deep Windows 64-bit kernel crash dump parser.

### Command Reference:
```bash
# Analyze a single SleepStudy or WinEvents export:
python3 skill/scripts/sleepstudy-reader.py sleepstudy.html
python3 skill/scripts/sleepstudy-reader.py winevents.txt

# Dissect a crash minidump:
python3 skill/scripts/sleepstudy-reader.py crash.dmp
# Or standalone:
python3 skill/scripts/parse_minidump.py minidump.dmp

# Scan an entire directory of logs and crash dumps:
python3 skill/scripts/sleepstudy-reader.py reports/
```

---

## 2. The 7 Orthogonal Telemetry Dimensions

When analyzing historical incidents (the "Death Session") or latest test results, audit these seven dimensions:

1. **Peripheral State (`EventLog.ExternalMonitorState`):**
   * `Connected`: Discrete GPU display engine is actively driving external display lines. Implicates dGPU runtime power-gating, MUX lines, and HDMI audio.
   * `Disconnected`: Internal panel only. GPU may be fully powered down.
2. **Power Source (`OnAc`):**
   * `True` (AC Wall Charger): Standard ASPM, standard RTD3 timers.
   * `False` (Battery DC): Aggressive PCIe L1.1/L1.2 ASPM, short 5s RTD3 timeouts, Type-C PD renegotiation.
3. **Trigger Mechanism (`EntryReason`):**
   * `Screen Off Request` (Forced Sleep / Lid Close): System initiates total S0ix quiescence. Audio torn down, apps suspended.
   * `Video Idle Timeout` (Display Idle): System remains **actively running in S0**. Audio active in D0. Never assert reset or cut power rails.
4. **Logon Context (`UserLogonState`):**
   * Desktop (`TDGC == 1`): User logged in. User-mode driver daemons running (NVIDIA container, AMD Adrenalin).
   * Lock Screen (`TDGC == 0`): Pre-logon. Stock firmware often uses a simplified `POFF`/`PON` power path.
5. **Standby Latency Milestone & Time-to-Fault:**
   * $0\text{--}5\text{s}$: Shallow D3hot entry / panel blanking.
   * $30\text{--}45\text{s}$: Monitor DPMS standby (orange LED) $\rightarrow$ deep D3cold / link parked in L23.
   * $40\text{--}50\text{s}$: Modern Standby Dark Wake maintenance window query.
   * $\approx 115\text{--}120\text{s}$: Kernel Power Watchdog timeout (pending driver power IRP).
   * $> 3\text{h}$: Adaptive Hibernate threshold (S0ix $\rightarrow$ S4 failure).
6. **Physical Lid State (`EventLog.LidState`):** `Opened` vs `Closed`.
7. **Subsystem Blockers (`BlockerGroups`):** Checks `Audio Activity`, `FX Devices`, and `PEP Pre-Vetoes`.

---

## 3. Target Hardware & Driver Contract Audit ("Know Your Target")

Never assume endpoint behavior. Query the live operating system directly:

### 3.1 Interrupt Delivery Architecture (MSI vs Legacy INTx)
Query the Windows Registry for the target peripheral or secondary function:
```powershell
# Query MSI support for target hardware ID:
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Enum\PCI\<Target_Device_ID>\*\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties" -Name MSISupported
```
* **If `MSISupported == 0`:** The device uses **legacy pin interrupts (INTx / IRQ lines)**.
  * *Critical Rule:* Never set Bit 10 (`Interrupt Disable = 1`) in the PCI Command register. Setting Bit 10 silences legacy line interrupts, causing driver threads to spin at 100% CPU waiting for un-serviced interrupts.
* **If `MSISupported == 1`:** The device uses Message Signaled Interrupts (MSI / MSI-X).

### 3.2 Multi-Function Coupling & Power Resource Check
* Inspect dumped ACPI tables for secondary functions sharing the same physical PCIe link:
  * Does the secondary function define its own Power Resources (`_PR0..3`)?
  * If `_PR0..3` is **missing**, OSPM (`pci.sys`) does **not** track its power state and will **never re-enumerate or restore its BARs across D3cold wake**. Firmware must pre-capture and restore its BARs surgically.
  * Audit endpoint strap behavior: Check if target hardware clears secondary function enable straps across D3cold or deep power-down. Firmware must explicitly set the strap in ACPI wake before returning control to the OS.

### 3.3 Live ACPI Table Extraction
Do not unpack vendor capsule ROMs. Dump exact runtime tables directly:
* **Windows:** Run `acpidump.exe -b` (dumps binary `.dat` tables).
* **Linux:** Run `acpidump -b` or `cp /sys/firmware/acpi/tables/* .`

---

## 4. The 3D Baseline Matrix Sweep (Stock Calibration)

Run this sweep on **100% unmodified factory firmware** to establish the empirical baseline:

1. Configure fast 1-minute display idle timeout:
   ```cmd
   powercfg /change monitor-timeout-ac 1
   ```
2. Execute the 6-Scenario Baseline Sweep:

| Test ID | Trigger Mode | Logon Context | Hold Duration | Hardware Depth | Expected Stock Result |
|:---:|:---:|:---:|:---:|:---:|:---|
| **T1** | Forced Sleep | Lock Screen | 10–15 s | Shallow (D3hot) | Pass (<1s wake) |
| **T2** | Forced Sleep | Lock Screen | 40–60 s | Deep (D3cold / Power-Off) | Pass (<1s wake) |
| **T3** | Idle Standby | Lock Screen | 70 s (1m timer) | S0 Display Idle | Pass (<1s wake) |
| **T4** | Forced Sleep | Active Desktop | 10–15 s | Shallow (D3hot) | Pass (<1s wake) |
| **T5** | Forced Sleep | Active Desktop | 40–60 s | Deep (D3cold / Runtime D3) | **Failure Point (Hang / Reboot)** |
| **T6** | Idle Standby | Active Desktop | 70 s (1m timer) | S0 Display Idle | **Failure Point (Hang / Reboot)** |

### 4.1 Search Space Pruning
* **The Invariant Freezing Rule:** Any dimension that passes 100% on stock firmware (e.g., Lock Screen T1–T3, Shallow Sleep T4) is **frozen**.
* **Active Failure Set:** Confine active iteration strictly to the failing subset (`T5` and `T6`). Iteration time drops to **under 3 minutes per patch**.

---

## 5. Symptom-to-Hardware Primitive Classification

Map the observed failure behavior to the underlying hardware root cause:

| Observed Symptom | Hardware Root Cause | Diagnostic Signature |
|:---|:---|:---|
| **Silent Freeze / Black Screen / Fans Run** | Unbounded while-loop in ACPI interpreter | PCIe config read returns `0xFFFFFFFF` (no exception); ACPI spins at high IRQL. |
| **Instant Cold Reboot Back to POST** | PCIe Configuration Write Completer Abort or unaligned Host Bridge ECAM write | Writing to unpowered/reset endpoint; unaligned write to SoC Host Bridge ECAM; MCA reset. |
| **30s Watchdog BugCheck (`0x19C 0x50`)** | Unmapped MMIO aperture / Zeroed BARs | Display driver timed out lighting monitor; bulk copy zeroed BARs or Command MSE=0. |
| **40s–50s Standby Auto-Reboot** | Modern Standby Dark Wake maintenance hijack | Device `_PS0` woke link during 0.15s display-off PDC maintenance without `_PR0`; SoC MCA reset. |
| **115s–120s Delayed Watchdog Reboot** | Active S0 driver deadlocked on unpowered endpoint | Device power state asserted reset during S0 Video Idle while dependent services were in D0. |
| **Audio Distortion / High CPU Spin** | MSI Bit 10 interrupt masking on legacy line interrupt | Bit 10 (`Interrupt Disable`) set in Command register, starving legacy INTx line when `MSISupported : 0`. |
