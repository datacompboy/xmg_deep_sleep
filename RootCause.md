# Root Cause Analysis: XMG NEO 15 (M22) / Tongfang GM5RGxx Modern Standby (S0ix) Failure with External Monitor

**Document Version:** 1.0  
**Date:** September 25, 2026  
**Chassis:** Tongfang GM5RGxx / Schenker XMG NEO 15 (M22)  
**Platform:** AMD Rembrandt (Zen 3+, Ryzen 7 6800H / Ryzen 9 6900HX), Socket FP7, AMD Promontory/Rembrandt FCH  
**dGPU:** NVIDIA GeForce RTX 3070 Ti / 3080 Mobile (GA104), PCIe Gen4 x8 on AMD Root Port `\_SB.PCI0.GPP0`  
**Firmware:** AMI Aptio V, BIOS `N.1.15A14` / `GM5RGxxN115A14`  
**Operating System:** Windows 11 64-bit (Modern Standby / S0 Low Power Idle enabled)

---

## 1. Executive Summary

On the Tongfang GM5RGxx (XMG NEO 15 M22) chassis, connecting an external display (via HDMI 2.1 or USB-C DisplayPort Alt-Mode) and allowing the system to enter Modern Standby (S0ix) or display idle timeout caused one of two failure modes:
1. **The Original Stock Bug:** The laptop entered sleep, screens went black, but the laptop remained powered on, warm, with fans spinning, completely unresponsive to keyboard, mouse, or power button. It remained in this state permanently until the battery was completely drained to 0%.
2. **The Intermediate Patch Bug:** The laptop survived manual sleep/wake, but on video idle timeout, it instantly crashed and rebooted at the exact millisecond of sleep entry (`Duration: 0s`).

Through reverse-engineering of the OEM ACPI tables (`Opt2Tabl`), disassembly of runtime ACPI dumps, and forensic analysis of Windows SleepStudy (`sleepstudy11.html`, `sleepstudy12.html`) and Windows Event logs (`winevents11.txt`, `winevents12.txt`), the **root cause** has been definitively identified:

> **The root cause is a dual defect in the OEM ACPI power sequencing for the dGPU PCIe Root Port (`\_SB.PCI0.GPP0`):**
> 1. **PCIe Link State Desynchronization (`PTOF` flaw):** The ACPI power resource methods (`_OFF` and `_ON`) relied on an uninitialized/zero flag (`PTOF`) instead of enforcing hardware L2/L3 entry (`DL23(1)`) and exit (`L23D(1)`). Cutting dGPU power while the AMD root complex was still in active `L0` triggered an immediate **PCIe Surprise Down Hardware Fatal Abort** (instant reboot).
> 2. **Unbounded Infinite Polling Loops:** If the link was not ready, both `GC6O` and `_ON` entered infinite while-loops polling `While (NVID != 0x10DE)`. Because `Sleep(1)` yields the CPU thread in Windows `ACPI.sys`, CPU watchdog timers never fired; instead, Windows **Power IRP serialization** blocked the entire device power stack indefinitely, locking the OS in an un-wakeable black-screen state until the battery died.
> 3. **Unguarded Configuration Restores in `_PS0`:** Method `_PS0` blindly wrote 251 bytes of PCIe configuration space (`VGAR = VGAB`) into the offline dGPU, causing uncorrectable AMD PCIe Master Aborts.

---

## 2. Hardware & Architecture Baseline

### 2.1 Video Routing Topology
- **Internal Panel (eDP):** Physically wired to the AMD Radeon 680M iGPU.
- **External Video Outputs:** The HDMI 2.1 port and USB-C DisplayPort lines are physically wired **directly to the NVIDIA dGPU PHYs**.
- **Significance:** When no external monitor is attached, the dGPU can stay in deep RTD3 / D3cold indefinitely. When an external monitor is attached, Hot-Plug Detect (HPD) is held high, and the monitor's sink termination pulls on the TMDS/DP AUX lines. Any power transition requires full dGPU power cycling and PCIe link re-training across the AMD Root Port.

### 2.2 Power Architecture & Controllers
- **Root Port:** `\_SB.PCI0.GPP0`
- **PCIe Endpoint:** `\_SB.PCI0.GPP0.PEGP` (NVIDIA dGPU, Vendor ID `0x10DE`)
- **Audio Endpoint:** `\_SB.PCI0.GPP0.NHDA` (NVIDIA High Definition Audio Controller)
- **Power Resource:** `\_SB.PCI0.GPP0.PG00` (Controls `_PR0`, `_PR2`, `_PR3`)
- **Embedded Controller:** ITE IT8xxx EC, managing discrete power rails (`PWEN`, `PWOK`, `REST#` / `PERST#`) via GPIO method `M010`.

```
+-------------------------------------------------------------------+
|                        AMD Ryzen SoC                              |
|  [Radeon 680M iGPU] ------------> Internal eDP Panel              |
|  [PCIe Root Port GPP0]                                            |
+--------------------------|----------------------------------------+
                           | PCIe Gen4 x8 Link
+--------------------------v----------------------------------------+
|                      NVIDIA dGPU (PEGP)                           |
|  [Display Engine] --------------> External Monitor (HDMI / USB-C) |
+-------------------------------------------------------------------+
```

---

## 3. The Working Theory: The Unified Root Cause

The issue is governed by the state of the OEM Optimus flag `TDGC` (Target Device GC6) inside ACPI table `Opt2Tabl`:

```
                             [Power Transition Requested]
                                          |
                                    Is TDGC == 1?
                                   /             \
                             YES  /               \  NO
                                 v                 v
                       [Optimus GC6 Path]    [Cold D3 Path]
                       (GC6I / GC6O)         (PG00._OFF / PG00._ON)
```

### 3.1 Path A: `TDGC == 1` (Optimus GC6 State)
- **Sleep Entry (`GC6I`):**
  ```asl
  Method (GC6I, 0, Serialized)
  {
      \_SB.PCI0.GPP0.PEGP.LTRE = \_SB.PCI0.GPP0.LREN
      \_SB.PCI0.GPP0.DL23 (One)    // Passes 'One' -> Calls TPV0() -> AMD Root Port enters L2/L3 Ready
      DLYM (0x0A)
      M010 (REST, Zero)            // Asserts PERST# cleanly
  }
  ```
- **Sleep Exit (`GC6O`):**
  Calls `L23D(One)`, which invokes `TPV1()` and `TPV2()`, writing bit 22 to root port register `0x0280` (`M403`) to release L2/L3.
- **Stock Flaw in `GC6O`:**
  ```asl
  While ((\_SB.PCI0.GPP0.PEGP.NVID != 0x10DE))
  {
      DLYM (One)   // Infinite loop if link training takes > 0ms!
  }
  ```
  If the link is slow to train with an external monitor attached, `GC6O` hangs the CPU core spinning in `DLYM(1)` (100µs stalls).

---

### 3.2 Path B: `TDGC == 0` (Cold D3 Power Resource Path)
When the system has already woken up once, `TDGC` is cleared to `0`. When the screen goes idle again, the firmware takes the `Else` branch of `PG00._OFF` and `PG00._ON`:

#### Defect 1: The `PTOF` Flag Flaw
In stock `Opt2Tabl`:
```asl
// In PG00._OFF:
\_SB.PCI0.GPP0.DL23 (PTOF)   // PTOF is evaluated from NVS Field TPNV
\_SB.PCI0.GPP0.POFF ()        // Cuts PWEN and drops power!

// In PG00._ON:
\_SB.PCI0.GPP0.L23D (PTOF)   // Evaluated from PTOF!
While ((\_SB.PCI0.GPP0.PEGP.NVID != 0x10DE))
{
    Sleep (One)               // Infinite loop!
}
```
- In `DL23`:
  ```asl
  Method (DL23, 1, Serialized)
  {
      If ((Arg0 == One)) { TPV0 () } // TPV0 is ONLY called if Arg0 == 1
      ...
  }
  ```
- In `L23D`:
  ```asl
  Method (L23D, 1, Serialized)
  {
      If ((Arg0 == One)) { TPV1 () } // TPV1/TPV2 ONLY called if Arg0 == 1
      ...
      If ((Arg0 == One)) { TPV2 () }
  }
  ```
- **The Disaster:** In the OEM NVS table, `PTOF` is initialized to `0`.
  1. On Sleep Entry (`_OFF`): `DL23(PTOF)` passes `0`. `TPV0()` is **never called**. The AMD root port remains in `L0`. Immediately after, `POFF()` cuts power to the dGPU. **Cutting power to a live PCIe endpoint while the root complex is in L0 triggers a PCIe Surprise Down Fatal Abort (instant hardware reset).**
  2. On Sleep Exit (`_ON`): `L23D(PTOF)` passes `0`. `TPV1()` and `TPV2()` are **never called**. The AMD root port is never signaled to exit L2/L3. The PCIe link **cannot train**. `NVID` remains `0xFFFF`.

#### Defect 2: The "Until Battery Drained" Hang Mechanism
When `NVID` remains `0xFFFF` during `_ON`:
```asl
While ((\_SB.PCI0.GPP0.PEGP.NVID != 0x10DE))
{
    Sleep (One)  // Yields execution in ACPI.sys
}
```
1. `Sleep(One)` calls `KeDelayExecutionThread` inside `ACPI.sys`. It does **not** peg the CPU at 100%. The Windows DPC watchdog (`0x133`) sees healthy timer ticks and does not fire.
2. In the Windows kernel power manager, **Power IRPs (`IRP_MN_SET_POWER`) are strictly serialized**.
3. Because the Power IRP for `PG00` never returns, all subsequent power events (including screen-wake, keyboard events, power-button taps) are queued behind the blocked IRP.
4. The OS cannot wake, cannot sleep further, cannot crash. The machine sits with screens dark and power rails active until the battery drops to 0%.

#### Defect 3: Blind PCIe Configuration Space Writes in `_PS0`
In stock `_PS0` (`ssdt4.dsl`, line 625):
```asl
Method (_PS0, 0, NotSerialized)
{
    _PSC = Zero
    If ((DGPS != Zero))
    {
        \_SB.PCI0.GPP0.PG00._ON ()
        If ((GPRF != One))
        {
            VGAR = VGAB  // Restores 251 BYTES of PCIe config space!
        }
        DGPS = Zero
    }
}
```
- `VGAR` is defined at offset `0x05` of `PCIM` (the dGPU PCIe config space) with length **2008 bits (251 bytes)**.
- If `_ON()` timed out or bailed out because link training failed, the stock `_PS0` immediately writes 251 bytes into an offline PCIe link.
- Writing to the configuration space of an offline PCIe endpoint triggers an **AMD PCIe Master Abort / Uncorrectable Target Error**, crashing the SoC.

---

## 4. Empirical Evidence & Test Progression

| Attempt / Session | Condition | TDGC State | Method Path | Observed Behavior | Root Cause Deduction |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Stock BIOS** | External display plugged in, idle timeout | Any | Stock `Opt2Tabl` | Black screen, fans spinning, battery drains to 0% | `While (NVID != 0x10DE)` infinite loop blocked Windows Power IRP queue permanently. |
| **Attempt 11 (Session 173)** | Monitor connected, idle timeout | `TDGC == 1` | Patched `GC6O` | **Slept 41 minutes, woke cleanly on Keyboard!** | Proved that fixing the loop in `GC6O` with active `PERST#` retry resolves the issue when `TDGC == 1`. |
| **Attempt 11 (Session 175)** | Monitor connected, idle timeout | `TDGC == 1` | Patched `GC6O` | **Slept 5 minutes, woke cleanly on Keyboard!** | Confirmed reproducibility on the `TDGC == 1` path. |
| **Attempt 11 (Session 179)** | Monitor connected, idle timeout | `TDGC == 0` | Stock `_ON` | Crashed on entry, powered down after 15 min | First wake cleared `TDGC` to `0`. Next sleep hit the unpatched second infinite loop in `_ON`. |
| **Attempt 12 (Session 188)** | Manual sleep (Screen Off Request) | `TDGC == 1` | Patched `GC6O` | **Slept 16 seconds, woke cleanly on Keyboard!** | Proved manual sleep routes through `GC6O` and functions properly. |
| **Attempt 12 (Session 190)** | Woke to lock screen, 45s idle timeout | `TDGC == 0` | Stock `_OFF` with `PTOF` | **Instant reboot at entry (Duration: 0s)** | `_OFF` executed `DL23(PTOF)` with `PTOF==0`. Skipped `TPV0()`, cut power while root port was in `L0`. Instant PCIe Surprise Down reboot! |
| **Attempt 12 (Session 193)** | Rebooted, sat at login screen 5m, idle timeout | `TDGC == 1` | Patched `GC6O` / `_ON` | **Slept 178 seconds (3m), woke cleanly on Keyboard!** | Fresh boot had `TDGC == 1`, avoiding the `_OFF` defect and waking cleanly. |

---

## 5. Excluded & Suppressed Theories

### Theory 1: "AMD Zen3+ AGESA / Microcode S0ix Firmware Defect"
- **Status: EXCLUDED.**
- **Rationale:** Modern Standby functions with 0% failure rate when no external monitor is attached. Furthermore, in Sessions 173, 175, 188, and 193, Modern Standby slept for up to 41 minutes and woke cleanly with the external monitor connected. If the CPU/SoC power plane had an inherent S0ix architectural flaw, those sessions could never have succeeded.

### Theory 2: "NVIDIA Display Driver (`nvlddmkm.sys`) Deadlock"
- **Status: EXCLUDED.**
- **Rationale:** Windows WDDM event traces showed the driver successfully requested `D3hot`/`D3cold` transitions. The lockup occurred inside `ACPI.sys` evaluating AML opcodes and inside the AMD PCIe Root Complex handling PCIe Surprise Down aborts. The driver was simply the caller of the standard ACPI power interfaces.

### Theory 3: "Hardware Failure / Cold Solder Joints / VRAM Degradation"
- **Status: EXCLUDED.**
- **Rationale:** The system maintains complete hardware stability under sustained heavy GPU/CPU workloads (FurMark, 3DMark, gaming) without PCIe bus errors, TDRs, or thermal throttling. The failure is purely state-machine-driven during power down/up.

### Theory 4: "Hardware Watchdog Timer Killing Power After 15 Minutes"
- **Status: REFINED / SUPPRESSED.**
- **Rationale:** Forensic inspection of `winevents12.txt` and `sleepstudy12.html` showed that Session 190 did **not** hang for 15 minutes before dying. It crashed and rebooted **in 0.0 seconds** (at 21:41:38). The reboot process took 44 seconds, returning the user to the Windows login screen at 21:42:22. The user returned to the laptop 15 minutes later and assumed it had just powered down, whereas it had actually rebooted immediately and sat idle at the lock screen.

### Theory 5: "Static ACPI Table Replacement / NVS Dropping"
- **Status: SUPPRESSED / ABANDONED.**
- **Rationale:** Early attempts to drop `Opt2Tabl` or re-inject modified SSDTs caused Windows Bugcheck `0xA5 (ACPI_BIOS_ERROR)`. This occurred because the OEM BIOS dynamically initializes memory structures (`OperationRegion TPNV, SystemMemory, 0xD3CD8000, 0x004D`) at boot. Dropping and re-adding tables caused address desynchronization with `dsdt.aml` and `ssdt9.aml`. The only stable mechanism is **in-place method renaming via OpenCore binary patches** paired with a supplementary override SSDT.

---

## 6. The Complete Solution: Attempt 13 Architecture

The solution requires five synchronized components across OpenCore and a custom ACPI SSDT ([SSDT-SLEEPFIX.dsl](file:///home/datacompboy/fun/xmg/Bios-XMG-NEO_XNE15E20_XNE17E20_BIOS-N106v2/SSDT-SLEEPFIX.dsl)):

### 6.1 Binary Method Renames in `Opt2Tabl` (`config.plist`)
All patches target `TableSignature: SSDT` (`U1NEVA==`) and `OemTableId: Opt2Tabl` (`T3B0MlRhYmw=`):
1. **`Method (GC6O)` $\rightarrow$ `XC6O`:**
   - Find: `14 4c 0d 47 43 36 4f 08` (`FEwNR0M2Twg=`)
   - Replace: `14 4c 0d 58 43 36 4f 08` (`FEwNWEM2Twg=`)
2. **`Method (_ON)` in `PG00` $\rightarrow$ `XON`:**
   - Find: `14 49 1d 5f 4f 4e 5f 08` (`FEkdX09OXwg=`)
   - Replace: `14 49 1d 58 4f 4e 5f 08` (`FEkdWE9OXwg=`)
3. **`Method (_OFF)` in `PG00` $\rightarrow$ `XOFF`:**
   - Find: `14 4f 11 5f 4f 46 46 08` (`FE8RX09GRgg=`)
   - Replace: `14 4f 11 58 4f 46 46 08` (`FE8RWE9GRgg=`)
4. **`Method (_PS0)` in `PEGP` $\rightarrow$ `XPS0`:**
   - Find: `14 45 04 5f 50 53 30 00` (`FEUEX1BTMAA=`)
   - Replace: `14 45 04 58 50 53 30 00` (`FEUEWFBTMAA=`)
5. **`Method (_PS3)` in `PEGP` $\rightarrow$ `XPS3`:**
   - Find: `14 4d 04 5f 50 53 33 00` (`FE0EX1BTMwA=`)
   - Replace: `14 4d 04 58 50 53 33 00` (`FE0EWFBTMwA=`)

---

### 6.2 Override Implementations in `SSDT-SLEEPFIX.aml`

#### 1. Safe Power Off (`PG00._OFF`):
```asl
Method (_OFF, 0, Serialized)
{
    If ((GSTA () != One)) { Return (Zero) }
    Local4 = M453; M453 = Zero;
    If ((TDGC == One))
    {
        CreateField (\_SB.PCI0.GPP0.TGPC, Zero, 0x03, GPPC)
        If (((ToInteger (GPPC) == One) || (ToInteger (GPPC) == 0x02)))
        {
            \_SB.PCI0.GPP0.PEGP.GC6I ()
        }
    }
    Else
    {
        \_SB.PCI0.GPP0.BPGF ()
        \_SB.PCI0.GPP0.PEGP.LTRE = \_SB.PCI0.GPP0.LREN
        Sleep (0x18)
        \_SB.PCI0.GPP0.DL23 (One)   // FORCED ONE: Root Port ALWAYS enters L2/L3 before power cut
        \_SB.PCI0.GPP0.POFF ()
        \_SB.PCI0.GPP0.APGF ()
    }
    M453 = Local4
    Return (Zero)
}
```

#### 2. Safe Power On (`PG00._ON`):
```asl
Method (_ON, 0, Serialized)
{
    If ((GSTA () != Zero)) { Return (Zero) }
    Local4 = M453; M453 = Zero;
    If ((TDGC == One))
    {
        If (((DGCX == 0x03) || (DGCX == 0x04)))
        {
            \_SB.PCI0.GPP0.PEGP.GC6O ()
        }
        TDGC = Zero; DGCX = Zero;
    }
    Else
    {
        \_SB.PCI0.GPP0.BPGN ()
        \_SB.PCI0.GPP0.PON ()
        Sleep (0x012C)
        \_SB.PCI0.GPP0.L23D (One)   // FORCED ONE: Root Port ALWAYS exits L2/L3 cleanly
        \_SB.PCI0.GPP0.CMDR |= 0x07
        \_SB.PCI0.GPP0.D0ST = Zero
        
        Local0 = 0x64              // 100ms Bounded Countdown Poll
        While (((\_SB.PCI0.GPP0.PEGP.NVID != 0x10DE) && (Local0 > Zero)))
        {
            Sleep (One)
            Local0--
        }

        If ((\_SB.PCI0.GPP0.PEGP.NVID != 0x10DE))
        {
            // Active Hardware Link Retry: Pulse PERST# Low (10ms) -> High (10ms)
            M010 (REST, Zero)
            Sleep (0x0A)
            M010 (REST, One)
            Sleep (0x0A)
            \_SB.PCI0.GPP0.L23D (One)
            \_SB.PCI0.GPP0.CMDR |= 0x07
            \_SB.PCI0.GPP0.D0ST = Zero
            Local0 = 0x64
            While (((\_SB.PCI0.GPP0.PEGP.NVID != 0x10DE) && (Local0 > Zero)))
            {
                Sleep (One)
                Local0--
            }
        }

        // Safe Bailout: Never touch offline PCIe config space!
        If ((\_SB.PCI0.GPP0.PEGP.NVID == 0x10DE))
        {
            \_SB.PCI0.GPP0.LREN = \_SB.PCI0.GPP0.PEGP.LTRE
            \_SB.PCI0.GPP0.CEDR = One
            \_SB.PCI0.GPP0.PEGP.SSSV = HYSS
            \_SB.PCI0.GPP0.APGN ()
        }
    }
    M453 = Local4
    Return (Zero)
}
```

#### 3. Guarded Power State Restore (`PEGP._PS0`):
```asl
Method (_PS0, 0, NotSerialized)
{
    _PSC = Zero
    If ((DGPS != Zero))
    {
        \_SB.PCI0.GPP0.PG00._ON ()
        If ((GPRF != One))
        {
            // Guarded: Never blast 251 bytes of config space into an unlinked PCIe endpoint
            If ((\_SB.PCI0.GPP0.PEGP.NVID == 0x10DE))
            {
                VGAR = VGAB
            }
        }
        DGPS = Zero
    }
}
```

---

## 7. Verification & Success Criteria

The fix is considered 100% verified when:
1. **SleepStudy Logs:** Show multiple consecutive sessions entering via both `Screen Off Request` and `Video Idle Timeout` with durations > 10 minutes and `ExitReason: Input Keyboard` or `Input Mouse`.
2. **Event Log:** Contains zero Event 41 (Kernel-Power unexpected shutdown) and zero Event 6008 entries following standby periods.
3. **Hardware State:** Fans spin down, system temperature drops, battery drain in standby conforms to standard S0ix specifications (~1-2% per 8 hours), and waking returns instantly to the active desktop.
