---
name: acpi-design-architect
description: Maps failure telemetry to hardware power primitives, documents why previous patch attempts failed, and maintains the operational state matrix (Design.md) before code synthesis.
---

# ACPI Design Architect Subskill

## Overview

This subskill covers **Step 2 (State Matrix & Design)** and **Step 3 (Invalidate Prior Attempt)** in the iterative debugging loop.

It focuses on mapping observed symptoms to bus/hardware states and keeping an operational state matrix (`Design.md`) updated. Writing down the expected hardware states across scenarios ensures the team doesn't play whack-a-mole where fixing sleep breaks display idle, or vice versa.

> [!NOTE]
> This step produces **declarative requirements** (what state each rail, reset line, and device should be in). Writing the actual ASL code is handled by [`acpi-patch-synthesizer`](../acpi-patch-synthesizer/SKILL.md).

---

## 1. Mapping Failure Telemetry to Hardware Primitives

When analyzing initial crash logs or a failed test run, map the observed symptom to the underlying hardware cause:

| Observed Symptom | Hardware Primitive | Root Mechanism |
|:---|:---|:---|
| **Silent Freeze / Black Screen / Fans Run** | Unbounded bus polling / Blocked IRP | Reading an unpowered or training link returns Master Abort (`0xFFFFFFFF`); ACPI while-loop spins forever at high IRQL. |
| **Instant Cold Reboot Back to POST** | PCIe Completer Abort / Bus Error | Writing to an unpowered/reset endpoint or issuing unaligned writes to Host Bridge ECAM; triggers Machine Check Architecture (MCA) hardware reset. |
| **30s Display Watchdog BugCheck (`0x19C 0x50`)** | Unmapped MMIO Aperture | Device wake did not restore Base Address Registers (BARs) or left Memory Space Enable cleared (`MSE = 0`); display driver times out lighting the panel. |
| **40s–50s Standby Maintenance Reboot** | Dark Wake Rail Hijack | Device `_PS0` powered on physical rails during a display-off Modern Standby maintenance window without OSPM Power Resource (`_PR0`) reference counting. |
| **115s–120s Delayed Watchdog Reboot** | Asymmetric Power Gating | Power-gating cut power or asserted reset (`PERST#`) during active S0 runtime (display idle) while background services (e.g. audio) were active in D0. |
| **Audio Stutter / High CPU Spin** | Interrupt Configuration Mismatch | PCI Command register disabled interrupts (Bit 10 = 1) on an endpoint configured in the OS for legacy line interrupts (`MSISupported : 0`). |

---

## 2. Invalidate Prior Attempt (Why Did the Last Patch Fail?)

Before jumping into code edits, write down exactly why the previous patch broke:

### Invalidation Template:
```markdown
### Invalidation: Iteration N
* **Symptom:** [e.g. Spontaneous reboot ~45s after sleep]
* **Failing Scenario:** [e.g. Modern Standby background maintenance window with screen off]
* **Why It Failed:** 
  The patch turned on power rails inside `_PS0`. When the OS fired a quick background
  maintenance check with the screen off, `_PS0` powered on the hardware, but the OS
  never evaluated `_PR0` (since the display remained off). When the maintenance window
  ended, `_OFF` was never called, leaving the link awake while the SoC tried to enter
  low-power idle.
* **Correction Needed:** 
  Keep `_PS0` as a passive stub (`_PSC = Zero`). Power rail sequencing must stay strictly
  in Power Resources (`_PR0..3`).
```

---

## 3. Operational State Matrix (`Design.md`)

Maintain a state matrix enumerating the operating scenarios:
* **Display:** On (Active) / Off (Video Idle)
* **Audio:** Idle / Active Stream (D0)
* **Logon State:** Desktop Session / Lock Screen
* **Power Source:** AC Adapter / Battery DC
* **Standby Depth:** Shallow Sleep (D3hot) / Deep Standby (D3cold) / Background Maintenance (Dark Wake)

For each scenario, specify expected hardware states:

| Scenario ID | Trigger & Context | Link State | Hardware Reset (PERST#) | Power Rail (PWEN) | Required Strap State | OSPM Refcount |
|:---:|:---|:---:|:---:|:---:|:---:|:---:|
| **S01** | Forced Sleep, Desktop, AC | L23 / Offline | Asserted (0) | Off (0) | Set (1) | 0 |
| **S02** | Display Idle in S0 | L0 / L1 | De-asserted (1) | On (1) | Set (1) | 1 |
| **S03** | Modern Standby Maintenance Window | L23 / Offline | Asserted (0) | Off (0) | Unchanged | 0 |
| **S04** | User Keypress Wake from Deep Sleep | L0 | De-asserted (1) | On (1) | Set (1) | 1 |
| *...* | *(Other applicable permutations)* | *...* | *...* | *...* | *...* | *...* |

---

## 4. Handoff Checklist

Before passing requirements to [`acpi-patch-synthesizer`](../acpi-patch-synthesizer/SKILL.md), confirm:
* [ ] The observed failure symptom is identified.
* [ ] The previous failed attempt has a clear explanation of why it broke.
* [ ] The state matrix covers display idle, full system sleep, and display-off maintenance wakes.
* [ ] Requirements state what the hardware should do, without getting bogged down in ASL syntax.
