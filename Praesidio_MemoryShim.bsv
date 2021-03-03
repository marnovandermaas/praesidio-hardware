// Copyright (c) 2021 Marno van der Maas

package Praesidio_MemoryShim;

// ================================================================
// Separate interfaces for input-side and output-side of FIFOF.
// Conversion functions to these, from FIFOF interfaces.

// ================================================================
// BSV library imports

import Connectable  :: *;
import GetPut       :: *;
import FIFOF        :: *;
import SpecialFIFOs :: *;

// ================================================================
// BlueStuff imports

import AXI4 :: *;
// BlueBasics import
import SourceSink :: *;

// ================================================================
// Praesidio MemoryShim interface

interface Praesidio_MemoryShim #(
    numeric type id_,
    numeric type addr_,
    numeric type data_,
    numeric type awuser_,
    numeric type wuser_,
    numeric type buser_,
    numeric type aruser_,
    numeric type ruser_);
  method Action clear;
  interface AXI4_Initiator #(
    id_, addr_, data_, awuser_, wuser_, buser_, aruser_, ruser_
  ) initiator;
  interface AXI4_Target #(
    id_, addr_, data_, awuser_, wuser_, buser_, aruser_, ruser_
  ) target;
  //interface AXI4_Target#(
  //  id_, addr_, data_, awuser_, wuser_, buser_, aruser_, ruser_
  //) configure;
endinterface

// ================================================================
// Praesidio MemoryShim module

module mkPraesidio_MemoryShim (Praesidio_MemoryShim #(a, b, c, d, e, f, g, h));

  // Shims
  let inShim <- mkAXI4InitiatorTargetShimBypassFIFOF;
  let outShim <- mkAXI4InitiatorTargetShimBypassFIFOF;
  // handy names
  let  inAW =  inShim.initiator.aw;
  let  inW  =  inShim.initiator.w;
  let  inB  =  inShim.initiator.b;
  let  inAR =  inShim.initiator.ar;
  let  inR  =  inShim.initiator.r;
  let outAW = outShim.target.aw;
  let outW  = outShim.target.w;
  let outB  = outShim.target.b;
  let outAR = outShim.target.ar;
  let outR  = outShim.target.r;
  // internal state

  // DEBUG //
  //////////////////////////////////////////////////////////////////////////////
  Bool debug = True;
  (* fire_when_enabled *)
  rule dbg (debug);
    Fmt dbg_str = $format("inAW.canPeek:\t ", fshow(inAW.canPeek))
                + $format("\toutAW.canPut:\t ", fshow(outAW.canPut))
                + $format("\n\tinW.canPeek:\t ", fshow(inW.canPeek))
                + $format("\toutW.canPut:\t ", fshow(outW.canPut))
                + $format("\n\tinB.canPut:\t ", fshow(inB.canPut))
                + $format("\toutB.canPeek:\t ", fshow(outB.canPeek))
                + $format("\n\tinAR.canPeek:\t ", fshow(inAR.canPeek))
                + $format("\toutAR.canPut:\t ", fshow(outAR.canPut))
                + $format("\n\tinR.canPut:\t ", fshow(inR.canPut))
                + $format("\toutR.canPeek:\t ", fshow(outR.canPeek));
    $display("%0t: ", $time, dbg_str);
  endrule

  // Writes
  //////////////////////////////////////////////////////////////////////////////
  rule forward_write_req;
    outAW.put(inAw.peek);
    outW.put(get(inW));
    inAW.drop;
    // DEBUG //
    if (debug) $display("%0t: forward_write_req", $time,
                        "\n", fshow(inAw.peek), "\n", fshow(inW.peek));
  endrule
  rule handle_write_rsp;
    outB.drop;
    inB.put(outB.peek);
    // DEBUG //
    if (debug) $display("%0t: handle_write_rsp - ", $time, fshow(outB.peek));
  endrule

  // Reads
  //////////////////////////////////////////////////////////////////////////////
  rule forward_read_req;
    outAR.put(inAR.peek);
    inAR.drop;
    // DEBUG //
    if (debug) $display("%0t: forward_read_req", $time,
                        "\n", fshow(inAR.peek));
  endrule
  rule forward_read_rsp;
    outR.drop;
    inR.put(outR.peek);
    // DEBUG //
    if (debug) $display("%0t: forward_read_rsp - ", $time, fshow(outR.peek));
  endrule

  // Interface
  //////////////////////////////////////////////////////////////////////////////
  method clear = action
    inShim.clear;
    outShim.clear;
  endaction;
  interface target    =  inShim.target;
  interface initiator = outShim.initiator;

endmodule: mkPraesidio_MemoryShim

// ================================================================

endpackage
