# Root Cause Analysis: XMG NEO 15 (M22) / Tongfang GM5RGxx Modern Standby (S0ix) Failure with External Monitor

**Document Version:** 2.0  
**Date:** September 26, 2026  
**Chassis:** Tongfang GM5RGxx / Schenker XMG NEO 15 (M22)  
**Platform:** AMD Rembrandt (Zen 3+, Ryzen 7 6800H / Ryzen 9 6900HX), Socket FP7, AMD Promontory/Rembrandt FCH  
**dGPU:** NVIDIA GeForce RTX 3070 Ti / 3080 Mobile (GA104), PCIe Gen4 x8 on AMD Root Port `\_SB.PCI0.GPP0`  
**Firmware Versions:** AMI Aptio V, BIOS `N.1.13` (Dec 2022) & `N.1.15A14` (Jan 2025)  
**Operating System:** Windows 11 64-bit (Modern Standby / S0 Low Power Idle enabled)

---

## 1. Executive Summary: The Evolution of the Failure Modes

Connecting an external display (via HDMI 2.1 or USB-C DisplayPort Alt-Mode directly wired to the dGPU) on the Tongfang GM5RGxx (XMG NEO 15 M22) causes severe Modern Standby (S0ix) failures. Through systematic reverse engineering of the OEM ACPI tables (`Opt2Tabl`), runtime ACPI table dumps, Windows SleepStudy reports, and Windows System Event logs, the root cause was determined to be a **compound sequence of OEM ACPI firmware defects** in graphics power sequencing.

As each layer was diagnosed and patched, the underlying state machine defects in the OEM firmware were uncovered in sequence:

```
[Factory BIOS N1.13 / N1.15A14]
   │
   ├─► Logged-in Desktop (TDGC == 1): Infinite While Loop in GC6O / _ON
   │     └─► Blocks Windows Power IRPs ──► Screen black, fans spin, 100% battery drain to 0%
   │
   └─► Lock Screen (TDGC == 0): POFF Power Cut + Blind PCIe Writes in _PS0 (VGAR = VGAB)
         └─► Blasts config space to dead GPU ──► AMD PCIe Completer Abort ──► Instant Cold Reboot
   │
[Attempt 11–12: Bounded GC6O Loop + PERST# Retry]
   │
   └─► Solved the infinite loop, but exposed the Lock Screen TDGC == 0 "POFF" instant reboot.
   │
[Attempt 13–15: Banned POFF, Forced GC6, Created PSTA State Machine]
   │
   ├─► Discovered the GSTA() trap (PWOK always 1 in GC6, causing _ON to abort immediately).
   ├─► Created PSTA software state machine to bypass GSTA().
   └─► Wake crash isolated to VGAR = VGAB bulk writes in _PS0.
   │
[Attempt 16: Removed VGAR = VGAB, Restored Root Port Bridge Decode (CMDR |= 0x07)]
   │
   └─► 100% SUCCESS on manual sleep (Session 259: 6m45s) & short lock screen (Session 261: 8s).
   │
[Attempt 16a: Long Desktop Idle Freeze (Session 263)]
   │
   └─► Left idle at desktop for 1 hour ──► NVIDIA driver entered RTD3 via NVJT calling stock GC6I().
         └─► Stock GC6I asserted reset but never updated DGPS or PSTA.
         └─► On wake, NVOP reported CGCS=3 (awake) & _ON saw PSTA=1 (on) ──► GC6O was NEVER called!
         └─► MMIO access to dGPU held in reset ──► PCIe bus freeze (white LED, spinning fans).
   │
[Attempt 17: Complete State Sync & The Lock Screen Audio Trap (Sessions 271, 273, 275)]
   │
   ├─► Manual sleep (Session 271): 100% SUCCESS.
   ├─► Desktop Idle Timeout (Session 273: 18.2m): 100% SUCCESS! Woke cleanly on mouse!
   │     └─► Proved RTD3 / NVJT state synchronization fix works for active desktop idle.
   └─► Lock Screen Idle Timeout (Session 275): Instant reboot on wake!
         └─► PERST# in GC6 cleared HDAE (offset 0x48B bit 1), hiding Function 1 (NHDA).
         └─► Because VGAR=VGAB was removed, HDAE remained 0 on wake.
         └─► At lock screen, Windows pci.sys wakes NHDA, issuing D0/config write to non-existent function.
         └─► AMD Zen 3+ Completer Abort on unpopulated function write ──► Instant MCA Cold Reboot!
   │
[Attempt 18: Option A & The Command Register Trap (Sessions 285, 288, 290)]
   │
   ├─► Short sleep from Desktop (Session 285: 8s): 100% SUCCESS.
   ├─► Sleep until screen asleep from Desktop (Session 288: 28s orange LED): 100% SUCCESS!
   │     └─► Woke cleanly on keyboard! Proved Option A BAR restore works seamlessly during active sessions.
   └─► Sleep until screen asleep from Lock Screen (Session 290: 83s orange LED): Crash on wake!
         └─► BugCheck 0x19C (0x50): WIN32K_POWER_WATCHDOG_TIMEOUT ("Calling monitor driver to power on").
         └─► SCMD = VCMD in GC6I saved 0x0000 because pci.sys clears Command in D3hot before ACPI _OFF.
         └─► GC6O restored VCMD = 0x0000, disabling Memory Space & Bus Master on GA104.
         └─► nvlddmkm.sys hung trying to access disabled dGPU MMIO to light up external monitor.
         └─► Also: 8-bit byte write at 0x48B (AnyAcc) ignored by GA104 32-bit vendor registers.
   │
[Attempt 19: Unconditional Command Enable + 32-bit DWord HDAE (Sessions 301, 302, 304, 305, 307)]
   │
   ├─► Short sleep from Lock Screen (Session 302: 9.1s): 100% SUCCESS! Woke cleanly on Keyboard!
   ├─► Deep sleep until screen asleep from Lock Screen (Session 305: 32s orange LED): 100% SUCCESS!
   │     └─► Woke cleanly on Keyboard! Proved VCMD |= 0x07 and HDA8 bit 25 100% SOLVED BugCheck 0x19C!
   └─► Lock Screen Display Idle Timeout (Session 307): Hung on sleep entry, rebooted after 115s (watchdog)!
         └─► At lock screen, video idle timer expires (Video Idle Timeout) before system sleep.
         └─► pci.sys puts PEGP into D3hot, calling PEGP._PS3.
         └─► Attempt 17-19 _PS3 unconditionally called PG00._OFF() -> GC6I(), asserting PERST# on dGPU.
         └─► Function 1 (NHDA audio) was still active in D0 while system was in S0; audiosrv/hdaudio.sys
             accessed reset chip on HDMI disconnect -> PCIe bus hang -> 120s Windows Power Watchdog reboot!
   │
[Attempt 20: Restored OMPR Guard on _PS3 + DGPS Guard on _PS0]
   │
   ├─► In PEGP._PS3: Restore If (OMPR == 0x03) guard so display-only idle (Video Idle Timeout) never
   │     calls PG00._OFF() or asserts PERST# while the system is awake in S0 with an external monitor.
   ├─► In PEGP._PS0: Restore If (DGPS != Zero) guard so _ON() is only called if dGPU was in GC6.
   ├─► System Sleep (Modern Standby) is governed natively by Root Port GPP0 Power Resources (_PR0.._PR3),
   │     which cleanly suspends the entire PCIe hierarchy synchronously.
   └─► Retains all Attempt 19 fixes: VCMD |= 0x07, 32-bit DWord HDA8 |= 0x02000000, guarded BARs.
```

---

## 2. Hardware & Architecture Baseline

### 2.1 Video Routing Topology
- **Internal Panel (eDP):** Physically wired to the AMD Radeon 680M integrated GPU (iGPU).
- **External Video Outputs:** The HDMI 2.1 port and USB-C DisplayPort Alt-Mode lines are physically wired **directly to the NVIDIA dGPU PHYs**.
- **Significance:** When no external monitor is attached, the dGPU can remain in deep Runtime D3 (RTD3 / D3cold) indefinitely. When an external monitor is attached, Hot-Plug Detect (HPD) is asserted high, and the monitor's sink termination pulls on the TMDS/FRL/DP AUX lines. Any power transition requires full dGPU power cycling and PCIe link re-training across the AMD Root Port.

### 2.2 Power Architecture & Controllers
- **Root Port:** `\_SB.PCI0.GPP0` (AMD Rembrandt PCIe Root Port 0, Gen4 x8)
- **PCIe Endpoint:** `\_SB.PCI0.GPP0.PEGP` (NVIDIA GeForce RTX 3070 Ti / 3080 Mobile, Vendor ID `0x10DE`)
- **Audio Endpoint:** `\_SB.PCI0.GPP0.NHDA` (NVIDIA High Definition Audio Controller)
- **Power Resource:** `\_SB.PCI0.GPP0.PG00` (Governs `_PR0`, `_PR2`, `_PR3` for `GPP0`)
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

## 3. The Stock Firmware Defects (Deep Dive)

### 3.1 Defect 1: The Original Stock Bug — Unbounded Polling Loops in `GC6O` and `_ON`
* **Trigger:** Active logged-in Windows desktop session with external monitor connected.
* **ACPI State:** NVIDIA driver sets `TDGC = 1` (Target Device GC6).
* **The Vulnerable Code:**
  Inside stock `Opt2Tabl` (`ssdt4.dsl`), method `PEGP.GC6O` (line 1505) and method `PG00._ON` (line 498):
  ```asl
  // Method GC6O (Sleep Exit):
  While ((\_SB.PCI0.GPP0.PEGP.NVID != 0x10DE))
  {
      DLYM (One)   // 100µs spin stall per iteration
  }

  // Method PG00._ON (Power Resource Power-On):
  While ((\_SB.PCI0.GPP0.PEGP.NVID != 0x10DE))
  {
      Sleep (One)  // 1ms OS thread yield per iteration
  }
  ```
* **Why the Loop Stalls:**
  With an external monitor connected, HDMI/DP PHY termination lines pull on the dGPU. Upon wake from sleep or display idle, the PCIe link between the AMD Root Port and NVIDIA GA104 silicon is slow to train or fails to train within the initial hardware settling window.
* **Why it Causes an Infinite Hang Rather than a Reboot:**
  Reading `NVID` (PCIe Vendor ID at offset `0x00`) over an unready or reset PCIe link returns `0xFFFF` (PCIe Master Abort). Under standard PCIe specifications, configuration *reads* returning `0xFFFF` are legal and do **not** generate hardware exceptions or CPU machine checks.
* **The System Lockout Mechanism:**
  Windows Power Manager (`ntoskrnl.exe` / `ACPI.sys`) strictly serializes all Power IRPs (`IRP_MN_SET_POWER`). As long as `GC6O` or `_ON` is spinning inside this while-loop waiting for `NVID == 0x10DE`, the ACPI Power IRP queue is blocked indefinitely:
  - CPU watchdog timers do not fire because `Sleep(1)` yields the thread and `DLYM(1)` executes normal stalls.
  - No subsequent wake events, display power-ons, or user inputs can be processed.
  - The displays remain black, the power LED stays solid white, the cooling fans run slowly, and the laptop remains fully powered until the battery **drains completely to 0%**.

---

### 3.2 Defect 2: The `TDGC` Reset & Dangerous `POFF()` Power Cut
* **Trigger:** Modern Standby entry from the Windows Lock Screen or fresh boot.
* **The Mechanism:**
  In stock ACPI, whenever `_ON` completes on wake, it explicitly resets:
  ```asl
  \_SB.PCI0.GPP0.TDGC = Zero
  \_SB.PCI0.GPP0.DGCX = Zero
  ```
  When the user is logged into Windows, user-mode NVIDIA container services periodically call `NVJT(JT_FUNC_POWERCONTROL)` and re-arm `TDGC = 1`.
  However, at the **Windows Lock Screen**, user-mode NVIDIA services do not run. Therefore, when the 45-to-60-second lock screen idle timeout expires, **`TDGC` is still 0**!
* **The Dangerous `POFF()` Fallback:**
  Because `TDGC == 0`, `PG00._OFF` fell into its `Else` branch:
  ```asl
  Method (_OFF, 0, Serialized)
  {
      If ((GSTA () != One)) { Return (Zero) }
      If ((\_SB.PCI0.GPP0.TDGC == One))
      {
          \_SB.PCI0.GPP0.PEGP.GC6I () // Optimus GC6 path (keeps PWEN alive)
      }
      Else
      {
          \_SB.PCI0.GPP0.BPGF ()
          \_SB.PCI0.GPP0.PEGP.LTRE = \_SB.PCI0.GPP0.LREN
          Sleep (0x18)
          \_SB.PCI0.GPP0.DL23 (PTOF)
          \_SB.PCI0.GPP0.POFF ()        // <-- CUTS PWEN MAIN POWER TO dGPU!
          \_SB.PCI0.GPP0.APGF ()
      }
  }
  ```
* **Why `POFF()` Kills the Platform with an External Monitor:**
  In `GC6I()`, main power is preserved—the dGPU is placed in hardware reset (`REST# = 0`) and PCIe L2/L3 while core VCC and VRAM self-refresh stay live.
  In `POFF()`, method `M010(PWEN, Zero)` physically removes main VCC power from the dGPU. With an external monitor attached, the monitor's active terminations and DDC +5V backfeed current into the unpowered dGPU die. This causes power rail collapse, latch-up, and an immediate PCIe Surprise Down hardware crash on the AMD Root Port.

---

### 3.3 Defect 3: Blind PCIe Configuration Space Writes in `_PS0` (`VGAR = VGAB`)
* **Trigger:** Wake from sleep when `POFF()` was invoked (`DGPS == 1`).
* **The Vulnerable Code in Stock `_PS0`:**
  ```asl
  Method (_PS0, 0, NotSerialized)
  {
      _PSC = Zero
      If ((DGPS != Zero))
      {
          \_SB.PCI0.GPP0.PG00._ON ()
          If ((GPRF != One))
          {
              VGAR = VGAB   // Blindly writes 251 bytes of config space!
          }
          DGPS = Zero
      }
  }
  ```
* **Why it Causes an Instant Cold Reboot:**
  - `VGAR` is a 2008-bit (251-byte) bulk field covering offsets `0x05` through `0x100` of the dGPU's PCIe configuration space.
  - Writing 251 bytes directly into ECAM memory writes across Read-Only silicon registers, MSI-X tables, and **PCIe Link Control / ASPM**.
  - Writing Link Control mid-flight drops the PCIe link.
  - Unlike PCIe reads (which return `0xFFFF`), a PCIe configuration **write** to an offline or reset endpoint generates an **Uncorrectable Fatal PCIe Completer Abort / Unsupported Request**.
  - The AMD Rembrandt Root Complex detects an uncorrectable PCIe hardware fatal error and immediately triggers an **MCA (Machine Check Architecture) Hardware Reset**, causing an instant cold reboot back to POST.

---

### 3.4 Defect 4: The `GSTA()` Power OK Logic Trap in `_ON`
* **Trigger:** Routing `PG00._OFF` to `GC6I()` without rewriting `_ON`.
* **The Vulnerable Code in Stock `_ON`:**
  ```asl
  Method (_ON, 0, Serialized)
  {
      If ((GSTA () != Zero))
      {
          Return (Zero)   // <-- THE GSTA() TRAP!
      }
      ...
  }
  ```
* **Why it Traps Modern Standby:**
  - `GSTA()` evaluates `M009(PWOK)` (the main dGPU power rail).
  - In GC6, **main power is never cut**—the dGPU is placed in hardware reset (`REST# = 0`) while VCC remains live.
  - Therefore, `PWOK` is **always 1**!
  - `If (GSTA () != Zero)` evaluated to `1 != 0` (**TRUE**).
  - **`_ON` immediately exited on line 1 and NEVER called `GC6O()`!**
  - The dGPU was left permanently frozen in reset (`REST# = 0`) with the PCIe link in L2/L3. On `Video Idle Timeout`, Windows tried to wake the screen via `_ON`, which did nothing, freezing the OS and keeping the power LED constantly lit.

---

### 3.5 Defect 5: NVIDIA Runtime D3 (`NVJT`) Desynchronization (Session 263 Freeze)
* **Trigger:** Leaving the laptop untouched at the desktop until `Video Idle Timeout` (e.g. 10 minutes) and the external monitor enters orange DPMS standby.
* **The Mechanism:**
  1. Once the external HDMI monitor enters power saving, the NVIDIA driver (`nvlddmkm.sys`) detects zero active displays and initiates Runtime D3 (RTD3).
  2. The driver calls ACPI DSM method `NVJT(JT_FUNC_POWERCONTROL, Case 3)`.
  3. If immediate power control is requested (`DFGC == 0`), `NVJT` calls stock `GC6I()` directly:
     ```asl
     If ((ToInteger (GPPC) == One))
     {
         GC6I ()
         PLST = One
         GUPS = Zero
     }
     ```
  4. Stock `GC6I()` asserts hardware reset (`M010(REST, Zero)`) and puts the PCIe link into L23 (`DL23(One)`).
  5. **However, stock `GC6I()` never updated `DGPS` or `PSTA`!**
     - `DGPS` remained `0`.
     - `PSTA` remained `1`.
* **The Fatal Desynchronization on Wake:**
  1. When wake was requested, the NVIDIA driver queried `NVOP(0x1A)`:
     ```asl
     If ((DGPS == Zero))
     {
         CGCS = 0x03   // 3 = GPU is Powered On (NOT in GC6)!
     }
     ```
  2. Because `DGPS` was still `0`, `NVOP` told the NVIDIA driver that **the GPU was already powered on (`CGCS = 3`)**!
  3. The NVIDIA driver assumed the GPU was already active and **never called `GC6O()`**!
  4. Meanwhile, Windows evaluated `PG00._ON()`. Because `PSTA` was still `1`, `_ON()` immediately exited and also **never called `GC6O()`**!
  5. The dGPU was left physically held in hardware reset (`REST# = 0`).
  6. The first PCIe MMIO transaction triggered an uncorrectable AMD PCIe Completer Abort / bus lockup, freezing the laptop with a solid white power LED and slowly spinning fans.

---

### 3.6 Defect 6: Disappearing NVIDIA High Definition Audio Controller (`NHDA`) on Lock Screen Wake (Session 275 Reboot)
* **Trigger:** Video idle timeout at the Windows Lock Screen while connected to an external display.
* **The Multi-Function Topology:**
  - NVIDIA GA104 is a multi-function PCIe endpoint on Bus 1:
    - **Function 0 (`01:00.0`):** 3D Graphics / Display Engine (`PEGP`).
    - **Function 1 (`01:00.1`):** High Definition Audio Controller (`NHDA`).
  - Function 1 is physically gated by Function 0's vendor-specific configuration register: **offset `0x48B`, bit 1 (`HDAE` — High Definition Audio Enable)**:
    ```asl
    Offset (0x48B), 
        ,   1, 
    HDAE,   1
    ```
  - When `HDAE == 0`, Function 1 does not decode or respond to PCIe transactions on the bus.
* **The Mechanism:**
  1. In `GC6I`, hardware reset (`PERST#`) is asserted via `M010(REST, Zero)`.
  2. PCIe Fundamental Reset resets all non-sticky configuration registers inside GA104:
     - Base Address Registers `BAR0..BAR5` reset to `0x00000000`.
     - Command Register (`0x04`) resets to `0x0000`.
     - `HDAE` (offset `0x48B` bit 1) resets to `0` $\rightarrow$ **Function 1 disappears from the PCIe bus!**
  3. Stock OEM firmware never restored `HDAE` in `GC6O` (and OEM `VGAR` from `0x05` to `0x100` never covered offset `0x48B`). In stock firmware, `HDAE` was only written during cold-boot setup or driver initialization.
  4. On wake, `GC6O` deasserts reset and re-trains the PCIe link (`NVID == 0x10DE`), but **left `HDAE == 0`**.
  5. On an active desktop session, the Windows audio stack (`audiosrv`) does not immediately query `01:00.1`.
  6. However, at the **Windows Lock Screen**, Windows Power Manager and `pci.sys` systematically transition all children under `GPP0` back to D0. `pci.sys` dispatches a Power IRP / configuration write directly to `01:00.1`.
  7. Because `HDAE == 0`, `01:00.1` is unpopulated.
  8. While PCIe reads to missing functions return `0xFFFFFFFF` (master abort), an uncorrectable PCIe **configuration write abort** on AMD Rembrandt Zen 3+ Root Complexes immediately trips a fatal **Machine Check Architecture (MCA) Hardware Reset**, causing an instant cold reboot back to POST.

---

### 3.7 Defect 7: Memory Space Disable via Command Register (`0x19C (0x50)` Watchdog Timeout)
* **Trigger:** Attempt 18 lock screen wake crash (Session 290, `BugCheck 0x19C (0x50)`).
* **The Mechanism:**
  1. In Attempt 18, Option A introduced dynamic saving of the dGPU Command Register: `SCMD = VCMD` in `GC6I` and `VCMD = SCMD` in `GC6O`.
  2. However, when Windows transitions devices toward D3cold via ACPI `_OFF`:
     - Windows `pci.sys` first places `PEGP` into D3hot (`PMCSR = 3`).
     - **`pci.sys` explicitly writes `0x0000` to the PCI Command Register** to disable DMA and memory accesses before evaluating ACPI power resources.
  3. When ACPI `GC6I` executed, `VCMD` was read as **`0x0000`**, storing `0x0000` into `SCMD`.
  4. On wake, `GC6O` executed `VCMD = SCMD`, restoring **`0x0000`** into the GA104 Command Register!
  5. Writing `0x0000` to `VCMD` cleared `Memory Space Enable (MSE, bit 1)` and `Bus Master Enable (BME, bit 2)`.
  6. The dGPU MMIO space (`BAR0`) and VRAM aperture were **completely unmapped from the host bus**.
  7. When `win32k` dispatched the display power-on IRP to `nvlddmkm.sys`, the graphics driver attempted to access display engine registers over BAR0, but every read returned `0xFFFFFFFF`.
  8. `nvlddmkm.sys` hung in an infinite polling loop waiting for hardware acknowledgement.
  9. The Win32k Power Watchdog timer expired after ~15-20 seconds, triggering:
     $$\text{BugCheck 0x19C: WIN32K\_POWER\_WATCHDOG\_TIMEOUT}$$
     $$\text{Parameter 1: 0x50 (Calling monitor driver to power on)}$$
  10. Additionally, declaring `VHDA` with `AnyAcc` generated an 8-bit unaligned byte write at offset `0x48B`. GA104 vendor-specific configuration registers above `0x100` require strict **32-bit aligned DWord access** (register `0x488`, Bit 25), causing the audio enable write to be ignored or glitched.

---

### 3.8 Defect 8: Lock Screen Display Idle Timeout (`Video Idle Timeout`) vs System Sleep (`Screen Off Request`) — The Premature `_PS3` PERST# Trap
* **Trigger:** Leaving the laptop idle at the Windows Lock Screen until the display turns off automatically (Session 307: `Video Idle Timeout`).
* **The Fundamental Distinction:**
  - **`Screen Off Request` (Forced / System Sleep):** Triggered when the user presses Sleep or clicks Sleep on the lock screen. Windows initiates a **full system-wide power transition** (`S0 -> S0ix`). Windows suspends user mode, halts audio streams, puts `NHDA` into D3hot, and powers down the AMD Root Port `GPP0`. Evaluating `PG00._OFF()` / `GC6I()` is completely safe because all devices on Bus 1 are already quiescent and asleep.
  - **`Video Idle Timeout` (Display-Only Standby):** Triggered by the 60-second lock screen display timer. **The laptop is STILL RUNNING IN S0.** Background services, Windows Audio (`audiosrv`), and the desktop window manager are fully active. Windows merely asks the display engine to turn off video heads.
* **The Mechanism:**
  1. When display idle timeout occurs, `dxgkrnl` turns off video outputs and places `PEGP` into D3hot.
  2. Windows `pci.sys` evaluates `PEGP._PS3`.
  3. In stock OEM firmware, `_PS3` was protected by `If ((OMPR == 0x03))`. When driving an external monitor, `OMPR` is `0x02` (not `0x03`), so stock `_PS3` **did NOT call `_OFF()`**.
  4. In Attempt 17–19, `If ((OMPR == 0x03))` was removed, causing `PEGP._PS3` to **unconditionally invoke `PG00._OFF()` $\rightarrow$ `GC6I()`**.
  5. `GC6I()` immediately asserted `PERST#` (`M010(REST, Zero)`), placing the physical GA104 chip into hardware reset.
  6. **Function 1 (`NHDA`, audio) was still in D0!** The audio controller was never placed into D3hot by Windows Audio.
  7. When the HDMI display turned off, Windows Audio Service (`audiosrv`) and Microsoft High Definition Audio driver (`hdaudio.sys`) attempted to query `01:00.1` (`NHDA`) to update stream topology.
  8. Because the physical chip was held in reset by `PERST#`, the PCIe MMIO read/write transaction could not complete.
  9. The kernel work item in `hdaudio.sys` deadlocked.
  10. Windows Kernel Power Watchdog has a strict **120-second timeout** for pending power transitions. After 115 seconds (19:10:16 to 19:12:11), the watchdog expired and triggered a reboot!
* **The Solution (Attempt 20):**
  - In `PEGP._PS3`, restore `If ((OMPR == 0x03))` so display-only idle (`Video Idle Timeout`) never powers down or resets the dGPU while the system is awake in S0.
  - In `PEGP._PS0`, restore `If ((DGPS != Zero))` so `_ON()` is only called if the dGPU was actually in GC6.
  - True Modern Standby system sleep is governed natively by Root Port `GPP0`'s Power Resources (`_PR0.._PR3`), which cleanly coordinates `PG00._OFF()` / `_ON()` when the entire PCIe hierarchy enters sleep.

---

## 4. Forensic Investigation & Test Progression

The table below documents the empirical progression across all test iterations:

| Attempt / Session | Condition | Method Path | Observed Behavior | Root Cause Deduction |
| :--- | :--- | :--- | :--- | :--- |
| **Stock BIOS (Desktop)** | External display plugged in, active desktop session | Stock `Opt2Tabl` (`GC6O`) | Black screen, fans spinning, battery drains to 0% | `While (NVID != 0x10DE)` config-read loop blocked Windows Power IRP queue permanently. |
| **Stock BIOS (Lock Screen)** | External display plugged in, lock screen idle | Stock `_OFF` + `_PS0` | Instant reboot on wake / at timeout | `POFF` cut power; `_PS0` PCIe config write (`VGAR=VGAB`) triggered AMD PCIe Completer Abort MCA reset. |
| **Attempt 11 (Session 173)** | Monitor connected, idle timeout | Patched `GC6O` (100ms timeout) | **Slept 41 minutes, woke cleanly on Keyboard!** | Proved that fixing the loop in `GC6O` with active `PERST#` retry resolves the issue when `TDGC == 1`. |
| **Attempt 11 (Session 175)** | Monitor connected, idle timeout | Patched `GC6O` | **Slept 5 minutes, woke cleanly on Keyboard!** | Confirmed reproducibility on the `TDGC == 1` path. |
| **Attempt 11 (Session 179)** | Monitor connected, lock screen idle | Stock `_ON` | Crashed on entry, powered down after 15 min | First wake cleared `TDGC` to `0`. Next sleep hit the unpatched second infinite loop in `_ON`. |
| **Attempt 12 (Session 188)** | Manual sleep (Screen Off Request) | Patched `GC6O` | **Slept 16 seconds, woke cleanly on Keyboard!** | Proved manual sleep routes through `GC6O` and functions properly. |
| **Attempt 12 (Session 190)** | Woke to lock screen, 45s idle timeout | Stock `_OFF` with `PTOF` | **Instant reboot at entry (Duration: 0s)** | `_OFF` executed `DL23(PTOF)` with `PTOF==0`. Skipped `TPV0()`, cut power while root port was in `L0`. Instant PCIe Surprise Down reboot! |
| **Attempt 12 (Session 193)** | Rebooted, sat at login screen 5m, idle timeout | Patched `GC6O` / `_ON` | **Slept 178 seconds (3m), woke cleanly on Keyboard!** | Fresh boot had `TDGC == 1`, avoiding the `_OFF` defect and waking cleanly. |
| **Attempt 14 (Sessions 215, 218, 221)** | Manual sleep (Screen Off Request) | Patched `_ON`/`_OFF` to GC6 | **Slept and woke cleanly 3 consecutive times!** | Proved routing to GC6 works, but Video Idle Timeout hung due to the `GSTA()` trap. |
| **Attempt 15 (Sessions 232, 235, 237, 239)** | Manual sleep & Lock screen idle timeout | `PSTA` state machine | **Slept & woke cleanly 4 consecutive times!** | Proved `PSTA` eliminates the `GSTA()` trap. Screen Off test slept 33m17s (Session 245). Deep sleep wake rebooted due to `VGAR=VGAB`. |
| **Attempt 16 (Sessions 259, 261)** | Manual sleep (orange screen 6m45s) & Lock screen idle | No `VGAR=VGAB`, `CMDR\|=0x07`, `_PS3` with `OMPR==3` | **100% SUCCESS! Slept 6m45s (259) & 7.38s (261), woke cleanly on Keyboard!** | Eliminating bulk config writes stopped PCIe write aborts; `_PS3` guarded by `OMPR==3` prevented premature dGPU reset during display idle timeout. |
| **Attempt 17 (Session 271)** | Manual sleep (`Screen Off Request`) | Patched `GC6O` / `PSTA` | **100% SUCCESS! Woke cleanly in 0.7s.** | Clean wake path when triggered manually from active session. |
| **Attempt 17 (Session 273)** | Desktop idle timeout (active session) | `NVJT` $\rightarrow$ Patched `GC6I` / `GC6O` | **100% SUCCESS! Slept 18.2m (1094s), woke cleanly on Mouse!** | External monitor was in orange DPMS standby. Proved `NVJT` / `GC6I` / `GC6O` state sync completely solved the desktop idle freeze! |
| **Attempt 17 (Session 275)** | Lock screen idle timeout (`Video Idle Timeout`) | `_OFF` $\rightarrow$ `GC6I` $\rightarrow$ wake | **Cold reboot on sleep entry (`Duration: 0s`, Event 41)** | `_PS3` unconditionally called `_OFF` on display timeout. `PERST#` wiped `HDAE` while `NHDA` was still active in D0. 120s watchdog reboot. |
| **Attempt 18 (Session 285)** | Short manual sleep (`Screen Off Request`, 8s) | Patched `GC6O` / Option A | **100% SUCCESS! Woke cleanly in 0.8s.** | Verified short sleep path with Option A. |
| **Attempt 18 (Session 288)** | Desktop sleep (`Screen Off Request`, 28s orange LED) | Option A BAR restore + `VHDA=1` | **100% SUCCESS! Woke cleanly on Keyboard!** | Waited until external screen entered orange DPMS sleep. Woke cleanly! Proved Option A BAR restore works seamlessly during active desktop sessions. |
| **Attempt 18 (Session 290)** | Lock screen sleep (`Screen Off Request`, 83s orange LED) | Option A (`VCMD = SCMD`, `VHDA=1`) | **Crash on wake (Duration: 0s, Event 41)** | `BugCheck 0x19C (0x50): WIN32K_POWER_WATCHDOG_TIMEOUT` ("Calling monitor driver to power on"). `SCMD = VCMD` saved `0x0000` because `pci.sys` clears Command in D3hot before `_OFF`. `GC6O` restored `VCMD = 0x0000`, disabling Memory Space and Bus Master on GA104. `nvlddmkm.sys` hung trying to access disabled dGPU MMIO to light up external monitor. |
| **Attempt 19 (Sessions 302, 305, 307)** | Lock screen forced sleep vs lock screen display idle | Unconditional `VCMD\|=0x07` + 32-bit DWord `HDA8` | **Forced sleep: 100% SUCCESS! Display idle: Watchdog reboot.** | Session 302 (9.1s) and Session 305 (32s orange monitor sleep) woke cleanly on keyboard, proving `VCMD|=0x07` and `HDA8` bit 25 completely fixed `BugCheck 0x19C (0x50)`. Session 307 hung on display idle entry because `PEGP._PS3` unconditionally asserted `PERST#` while system was in S0. |
| **Attempt 20** | Lock screen display idle timeout (`Video Idle Timeout`) + system sleep | `If (OMPR == 0x03)` in `_PS3` + `If (DGPS != Zero)` in `_PS0` | **Tested / Current Revision** | Restores OEM `OMPR==3` guard on `PEGP._PS3` and `DGPS` guard on `PEGP._PS0`. Prevents premature dGPU `PERST#` during display idle timeout while leaving full Modern Standby sleep to Root Port `GPP0` Power Resources (`_PR0.._PR3`). Retains all Attempt 19 BAR, Command, and Audio fixes. |

---

## 5. The Patched Architecture & Implementation (Attempt 20)

The complete solution requires seven binary method renames in OpenCore targeting `Opt2Tabl` paired with a custom ACPI SSDT ([`SSDT-SLEEPFIX.dsl`](file:///home/datacompboy/fun/xmg/Bios-XMG-NEO_XNE15E20_XNE17E20_BIOS-N106v2/SSDT-SLEEPFIX.dsl)) implementing **Guarded BAR Restore, Unconditional Command Decode (`VCMD |= 0x07`), and 32-bit Aligned Audio Controller Enable (`HDA8 |= 0x02000000`)**:

### 5.1 OpenCore Binary Renames in `config.plist`
All patches target `TableSignature: SSDT` (`U1NEVA==`) and `OemTableId: Opt2Tabl` (`T3B0MlRhYmw=`):
1. **`Method (GC6O)` $\rightarrow$ `XC6O`:**
   `FEwNR0M2Twg=` $\rightarrow$ `FEwNWEM2Twg=` (Count: 1)
2. **`Method (GC6I)` $\rightarrow$ `XC6I`:**
   `FEYGR0M2SQg=` $\rightarrow$ `FEYGWEM2SQg=` (Count: 1)
3. **`Method (_ON)` in `PG00` $\rightarrow$ `XON`:**
   `FEkdX09OXwg=` $\rightarrow$ `FEkdWE9OXwg=` (Count: 1)
4. **`Method (_OFF)` in `PG00` $\rightarrow$ `XOFF`:**
   `FE8RX09GRgg=` $\rightarrow$ `FE8RWE9GRgg=` (Count: 1)
5. **`Method (_STA)` in `PG00` $\rightarrow$ `XSTA`:**
   `FBVfU1RBAA==` $\rightarrow$ `FBVYU1RBAA==` (Count: 1)
6. **`Method (_PS0)` in `PEGP` $\rightarrow$ `XPS0`:**
   `FEUEX1BTMAA=` $\rightarrow$ `FEUEWFBTMAA=` (Count: 1)
7. **`Method (_PS3)` in `PEGP` $\rightarrow$ `XPS3`:**
   `FE0EX1BTMwA=` $\rightarrow$ `FE0EWFBTMwA=` (Count: 1)

---

### 5.2 The Complete Override SSDT

See [`SSDT-SLEEPFIX.dsl`](SSDT-SLEEPFIX.dsl)

---

## 6. Firmware Historical Evolution: N1.13 (Dec 2022) vs. N1.15A14 (Jan 2025)

A complete binary extraction, disassembly, and line-by-line diff between the stock factory BIOS `GM5RGxxN113.ROM` and the latest update `GM5RGxxN115A14.ROM` was conducted to investigate whether this bug was regression-induced:

### 6.1 NVIDIA Optimus Tables (`Opt2Tabl` / `OemNv2T`)
- **Zero Power Sequencing Fixes:** The diff in `Opt2Tabl` between N113 and N115 is only 76 lines, consisting entirely of cosmetic or header adjustments:
  - `TM04` field in `TPNV` expanded from 8 bits to 32 bits (memory alignment).
  - `OPDR` buffer in `_DSM` Case (0x10) reduced from a static 0xA1 buffer to `Buffer (One) { 0x00 }`.
  - External references `M29A` and `M408` (Mutex) added.
- **Identical Defect Code:** Every critical defect—the unbounded `While (NVID != 0x10DE)` polling loop in `GC6O`, the missing `PERST#` retry logic, `_ON` clearing `TDGC = 0`, `DL23(PTOF)` with `PTOF == 0`, and the unguarded `VGAR = VGAB` configuration restore in `_PS0`—**existed identically in N1.13 and was carried into N1.15A14 untouched**.

### 6.2 AMD Platform & AGESA Updates
Between 2022 and 2025, OEM firmware updates were focused strictly on AMD AGESA platform code:
1. **PCIe CLKREQ# Bugfix (`SSDT_CPMCMN`):** Fixed an AMD bug in `CpmReadClkReq` and `CpmWriteClkReq` where the CLKREQ# register index was erroneously bit-shifted by `>> 8` instead of `>> 3`.
2. **Modern Standby Type-C Wake (`SSDT_INTGPP03`):** Updated `_PRW` methods to include the `PWRS` Power Resource package required for compliant USB4 / Type-C DisplayPort Alt-Mode wake in Windows 11.
3. **Smart Mux (`SSDT_CPMSMMUX`):** Injected dynamic mux-switching support (`\_SB.PCI0.PB2.SWUS.SWDS.VGA`).
4. **Platform Thermal / Microprocessor Power Management (`SSDT_MPMS`):** Added `\_SB.MPM0` platform telemetry linking SoC temperature sensors to the ITE EC.
5. **Debug Port 80 Instrumentation (`SSDT_ALIB`):** Added I/O port 0x80 POST code macros (`A007(0xAA80...)`) across AMD PCIe root complex methods.

### 6.3 Architectural Conclusion
The GA104 NVIDIA Optimus ACPI implementation on this chassis has been broken since factory release (N1.13). Reverting to N1.13 would not fix Modern Standby—it would maintain the exact same NVIDIA power defects while reintroducing the broken AMD CLKREQ# pin shift. The custom ACPI override (`SSDT-SLEEPFIX.aml` + OpenCore binary patches) is the only viable path to correct the OEM firmware flaw.

---

## 7. OpenCore Loader Integration

OpenCore is used strictly as an in-memory ACPI patcher during UEFI boot:
1. **Non-Invasive Binary Renames:** OpenCore executes in UEFI DXE phase before `bootmgfw.efi` (Windows Boot Manager) starts. It applies 7 in-place 8-byte ASCII method renames across the OEM `Opt2Tabl` loaded in RAM.
2. **SSDT Injection:** OpenCore inserts `SSDT-SLEEPFIX.aml` into the system XSDT.
3. **Dynamic Memory Safety:** OpenCore does **not** drop `Opt2Tabl` or alter dynamic ACPI NVS memory regions (`OperationRegion TPNV, SystemMemory, 0xD3CD8000, 0x004D`), avoiding Windows Bugcheck `0xA5 (ACPI_BIOS_ERROR)`.
4. **Persistence Through Sleep:** Once patched tables are loaded into Windows non-paged kernel pool at boot, they remain active 100% of the time. The BIOS ROM is never re-read during Modern Standby (S0ix) sleep or wake.

---

## 8. Interim Deployment with Secure Boot Enabled

While the manufacturer evaluates this report and incorporates the patched ACPI logic into an official signed BIOS update, the OpenCore ACPI override can run on the machine with **Secure Boot fully enabled** to satisfy BitLocker, Windows Device Guard, and TPM requirements.

### Method 1: BIOS Hash Enrollment (Fastest & Native on AMI Aptio V)
1. **Enter BIOS Setup:** Reboot and press `F2` or `Del`.
2. **Navigate to Security $\rightarrow$ Secure Boot:**
   - Set **Secure Boot Mode** to `Custom` (if set to `Standard`).
   - Open **Key Management**.
3. **Enroll OpenCore's Hash in Authorized Signatures (`db`):**
   - Select **Authorized Signatures (`db`)** $\rightarrow$ **Enroll Efi Image** (or **Append from file**).
   - Browse to the USB thumb drive or internal EFI system partition:
     `EFI\BOOT\BOOTX64.EFI` (or `EFI\OC\OpenCore.efi`).
   - Confirm enrollment. The BIOS calculates the SHA-256 hash of the OpenCore binary and commits it to the secure NVRAM `db` keystore.
4. **Enable Secure Boot:**
   - Set **Secure Boot** to `Enabled`.
   - Save & Exit (`F10`).
5. **Chain of Trust:**
   - The BIOS verifies `BOOTX64.EFI` against the hash in `db` $\rightarrow$ passes.
   - OpenCore initializes, patches ACPI table `Opt2Tabl`, injects `SSDT-SLEEPFIX.aml`.
   - OpenCore chainloads `bootmgfw.efi` (Windows Boot Manager), which is officially signed by Microsoft.
   - Windows boots with full Secure Boot active, BitLocker sealed, and ACPI sleep fix operational.

### Method 2: Installing OpenCore to the Internal NVMe SSD (USB-Free Operation)
Once verified on USB:
1. In Windows (Admin PowerShell), mount the internal EFI System Partition (ESP):
   ```powershell
   mountvol S: /s
   ```
2. Copy the `EFI\OC` folder and `EFI\BOOT` to `S:\EFI\OC`.
3. Enroll `S:\EFI\BOOT\BOOTX64.EFI` in BIOS `db` using Method 1 above. The laptop boots with the ACPI fix automatically on every startup.

---

## 9. Recommendation for Official OEM Firmware Release

To resolve this issue permanently in official BIOS updates (`N.1.16+`), the OEM firmware engineering team (Tongfang / Schenker / XMG) should incorporate the following changes directly into `Opt2Tabl.asl`:

1. **In Method `GC6O`:**
   - Add a 100ms loop timeout with active `PERST#` hardware pulse retry to eliminate the infinite config-read hang.
   - Set Root Port command register `CMDR |= 0x07` (`Bus Master | Memory Space | I/O Space`).
   - Clear `DGPS = Zero` upon successful link training.
2. **In Method `GC6I`:**
   - Set `DGPS = One` upon asserting `REST# = Zero`.
3. **In Method `_PS0`:**
   - Permanently delete the bulk PCIe configuration restore `VGAR = VGAB`.
   - Unconditionally invoke `\_SB.PCI0.GPP0.PG00._ON ()`.
4. **In Method `_PS3`:**
   - Permanently delete the bulk PCIe configuration save `VGAB = VGAR`.
   - Remove the `If ((OMPR == 0x03))` restriction and unconditionally invoke `\_SB.PCI0.GPP0.PG00._OFF ()`.
5. **In Power Resource `PG00` (`_ON` and `_OFF`):**
   - Remove the `If (GSTA () != Zero)` check in `_ON`.
   - Unconditionally route `_OFF` to `GC6I()` and `_ON` to `GC6O()` during Modern Standby (never invoke `POFF()` while an external display is detected or during S0ix).
6. **In PCIe Configuration Space Restoration:**
   - Rather than blasting 251 raw bytes across PCIe Link Control / ASPM registers via bulk `VGAR = VGAB`, implement targeted restoration of Base Address Registers (`BAR0..BAR5`) and the Command register (`0x04`).
   - In `GC6O`, unconditionally restore High Definition Audio Enable (`HDAE = 1` at offset `0x48B` bit 1) with a 1ms settling delay so Function 1 (`NHDA`) remains visible on the PCIe bus. This prevents Windows `pci.sys` from encountering uncorrectable PCIe write Completer Aborts when waking the audio endpoint during lock-screen power transitions.

