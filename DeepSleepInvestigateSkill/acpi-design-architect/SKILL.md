---
name: acpi-design-architect
description: Maps failure telemetry to hardware power primitives, formulates new test scenarios and failure hypotheses in the operational state matrix (Design.md), and hands off to static verifier for defect reproduction before code synthesis.
---

# ACPI Design Architect Subskill

## Overview

This subskill covers **Step 2 (State Matrix & Design)** in the iterative debugging loop.

It focuses on mapping observed symptoms to bus/hardware states and keeping an operational state matrix (`Design.md`) updated. Writing down the expected hardware states across scenarios ensures the team doesn't play whack-a-mole where fixing sleep breaks display idle, or vice versa.

> [!NOTE]
> This step produces **declarative requirements** (what state each rail, reset line, and device should be in). 
> * Defect reproduction is verified statically by [`acpi-static-verifier`](../acpi-static-verifier/SKILL.md) in Step 3.
> * Bytecode synthesis is handled by [`acpi-patch-synthesizer`](../acpi-patch-synthesizer/SKILL.md) in Step 4.

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

## 2. Formulating the Failure Scenario & Hypothesis for Step 3

Before modifying or synthesizing new code, formalize the failure scenario and state why the previous patch (`v(N-1)`) broke:

### Scenario & Invalidation Template (in `Design.md`):
```markdown
### Scenario Sxx: [Name, e.g. Modern Standby Display-Off Maintenance Window]
* **Trigger & Context:** Screen turns off, system in S0ix, OS background daemon queries device status.
* **Expected Invariants:** 
  - Physical power rails must remain OFF (`PWEN = 0`).
  - Device `_PS0` evaluation must remain a passive stub (`_PSC = 0`) without rail side-effects.
  - OSPM `_PR0` refcount must remain 0.
* **Failure Hypothesis for Version N-1:** 
  The patch turned on power rails inside `_PS0`. When the OS executed a display-off maintenance query,
  `_PS0` powered on the hardware, but OSPM never evaluated `_PR0`. When the window ended,
  rails were left powered while the SoC attempted idle sleep, triggering a spontaneous reboot.
* **Handoff to Verifier:** Request `acpi-static-verifier` to simulate Scenario Sxx on Version N-1 (Step 3).
```

---

## 3. Operational State Matrix (`Design.md`)

Maintain a comprehensive state matrix enumerating all operating scenarios:
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
| **S05** | Audio Playback during Display Idle | L0 / L1 | De-asserted (1) | On (1) | Set (1) | 1 |
| *...* | *(Other applicable permutations)* | *...* | *...* | *...* | *...* | *...* |

---

## 4. Handoff Checklist

Before passing requirements downstream:
* [ ] The observed failure symptom is mapped to a hardware primitive.
* [ ] A new or updated scenario test case is added to `Design.md`.
* [ ] **Gate Step 3:** Instruct [`acpi-static-verifier`](../acpi-static-verifier/SKILL.md) to statically evaluate Version N-1 against the scenario.
* [ ] **Gate Step 4:** Only after `acpi-static-verifier` confirms defect reproduction (Mode A), pass the requirements to [`acpi-patch-synthesizer`](../acpi-patch-synthesizer/SKILL.md).
