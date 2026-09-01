package chipyard

import org.chipsalliance.cde.config.{Config}
import freechips.rocketchip.prci.{AsynchronousCrossing}
import freechips.rocketchip.subsystem.{InCluster}

// --------------
// Rocket Configs
// --------------

class RocketConfig extends Config(
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++         // single rocket-core
  new chipyard.config.AbstractConfig)

class DualRocketConfig extends Config(
  new freechips.rocketchip.rocket.WithNHugeCores(2) ++
  new chipyard.config.AbstractConfig)

class TinyRocketConfig extends Config(
  new chipyard.harness.WithDontTouchChipTopPorts(false) ++        // TODO FIX: Don't dontTouch the ports
  new testchipip.soc.WithNoScratchpads ++                         // All memory is the Rocket TCMs
  new freechips.rocketchip.subsystem.WithIncoherentBusTopology ++ // use incoherent bus topology
  new freechips.rocketchip.subsystem.WithNBanks(0) ++             // remove L2$
  new freechips.rocketchip.subsystem.WithNoMemPort ++             // remove backing memory
  new freechips.rocketchip.rocket.With1TinyCore ++                // single tiny rocket-core
  new chipyard.config.AbstractConfig)

class QuadRocketConfig extends Config(
  new freechips.rocketchip.rocket.WithNHugeCores(4) ++    // quad-core (4 RocketTiles)
  new chipyard.config.AbstractConfig)

class Cloned64RocketConfig extends Config(
  new freechips.rocketchip.rocket.WithCloneRocketTiles(63, 0) ++ // copy tile0 63 more times
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++            // tile0 is a BigRocket
  new chipyard.config.AbstractConfig)

class RV32RocketConfig extends Config(
  new freechips.rocketchip.rocket.WithRV32 ++            // set RocketTiles to be 32-bit
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig)

// DOC include start: l1scratchpadrocket
class ScratchpadOnlyRocketConfig extends Config(
  new chipyard.config.WithL2TLBs(0) ++
  new testchipip.soc.WithNoScratchpads ++                      // remove subsystem scratchpads, confusingly named, does not remove the L1D$ scratchpads
  new freechips.rocketchip.subsystem.WithNBanks(0) ++
  new freechips.rocketchip.subsystem.WithNoMemPort ++          // remove offchip mem port
  new freechips.rocketchip.rocket.WithScratchpadsOnly ++       // use rocket l1 DCache scratchpad as base phys mem
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig)
// DOC include end: l1scratchpadrocket

class MMIOScratchpadOnlyRocketConfig extends Config(
  new freechips.rocketchip.subsystem.WithDefaultMMIOPort ++  // add default external master port
  new freechips.rocketchip.subsystem.WithDefaultSlavePort ++ // add default external slave port
  new chipyard.config.WithL2TLBs(0) ++
  new testchipip.soc.WithNoScratchpads ++                      // remove subsystem scratchpads, confusingly named, does not remove the L1D$ scratchpads
  new freechips.rocketchip.subsystem.WithNBanks(0) ++
  new freechips.rocketchip.subsystem.WithNoMemPort ++          // remove offchip mem port
  new freechips.rocketchip.rocket.WithScratchpadsOnly ++       // use rocket l1 DCache scratchpad as base phys mem
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig)

class L1ScratchpadRocketConfig extends Config(
  new chipyard.config.WithRocketICacheScratchpad ++         // use rocket ICache scratchpad
  new chipyard.config.WithRocketDCacheScratchpad ++         // use rocket DCache scratchpad
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig)

class MulticlockRocketConfig extends Config(
  new freechips.rocketchip.rocket.WithAsynchronousCDCs(8, 3) ++ // Add async crossings between RocketTile and uncore
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  // Frequency specifications
  new chipyard.config.WithTileFrequency(1000.0) ++        // Matches the maximum frequency of U540
  new chipyard.clocking.WithClockGroupsCombinedByName(("uncore"   , Seq("sbus", "cbus", "implicit", "clock_tap"), Nil),
                                                      ("periphery", Seq("pbus", "fbus"), Nil)) ++
  new chipyard.config.WithSystemBusFrequency(500.0) ++    // Matches the maximum frequency of U540
  new chipyard.config.WithMemoryBusFrequency(500.0) ++    // Matches the maximum frequency of U540
  new chipyard.config.WithPeripheryBusFrequency(500.0) ++ // Matches the maximum frequency of U540
  //  Crossing specifications
  new chipyard.config.WithFbusToSbusCrossingType(AsynchronousCrossing()) ++ // Add Async crossing between FBUS and SBUS
  new chipyard.config.WithCbusToPbusCrossingType(AsynchronousCrossing()) ++ // Add Async crossing between PBUS and CBUS
  new chipyard.config.WithSbusToMbusCrossingType(AsynchronousCrossing()) ++ // Add Async crossings between backside of L2 and MBUS
  new chipyard.config.AbstractConfig)

class CustomIOChipTopRocketConfig extends Config(
  new chipyard.example.WithBrokenOutUARTIO ++
  new chipyard.example.WithCustomChipTop ++
  new chipyard.example.WithCustomIOCells ++
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++         // single rocket-core
  new chipyard.config.AbstractConfig)

class PrefetchingRocketConfig extends Config(
  new barf.WithHellaCachePrefetcher(Seq(0), barf.SingleStridedPrefetcherParams()) ++   // strided prefetcher, sits in front of the L1D$, monitors core requests to prefetching into the L1D$
  new barf.WithTLICachePrefetcher(barf.MultiNextLinePrefetcherParams()) ++             // next-line prefetcher, sits between L1I$ and L2, monitors L1I$ misses to prefetch into L2
  new barf.WithTLDCachePrefetcher(barf.SingleAMPMPrefetcherParams()) ++                // AMPM prefetcher, sits between L1D$ and L2, monitors L1D$ misses to prefetch into L2
  new chipyard.config.WithTilePrefetchers ++                                           // add TL prefetchers between tiles and the sbus
  new freechips.rocketchip.rocket.WithL1DCacheNonblocking(2) ++                        // non-blocking L1D$, L1 prefetching only works with non-blocking L1D$
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++                                  // single rocket-core
  new chipyard.config.AbstractConfig)

class ClusteredRocketConfig extends Config(
  new freechips.rocketchip.rocket.WithNHugeCores(4, location=InCluster(1)) ++
  new freechips.rocketchip.rocket.WithNHugeCores(4, location=InCluster(0)) ++
  new freechips.rocketchip.subsystem.WithCluster(1) ++
  new freechips.rocketchip.subsystem.WithCluster(0) ++
  new chipyard.config.AbstractConfig)

class FastRTLSimRocketConfig extends Config(
  new freechips.rocketchip.subsystem.WithoutTLMonitors ++
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig)

class SV48RocketConfig extends Config(
  new freechips.rocketchip.rocket.WithSV48 ++
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig)

class QuadBigRocket8KL1_128KL2Config extends Config(
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 16, capacityKB = 128) ++ // 128KB 16-way L2
  new freechips.rocketchip.rocket.WithL1DCacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1D
  new freechips.rocketchip.rocket.WithL1ICacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1I
  new freechips.rocketchip.rocket.WithNBigCores(4) ++                                    // 4 Big Rocket cores
  new chipyard.config.AbstractConfig)

class QuadBigRocket8KL1_64K8WL2Config extends Config(
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 8, capacityKB = 64) ++ // 64KB 8-way L2
  new freechips.rocketchip.rocket.WithL1DCacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1D
  new freechips.rocketchip.rocket.WithL1ICacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1I
  new freechips.rocketchip.rocket.WithNBigCores(4) ++                                    // 4 Big Rocket cores
  new chipyard.config.AbstractConfig)

class QuadBigRocket8KL1_256K16WL2Config extends Config(
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 16, capacityKB = 256) ++ // 256KB 16-way L2
  new freechips.rocketchip.rocket.WithL1DCacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1D
  new freechips.rocketchip.rocket.WithL1ICacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1I
  new freechips.rocketchip.rocket.WithNBigCores(4) ++                                    // 4 Big Rocket cores
  new chipyard.config.AbstractConfig)

class SingleRocket8KL1_256KL2Config extends Config(
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 8, capacityKB = 128) ++ // 128KB 8-way L2
  new freechips.rocketchip.rocket.WithL1DCacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1D
  new freechips.rocketchip.rocket.WithL1ICacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1I
  new freechips.rocketchip.rocket.WithNBigCores(1) ++                                    // 1 Big Rocket core
  new chipyard.config.AbstractConfig)

class SingleRocket8KL1_64K8WL2Config extends Config(
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 8, capacityKB = 64) ++ // 64KB 8-way L2
  new freechips.rocketchip.rocket.WithL1DCacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1D
  new freechips.rocketchip.rocket.WithL1ICacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1I
  new freechips.rocketchip.rocket.WithNBigCores(1) ++                                    // 1 Big Rocket core
  new chipyard.config.AbstractConfig)

class SingleRocket8KL1_256K16WL2Config extends Config(
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 16, capacityKB = 256) ++ // 256KB 16-way L2
  new freechips.rocketchip.rocket.WithL1DCacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1D
  new freechips.rocketchip.rocket.WithL1ICacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1I
  new freechips.rocketchip.rocket.WithNBigCores(1) ++                                    // 1 Big Rocket core
  new chipyard.config.AbstractConfig)

class QuadBigRocket8KL1_256KL2Config extends Config(
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 16, capacityKB = 256) ++ // 256KB 16-way L2
  new freechips.rocketchip.rocket.WithL1DCacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1D
  new freechips.rocketchip.rocket.WithL1ICacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1I
  new freechips.rocketchip.rocket.WithNBigCores(4) ++                                    // 4 Big Rocket cores
  new chipyard.config.AbstractConfig)

class SingleRocketVCU118L18K256K16WL2ConfigSBCPhase2 extends Config(
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 16, capacityKB = 256, sbcAutoMigrate = true) ++ // SBC auto-migration enabled, 256KB 16-way L2 ++
  new freechips.rocketchip.rocket.WithL1DCacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1D
  new freechips.rocketchip.rocket.WithL1ICacheSets(32) ++                                // 32 sets * 4 ways * 64B = 8KB L1I
  new freechips.rocketchip.rocket.WithNBigCores(1) ++                                    // 1 Big Rocket core
  new chipyard.config.AbstractConfig)

class VerilatorRocket8KL116KL2Config extends Config(
  new freechips.rocketchip.rocket.WithL1ICacheSets(2) ++  // ICache with 2KB capacity (4 sets × 8 ways × 64B)
  new freechips.rocketchip.rocket.WithL1ICacheWays(2) ++
  new freechips.rocketchip.rocket.WithL1DCacheSets(2) ++  // DCache with 2KB capacity (4 sets × 8 ways × 64B)
  new freechips.rocketchip.rocket.WithL1DCacheWays(2) ++
  new freechips.rocketchip.rocket.WithNBigCores(1) ++
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 8, capacityKB = 4, subBankingFactor = 2, sbcAutoMigrate = true) ++ // 16KB 8-way L2                                 // 4 Big Rocket cores
  new chipyard.config.AbstractConfig)

// SBC OFF control: identical geometry to VerilatorRocket8KL116KL2Config but set-balancing disabled.
// Used to prove whether a data-correctness failure is caused by migration at all.
class VerilatorRocket8KL116KL2NoSbcConfig extends Config(
  new freechips.rocketchip.rocket.WithL1ICacheSets(2) ++
  new freechips.rocketchip.rocket.WithL1ICacheWays(2) ++
  new freechips.rocketchip.rocket.WithL1DCacheSets(2) ++
  new freechips.rocketchip.rocket.WithL1DCacheWays(2) ++
  new freechips.rocketchip.rocket.WithNBigCores(1) ++
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 8, capacityKB = 4, subBankingFactor = 2, enableSetBalancing = false) ++
  new chipyard.config.AbstractConfig)

// SBC shadow-hunt config (003 Amendment 11): the standard VerilatorRocket8KL116KL2Config plus the
// sim-only shadow models (sbcShadow) and counter printfs (sbcDebug). NO sbcForceDstSet — migrations
// land where a real workload sends them, the realistic case. sbcShadow/sbcDebug are sim-only.
// Amendment 11 follow-up: the auto-derived threshold is T_hi=2*nWays-1=15
// (=satMax), so a benign matmul almost never migrates; migrationThreshold=4/clear=2 makes a set migrate
// after only a few net misses so a real self-checking workload actually exercises the serve-in-place
// datapath while the BankedStore/homeShadow address models are armed. tmp.c is unchanged, so its
// checksum oracle (vs NoSbcConfig) still validates the migrated data.
class VerilatorRocket8KL116KL2SbcShadowConfig extends Config(
  new freechips.rocketchip.rocket.WithL1ICacheSets(2) ++
  new freechips.rocketchip.rocket.WithL1ICacheWays(2) ++
  new freechips.rocketchip.rocket.WithL1DCacheSets(2) ++
  new freechips.rocketchip.rocket.WithL1DCacheWays(2) ++
  new freechips.rocketchip.rocket.WithNBigCores(1) ++
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 8, capacityKB = 4, subBankingFactor = 2, sbcAutoMigrate = true, sbcShadow = true, sbcDebug = true, migrationThreshold = 4, migrationClearThreshold = 2) ++
  new chipyard.config.AbstractConfig)

// SBC serve-in-place test config (003 §10.3): stock SBC geometry, pairing PINNED to 5<->6 via
// sbcForceDstSet=6 so sw/serve_in_place_test.c can address the partner row directly. Partner 6 (not 7)
// keeps HOT_SET 5 and PARTNER 6 in DIFFERENT L1 D$ sets (D$ set = L2 set & 1). sbcShadow on for the
// BankedStore/homeShadow models. Under sbcForceDstSet, forcedLegal (SetBalanceUnit) keeps 1:1 pinning.
class VerilatorRocket8KL116KL2SipTestConfig extends Config(
  new freechips.rocketchip.rocket.WithL1ICacheSets(2) ++
  new freechips.rocketchip.rocket.WithL1ICacheWays(2) ++
  new freechips.rocketchip.rocket.WithL1DCacheSets(2) ++
  new freechips.rocketchip.rocket.WithL1DCacheWays(2) ++
  new freechips.rocketchip.rocket.WithNBigCores(1) ++
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 8, capacityKB = 4, subBankingFactor = 2, sbcAutoMigrate = true, sbcShadow = true, sbcDebug = true, sbcForceDstSet = 6) ++
  new chipyard.config.AbstractConfig)

// SBC serve-in-place DUAL-core test config (003 §10.6 S3/S4): two big cores so a SECOND probe-capable
// client can hold a parked line while the first writes/reads it — the only way secProbe (the 9a
// probe-back path) can fire. Same L2 geometry and 5<->6 pinning. Run serve_in_place_dual.riscv.
class VerilatorRocket8KL116KL2SipTestDualConfig extends Config(
  new freechips.rocketchip.rocket.WithL1ICacheSets(2) ++
  new freechips.rocketchip.rocket.WithL1ICacheWays(2) ++
  new freechips.rocketchip.rocket.WithL1DCacheSets(2) ++
  new freechips.rocketchip.rocket.WithL1DCacheWays(2) ++
  new freechips.rocketchip.rocket.WithNBigCores(2) ++
  new freechips.rocketchip.subsystem.WithInclusiveCache(nWays = 8, capacityKB = 4, subBankingFactor = 2, sbcAutoMigrate = true, sbcShadow = true, sbcDebug = true, sbcForceDstSet = 6) ++
  new chipyard.config.AbstractConfig)
