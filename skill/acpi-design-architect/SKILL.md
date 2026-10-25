---
name: acpi-design-architect
description: Subagent runbook for failure mode characterization, old design invalidation, and declarative power state modeling. Translates empirical telemetry into formal Design.md specifications and the N-Scenario Operational State Matrix without touching implementation bytecode.
---

# ACPI Design Architect Subskill

## Overview

This subskill governs **Step 2 (Design Generation)** and **Step 3 (Old Design Invalidation)** in the iterative Modern Standby engineering loop.

It operates at the **systems architecture level**. The architect analyzes failure telemetry, maps symptoms to fundamental power primitives, formally invalidates incomplete prior designs, and constructs a declarative, implementation-agnostic specification ([`Design.md`](file:///home/datacompboy/fun/xmg/Bios-XMG-NEO_XNE15E20_XNE17E20_BIOS-N106v2/Design.md)) with an exhaustive operational state matrix.

> [!NOTE]
> The Design Architect produces **pure declarative specifications**. It does not write ASL bytecode or edit bootloader configuration files; implementation is strictly delegated to the [`acpi-patch-synthesizer`](file:///home/datacompboy/fun/xmg/skill/acpi-patch-synthesizer/SKILL.md).

---

## 1. Mapping Failure Telemetry to Architectural Primitives

When analyzing initial incident data or the delta from a failed test iteration, translate observed symptoms into architectural primitives:

| Observed Failure Symptom | Underlying Hardware Primitive | Architectural Root Mechanism |
|:---|:---|:---|
| **Silent Freeze / Black Screen / Fans Run** | Unbounded bus polling / Deadlocked IRP | Endpoint returns Master Abort (`0xFFFFFFFF`) across offline or reset link; ACPI interpreter spins at high IRQL. |
| **Instant Cold Reboot Back to POST** | PCIe Completer Abort / Host Bridge Bus Error | Configuration write to offline/unpowered endpoint or unaligned access to SoC Host Bridge ECAM; triggers Machine Check Architecture (MCA) hardware reset. |
| **30s Display Watchdog BugCheck (`0x19C 0x50`)** | Unmapped MMIO Aperture | Device wake failed to restore Base Address Registers (BARs) or left Memory Space Enable cleared (`MSE = 0`); driver timed out lighting monitor. |
| **40s–50s Standby Maintenance Reboot** | Dark Wake Active Power Hijack | Device power evaluation method (`_PS0`) executed active rail power-up during a display-off Modern Standby maintenance window without OSPM Power Resource (`_PR0`) reference counting. |
| **115s–120s Delayed Watchdog Reboot** | Asymmetric Power Gating | Power-gating asserted reset (`PERST#`) during active S0 runtime (Video Idle Timeout) while dependent services (e.g. audio) were active in D0. |
| **Audio Distortion / High CPU Spinlock** | Interrupt Delivery Architecture Mismatch | PCI Command register masked legacy line interrupts (Bit 10 `Interrupt Disable = 1`) on an endpoint configured in the OS for legacy pin interrupts (`MSISupported : 0`). |

---

## 2. Step 3: Old Design Static Invalidation

Whenever a patch iteration fails or an edge case is exposed, do **not** immediately modify code. Formally invalidate the previous design:

### Invalidation Template:
```markdown
### Design Invalidation: Iteration N
* **Observed Symptom:** [e.g. 46-second reboot during Modern Standby sleep]
* **Failing Scenario:** [e.g. Scenario 03: Modern Standby Dark Wake PDC Maintenance Window]
* **Mechanism of Invalidation:** 
  In Iteration N, the design coupled physical power rail sequencing to device evaluation:
  `Device._PS0 -> PowerResource._ON()`.
  When OSPM triggered a 0.15s background maintenance query with display off, `_PS0` powered
  up hardware rails behind ACPI's back. Because the display was off, OSPM never evaluated
  `_PR0`, leaving its reference count at 0. When the maintenance query ended, `_OFF()` was
  never invoked. The SoC attempted to enter hardware low-power idle (S0i3) with the root
  port held in L0, triggering an SoC hardware watchdog reset.
* **Architectural Correction:** 
  Strictly decouple `_PS0` from physical rails. Enforce `_PS0` as a passive status stub
  (`_PSC = Zero`). Physical rail transitions belong exclusively in Power Resources (`_PR0..3`).
```

---

## 3. Step 2: Formal Declarative Design & State Matrix

Author or update the formal specification document (`Design.md`).

### 3.1 Formalize the Architectural Invariants
Define the governing rules that any valid implementation must satisfy:
1. **Separation of Concerns:** Power Resources (`_PRx`) own physical rails and reference counts; Device States (`_PSx`) remain passive status reporters.
2. **Runtime vs System Sleep Invariance:** S0 Video Idle Timeout (screen off) must never assert hardware reset or cut rails to devices shared with active system services.
3. **Multi-Function Strap & Register Persistence:** If endpoint hardware clears function-enable straps across power cuts, firmware must unmask the strap and restore secondary function BARs in wake before returning control to OSPM.
4. **Interrupt Mode Alignment:** PCI Command register configuration must reflect the OS driver interrupt model (`MSISupported : 0` mandates Bit 10 = 0).

### 3.2 The N-Scenario Operational State Matrix
Enumerate all operating dimensions into an exhaustive state matrix:
* **Dimension 1 (Display):** On (Active) / Off (Video Idle)
* **Dimension 2 (Audio):** Idle / Active Audio Stream (D0)
* **Dimension 3 (Logon Context):** Desktop Session (`TDGC == 1`) / Pre-Logon Lock Screen (`TDGC == 0`)
* **Dimension 4 (Power Source):** AC Wall Adapter / Battery DC
* **Dimension 5 (Standby Latency):** Shallow Sleep (D3hot) / Deep Standby (D3cold) / Dark Wake Maintenance

For every permutation, define the declarative contract:

| Scenario ID | Trigger & Context | Required Link State | Hardware Reset (PERST#) | Power Rail (PWEN) | Required Strap State | OSPM Refcount |
|:---:|:---|:---:|:---:|:---:|:---:|:---:|
| **S01** | Forced Sleep, Desktop, AC | L23 / Offline | Asserted (0) | Off (0) | Unmasked (1) | 0 |
| **S02** | Display Idle Timeout in S0 | L0 / L1 | De-asserted (1) | On (1) | Unmasked (1) | 1 |
| **S03** | Modern Standby Dark Wake | L23 / Offline | Asserted (0) | Off (0) | Unchanged | 0 |
| **S04** | User Keypress Wake from Deep Sleep | L0 | De-asserted (1) | On (1) | Unmasked (1) | 1 |
| *...* | *(Enumerate all active scenarios)* | *...* | *...* | *...* | *...* | *...* |

---

## 4. Exit Criteria & Handoff Gate

Before passing the specification to [`acpi-patch-synthesizer`](file:///home/datacompboy/fun/xmg/skill/acpi-patch-synthesizer/SKILL.md), confirm:
* [ ] All observed failure symptoms are mapped to low-level hardware primitives.
* [ ] The previous failed iteration has a formal written invalidation proof.
* [ ] The N-Scenario Operational State Matrix accounts for S0 display idle, system S0ix, and Dark Wake maintenance windows.
* [ ] All requirements are expressed declaratively (zero ASL bytecode or patch hex strings).
