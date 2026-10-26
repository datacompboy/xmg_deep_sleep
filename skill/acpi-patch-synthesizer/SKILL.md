---
name: acpi-patch-synthesizer
description: Translates declarative Design.md requirements into minimal ASL patches and OpenCore bootloader configuration entries.
---

# ACPI Patch Synthesizer Subskill

## Overview

This subskill covers **Step 4 (Synthesize Minimal Patch)** in the iterative debugging loop.

It translates the hardware requirements from `Design.md` into surgical ASL/AML patches and bootloader in-memory method renames (`config.plist`).

---

## 1. Low-Level Firmware Rules

When writing replacement ASL methods, adhere to these common firmware constraints:

### Rule 1: Strict Separation of Concerns (`_PRx` vs `_PSx`)
* **Power Resources (`_PR0..3`):** Manage physical hardware power switches, clock gates, reset lines, and OSPM reference counting.
* **Device States (`_PS0..3`):** Must remain **passive status stubs**:
  ```asl
  Method (_PS0, 0, NotSerialized)
  {
      _PSC = Zero
      // Keep passive: do not toggle reset lines or call rail power-on routines here.
  }
  ```

### Rule 2: Bounded Polling with Active Hardware Retry
Never poll vendor IDs, link status, or hardware power-good flags in an unbounded while-loop. Always include a decrementing timeout counter and an active recovery pulse:
```asl
Local0 = 500 // 50ms timeout (500 * 100µs)
While ((VEND_ID != EXPECTED_ID) && (Local0 > Zero))
{
    DLYM (One)
    Local0--
}
If (Local0 == Zero)
{
    // Active hardware recovery pulse if link fails to train
    ASSERT_RESET ()
    DLYM (0x0A)
    RELEASE_RESET ()
    DLYM (0x14)
}
```

### Rule 3: Bus Settling Latency ($T_\text{PVPERL}$)
Under the PCI Express Base Specification, insert a settling delay of $\ge 10\text{ms}$ after releasing Fundamental Reset before initiating link training or wake operations:
```asl
RELEASE_RESET ()
DLYM (0x14)       // 20ms settling delay (T_PVPERL)
DIRECT_LINK_WAKE ()
```

### Rule 4: Surgical Register Restoration vs. Bulk Block Copies
* **Do NOT perform bulk block copies** across configuration space (e.g. dumping a raw 256-byte buffer back into config space). Bulk writes corrupt read-only capability pointers, link control registers, and write uninitialized zeroes over Base Address Registers (BARs).
* **Save and restore only specific, verified registers**:
  * Base Address Registers (`BAR0..BAR5`)
  * PCI Command Register (`CMDR |= 0x07` for BME/MSE/IO)
  * Secondary Function Enable Straps

### Rule 5: Multi-Function Peripheral Strap & BAR Restores
On multi-function endpoints where Function 0 (e.g. GPU) and Function 1 (e.g. Audio) share the same physical link and power rails:
1. Pre-capture Function 1 BARs while the device is in D0.
2. If hardware clears the secondary function enable strap across D3cold, explicitly set the strap bit during link wake in ACPI.
3. Restore Function 1 BARs surgically before returning control to OSPM.

### Rule 6: SoC ECAM 32-Bit DWORD Alignment
On many modern SoC Host Bridges, configuration space accesses must be **32-bit DWORD aligned** (offsets divisible by 4, access size = 32 bits). Avoid issuing 8-bit byte-writes or 16-bit unaligned writes to Host Bridge registers.

### Rule 7: Legacy Interrupt Line Routing
If target telemetry or OS registry confirms the endpoint uses legacy line interrupts (`MSISupported : 0`), ensure PCI Command register Bit 10 (`Interrupt Disable`) remains cleared:
```asl
ACMD = 0x0006 // Bit 10 = 0 (INTx unmasked), MSE = 1, BME = 1
```

---

## 2. Bootloader In-Memory Patch Setup (OpenCore)

To test patches without flashing the motherboard SPI flash:

### 2.1 In-Memory Method Renames (`ACPI -> Patch`)
* Use 4-byte ASCII method renames (e.g. `_ON` $\rightarrow$ `XON_`, `GC6O` $\rightarrow$ `XC6O`, `GC6I` $\rightarrow$ `XC6I`, `_PS0` $\rightarrow$ `XPS0`).
* Ensure replacement methods provide drop-in compatibility with the original OEM signature.

### 2.2 Bootloader Configuration (`config.plist`)
* `PlatformInfo -> Automatic = false` (Preserves genuine SMBIOS, Windows activation, BitLocker PCRs).
* `ACPI -> Delete` = Empty (Never drop OEM tables containing dynamic ACPI NVS memory).
* `Misc -> Debug -> Target = 0` (Disable disk debug logging).
* Place an `EFI/OC/.contentVisibility` file containing `Disabled` on the USB EFI partition to suppress the bootloader from displaying itself in its boot picker.

---

## 3. Bytecode Compilation & Handoff

1. Compile the synthesized ASL source into binary AML:
   ```bash
   iasl -tc SSDT-SLEEPFIX.dsl
   ```
2. Verify exit code is `0`.
3. Hand off the compiled `SSDT-SLEEPFIX.aml` and updated `config.plist` to [`acpi-static-verifier`](../acpi-static-verifier/SKILL.md) for pre-boot static checks.
