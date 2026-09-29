DefinitionBlock ("", "SSDT", 2, "XMG", "SLEEPFIX", 0x00001000)
{
    External (_SB_.PCI0.GPP0, DeviceObj)
    External (_SB_.PCI0.GPP0.APGN, MethodObj)
    External (_SB_.PCI0.GPP0.BPGN, MethodObj)
    External (_SB_.PCI0.GPP0.CEDR, FieldUnitObj)
    External (_SB_.PCI0.GPP0.CMDR, FieldUnitObj)
    External (_SB_.PCI0.GPP0.D0ST, FieldUnitObj)
    External (_SB_.PCI0.GPP0.DGCX, IntObj)
    External (_SB_.PCI0.GPP0.DL23, MethodObj)
    External (_SB_.PCI0.GPP0.GSTA, MethodObj)
    External (_SB_.PCI0.GPP0.L23D, MethodObj)
    External (_SB_.PCI0.GPP0.LREN, FieldUnitObj)
    External (_SB_.PCI0.GPP0.PEGP, DeviceObj)
    External (_SB_.PCI0.GPP0.PEGP._PSC, IntObj)
    External (_SB_.PCI0.GPP0.PEGP.DGPS, IntObj)
    External (_SB_.PCI0.GPP0.PEGP.DLYM, MethodObj)
    External (_SB_.PCI0.GPP0.PEGP.LTRE, IntObj)
    External (_SB_.PCI0.GPP0.PEGP.NVID, FieldUnitObj)
    External (_SB_.PCI0.GPP0.PEGP.SSSV, FieldUnitObj)
    External (_SB_.PCI0.GPP0.PG00, PowerResObj)
    External (_SB_.PCI0.GPP0.PON_, MethodObj)
    External (_SB_.PCI0.GPP0.TDGC, IntObj)
    External (_SB_.PCI0.SBRG.EC0_.DBD1, FieldUnitObj)
    External (_SB_.PCI0.SBRG.EC0_.DBD2, FieldUnitObj)
    External (EBAS, FieldUnitObj)
    External (HYSS, FieldUnitObj)
    External (M010, MethodObj)
    External (M453, FieldUnitObj)
    External (PTOF, FieldUnitObj)
    External (REST, IntObj)

    Scope (\_SB.PCI0.GPP0.PEGP)
    {
        OperationRegion (XPC1, SystemMemory, EBAS, 0x0500)
        Field (XPC1, WordAcc, NoLock, Preserve)
        {
            Offset (0x04), 
            VCMD,   16
        }

        Field (XPC1, DWordAcc, NoLock, Preserve)
        {
            Offset (0x10), 
            VBA0,   32, 
            VBA1,   32, 
            VBA2,   32, 
            VBA3,   32, 
            VBA4,   32, 
            VBA5,   32, 
            Offset (0x488), 
            HDA8,   32
        }

        Name (SBA0, Zero)
        Name (SBA1, Zero)
        Name (SBA2, Zero)
        Name (SBA3, Zero)
        Name (SBA4, Zero)
        Name (SBA5, Zero)
        Name (VVAL, Zero)

        //
        // Patched GC6I: Power-Down / Sleep Entry to GC6
        // Saves BARs while dGPU is fully alive, parks link, and asserts PERST#.
        // Idempotent: safe if called by both NVJT and PG00._OFF.
        //
        Method (GC6I, 0, Serialized)
        {
            Debug = "<<< GC6I (Patched v28) >>>"
            If ((DGPS == One))
            {
                Return (Zero)
            }

            If (CondRefOf (\_SB.PCI0.SBRG.EC0.DBD1))
            {
                \_SB.PCI0.SBRG.EC0.DBD1 = 0x61 // 'a'
                \_SB.PCI0.SBRG.EC0.DBD2 = One
            }

            // Save BAR registers while device is in D0/D3hot
            If ((\_SB.PCI0.GPP0.PEGP.NVID == 0x10DE))
            {
                If (((VBA0 != Zero) && (VBA0 != 0xFFFFFFFF)))
                {
                    SBA0 = VBA0
                    SBA1 = VBA1
                    SBA2 = VBA2
                    SBA3 = VBA3
                    SBA4 = VBA4
                    SBA5 = VBA5
                    VVAL = One
                }
            }

            \_SB.PCI0.GPP0.PEGP.LTRE = \_SB.PCI0.GPP0.LREN
            \_SB.PCI0.GPP0.DL23 (One)
            DLYM (0x0A)
            M010 (REST, Zero)
            DGPS = One

            If (CondRefOf (\_SB.PCI0.SBRG.EC0.DBD1))
            {
                \_SB.PCI0.SBRG.EC0.DBD1 = 0x61
                \_SB.PCI0.SBRG.EC0.DBD2 = 0x02
            }

            Return (Zero)
        }

        //
        // Patched GC6O: Power-Up / Wake Exit from GC6
        // Deasserts PERST#, settles GA104 power, unparks L23 link, enables bridge decoding,
        // polls NVID with bounded timeout (NO INFINITE LOOP!), restores BARs, enables VCMD,
        // and restores Function 1 High Definition Audio.
        // Idempotent: safe if called by both PG00._ON and NVJT.
        //
        Method (GC6O, 0, Serialized)
        {
            Debug = "<<< GC6O (Patched v28) >>>"
            If (((DGPS == Zero) && (\_SB.PCI0.GPP0.PEGP.NVID == 0x10DE)))
            {
                Return (Zero)
            }

            If (CondRefOf (\_SB.PCI0.SBRG.EC0.DBD1))
            {
                \_SB.PCI0.SBRG.EC0.DBD1 = 0x6F // 'o'
                \_SB.PCI0.SBRG.EC0.DBD2 = One
            }

            // Step 1: Deassert PERST#
            M010 (REST, One)

            // Step 2: Settling delay (20ms) for GA104 power rails & clocks
            DLYM (0x14)

            If (CondRefOf (\_SB.PCI0.SBRG.EC0.DBD1))
            {
                \_SB.PCI0.SBRG.EC0.DBD1 = 0x6F
                \_SB.PCI0.SBRG.EC0.DBD2 = 0x02
            }

            // Step 3: Unpark PCIe link from L23
            \_SB.PCI0.GPP0.L23D (One)

            // Step 4: Enable full bridge decode (Bus Master, Memory Space, I/O Space)
            \_SB.PCI0.GPP0.CMDR |= 0x07
            \_SB.PCI0.GPP0.D0ST = Zero

            If (CondRefOf (\_SB.PCI0.SBRG.EC0.DBD1))
            {
                \_SB.PCI0.SBRG.EC0.DBD1 = 0x6F
                \_SB.PCI0.SBRG.EC0.DBD2 = 0x03
            }

            // Step 5: Bounded polling for NVID == 0x10DE (max 50ms = 500 * 100us)
            Local0 = 0x01F4
            While (((\_SB.PCI0.GPP0.PEGP.NVID != 0x10DE) && (Local0 > Zero)))
            {
                DLYM (One)
                Local0--
            }

            If ((\_SB.PCI0.GPP0.PEGP.NVID == 0x10DE))
            {
                \_SB.PCI0.GPP0.LREN = \_SB.PCI0.GPP0.PEGP.LTRE
                \_SB.PCI0.GPP0.CEDR = One

                // Restore saved BARs
                If ((VVAL == One))
                {
                    VBA0 = SBA0
                    VBA1 = SBA1
                    VBA2 = SBA2
                    VBA3 = SBA3
                    VBA4 = SBA4
                    VBA5 = SBA5
                }

                // Restore Command register: Bus Master, Memory Space, I/O Space
                VCMD |= 0x07

                // Re-enable Function 1 (NVIDIA High Definition Audio Controller)
                HDA8 |= 0x02000000

                DLYM (One)

                If (CondRefOf (\_SB.PCI0.SBRG.EC0.DBD1))
                {
                    \_SB.PCI0.SBRG.EC0.DBD1 = 0x6F
                    \_SB.PCI0.SBRG.EC0.DBD2 = 0x05
                }
            }
            Else
            {
                // Bounded loop expired without NVID == 0x10DE.
                // Do not lock up ACPI. Mark state in EC debug register.
                If (CondRefOf (\_SB.PCI0.SBRG.EC0.DBD1))
                {
                    \_SB.PCI0.SBRG.EC0.DBD1 = 0x6F
                    \_SB.PCI0.SBRG.EC0.DBD2 = 0xEE
                }
            }

            DGPS = Zero
            Return (Zero)
        }

        //
        // Patched _PS0:
        // Sets _PSC = 0 and calls PG00._ON() if dGPU was asleep (DGPS != 0).
        // CRITICAL FIX: Permanently removes the OEM 'VGAR = VGAB' bulk write which
        // blasted 250 bytes of uninitialized zeroes across GA104 config space,
        // destroying BARs, VCMD, and HDAE and causing BugCheck 0x19C (0x50)!
        //
        Method (_PS0, 0, NotSerialized)
        {
            Debug = "<<< _PS0 (Patched v28) >>>"
            _PSC = Zero
            If ((DGPS != Zero))
            {
                \_SB.PCI0.GPP0.PG00._ON ()
                DGPS = Zero
            }
        }
    }

    Scope (\_SB.PCI0.GPP0.PG00)
    {
        //
        // Patched PG00._ON:
        // Handles both GC6 wake (TDGC == 1 or DGPS == 1) and cold PON wake (GSTA == 0).
        // Fixes OEM defect where GSTA != 0 aborted _ON and blocked GC6O from ever executing.
        //
        Method (_ON, 0, Serialized)
        {
            Local4 = M453
            M453 = Zero

            // Path A: Wake from GC6 (Desktop deep sleep)
            If ((\_SB.PCI0.GPP0.TDGC == One) || (\_SB.PCI0.GPP0.PEGP.DGPS == One) || (\_SB.PCI0.GPP0.PEGP.NVID != 0x10DE))
            {
                If (CondRefOf (\_SB.PCI0.SBRG.EC0.DBD1))
                {
                    \_SB.PCI0.SBRG.EC0.DBD1 = One
                    \_SB.PCI0.SBRG.EC0.DBD2 = One
                }

                \_SB.PCI0.GPP0.PEGP.GC6O ()
                \_SB.PCI0.GPP0.TDGC = Zero
                \_SB.PCI0.GPP0.DGCX = Zero
            }
            // Path B: Cold power-on from POFF (Lock screen deep sleep - proven working in Session 146 & 149)
            ElseIf ((\_SB.PCI0.GPP0.GSTA () == Zero))
            {
                If (CondRefOf (\_SB.PCI0.SBRG.EC0.DBD1))
                {
                    \_SB.PCI0.SBRG.EC0.DBD1 = One
                    \_SB.PCI0.SBRG.EC0.DBD2 = 0x02
                }

                \_SB.PCI0.GPP0.BPGN ()
                \_SB.PCI0.GPP0.PON ()
                Sleep (0x012C)
                \_SB.PCI0.GPP0.L23D (PTOF)
                \_SB.PCI0.GPP0.CMDR |= 0x07
                \_SB.PCI0.GPP0.D0ST = Zero
                Local0 = 0x64
                While (((\_SB.PCI0.GPP0.PEGP.NVID != 0x10DE) && (Local0 > Zero)))
                {
                    Sleep (One)
                    Local0--
                }

                If ((\_SB.PCI0.GPP0.PEGP.NVID == 0x10DE))
                {
                    \_SB.PCI0.GPP0.LREN = \_SB.PCI0.GPP0.PEGP.LTRE
                    \_SB.PCI0.GPP0.CEDR = One
                    \_SB.PCI0.GPP0.PEGP.SSSV = HYSS
                    \_SB.PCI0.GPP0.APGN ()
                }
            }
            // Path C: Already awake and fully responsive
            Else
            {
                If (CondRefOf (\_SB.PCI0.SBRG.EC0.DBD1))
                {
                    \_SB.PCI0.SBRG.EC0.DBD1 = One
                    \_SB.PCI0.SBRG.EC0.DBD2 = Zero
                }
            }

            M453 = Local4
            Return (Zero)
        }
    }
}
