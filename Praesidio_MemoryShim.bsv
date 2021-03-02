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
  let awff <- mkBypassFIFOF;
  let  wff <- mkBypassFIFOF;
  let  bff <- mkBypassFIFOF;
  let arff <- mkBypassFIFOF;
  let  rff <- mkBypassFIFOF;

  method clear = action
    awff.clear;
    wff.clear;
    bff.clear;
    arff.clear;
    rff.clear;
  endaction;

  interface initiator = interface AXI4_Initiator;
    interface aw = toSource(awff);
    interface  w = toSource(wff);
    interface  b = toSink(bff);
    interface ar = toSource(arff);
    interface  r = toSink(rff);
  endinterface;

  interface target = interface AXI4_Target;
    interface aw = toSink(awff);
    interface  w = toSink(wff);
    interface  b = toSource(bff);
    interface ar = toSink(arff);
    interface  r = toSource(rff);
  endinterface;

endmodule: mkPraesidio_MemoryShim

// ================================================================

endpackage
