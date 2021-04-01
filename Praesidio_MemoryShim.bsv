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
    numeric type cid_,
    numeric type addr_,
    numeric type data_,
    numeric type awuser_,
    numeric type wuser_,
    numeric type buser_,
    numeric type aruser_,
    numeric type ruser_);
  method Action clear;
  interface AXI4_Initiator #(
    id_,  addr_, data_, awuser_, wuser_, buser_, aruser_, ruser_
  ) initiator;
  interface AXI4_Target #(
    id_,  addr_, data_, awuser_, wuser_, buser_, aruser_, ruser_
  ) target;
  interface AXI4_Target#(
    cid_, addr_, data_, awuser_, wuser_, buser_, aruser_, ruser_
  ) configTarget;
endinterface

// ================================================================
// Praesidio MemoryShim module

typedef 64 BitsPerBramWord;
typedef Bit#(BitsPerBramWord) BramWordType;
typedef 12 PageBitOffset;
typedef 13 BramAddressBits;

module mkPraesidio_MemoryShim
    #(Bit#(addr_) start_address, Bit#(addr_) end_address, Bit#(addr_) conf_address)
    (Praesidio_MemoryShim #(id_, cid_, addr_, data_, awuser_, wuser_, buser_, aruser_, ruser_))
  provisos(
    Add #(PageBitOffset, a__, addr_), //12 <= addr_
    Add #(addr_, b__, data_) // addr <= data_
    //Add #(BitsPerBramWord, 0, data_) //data_ = BitsPerBramWord
  );

  // Shims
  let  inShim <- mkAXI4InitiatorTargetShimBypassFIFOF;
  let outShim <- mkAXI4InitiatorTargetShimBypassFIFOF;
  let confShim<- mkAXI4InitiatorTargetShimFF;
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
  let confAW=confShim.initiator.aw;
  let confW =confShim.initiator.w;
  let confB =confShim.initiator.b;
  let confAR=confShim.initiator.ar;
  let confR =confShim.initiator.r;
  // internal bram
  BRAM_Configure cfg = defaultValue;
  cfg.memorySize = 8*1024; // 1 GiB DRAM and a two bits per 4 KiB page, this is 2*256*1024/8 Bytes = 64 KiB, assuming 64 bit dram words this is 64*1024*8/64 = 8*1024
  //cfg.loadFormat = tagged Hex "Zero.hex";
  BRAM2Port#(UInt#(BramAddressBits), BramWordType) bram <- mkBRAM2Server(cfg);
  // internal fifos for outstanding BRAM requests
  let internal_fifof_depth = cfg.outFIFODepth;
  FIFOF #(AXI4_AWFlit#(id_, addr_, awuser_)) awFF <- mkSizedFIFOF(internal_fifof_depth);
  FIFOF #( AXI4_WFlit#(     data_,  wuser_))  wFF <- mkSizedFIFOF(internal_fifof_depth);
  FIFOF #(AXI4_ARFlit#(id_, addr_, aruser_)) arFF <- mkSizedFIFOF(internal_fifof_depth);
  // internal fifos for responses to invalid requests
  FIFOF #( AXI4_BFlit#(id_,         buser_))  bFF <- mkFIFOF;
  FIFOF #( AXI4_RFlit#(id_, data_,  ruser_))  rFF <- mkFIFOF;
  // internal fifos for config requests
  FIFOF #(AXI4_AWFlit#(cid_, addr_, awuser_)) confAW_FF <- mkSizedFIFOF(internal_fifof_depth);
  FIFOF #( AXI4_WFlit#(      data_,  wuser_))  confW_FF <- mkSizedFIFOF(internal_fifof_depth);
  // initialized register
  Reg #(Bool) initialized <- mkReg(False);

  // DEBUG //
  //////////////////////////////////////////////////////////////////////////////
  Bool debug = False;
//  (* fire_when_enabled *)
//  rule dbg (debug);
//    Fmt dbg_str = $format("inAW.canPeek:\t ", fshow(inAW.canPeek))
//                + $format("\toutAW.canPut:\t ", fshow(outAW.canPut))
//                + $format("\n\tinW.canPeek:\t ", fshow(inW.canPeek))
//                + $format("\toutW.canPut:\t ", fshow(outW.canPut))
//                + $format("\n\tinB.canPut:\t ", fshow(inB.canPut))
//                + $format("\toutB.canPeek:\t ", fshow(outB.canPeek))
//                + $format("\n\tinAR.canPeek:\t ", fshow(inAR.canPeek))
//                + $format("\toutAR.canPut:\t ", fshow(outAR.canPut))
//                + $format("\n\tinR.canPut:\t ", fshow(inR.canPut))
//                + $format("\toutR.canPeek:\t ", fshow(outR.canPeek));
//    $display("%0t: ", $time, dbg_str);
//  endrule

  // Common functions
  //////////////////////////////////////////////////////////////////////////////
  function Bit#(addr_) get_page_offset(Bit#(addr_) address);
    let offset = address - start_address;
    let page_number = offset >> fromInteger(valueOf(PageBitOffset));
    return page_number;
  endfunction

  function UInt#(BramAddressBits) get_bram_addr(Bit#(addr_) address);
    let page_number = get_page_offset(address);
    let bram_addr = page_number / (fromInteger(valueOf(BitsPerBramWord))/2);
    return unpack(bram_addr[(fromInteger(valueOf(BramAddressBits))-1):0]);
  endfunction

  function Bool is_in_range(Bit#(addr_) address);
    return (address >= start_address) && (address < end_address);
  endfunction

  function BramWordType get_bram_mask(Bit#(addr_) address, Bool owner, Bool reader);
    BramWordType return_value = owner ? 'b01 : 'b00;
    if(reader) begin
      return_value = return_value | 'b10;
    end
    let remainder = get_page_offset(address) % (fromInteger(valueOf(BitsPerBramWord))/2);
    return return_value << (remainder * 2);
  endfunction

  // Configuration
  //////////////////////////////////////////////////////////////////////////////
//  rule initialize(!initialized);
//    Bit#(addr_) allow_address = 'h80000000;
//    bram.portA.request.put(BRAMRequest{
//      write: True,
//      responseOnWrite: False,
//      address: get_bram_addr(allow_address),
//      datain: 0
//    });
//    Bit#(addr_) block_address = 'h80730000;
//    bram.portB.request.put(BRAMRequest{
//      write: True,
//      responseOnWrite: False,
//      address: get_bram_addr(block_address),
//      datain: get_bram_mask(block_address, True, True)
//    });
//    initialized <= True;
//    // DEBUG //
//    if (debug) begin
//      $display("%0t: initialize", $time);
//    end
//  endrule

  rule enq_config_write;
    //TODO check that initiator ID matches before accepting request
    confAW.drop;
    confW.drop;
    confAW_FF.enq(confAW.peek);
    confW_FF.enq(confW.peek);
    bram.portB.request.put(BRAMRequest{
      write: False,
      responseOnWrite: False,
      address: get_bram_addr(confAW.peek.awaddr),
      datain: 0
    });
    // DEBUG //
    if (debug) begin
      $display("%0t: enq_config_write", $time,
               "\n", fshow(confAW.peek),
               "\n", fshow(confW.peek));
    end
  endrule

  rule deq_config_write;
    confAW_FF.deq;
    confW_FF.deq;
    let reqAddress = confAW_FF.first.awaddr;
    Bit#(addr_) argAddress = truncate(confW_FF.first.wdata);
    let rsp <- bram.portB.response.get;
    let revoke = rsp & ~get_bram_mask(argAddress, True, True);
    // DEBUG //
    if (debug) begin
      $display("%0t: deq_config_write", $time,
               "\n\t", fshow(rsp),
               "\n\t", fshow(revoke),
               "\n\t", fshow(conf_address),
               "\n\t", fshow(reqAddress),
               "\n\t", fshow(argAddress));
    end
    if(reqAddress == conf_address) begin
      //Revoke access to page
      bram.portB.request.put(BRAMRequest{
        write: True,
        responseOnWrite: False,
        address: get_bram_addr(argAddress),
        datain: revoke
      });
      if (debug) begin
        $display("\trevoke access");
      end
    end else if (reqAddress == conf_address + fromInteger(valueOf(BitsPerBramWord))) begin
      //Grant ownership permission
      bram.portB.request.put(BRAMRequest{
        write: True,
        responseOnWrite: False,
        address: get_bram_addr(argAddress),
        datain: revoke | get_bram_mask(argAddress, True, False)
      });
      if (debug) begin
        $display("\tgrant ownership");
      end
    end else if (reqAddress == conf_address + 2*fromInteger(valueOf(BitsPerBramWord))) begin
      //Grant reader permission
      bram.portB.request.put(BRAMRequest{
        write: True,
        responseOnWrite: False,
        address: get_bram_addr(argAddress),
        datain: revoke | get_bram_mask(argAddress, False, True)
      });
      if (debug) begin
        $display("\tgrant reader");
      end
    end else begin
      //Set initialized to True
      initialized <= True;
      if (debug) begin
        $display("\tinitialized");
      end
    end
    //Check whether buser should actually be 0
    confB.put(AXI4_BFlit { bid: confAW_FF.first.awid, bresp: OKAY, buser: 0});
  endrule

  rule config_read;
    confAR.drop;
    //Maybe return error here?
    confR.put(AXI4_RFlit{ rid: confAR.peek.arid, rdata: -1, rresp: OKAY, rlast: True, ruser: 0});
    // DEBUG //
    if (debug) begin
      $display("%0t: config_read", $time,
               "\n", fshow(confAR.peek));
    end
  endrule

  // Writes
  //////////////////////////////////////////////////////////////////////////////
  rule enq_write_req;
    awFF.enq(inAW.peek);
    wFF.enq(inW.peek);
    if(is_in_range(inAW.peek.awaddr) && initialized) begin
      bram.portA.request.put(BRAMRequest{
        write: False,
        responseOnWrite: False,
        address: get_bram_addr(inAW.peek.awaddr),
        datain: 0
      });
    end
    inAW.drop;
    inW.drop;
    // DEBUG //
    if (debug) begin
      $display("%0t: enq_write_req", $time,
               "\n", fshow(inAW.peek), "\n", fshow(inW.peek));
    end
  endrule

  rule deq_write_req;
    Bool allowAccess = False;
    BramWordType rsp = ?;
    BramWordType mask = ?;
    if(is_in_range(awFF.first.awaddr) && initialized) begin
      rsp <- bram.portA.response.get;
      mask = get_bram_mask(awFF.first.awaddr, True, False);
      allowAccess = (rsp & mask) != 0;
    end
    awFF.deq;
    wFF.deq;
    // DEBUG //
    if (debug) begin
      $display("%0t: deq_write_req", $time,
               "\n\t", fshow(awFF.first),
               "\n\t", fshow(wFF.first),
               "\n\t", fshow(rsp),
               "\n\tAllow: ", fshow(allowAccess));
    end
    if(allowAccess || !is_in_range(awFF.first.awaddr) || !initialized) begin
      outAW.put(awFF.first);
      outW.put(wFF.first);
      if (debug) begin
        $display("\tForwarded request");
      end
    end else begin
      //Check whether buser should actually be 0
      bFF.enq(AXI4_BFlit { bid: awFF.first.awid, bresp: OKAY, buser: 0});
      if (debug) begin
        $display("\tBlocked request");
      end
    end
  endrule

  rule deq_write_rsp;
    inB.put(bFF.first);
    bFF.deq;
    // DEBUG //
    if (debug) begin
      $display("%0t: deq_write_rsp - ", $time, fshow(bFF.first));
    end
  endrule

  rule enq_write_rsp;
    outB.drop;
    bFF.enq(outB.peek);
    // DEBUG //
    if (debug) begin
      $display("%0t: enq_write_rsp - ", $time, fshow(outB.peek));
    end
  endrule

  // Reads
  //////////////////////////////////////////////////////////////////////////////
  rule enq_read_req;
    arFF.enq(inAR.peek);
    inAR.drop;
    if (is_in_range(inAR.peek.araddr) && initialized) begin
      bram.portA.request.put(BRAMRequest{
        write: False,
        responseOnWrite: False,
        address: get_bram_addr(inAR.peek.araddr),
        datain: 0
      });
    end
    // DEBUG //
    if (debug) begin
      $display("%0t: enq_read_req", $time,
               "\n", fshow(inAR.peek));
    end
  endrule

  rule deq_read_req;
    BramWordType rsp = ?;
    BramWordType mask = ?;
    Bool allowAccess = False;
    if(is_in_range(arFF.first.araddr) && initialized) begin
      rsp <- bram.portA.response.get;
      mask = get_bram_mask(arFF.first.araddr, True, True);
      allowAccess = (rsp & mask) != 0;
    end
    arFF.deq;
    // DEBUG //
    if (debug) begin
      $display("%0t: deq_read_req", $time,
               "\n\t", fshow(arFF.first),
               "\n\t", fshow(rsp),
               "\n\tAllow: ", fshow(allowAccess));
    end
    if(allowAccess || !is_in_range(arFF.first.araddr) || !initialized) begin
      outAR.put(arFF.first);
      if (debug) begin
        $display("\tForwarded request");
      end
    end else begin
      //TODO check whether you need to send multiple -1 back.
      rFF.enq(AXI4_RFlit{ rid: arFF.first.arid, rdata: -1, rresp: OKAY, rlast: True, ruser: 0});
      if (debug) begin
        $display("\tBlocked request");
      end
    end
  endrule

  rule deq_read_rsp;
    inR.put(rFF.first);
    rFF.deq;
    // DEBUG //
    if (debug) begin
      $display("%0t: deq_read_rsp - ", $time, fshow(rFF.first));
    end
  endrule

  rule enq_read_rsp;
    outR.drop;
    rFF.enq(outR.peek);
    // DEBUG //
    if (debug) begin
      $display("%0t: enq_read_rsp - ", $time, fshow(outR.peek));
    end
  endrule

  // Interface
  //////////////////////////////////////////////////////////////////////////////
  method clear = action
    inShim.clear;
    outShim.clear;
    initialized <= False;
  endaction;
  interface target    =  inShim.target;
  interface initiator = outShim.initiator;
  interface configTarget = confShim.target;

endmodule: mkPraesidio_MemoryShim

// ================================================================

endpackage
