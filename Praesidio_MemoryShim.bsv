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
import BRAM :: *;

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
    numeric type user_);
  method Action clear;
  interface AXI4_Initiator #(
    id_, addr_, data_, user_, user_, user_, user_, user_
  ) initiator;
  interface AXI4_Target #(
    id_, addr_, data_, user_, user_, user_, user_, user_
  ) target;
  //interface AXI4_Target#(
  //  id_, addr_, data_, user_, user_, user_, user_, user_
  //) configure;
endinterface

// ================================================================
// Praesidio MemoryShim module

module mkPraesidio_MemoryShim
    #(Bit#(addr_) start_address, Bit#(addr_)end_address)
    (Praesidio_MemoryShim #(id_, addr_, data_, user_))
//TODO provisos: start_address < end_address, addr_ > 12
  provisos();

  // Shims
  let  inShim <- mkAXI4InitiatorTargetShimBypassFIFOF;
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
  // internal bram
  BRAM_Configure cfg = defaultValue;
  cfg.memorySize = 8*1024; // 1 GiB DRAM and a two bits per 4 KiB page, this is 2*512*1024/8 Bytes = 64 KiB, assuming 64 bit dram words this is 64*1024*8/64 = 8*1024
  BRAM2Port#(UInt#(13), Bit#(64)) bram <- mkBRAM2Server(cfg);
  // internal fifos
  let internal_fifof_depth = cfg.outFIFODepth;
  FIFOF #(AXI4_AWFlit#(id_, addr_, user_)) awFF <- mkSizedFIFOF(internal_fifof_depth);
  FIFOF #( AXI4_WFlit#(data_,      user_))  wFF <- mkSizedFIFOF(internal_fifof_depth);
  FIFOF #(AXI4_ARFlit#(id_, addr_, user_)) arFF <- mkSizedFIFOF(internal_fifof_depth);

  // DEBUG //
  //////////////////////////////////////////////////////////////////////////////
  Bool debug = False;
  (* fire_when_enabled *)
  rule dbg (False);
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

  // Common functions
  //////////////////////////////////////////////////////////////////////////////
  function Bit#(addr_) get_page_offset(Bit#(addr_) address);
    let offset = address - start_address;
    let page_number = offset >> 12;
    return page_number;
  endfunction

  function UInt#(13) get_bram_addr(Bit#(addr_) address);
    let page_number = get_page_offset(address);
    let bram_addr = page_number / 64;
    return unpack(bram_addr[12:0]);
  endfunction

  function Bool is_in_range(Bit#(addr_) address);
    return (address >= start_address) && (address < end_address);
  endfunction

  // Writes
  //////////////////////////////////////////////////////////////////////////////
  rule enq_write_req;
    awFF.enq(inAW.peek);
    wFF.enq(inW.peek);
    inAW.drop;
    inW.drop;
    bram.portA.request.put(BRAMRequest{
      write: False,
      responseOnWrite: False,
      address: get_bram_addr(inAW.peek.awaddr),
      datain: 0
    });
    // DEBUG //
    if (debug) $display("%0t: enq_write_req", $time,
                        "\n", fshow(inAW.peek), "\n", fshow(inW.peek));
  endrule

  rule deq_write_req;
    Bit#(64) rsp <- bram.portA.response.get;
    let page_offset = get_page_offset(awFF.first.awaddr);
    awFF.deq;
    wFF.deq;
    Bit#(64) mask = 1 << (page_offset % 64);
    if((rsp & mask) != 0) begin
      outAW.put(awFF.first);
      outW.put(wFF.first);
    end else begin
      inB.put(AXI4_BFlit { bid: awFF.first.awid, bresp: OKAY,buser: awFF.first.awuser});
    end
    // DEBUG //
    if (debug) $display("%0t: deq_write_req", $time,
                        "\n", fshow(awFF.first), "\n", fshow(wFF.first));
  endrule

  rule handle_write_rsp;
    outB.drop;
    inB.put(outB.peek);
    // DEBUG //
    if (debug) $display("%0t: handle_write_rsp - ", $time, fshow(outB.peek));
  endrule

  // Reads
  //////////////////////////////////////////////////////////////////////////////
  rule enq_read_req;
    arFF.enq(inAR.peek);
    inAR.drop;
    //TODO send request to internal bram.
    // DEBUG //
    if (debug) $display("%0t: enq_read_req", $time,
                        "\n", fshow(inAR.peek));
  endrule

  rule deq_read_req;
    outAR.put(arFF.first);
    arFF.deq;
    //TODO make this conditional based on BRAM result.
    // DEBUG //
    if (debug) $display("%0t: deq_read_req", $time,
                        "\n", fshow(arFF.first));
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
