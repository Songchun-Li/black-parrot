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
module bp_fe_bht_2bit
 import bp_fe_pkg::*;
 #(parameter vaddr_width_p = "inv"
   , parameter bht_idx_width_p = "inv"

   , parameter debug_p             = 0

   , localparam els_lp             = 2**bht_idx_width_p
   , localparam saturation_size_lp = 2
   , localparam mem_width_lp       = saturation_size_lp * 4
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


  logic [els_lp-1:0][mem_width_lp-1:0] counter_mem;
  logic [els_lp-1:0][1:0] history_mem;
  logic [els_lp-1:0] last_predict_mem;

  logic [mem_width_lp-1:0] counter_mem_read_data;
  logic [saturation_size_lp-1:0] targeted_counter;
  logic [1:0] history_mem_read_data, history_mem_read_data_old, history_mem_write_data;

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
   counter_mem_read_data = counter_mem[idx_r_r];
   history_mem_read_data = history_mem[idx_r_r];
  end

  bsg_mux #(
    .width_p(saturation_size_lp)
    ,.els_p(4)
    ) targeted_counter_mux
    (.data_i(counter_mem_read_data)
     ,.sel_i(history_mem_read_data)
     ,.data_o(targeted_counter)
     );

  assign predict_o = r_v_r ? targeted_counter[1] : 1'b0;

  // store the predict result for updating use
  always_ff @(posedge clk_i) begin
    if (reset_i)
      last_predict_mem <= '{default:1'b0};
    else if (r_v_r)
      last_predict_mem[idx_r_r] <= predict_o;
  end

  //2-bit saturating counter(high_bit:prediction direction,low_bit:strong/weak prediction)
  //10: Strongly taken
  //11: Weakly taken
  //01: Weakly not taken
  //00: Strongly not taken
  logic [mem_width_lp-1:0] counter_mem_read_data_old;
  logic [3:0][saturation_size_lp-1:0] counter_mem_write_data;
  logic [saturation_size_lp-1:0] counter_mem_update, counter_mem_read_data_target;
  // update the history memory with the true result from correctness signal and last prediction
  assign history_mem_read_data_old = history_mem[idx_w_i];
  assign history_mem_write_data = {history_mem_read_data_old[0], (last_predict_mem[idx_w_i] ^~ correct_i)};
  always_ff @(posedge clk_i) begin
    if (reset_i)
      history_mem <= '{default:2'b11};
    else if (w_v_i)
      history_mem[idx_w_i] <= history_mem_write_data;
  end

  bsg_mux #(
    .width_p(saturation_size_lp)
    ,.els_p(4)
    ) counter_updating_mux
    (.data_i(counter_mem_read_data_old)
     ,.sel_i(history_mem_read_data_old)
     ,.data_o(counter_mem_read_data_target)
     );

  always_comb begin
    counter_mem_read_data_old = counter_mem[idx_w_i];
    if (correct_i)
      begin
      counter_mem_update = {counter_mem_read_data_target[1], 1'b0};
    end
    else if (~correct_i)
      begin
      counter_mem_update = {counter_mem_read_data_target[1]^counter_mem_read_data_target[0], 1'b1};
    end

    case(history_mem_read_data_old)
      2'b00: // update counter0
        begin
          counter_mem_write_data[0] = counter_mem_update;
          counter_mem_write_data[1] = counter_mem_read_data_old[1];
          counter_mem_write_data[2] = counter_mem_read_data_old[2];
          counter_mem_write_data[3] = counter_mem_read_data_old[3];
        end
      2'b01: // update counter1
        begin
          counter_mem_write_data[0] = counter_mem_read_data_old[0];
          counter_mem_write_data[1] = counter_mem_update;
          counter_mem_write_data[2] = counter_mem_read_data_old[2];
          counter_mem_write_data[3] = counter_mem_read_data_old[3];
        end
      2'b10: // update counter2
        begin
          counter_mem_write_data[0] = counter_mem_read_data_old[0];
          counter_mem_write_data[1] = counter_mem_read_data_old[1];
          counter_mem_write_data[2] = counter_mem_update;
          counter_mem_write_data[3] = counter_mem_read_data_old[3];
        end
      2'b11: // update counter3
        begin
          counter_mem_write_data[0] = counter_mem_read_data_old[0];
          counter_mem_write_data[1] = counter_mem_read_data_old[1];
          counter_mem_write_data[2] = counter_mem_read_data_old[2];
          counter_mem_write_data[3] = counter_mem_update;
        end
    endcase
  end

  always_ff @(posedge clk_i)  begin
    if (reset_i)
      counter_mem <= '{default:8'b01010101};
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
