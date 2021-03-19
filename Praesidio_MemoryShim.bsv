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
  //  cid_, addr_, data_, awuser_, wuser_, buser_, aruser_, ruser_
  //) configure;
endinterface

// ================================================================
// Praesidio MemoryShim module

typedef 64 BitsPerBramWord;
typedef Bit#(BitsPerBramWord) BramWordType;
typedef 12 PageBitOffset;

module mkPraesidio_MemoryShim
    #(Bit#(addr_) start_address, Bit#(addr_)end_address)
    (Praesidio_MemoryShim #(id_, addr_, data_, awuser_, wuser_, buser_, aruser_, ruser_))
  provisos(
    Add #(PageBitOffset, a__, addr_) //12 <= addr_
    //TODO Add #(start_address, a__, end_address), //start_address <= end_address
  );

  // Shims
  let  inShim <- mkAXI4InitiatorTargetShimSizedFIFOF4;
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
  BRAM2Port#(UInt#(13), BramWordType) bram <- mkBRAM2Server(cfg);
//  // internal fifos for outstanding BRAM requests
//  let internal_fifof_depth = cfg.outFIFODepth;
//  FIFOF #(AXI4_AWFlit#(id_, addr_, awuser_)) awFF <- mkSizedFIFOF(internal_fifof_depth);
//  FIFOF #( AXI4_WFlit#(     data_,  wuser_))  wFF <- mkSizedFIFOF(internal_fifof_depth);
//  FIFOF #(AXI4_ARFlit#(id_, addr_, aruser_)) arFF <- mkSizedFIFOF(internal_fifof_depth);
  // internal fifos for responses to invalid requests
  FIFOF #( AXI4_BFlit#(id_,         buser_))  bFF <- mkFIFOF;
  FIFOF #( AXI4_RFlit#(id_, data_,  ruser_))  rFF <- mkFIFOF;
  // initialized register
  Reg #(Bool) initialized <- mkReg(True);

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
    let page_number = offset >> fromInteger(valueOf(PageBitOffset));
    return page_number;
  endfunction

  function UInt#(13) get_bram_addr(Bit#(addr_) address);
    let page_number = get_page_offset(address);
    let bram_addr = page_number / (fromInteger(valueOf(BitsPerBramWord))/2);
    return unpack(bram_addr[12:0]);
  endfunction

  function Bool is_in_range(Bit#(addr_) address);
    return (address >= start_address) && (address < end_address);
  endfunction

  // Writes
  //////////////////////////////////////////////////////////////////////////////
  rule enq_write_req(initialized);
    //awFF.enq(inAW.peek);
    //wFF.enq(inW.peek);
    bram.portA.request.put(BRAMRequest{
      write: False,
      responseOnWrite: False,
      address: get_bram_addr(inAW.peek.awaddr),
      datain: 0
    });
    // DEBUG //
    if (debug) begin
      $display("%0t: enq_write_req", $time,
               "\n", fshow(inAW.peek), "\n", fshow(inW.peek));
    end
  endrule

  rule deq_write_req(initialized);
    BramWordType rsp <- bram.portA.response.get;
    let pageOffset = get_page_offset(inAW.peek.awaddr);
    BramWordType mask = 1 << ((pageOffset % (fromInteger(valueOf(BitsPerBramWord))/2)) * 2);
    Bool allowAccess = (rsp & mask) != 0;
    //awFF.deq;
    //wFF.deq;
    inAW.drop;
    inW.drop;
    if(allowAccess) begin
      outAW.put(inAW.peek);
      outW.put(inW.peek);
    end else begin
      //TODO check whether buser should actually be 0
      bFF.enq(AXI4_BFlit { bid: inAW.peek.awid, bresp: OKAY, buser: 0});
    end
    // DEBUG //
    if (debug) begin
      $display("%0t: deq_write_req", $time,
               "\n", fshow(inAW.peek),
               "\n", fshow(inW.peek),
               "\nAllow: ", fshow(allowAccess));
    end
  endrule

  rule insert_write_rsp(initialized);
    inB.put(bFF.first);
    bFF.deq;
    // DEBUG //
    if (debug) begin
      $display("%0t: insert_write_rsp - ", $time, fshow(bFF.first));
    end
  endrule

  rule handle_write_rsp(initialized);
    outB.drop;
    inB.put(outB.peek);
    // DEBUG //
    if (debug) begin
      $display("%0t: handle_write_rsp - ", $time, fshow(outB.peek));
    end
  endrule

  // Reads
  //////////////////////////////////////////////////////////////////////////////
  rule enq_read_req(initialized);
    //arFF.enq(inAR.peek);
    //inAR.drop;
    bram.portA.request.put(BRAMRequest{
      write: False,
      responseOnWrite: False,
      address: get_bram_addr(inAR.peek.araddr),
      datain: 0
    });
    // DEBUG //
    if (debug) begin
      $display("%0t: enq_read_req", $time,
               "\n", fshow(inAR.peek));
    end
  endrule

  rule deq_read_req(initialized);
    BramWordType rsp <- bram.portA.response.get;
    let pageOffset = get_page_offset(inAR.peek.araddr);
    //The shifted value is 3 so that allow access will be true if either the owned or the read bit are set.
    BramWordType mask = 3 << ((pageOffset % (fromInteger(valueOf(BitsPerBramWord))/2)) * 2);
    Bool allowAccess = (rsp & mask) != 0;
    //arFF.deq;
    inAR.drop;
    if(allowAccess) begin
      outAR.put(inAR.peek);
    end else begin
      //TODO check whether you need to send multiple -1 back.
      rFF.enq(AXI4_RFlit{ rid: inAR.peek.arid, rdata: -1, rresp: OKAY, rlast: True, ruser: 0});
    end
    // DEBUG //
    if (debug) begin
      $display("%0t: deq_read_req", $time,
               "\n", fshow(inAR.peek),
               "\nAllow: ", fshow(allowAccess));
    end
  endrule

  rule insert_read_rsp(initialized);
    inR.put(rFF.first);
    rFF.deq;
    // DEBUG //
    if (debug) begin
      $display("%0t: insert_read_rsp - ", $time, fshow(rFF.first));
    end
  endrule

  rule handle_read_rsp(initialized);
    outR.drop;
    inR.put(outR.peek);
    // DEBUG //
    if (debug) begin
      $display("%0t: handle_read_rsp - ", $time, fshow(outR.peek));
    end
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
