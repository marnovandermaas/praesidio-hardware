// Copyright (c) 2021 Marno van der Maas

package Praesido_MemoryShim;

// ================================================================
// Separate interfaces for input-side and output-side of FIFOF.
// Conversion functions to these, from FIFOF interfaces.

// ================================================================
// BSV library imports

import Connectable :: *;
import GetPut      :: *;

// ================================================================
// BlueStuff imports

import AXI4 :: *;

// ================================================================
// Praesidio MemoryShim interface

interface Praesidio_MemoryShim

endinterface

// ================================================================
// Praesidio MemoryShim module

module mkPraesidio_MemoryShim (Praesidio_MemoryShim, AXI4_InitiatorTarget_Shim);

endmodule: mkPraesidio_MemoryShim

// ================================================================

endpackage
