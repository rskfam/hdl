// ***************************************************************************
// ***************************************************************************
// Copyright 2014 - 2018 (c) Analog Devices, Inc. All rights reserved.
//
// In this HDL repository, there are many different and unique modules, consisting
// of various HDL (Verilog or VHDL) components. The individual modules are
// developed independently, and may be accompanied by separate and unique license
// terms.
//
// The user should read each of these license terms, and understand the
// freedoms and responsibilities that he or she has by using this source/core.
//
// This core is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
// A PARTICULAR PURPOSE.
//
// Redistribution and use of source or resulting binaries, with or without modification
// of this file, are permitted under one of the following two license terms:
//
//   1. The GNU General Public License version 2 as published by the
//      Free Software Foundation, which can be found in the top level directory
//      of this repository (LICENSE_GPL2), and also online at:
//      <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
//
// OR
//
//   2. An ADI specific BSD license, which can be found in the top level directory
//      of this repository (LICENSE_ADIBSD), and also on-line at:
//      https://github.com/analogdevicesinc/hdl/blob/master/LICENSE_ADIBSD
//      This will allow to generate bit files and not release the source code,
//      as long as it attaches to an ADI device.
//
// ***************************************************************************
// ***************************************************************************

module axi_dmac_burst_memory #(
  parameter DATA_WIDTH_SRC = 64,
  parameter DATA_WIDTH_DEST = 64,
  parameter ID_WIDTH = 3,
  parameter MAX_BYTES_PER_BURST = 128,
  parameter ASYNC_CLK = 1
) (
  input src_clk,
  input src_reset,

  input src_data_valid,
  output src_data_ready,
  input [DATA_WIDTH_SRC-1:0] src_data,
  input src_data_last,

  input dest_clk,
  input dest_reset,

  output dest_data_valid,
  input dest_data_ready,
  output [DATA_WIDTH_DEST-1:0] dest_data
);

localparam DATA_WIDTH = DATA_WIDTH_SRC > DATA_WIDTH_DEST ?
  DATA_WIDTH_SRC : DATA_WIDTH_DEST;

/* A burst can have up to 256 beats */
localparam BURST_LEN = MAX_BYTES_PER_BURST / (DATA_WIDTH / 8);
localparam BURST_LEN_WIDTH = BURST_LEN > 128 ? 8 :
  BURST_LEN > 64 ? 7 :
  BURST_LEN > 32 ? 6 :
  BURST_LEN > 16 ? 5 :
  BURST_LEN > 8 ? 4 :
  BURST_LEN > 4 ? 3 :
  BURST_LEN > 2 ? 2 : 1;

localparam ADDRESS_WIDTH = BURST_LEN_WIDTH + ID_WIDTH - 1;

localparam AUX_FIFO_SIZE = 2**(ID_WIDTH-1);

/*
 * The burst memory is separated into 2**(ID_WIDTH-1) segments. Each segment can
 * hold up to BURST_LEN beats. The addresses that are used to access the memory
 * are split into two parts. The MSBs index the segment and the LSBs index a
 * beat in a specific segment.
 *
 * src_id and dest_id are used to index the segment of the burst memory on the
 * write and read side respectively. The IDs are 1 bit wider than the address of
 * the burst memory. So we can't use them directly as an index into the burst
 * memory.  Since the IDs are gray counted we also can't just leave out the MSB
 * like with a binary counter. But XOR-ing the two MSBs of a gray counter gives
 * us a gray counter of 1 bit less. Use this to generate the segment index.
 * These addresses are captured in the src_id_reduced and dest_id_reduced
 * signals.
 *
 * src_beat_counter and dest_beat_counter are used to index the beat on the
 * write and read side respectively. They will be incremented for each beat that
 * is written/read. Note that the beat counters are not reset to 0 on the last
 * beat of a burst. This means the first beat of a burst might not be stored at
 * offset 0 in the segment memory. But this is OK since the beat counter
 * increments modulo the segment size and both the write and read side agree on
 * the order.
 */

reg [ID_WIDTH-1:0] src_id_next;
reg [ID_WIDTH-1:0] src_id = 'h0;
reg src_id_reduced_msb = 1'b0;
reg [BURST_LEN_WIDTH-1:0] src_beat_counter = 'h00;
reg src_mem_data_ready = 1'b0;

reg [ID_WIDTH-1:0] dest_id_next = 'h0;
reg dest_id_reduced_msb_next = 1'b0;
reg dest_id_reduced_msb = 1'b0;
reg [ID_WIDTH-1:0] dest_id = 'h0;
reg [BURST_LEN_WIDTH-1:0] dest_beat_counter = 'h00;
reg [BURST_LEN_WIDTH-1:0] dest_burst_len = 'h00;
reg dest_valid = 1'b0;
reg dest_mem_data_valid = 1'b0;
reg dest_mem_data_last = 1'b0;

reg [BURST_LEN_WIDTH-1:0] burst_len_mem[0:AUX_FIFO_SIZE-1];

wire src_beat;
wire src_last_beat;
wire [ID_WIDTH-1:0] src_dest_id;
wire [ADDRESS_WIDTH-1:0] src_waddr;
wire [ID_WIDTH-2:0] src_id_reduced;
wire src_mem_data_valid;
wire src_mem_data_last;
wire [DATA_WIDTH-1:0] src_mem_data;

wire dest_beat;
wire dest_last_beat;
wire dest_last;
wire [ID_WIDTH-1:0] dest_src_id;
wire [ADDRESS_WIDTH-1:0] dest_raddr;
wire [ID_WIDTH-2:0] dest_id_reduced_next;
wire [ID_WIDTH-1:0] dest_id_next_inc;
wire [ID_WIDTH-2:0] dest_id_reduced;
wire dest_burst_valid;
wire dest_burst_ready;
wire dest_ready;
wire [DATA_WIDTH-1:0] dest_mem_data;
wire dest_mem_data_ready;

`include "inc_id.h"

generate if (ID_WIDTH >= 3) begin
  assign src_id_reduced = {src_id_reduced_msb,src_id[ID_WIDTH-3:0]};
  assign dest_id_reduced_next = {dest_id_reduced_msb_next,dest_id_next[ID_WIDTH-3:0]};
  assign dest_id_reduced = {dest_id_reduced_msb,dest_id[ID_WIDTH-3:0]};
end else begin
  assign src_id_reduced = src_id_reduced_msb;
  assign dest_id_reduced_next = dest_id_reduced_msb_next;
  assign dest_id_reduced = dest_id_reduced_msb;
end endgenerate

assign src_beat = src_mem_data_valid & src_mem_data_ready;
assign src_last_beat = src_beat & src_mem_data_last;
assign src_waddr = {src_id_reduced,src_beat_counter};

always @(*) begin
  if (src_last_beat == 1'b1) begin
    src_id_next <= inc_id(src_id);
  end else begin
    src_id_next <= src_id;
  end
end

always @(posedge src_clk) begin
  /* Ready if there is room for at least one full burst. */
  src_mem_data_ready <= (src_id_next[ID_WIDTH-1] == src_dest_id[ID_WIDTH-1] ||
                src_id_next[ID_WIDTH-2] == src_dest_id[ID_WIDTH-2] ||
                src_id_next[ID_WIDTH-3:0] != src_dest_id[ID_WIDTH-3:0]);
end

always @(posedge src_clk) begin
  if (src_reset == 1'b1) begin
    src_id <= 'h00;
    src_id_reduced_msb <= 1'b0;
  end else begin
    src_id <= src_id_next;
    src_id_reduced_msb <= ^src_id_next[ID_WIDTH-1-:2];
  end
end

always @(posedge src_clk) begin
  if (src_reset == 1'b1) begin
    src_beat_counter <= 'h00;
  end else if (src_beat == 1'b1) begin
    src_beat_counter <= src_beat_counter + 1'b1;
  end
end

always @(posedge src_clk) begin
  if (src_last_beat == 1'b1) begin
    burst_len_mem[src_id_reduced] <= src_beat_counter;
  end
end

assign dest_ready = ~dest_mem_data_valid | dest_mem_data_ready;
assign dest_last = dest_beat_counter == dest_burst_len;

assign dest_beat = dest_valid & dest_ready;
assign dest_last_beat = dest_last & dest_beat;
assign dest_raddr = {dest_id_reduced,dest_beat_counter};

assign dest_burst_valid = dest_src_id != dest_id_next;
assign dest_burst_ready = ~dest_valid | dest_last_beat;

/*
 * The data valid signal for the destination side is asserted if there are one
 * or more pending bursts. It is de-asserted if there are no more pending burst
 * and it is the last beat of the current burst
 */
always @(posedge dest_clk) begin
  if (dest_reset == 1'b1) begin
    dest_valid <= 1'b0;
  end else if (dest_burst_valid == 1'b1) begin
    dest_valid <= 1'b1;
  end else if (dest_last_beat == 1'b1) begin
    dest_valid <= 1'b0;
  end
end

/*
 * The output register of the memory creates a extra clock cycle of latency on
 * the data path. We need to handle this more the handshaking signals. If data
 * is available in the memory it will be available one clock cycle later in the
 * output register.
 */
always @(posedge dest_clk) begin
  if (dest_reset == 1'b1) begin
    dest_mem_data_valid <= 1'b0;
  end else if (dest_valid == 1'b1) begin
    dest_mem_data_valid <= 1'b1;
  end else if (dest_mem_data_ready == 1'b1) begin
    dest_mem_data_valid <= 1'b0;
  end
end

assign dest_id_next_inc = inc_id(dest_id_next);

always @(posedge dest_clk) begin
  if (dest_reset == 1'b1) begin
    dest_id_next <= 'h00;
    dest_id_reduced_msb_next <= 1'b0;
  end else if (dest_burst_valid == 1'b1 && dest_burst_ready == 1'b1) begin
    dest_id_next <= dest_id_next_inc;
    dest_id_reduced_msb_next <= ^dest_id_next_inc[ID_WIDTH-1-:2];
  end
end

always @(posedge dest_clk) begin
  if (dest_burst_valid == 1'b1 && dest_burst_ready == 1'b1) begin
    dest_burst_len <= burst_len_mem[dest_id_reduced_next];
  end
end

always @(posedge dest_clk) begin
  if (dest_burst_ready == 1'b1) begin
    dest_id <= dest_id_next;
    dest_id_reduced_msb <= dest_id_reduced_msb_next;
  end
end

always @(posedge dest_clk) begin
  if (dest_reset == 1'b1) begin
    dest_beat_counter <= 'h00;
  end else if (dest_beat == 1'b1) begin
    dest_beat_counter <= dest_beat_counter + 1'b1;
  end
end

axi_dmac_resize_src #(
  .DATA_WIDTH_SRC (DATA_WIDTH_SRC),
  .DATA_WIDTH_MEM (DATA_WIDTH)
) i_resize_src (
  .clk (src_clk),
  .reset (src_reset),

  .src_data_valid (src_data_valid),
  .src_data_ready (src_data_ready),
  .src_data (src_data),
  .src_data_last (src_data_last),

  .mem_data_valid (src_mem_data_valid),
  .mem_data_ready (src_mem_data_ready),
  .mem_data (src_mem_data),
  .mem_data_last (src_mem_data_last)
);

ad_mem #(
  .DATA_WIDTH (DATA_WIDTH),
  .ADDRESS_WIDTH (ADDRESS_WIDTH)
) i_mem (
  .clka (src_clk),
  .wea (src_beat),
  .addra (src_waddr),
  .dina (src_mem_data),

  .clkb (dest_clk),
  .reb (dest_beat),
  .addrb (dest_raddr),
  .doutb (dest_mem_data)
);

axi_dmac_resize_dest #(
  .DATA_WIDTH_DEST (DATA_WIDTH_DEST),
  .DATA_WIDTH_MEM (DATA_WIDTH)
) i_resize_dest (
  .clk (dest_clk),
  .reset (dest_reset),

  .mem_data_valid (dest_mem_data_valid),
  .mem_data_ready (dest_mem_data_ready),
  .mem_data (dest_mem_data),
  .mem_data_last (dest_mem_data_last),

  .dest_data_valid (dest_data_valid),
  .dest_data_ready (dest_data_ready),
  .dest_data (dest_data),
  .dest_data_last (dest_data_last)
);

sync_bits #(
  .NUM_OF_BITS (ID_WIDTH),
  .ASYNC_CLK (ASYNC_CLK)
) i_dest_sync_id (
  .in (src_id),
  .out_clk (dest_clk),
  .out_resetn (1'b1),
  .out (dest_src_id)
);

sync_bits #(
  .NUM_OF_BITS (ID_WIDTH),
  .ASYNC_CLK (ASYNC_CLK)
) i_src_sync_id (
  .in (dest_id),
  .out_clk (src_clk),
  .out_resetn (1'b1),
  .out (src_dest_id)
);

endmodule