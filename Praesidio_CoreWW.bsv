// Copyright (c) 2021 Marno van der Maas

//This file has a wrapper for CoreW as it is found in Toooba: https://github.com/CTSRD-CHERI/Toooba

package Praesidio_CoreWW;

import Vector               :: *;
import PLIC                 :: *;
import Fabric_Defs          :: *; // for Wd_Id, Wd_Addr, Wd_Data...
import SoC_Map              :: *;
import AXI4                 :: *;
import Routable             :: *;
import Connectable          :: *;
import Praesidio_MemoryShim :: *;
import CoreW_IFC            :: *;
import CoreW                :: *;

`ifdef PERFORMANCE_MONITORING
import Monitored :: *;
`endif

// ================================================================
// Main interface

interface Praesidio_CoreWW #(numeric type t_n_interrupt_sources, numeric type t_n_subordinates);

   // ----------------------------------------------------------------
   // Debugging: set core's verbosity

   method Action  set_verbosity (Bit #(4)  verbosity, Bit #(64)  logdelay);

   // ----------------------------------------------------------------
   // Start

   method Action start (Bool is_running, Bit #(64) tohost_addr, Bit #(64) fromhost_addr);

   // ----------------------------------------------------------------
   // AXI4 Fabric interface

   interface AXI4_Manager #(TAdd#(Wd_IId,2), Wd_Addr, Wd_Data,
                              0, 0, 0, 0, 0) cpu_mem_manager;

   interface AXI4_Subordinate #(t_n_subordinates, Wd_Addr, Wd_Data,
                           0, 0, 0, 0, 0) praesidio_config_subordinate;

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
module mkPraesidioCoreWW #(Reset dm_power_on_reset)
               (Praesidio_CoreWW #(N_External_Interrupt_Sources, Wd_SId));
  // ================================================================
  // Instantiate corew module
  CoreW_IFC #(N_External_Interrupt_Sources)  corew <- mkCoreW (dm_power_on_reset);
  let corew_cached_manager = corew.cpu_imem_master;
  let corew_uncached_manager = corew.cpu_dmem_master;

  // ================================================================
  // Instantiate Praesidio_MemoryShim module
  SoC_Map_IFC  soc_map  <- mkSoC_Map;
  //TODO what about reset?
  Praesidio_MemoryShim#(TAdd#(Wd_IId,2), Wd_SId, Wd_Addr, Wd_Data, 0, 0, 0, 0, 0) praesidio_shim <- mkPraesidio_MemoryShim(
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
  
  // ================================================================
  // AXI bus to funnel both cached and uncached accesses through Praesidio memory shim

  // Managers on the local 2x1 fabric
  Vector#(2, AXI4_Manager #(TAdd#(Wd_IId,1), Wd_Addr, Wd_Data, 0, 0, 0, 0, 0)) manager_vector = newVector;
  manager_vector[0] = corew_cached_manager;
  manager_vector[1] = corew_uncached_manager;

  // Subordinates on the local 2x1 fabric
  Vector#(1, AXI4_Subordinate #(TAdd#(Wd_IId,2), Wd_Addr, Wd_Data, 0, 0, 0, 0, 0)) subordinate_vector = newVector;
  subordinate_vector[0] = praesidio_shim.subordinate;

  Vector#(1, Bool) mergeRoute = replicate(True);
  mkAXI4Bus(constFn(mergeRoute), manager_vector, subordinate_vector);

  // ================================================================
  // Below this is just mapping methods and interfaces to corew except for cpu_mem_manager
  method set_verbosity = corew.set_verbosity;

  method start = corew.start;

  interface cpu_mem_manager = unwrapped_manager;

  interface praesidio_config_subordinate = praesidio_shim.configSubordinate;

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
