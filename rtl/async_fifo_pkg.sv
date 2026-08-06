// -----------------------------------------------------------------------------
// async_fifo_pkg.sv
// Package with shared types, parameters, and functions.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

package async_fifo_pkg;

  // Coverage / scoreboard types
  typedef enum {
    OP_WRITE,
    OP_READ,
    OP_IDLE
  } op_e;

  // Helper: compute gray code
  function automatic [31:0] bin2gray(input [31:0] bin);
    return bin ^ (bin >> 1);
  endfunction

  // Helper: compute binary from gray
  function automatic [31:0] gray2bin(input [31:0] gray);
    logic [31:0] bin;
    bin[31] = gray[31];
    for (int i = 30; i >= 0; i--)
      bin[i] = bin[i+1] ^ gray[i];
    return bin;
  endfunction

endpackage : async_fifo_pkg
