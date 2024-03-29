// Copyright (c) 2021 Marno van der Maas

//This file has a wrapper for CoreW as it is found in Toooba: https://github.com/CTSRD-CHERI/Toooba

package Praesidio_CoreWW;

import Vector               :: *;
import ClientServer         :: *;
import PLIC                 :: *;
import Fabric_Defs          :: *; // for Wd_Id, Wd_Addr, Wd_Data...
import SoC_Map              :: *; // SoC_Map_IFC
import AXI4                 :: *; // AXI4_Manager, AXI4_Subordinate...
import Routable             :: *;
import Connectable          :: *;
import Praesidio_MemoryShim :: *; // mkPraesidio_MemoryShim
import CoreW_IFC            :: *;
import CoreW                :: *; // mkCoreW
import Boot_ROM             :: *; // Boot_ROM_IFC, mkBoot_ROM

`ifdef INCLUDE_GDB_CONTROL
import Debug_Module         :: *;
`endif

`ifdef PERFORMANCE_MONITORING
import Monitored            :: *;
`endif

// ================================================================
// Main interface

interface Praesidio_CoreWW #(numeric type t_n_interrupt_sources);

   // ----------------------------------------------------------------
   // Debugging: set core's verbosity

   method Action  set_verbosity (Bit #(4)  verbosity, Bit #(64)  logdelay);

   // ----------------------------------------------------------------
   // Start

   method Action start (Bool is_running, Bit #(64) tohost_addr, Bit #(64) fromhost_addr);

   // ----------------------------------------------------------------
   // AXI4 Fabric interfaces

   interface AXI4_Manager #(TAdd#(Wd_MId,2), Wd_Addr, Wd_Data,
                              0, 0, 0, 0, 0) insecure_mem_manager;

   interface AXI4_Manager #(TAdd#(Wd_MId,2), Wd_Addr, Wd_Data,
                              0, 0, 0, 0, 0) secure_mem_manager;

   // ----------------------------------------------------------------
   // External interrupt sources

   interface Vector #(t_n_interrupt_sources, PLIC_Source_IFC)  core_external_interrupt_sources;

   // ----------------------------------------------------------------
   // Non-maskable interrupt request

   (* always_ready, always_enabled *)
   method Action nmi_req (Bool set_not_clear);

`ifdef RVFI_DII
    interface Toooba_RVFI_DII_Server rvfi_dii_server;
`endif

`ifdef INCLUDE_GDB_CONTROL
   // ----------------------------------------------------------------
   // Optional Debug Module interfaces

   // ----------------
   // DMI (Debug Module Interface) facing remote debugger

   interface DMI dmi;

   // ----------------
   // Facing Platform
   // Non-Debug-Module Reset (reset all except DM)

   interface Client #(Bool, Bool) ndm_reset_client;
`endif

`ifdef INCLUDE_TANDEM_VERIF
   // ----------------------------------------------------------------
   // Optional Tandem Verifier interface output tuples (n,vb),
   // where 'vb' is a vector of bytes
   // with relevant bytes in locations [0]..[n-1]

   interface Get #(Info_CPU_to_Verifier)  tv_verifier_info_get;
`endif

endinterface

(* synthesize *)
module mkPraesidioCoreWW_synth #(Reset dm_power_on_reset)
               (Praesidio_CoreWW #(N_External_Interrupt_Sources));
  SoC_Map_IFC soc_map <- mkSoC_Map;
  let tmp <- mkPraesidioCoreWW(dm_power_on_reset, soc_map);
  return tmp;
endmodule

module mkPraesidioCoreWW #(Reset dm_power_on_reset, SoC_Map_IFC soc_map)
               (Praesidio_CoreWW #(N_External_Interrupt_Sources));
  // ================================================================
  // Instantiate fast cores
  CoreW_IFC #(N_External_Interrupt_Sources)  corew <- mkCoreW (dm_power_on_reset,
  False);
  let corew_cached_manager   = corew.cpu_imem_master;
  let corew_uncached_manager = corew.cpu_dmem_master;

  // ================================================================
  // Instantiate secure cores
  CoreW_IFC #(N_External_Interrupt_Sources)  secure_corew <- mkCoreW (dm_power_on_reset, True);
  let secure_cached_manager   = secure_corew.cpu_imem_master;
  let secure_uncached_manager = secure_corew.cpu_dmem_master;

  Boot_ROM_IFC  boot_rom <- mkBoot_ROM(True);
  // AXI4 Deburster in front of Boot_ROM
  AXI4_ManagerSubordinate_Shim#(TAdd#(Wd_MId,2), Wd_Addr, Wd_Data, 0, 0, 0, 0, 0)
    boot_rom_axi4_deburster <- mkBurstToNoBurst_ManagerSubordinate;
  AXI4_Manager#(Wd_SId, Wd_Addr, Wd_Data_Periph, 0, 0, 0, 0, 0) extended_manager = extendIDFields(boot_rom_axi4_deburster.manager, 0);
  let boot_rom_subordinate = boot_rom.slave;
  mkConnection(extended_manager, boot_rom_subordinate);
  Reg#(Bool) initializing <- mkReg(True);

  // ================================================================
  // Instantiate Praesidio_MemoryShim module
  //TODO what about reset?
  Praesidio_MemoryShim#(TAdd#(Wd_MId,2), TAdd#(Wd_MId,2), Wd_Addr, Wd_Data, 0, 0, 0, 0, 0) praesidio_shim <- mkPraesidio_MemoryShim(
                    rangeBase(soc_map.m_mem0_controller_addr_range),
                    rangeTop(soc_map.m_mem0_controller_addr_range),
                    rangeBase(soc_map.m_praesidio_conf_addr_range));
`ifdef PERFORMANCE_MONITORING
  let monitored_manager <- monitorAXI4_Manager(praesidio_shim.manager);
  let unwrapped_manager = monitored_manager.ifc;
  rule report_axi_events;
    corew.events_axi(monitored_manager.events);
  endrule
`else
  let unwrapped_manager = praesidio_shim.manager;
`endif

  Praesidio_MemoryShim#(TAdd#(Wd_MId,2), TAdd#(Wd_MId,2), Wd_Addr, Wd_Data, 0, 0, 0, 0, 0) enclave_shim <- mkPraesidio_MemoryShim(
                    rangeBase(soc_map.m_mem0_controller_addr_range),
                    rangeTop(soc_map.m_mem0_controller_addr_range),
                    rangeBase(soc_map.m_praesidio_conf_addr_range));
  
  // ================================================================
  // AXI bus to funnel both cached and uncached accesses from fast cores through Praesidio memory shim

  // Managers on the local 2x1 fabric
  Vector#(2, AXI4_Manager #(TAdd#(Wd_MId,1), Wd_Addr, Wd_Data, 0, 0, 0, 0, 0)) insecure_manager_vector = newVector;
  insecure_manager_vector[0] = corew_cached_manager;
  insecure_manager_vector[1] = corew_uncached_manager;

  // Subordinates on the local 2x1 fabric
  Vector#(1, AXI4_Subordinate #(TAdd#(Wd_MId,2), Wd_Addr, Wd_Data, 0, 0, 0, 0, 0)) insecure_subordinate_vector = newVector;
  insecure_subordinate_vector[0] = praesidio_shim.subordinate;

  Vector#(1, Bool) mergeRoute = replicate(True);
  mkAXI4Bus(constFn(mergeRoute), insecure_manager_vector, insecure_subordinate_vector);

  // ================================================================
  // AXI bus to merge both cached and uncached accesses from secure cores to one manager and filter out config requests for memory shim
  //AXI4_ManagerSubordinate_Shim #(TAdd#(Wd_MId,2), Wd_Addr, Wd_Data,
  //   0, 0, 0, 0, 0) secure_axi_shim <- mkAXI4ManagerSubordinateShimBypassFIFOF;

  // Managers on the local 2x1 fabric
  Vector#(2, AXI4_Manager #(TAdd#(Wd_MId,1), Wd_Addr, Wd_Data, 0, 0, 0, 0, 0)) secure_manager_vector = newVector;
  secure_manager_vector[0] = secure_cached_manager;
  secure_manager_vector[1] = secure_uncached_manager;

  // Subordinates on the local 2x1 fabric
  Vector#(3, AXI4_Subordinate #(TAdd#(Wd_MId,2), Wd_Addr, Wd_Data, 0, 0, 0, 0, 0)) secure_subordinate_vector = newVector;
  secure_subordinate_vector[0] = boot_rom_axi4_deburster.subordinate;
  secure_subordinate_vector[1] = praesidio_shim.configSubordinate;
  secure_subordinate_vector[2] = enclave_shim.subordinate;

  function myRoute (addr);
    let route = replicate (False);
    if (inRange (soc_map.m_boot_rom_addr_range, addr)) route[0] = True;
    else if (inRange (soc_map.m_praesidio_conf_addr_range, addr)) route[1] = True;
    else route[2] = True;
    return route;
  endfunction

  mkAXI4Bus(myRoute, secure_manager_vector, secure_subordinate_vector);

  rule rl_initialize_boot_rom(initializing);
    boot_rom.set_addr_map(rangeBase(soc_map.m_boot_rom_addr_range),
                          rangeTop(soc_map.m_boot_rom_addr_range));
    initializing <= False;
  endrule

  // ----------------
  // Connect interrupt sources for secure cores

  (* fire_when_enabled, no_implicit_conditions *)
  rule rl_connect_external_interrupt_requests;
    // Tie off remaining interrupt request lines (1..N)
    for (Integer j = 0; j < valueOf (N_External_Interrupt_Sources); j = j + 1)
      secure_corew.core_external_interrupt_sources [j].m_interrupt_req (False);

    // Non-maskable interrupt request. [Tie-off; TODO: connect to genuine sources]
    secure_corew.nmi_req (False);
  endrule

  // ================================================================
  // Below this is just mapping methods and interfaces to corew except for cpu_mem_manager
  method Action set_verbosity (Bit #(4) verbosity, Bit #(64) logdelay);
    corew.set_verbosity(verbosity, logdelay);
    secure_corew.set_verbosity(verbosity, logdelay);
  endmethod

  method Action start (Bool is_running, Bit #(64) tohost_addr, Bit #(64) fromhost_addr);
    corew.start(is_running, tohost_addr, fromhost_addr);
    secure_corew.start(is_running, 0, 0);
  endmethod

  interface insecure_mem_manager = unwrapped_manager;

  interface secure_mem_manager = enclave_shim.manager;

  interface core_external_interrupt_sources = corew.core_external_interrupt_sources;
  
  method nmi_req = corew.nmi_req;

`ifdef RVFI_DII
   interface Toooba_RVFI_DII_Server rvfi_dii_server = proc.rvfi_dii_server;
`endif

`ifdef INCLUDE_GDB_CONTROL
   interface DMI dmi = corew.dmi;

   interface Client ndm_reset_client = corew.ndm_reset_client;
`endif

`ifdef INCLUDE_TANDEM_VERIF
   interface Get tv_verifier_info_get = corew.tv_verifier_info_get;
`endif

endmodule: mkPraesidioCoreWW

endpackage
