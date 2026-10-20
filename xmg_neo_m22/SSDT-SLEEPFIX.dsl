DefinitionBlock ("", "SSDT", 2, "XMG", "SLEEPFIX", 0x00001000)
{
    External (_SB_.PCI0.GPP0, DeviceObj)
    External (_SB_.PCI0.GPP0.APGF, MethodObj)    // 0 Arguments
    External (_SB_.PCI0.GPP0.APGN, MethodObj)    // 0 Arguments
    External (_SB_.PCI0.GPP0.BPGF, MethodObj)    // 0 Arguments
    External (_SB_.PCI0.GPP0.BPGN, MethodObj)    // 0 Arguments
    External (_SB_.PCI0.GPP0.CEDR, FieldUnitObj)
    External (_SB_.PCI0.GPP0.CMDR, FieldUnitObj)
    External (_SB_.PCI0.GPP0.D0ST, FieldUnitObj)
    External (_SB_.PCI0.GPP0.DGCX, IntObj)
    External (_SB_.PCI0.GPP0.DL23, MethodObj)    // 1 Arguments
    External (_SB_.PCI0.GPP0.GSTA, MethodObj)    // 0 Arguments
    External (_SB_.PCI0.GPP0.L23D, MethodObj)    // 1 Arguments
    External (_SB_.PCI0.GPP0.LREN, FieldUnitObj)
    External (_SB_.PCI0.GPP0.NHDA, DeviceObj)
    External (_SB_.PCI0.GPP0.PEGP, DeviceObj)
    External (_SB_.PCI0.GPP0.PEGP._PSC, IntObj)
    External (_SB_.PCI0.GPP0.PEGP.DGPS, IntObj)
    External (_SB_.PCI0.GPP0.PEGP.DLYM, MethodObj)    // 1 Arguments
    External (_SB_.PCI0.GPP0.PEGP.LTRE, IntObj)
    External (_SB_.PCI0.GPP0.PEGP.NVID, FieldUnitObj)
    External (_SB_.PCI0.GPP0.PEGP.SSSV, FieldUnitObj)
    External (_SB_.PCI0.GPP0.PG00, PowerResObj)
    External (_SB_.PCI0.GPP0.POFF, MethodObj)    // 0 Arguments
    External (_SB_.PCI0.GPP0.PON_, MethodObj)    // 0 Arguments
    External (_SB_.PCI0.GPP0.TDGC, IntObj)
    External (_SB_.PCI0.GPP0.TGPC, BuffObj)
    External (EBAS, FieldUnitObj)
    External (HYSS, FieldUnitObj)
    External (M010, MethodObj)    // 2 Arguments
    External (M453, FieldUnitObj)
    External (PTOF, FieldUnitObj)
    External (REST, IntObj)

    //
    // 1. Declarative D3cold topology for Function 1 (Audio)
    // Tells Windows pci.sys to natively save/restore Function 1 BAR0 & IRQ across D3cold.
    //
    Scope (\_SB.PCI0.GPP0.NHDA)
    {
        Name (_PR0, Package (0x01) { \_SB.PCI0.GPP0.PG00 })
        Name (_PR2, Package (0x01) { \_SB.PCI0.GPP0.PG00 })
        Name (_PR3, Package (0x01) { \_SB.PCI0.GPP0.PG00 })
        Method (_S0W, 0, NotSerialized) { Return (0x04) }
    }

    //
    // 2. Declarative D3cold topology & BAR Save/Restore for Function 0 (Graphics)
    // Anchors Power Resource PG00 reference count to Function 0 while in D0.
    // Prevents PG00._OFF() from running during S0 Video Idle Timeout while PEGP is in D0!
    //
    Scope (\_SB.PCI0.GPP0.PEGP)
    {
        Name (_PR0, Package (0x01) { \_SB.PCI0.GPP0.PG00 })
        Name (_PR2, Package (0x01) { \_SB.PCI0.GPP0.PG00 })
        Name (_PR3, Package (0x01) { \_SB.PCI0.GPP0.PG00 })
        Method (_S0W, 0, NotSerialized) { Return (0x04) }

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
        // GC6 Entry: Captures BAR0..5 before hardware PERST# is asserted
        //
        Method (GC6I, 0, Serialized)
        {
            Debug = "<<< GC6I (Patched v46) >>>"
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
            Return (Zero)
        }

        //
        // GC6 Exit: Restores PERST#, link, BAR0..5, Command (MSE/BME), Subsystem ID & HDA strap
        //
        Method (GC6O, 0, Serialized)
        {
            Debug = "<<< GC6O (Patched v46) >>>"
            M010 (REST, One)
            DLYM (0x14)
            \_SB.PCI0.GPP0.L23D (One)
            \_SB.PCI0.GPP0.CMDR |= 0x07
            \_SB.PCI0.GPP0.D0ST = Zero

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

                // Restore BAR0..5 expected by Resman
                If ((VVAL == One))
                {
                    VBA0 = SBA0
                    VBA1 = SBA1
                    VBA2 = SBA2
                    VBA3 = SBA3
                    VBA4 = SBA4
                    VBA5 = SBA5
                    VVAL = Zero
                }

                // Enable Bus Master & Memory Space Decode
                VCMD |= 0x07

                // Restore Subsystem ID & Audio Function 1 Silicon Strap
                \_SB.PCI0.GPP0.PEGP.SSSV = HYSS
                HDA8 |= 0x02000000
                DLYM (0x05)
            }

            DGPS = Zero
            \_SB.PCI0.GPP0.TDGC = Zero
            \_SB.PCI0.GPP0.DGCX = Zero
            Return (Zero)
        }

        // Clean _PS0: Dispatches to PG00._ON() if DGPS is set; zero blind config space writes!
        Method (_PS0, 0, NotSerialized)
        {
            Debug = "<<< _PS0 (Patched v46) >>>"
            _PSC = Zero
            If ((DGPS != Zero))
            {
                \_SB.PCI0.GPP0.PG00._ON ()
                DGPS = Zero
            }

            If ((\_SB.PCI0.GPP0.PEGP.NVID == 0x10DE))
            {
                HDA8 |= 0x02000000
            }
        }
    }

    //
    // 3. Symmetrical Power Resource PG00
    //
    Scope (\_SB.PCI0.GPP0.PG00)
    {
        Method (_OFF, 0, Serialized)
        {
            Debug = "<<< PG00._OFF (Patched v46) >>>"
            If ((\_SB.PCI0.GPP0.GSTA () != One))
            {
                Return (Zero)
            }

            Local4 = M453
            M453 = Zero

            //
            // Multi-cycle Modern Standby S0ix fix:
            // ALWAYS enter warm GC6 via PEGP.GC6I().
            // NEVER call POFF()! POFF() cuts 12V power rails (M010(PWEN, 0)),
            // which violently drops the PCIe link and destroys the active display
            // engine driving the external monitor, freezing the Zen root complex at 0s.
            // In GC6, 12V power remains live, PERST# is asserted after link parking,
            // BAR0..5 are saved, and the system sleeps and wakes cleanly across infinite cycles.
            //
            \_SB.PCI0.GPP0.PEGP.GC6I ()

            M453 = Local4
            Return (Zero)
        }

        Method (_ON, 0, Serialized)
        {
            Debug = "<<< PG00._ON (Patched v46) >>>"
            Local4 = M453
            M453 = Zero

            // Path A: Wake from POFF() (GSTA == 0, cold power cut)
            If ((\_SB.PCI0.GPP0.GSTA () == Zero))
            {
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
                    \_SB.PCI0.GPP0.PEGP.HDA8 |= 0x02000000
                    \_SB.PCI0.GPP0.PEGP.DLYM (0x05)
                    \_SB.PCI0.GPP0.APGN ()
                }

                \_SB.PCI0.GPP0.PEGP.DGPS = Zero
                \_SB.PCI0.GPP0.TDGC = Zero
                \_SB.PCI0.GPP0.DGCX = Zero
            }
            // Path B: Wake from GC6 (GSTA == 1, 12V alive, PERST# toggled)
            ElseIf ((\_SB.PCI0.GPP0.PEGP.DGPS != Zero))
            {
                \_SB.PCI0.GPP0.PEGP.GC6O ()
            }

            M453 = Local4
            Return (Zero)
        }
    }
}
