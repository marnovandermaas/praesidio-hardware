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

interface Praesidio_CoreWW #(numeric type t_n_interrupt_sources);

   // ----------------------------------------------------------------
   // Debugging: set core's verbosity

   method Action  set_verbosity (Bit #(4)  verbosity, Bit #(64)  logdelay);

   // ----------------------------------------------------------------
   // Start

   method Action start (Bool is_running, Bit #(64) tohost_addr, Bit #(64) fromhost_addr);

   // ----------------------------------------------------------------
   // AXI4 Fabric interface

   interface AXI4_Initiator #(TAdd#(Wd_IId,2), Wd_Addr, Wd_Data,
                              0, 0, 0, 0, 0) cpu_mem_initiator;

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
               (Praesidio_CoreWW #(N_External_Interrupt_Sources));
  // ================================================================
  // Instantiate corew module
  CoreW_IFC #(N_External_Interrupt_Sources)  corew <- mkCoreW (dm_power_on_reset);
  let corew_cached_initiator = corew.cpu_imem_master;
  let corew_uncached_initiator = corew.cpu_dmem_master;

  // ================================================================
  // Instantiate Praesidio_MemoryShim module
  SoC_Map_IFC  soc_map  <- mkSoC_Map;
  //TODO what about reset?
  Praesidio_MemoryShim#(TAdd#(Wd_IId,2), Wd_Addr, Wd_Data, 0, 0, 0, 0, 0) praesidio_shim <- mkPraesidio_MemoryShim(
                    rangeBase(soc_map.m_mem0_controller_addr_range),
                    rangeTop(soc_map.m_mem0_controller_addr_range));
`ifdef PERFORMANCE_MONITORING
  let monitored_initiator <- monitorAXI4_Initiator(praesidio_shim.initiator);
  let unwrapped_initiator = monitored_initiator.ifc;
  rule report_axi_events;
    corew.events_axi(monitored_initiator.events);
  endrule
`else
  let unwrapped_initiator = praesidio_shim.initiator;
`endif
  
  // ================================================================
  // AXI bus to funnel both cached and uncached accesses through Praesidio memory shim

  // Initiators on the local 2x1 fabric
  Vector#(2, AXI4_Initiator #(TAdd#(Wd_IId,1), Wd_Addr, Wd_Data, 0, 0, 0, 0, 0)) initiator_vector = newVector;
  initiator_vector[0] = corew_cached_initiator;
  initiator_vector[1] = corew_uncached_initiator;

  // Targets on the local 2x1 fabric
  Vector#(1, AXI4_Target #(TAdd#(Wd_IId,2), Wd_Addr, Wd_Data, 0, 0, 0, 0, 0)) target_vector = newVector;
  target_vector[0] = praesidio_shim.target;

  Vector#(1, Bool) mergeRoute = replicate(True);
  mkAXI4Bus(constFn(mergeRoute), initiator_vector, target_vector);

  // ================================================================
  // Below this is just mapping methods and interfaces to corew except for cpu_mem_initiator
  method set_verbosity = corew.set_verbosity;

  method start = corew.start;

  interface cpu_mem_initiator = unwrapped_initiator;

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
