package chipyard.fpga.vcu118

import sys.process._

import org.chipsalliance.cde.config.{Config, Parameters}
import freechips.rocketchip.subsystem.{SystemBusKey, PeripheryBusKey, ControlBusKey, ExtMem}
import freechips.rocketchip.devices.debug.{DebugModuleKey, ExportDebug, JTAG}
import freechips.rocketchip.devices.tilelink.{DevNullParams, BootROMLocated}
import freechips.rocketchip.diplomacy.{RegionType, AddressSet}
import freechips.rocketchip.resources.{DTSModel, DTSTimebase}

import sifive.blocks.devices.spi.{PeripherySPIKey, SPIParams}
import sifive.blocks.devices.uart.{PeripheryUARTKey, UARTParams}

import sifive.fpgashells.shell.{DesignKey}
import sifive.fpgashells.shell.xilinx.{VCU118ShellPMOD, VCU118DDRSize}

import testchipip.serdes.{SerialTLKey}

import chipyard._
import chipyard.harness._

object VCU118ConfigConsts {
  val sdboot_dir = "./fpga/src/main/resources/vcu118/sdboot_slow"
}

class WithDefaultPeripherals extends Config((site, here, up) => {
  case PeripheryUARTKey => List(UARTParams(address = BigInt(0x64000000L)))
  case PeripherySPIKey => List(SPIParams(rAddress = BigInt(0x64001000L)))
  case VCU118ShellPMOD => "SDIO"
})

class WithSystemModifications extends Config((site, here, up) => {
  case DTSTimebase => BigInt((1e6).toLong)
  case BootROMLocated(x) => up(BootROMLocated(x), site).map { p =>
    // invoke makefile for sdboot
    val freqMHz = (site(SystemBusKey).dtsFrequency.get / (1000 * 1000)).toLong
    val make = s"make -C ${VCU118ConfigConsts.sdboot_dir} PBUS_CLK=${freqMHz} bin"
    require (make.! == 0, "Failed to build bootrom")
    p.copy(hang = 0x10000, contentFileName = s"${VCU118ConfigConsts.sdboot_dir}/build/sdboot.bin")
  }
  case ExtMem => up(ExtMem, site).map(x => x.copy(master = x.master.copy(size = site(VCU118DDRSize)))) // set extmem to DDR size
  case SerialTLKey => Nil // remove serialized tl port
})

// DOC include start: AbstractVCU118 and Rocket
class WithVCU118Tweaks extends Config(
  // clocking
  new chipyard.harness.WithAllClocksFromHarnessClockInstantiator ++
  new chipyard.clocking.WithPassthroughClockGenerator ++
  new chipyard.config.WithUniformBusFrequencies(100) ++
  new WithFPGAFrequency(100) ++ // default 100MHz freq
  // harness binders
  new WithUART ++
  new WithSPISDCard ++
  new WithDDRMem ++
  new WithJTAG ++
  // other configuration
  new WithDefaultPeripherals ++
  new chipyard.config.WithTLBackingMemory ++ // use TL backing memory
  new WithSystemModifications ++ // setup busses, use sdboot bootrom, setup ext. mem. size
  new freechips.rocketchip.subsystem.WithoutTLMonitors ++
  new freechips.rocketchip.subsystem.WithNMemoryChannels(1)
)

class RocketVCU118Config extends Config(
  new WithVCU118Tweaks ++
  new chipyard.RocketConfig
)

class QuadRocketVCU118ConfigSatCounter extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.QuadBigRocket8KL1_64K8WL2Config // 4-core Rocket with 8KB L1 and 64KB L2
)

class QuadRocketVCU118ConfigTLSignalBasedSatCounterMorrisCounterBugfixed extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.QuadBigRocket8KL1_64K8WL2Config // 4-core Rocket with 8KB L1 and 128KB L2
)

class QuadRocketVCU118ConfigTLSignalBasedSatCounterMorrisCounterBugfixedProbeIncludedCounter extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.QuadBigRocket8KL1_64K8WL2Config // 4-core Rocket with 8KB L1 and 128KB L2
)

class QuadRocketVCU118ConfigSatTLCounter256l16W extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.QuadBigRocket8KL1_256K16WL2Config // 4-core Rocket with 8KB L1 and 256KB L2
)

class SingleRocketVCU118L18K64K8WL2ConfigTLCounter extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocket8KL1_64K8WL2Config // 1-core Rocket with 8KB L1 and 64KB L2
)


class SingleRocketVCU118L18K256K16WL2ConfigTLCounter extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocket8KL1_256K16WL2Config // 1-core Rocket with 8KB L1 and 256KB L2
)

class FPGASingleRocketVCU118L18K256K16WL2ConfigSBCPhase2Finish extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L18K256K16WL2ConfigSBCPhase2 // 1-core Rocket with 8KB L1 and 256KB L2
)

// Synthesis-clean SBC pair for the FPGA measurement (shadow + debug off). Build both: the SBC-off
// twin is the only way to say whether SBC helped, since enableSetBalancing is compile-time.
class FPGASingleRocketVCU118L18K256K16WL2ConfigSBC extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L18K256K16WL2ConfigSBC
)

class FPGASingleRocketVCU118L18K256K16WL2ConfigNoSbc extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L18K256K16WL2ConfigNoSbc
)

class FPGASingleRocketVCU118L18K64K16WL2ConfigSBC extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L18K64K16WL2ConfigSBC
)

// Task 008: 64KB SBC + PLRU (L2_Replacement at 0x490, reset = random).
class FPGASingleRocketVCU118L18K64K16WL2ConfigSBCPLRU extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L18K64K16WL2ConfigSBCPLRU
)

// 64 KB but 8-way -> 128 sets. More sets, lower associativity: closer to the paper's geometry.
class FPGASingleRocketVCU118L18K64K8WL2ConfigSBCPLRU extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L18K64K8WL2ConfigSBCPLRU
)

class FPGADualRocketVCU118L18K64K16WL2ConfigSBCPLRU extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.DualRocketVCU118L18K64K16WL2ConfigSBCPLRU
)

// Dual-core 64 KB 8-way (128 sets) SBC+PLRU.
class FPGADualRocketVCU118L18K64K8WL2ConfigSBCPLRU extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.DualRocketVCU118L18K64K8WL2ConfigSBCPLRU
)

// 1024 KB (1 MB) 8-way (2048 sets) SBC+PLRU
class FPGASingleRocketVCU118L18K1024K8WL2ConfigSBCPLRU extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L18K1024K8WL2ConfigSBCPLRU
)

class FPGASingleRocketVCU118L18K1M8WL2ConfigSBCPLRU extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L18K1M8WL2ConfigSBCPLRU
)

// 013: single core, 1 MB 8-way L2, 32 kB 8-way L1 (the paper's L1).
class FPGASingleRocketVCU118L132K1024K8WL2ConfigSBCPLRU extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L132K1024K8WL2ConfigSBCPLRU
)

// Dual-core 1024 KB (1 MB) 8-way (2048 sets) SBC+PLRU
class FPGADualRocketVCU118L18K1024K8WL2ConfigSBCPLRU extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.DualRocketVCU118L18K1024K8WL2ConfigSBCPLRU
)

class FPGADualRocketVCU118L18K1M8WL2ConfigSBCPLRU extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.DualRocketVCU118L18K1M8WL2ConfigSBCPLRU
)

class FPGASingleRocketVCU118L18K64K16WL2ConfigNoSbc extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L18K64K16WL2ConfigNoSbc
)

class FPGASingleRocketVCU118L18K128K16WL2ConfigSBC extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L18K128K16WL2ConfigSBC
)

class FPGASingleRocketVCU118L18K128K16WL2ConfigNoSbc extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L18K128K16WL2ConfigNoSbc
)

// Paper-geometry L1 pair (2026-09-12) — see RocketConfigs.scala for the rationale. 32KB/8-way L1s,
// same 256KB/16-way L2 as the 8KB-L1 pair above.
class FPGASingleRocketVCU118L132K256K16WL2ConfigSBC extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L132K256K16WL2ConfigSBC
)

class FPGASingleRocketVCU118L132K256K16WL2ConfigNoSbc extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L132K256K16WL2ConfigNoSbc
)

// Same geometry/params as ...ConfigSBC, built from the RTL that now carries the SBC_StatsReset MMIO
// register (0x3B8, counter-only reset). Distinct name so its bitstream dir is clearly the one with it.
class FPGASingleRocketVCU118L18K256K16WL2ConfigSBCResetEnabled extends Config(
  new WithFPGAFreq50MHz ++
  new WithVCU118Tweaks ++
  new chipyard.SingleRocketVCU118L18K256K16WL2ConfigSBC
)

class QuadRocketVCU118ConfigSatTLCounter256KL2Config extends Config(
  new WithFPGAFreq25MHz  ++
  new WithVCU118Tweaks ++
  new chipyard.QuadBigRocket8KL1_256KL2Config // 4-core Rocket with 8KB L1 and 256KB L2
)

// DOC include end: AbstractVCU118 and Rocket

class BoomVCU118Config extends Config(
  new WithFPGAFrequency(50) ++
  new WithVCU118Tweaks ++
  new chipyard.MegaBoomV3Config
)

class WithFPGAFrequency(fMHz: Double) extends Config(
  new chipyard.harness.WithHarnessBinderClockFreqMHz(fMHz) ++
  new chipyard.config.WithSystemBusFrequency(fMHz) ++
  new chipyard.config.WithPeripheryBusFrequency(fMHz) ++
  new chipyard.config.WithControlBusFrequency(fMHz) ++
  new chipyard.config.WithFrontBusFrequency(fMHz) ++
  new chipyard.config.WithMemoryBusFrequency(fMHz)
)

class WithFPGAFreq25MHz extends WithFPGAFrequency(25)
class WithFPGAFreq50MHz extends WithFPGAFrequency(50)
class WithFPGAFreq75MHz extends WithFPGAFrequency(75)
class WithFPGAFreq100MHz extends WithFPGAFrequency(100)
