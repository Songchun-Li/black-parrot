/*
 * bp_fe_bht.v
 *
 * Branch History Table (BHT) records the information of the branch history, i.e.
 * branch taken or not taken.
 * Each entry consists of 2 bit saturation counter. If the counter value is in
 * the positive regime, the BHT predicts "taken"; if the counter value is in the
 * negative regime, the BHT predicts "not taken". The implementation of BHT is
 * native to this design.
*/
module bp_fe_bht
 import bp_fe_pkg::*;
 #(parameter vaddr_width_p = "inv"
   , parameter bht_idx_width_p = "inv"

   , parameter debug_p             = 0

   , localparam els_lp             = 2**bht_idx_width_p
   , localparam saturation_size_lp = 2
   , localparam mem_width_lp       = saturation_size_lp * 2
   )
   ( input                         clk_i
   , input                       reset_i

   , input                       w_v_i
   , input [bht_idx_width_p-1:0] idx_w_i
   , input                       correct_i

   , input                       r_v_i
   , input [bht_idx_width_p-1:0] idx_r_i

   , output                      predict_o
   );

// logic [els_lp-1:0][saturation_size_lp-1:0] counter_mem;
logic [els_lp-1:0][mem_width_lp-1:0] counter_mem;
logic [els_lp-1:0] history_mem;
logic [els_lp-1:0] last_predict_mem;

logic [1:0][saturation_size_lp-1:0] counter_mem_read_data;
logic [saturation_size_lp-1:0] targeted_counter;
logic last_taken_read, last_taken_write;

logic [bht_idx_width_p-1:0] idx_r_r;
logic r_v_r;
bsg_dff
 #(.width_p(1+bht_idx_width_p))
 read_reg
  (.clk_i(clk_i)
   ,.data_i({r_v_i, idx_r_i})
   ,.data_o({r_v_r, idx_r_r})
   );

always_comb begin
  last_taken_read = history_mem[idx_r_r];
  counter_mem_read_data = counter_mem[idx_r_r];
  targeted_counter = last_taken_read ? counter_mem_read_data[1] : counter_mem_read_data[0];
  //  predict_o = r_v_r ? counter_mem[idx_r_r][1] : `BSG_UNDEFINED_IN_SIM(1'b0);
end
assign predict_o = r_v_r ? targeted_counter[1] : `BSG_UNDEFINED_IN_SIM(1'b0);

// store the predict result for updating use
always_ff @(posedge clk_i) begin
  if (reset_i)
    last_predict_mem <= '{default:1'b0};   // initialized with not taken
  else if (r_v_r)
    last_predict_mem[idx_r_r] <= predict_o;
end

//2-bit saturating counter(high_bit:prediction direction,low_bit:strong/weak prediction)
//10: Strongly taken
//11: Weakly taken
//01: Weakly not taken
//00: Strongly not taken

// update the history memory with the correctness signal and last predict result
logic history_mem_write_data;
assign history_mem_write_data = ~(last_predict_mem[idx_w_i] ^ correct_i);
always_ff @(posedge clk_i) begin
  if (reset_i)
    history_mem <= '{default:1'b0};      // initialized with not taken
  else if (w_v_i)
    history_mem[idx_w_i] <= history_mem_write_data;
end

logic [1:0][saturation_size_lp-1:0] counter_mem_write_data, counter_mem_last_data;
logic [saturation_size_lp-1:0] counter_mem_update;
always_comb begin
  last_taken_write = history_mem[idx_w_i];
  counter_mem_last_data = counter_mem[idx_w_i];
  if (correct_i)
    counter_mem_update = {counter_mem_last_data[1], 1'b0};
  else if (~correct_i)
    counter_mem_update = {counter_mem_last_data[1]^counter_mem_last_data, 1'b1};
  counter_mem_write_data[0] =  last_taken_write ? counter_mem_last_data[0] : counter_mem_update;
  counter_mem_write_data[1] =  last_taken_write ? counter_mem_update : counter_mem_last_data[1];
end

always_ff @(posedge clk_i)  begin
  if (reset_i)
    counter_mem <= '{default:4'b0101};
    // counter_mem <= '{default:2'b01};
  else if (w_v_i)
    counter_mem[idx_w_i] <= counter_mem_write_data;
end

//synopsys translate_off
logic [bht_idx_width_p-1:0] idx_w_r;
logic correct_r, w_v_r;
bsg_dff
 #(.width_p(2+bht_idx_width_p))
 write_reg
  (.clk_i(clk_i)

   ,.data_i({correct_i, w_v_i, idx_w_i})
   ,.data_o({correct_r, w_v_r, idx_w_r})
   );

if (debug_p)
  begin
     always_ff @(negedge clk_i)
       begin
         if (w_v_r | r_v_r)
	       $write("v=%b c=%b W[%h] (=%b); v=%b R[%h] (=%b) p=%b ",w_v_r,correct_r,idx_w_r,counter_mem[idx_w_r],r_v_r,idx_r_r,counter_mem[idx_r_r],predict_o);

	  if (w_v_r & ~correct_r)
	    $write("X\n");
	  else if (w_v_r | r_v_r)
	    $write("\n");
       end
end // if (debug_p)
//synopsys translate_on

endmodule
