module bp_stream_pump_out
 import bp_cce_pkg::*;
 import bp_common_pkg::*;
 import bp_common_aviary_pkg::*;
 import bp_me_pkg::*;
 import bsg_cache_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)

   , parameter stream_data_width_p = dword_width_p
   , parameter block_width_p = cce_block_width_p

   // Bitmask which determines which message types have a data payload
   // Constructed as (1 << e_payload_msg1 | 1 << e_payload_msg2)
   , parameter payload_mask_p = 0

   `declare_bp_bedrock_mem_if_widths(paddr_width_p, stream_data_width_p, lce_id_width_p, lce_assoc_p, xce)

   , localparam stream_words_lp = block_width_p / stream_data_width_p
   , localparam data_len_width_lp = `BSG_SAFE_CLOG2(stream_words_lp)
   , localparam stream_offset_width_lp = `BSG_SAFE_CLOG2(stream_data_width_p / 8)
   )
  ( input clk_i
  , input reset_i

  // bus side
  , output logic [bp_bedrock_xce_mem_msg_header_width_lp-1:0] mem_header_o
  , output logic [stream_data_width_p-1:0]                    mem_data_o
  , output logic                                              mem_v_o
  , output logic                                              mem_lock_o
  , input                                                     mem_yumi_i
  
  // FSM side
  , input        [bp_bedrock_xce_mem_msg_header_width_lp-1:0] fsm_base_header_i
  , input        [stream_data_width_p-1:0]                    fsm_data_i
  , input                                                     fsm_v_i
  , output logic                                              fsm_yumi_o

  // control signals
  , output logic [data_len_width_lp-1:0]       cnt_o
  , output logic                               done_o
  );

  `declare_bp_bedrock_mem_if(paddr_width_p, stream_data_width_p, lce_id_width_p, lce_assoc_p, xce);
  
  `bp_cast_i(bp_bedrock_xce_mem_msg_header_s, fsm_base_header);
  `bp_cast_o(bp_bedrock_xce_mem_msg_header_s, mem_header);

  enum logic [1:0] {e_reset, e_single, e_stream} state_n, state_r;
  
  wire is_master = (payload_mask_p == mem_cmd_payload_mask_gp);
  wire has_data = payload_mask_p[fsm_base_header_cast_i.msg_type];
  wire [data_len_width_lp-1:0] num_stream = `BSG_MAX((1'b1 << fsm_base_header_cast_i.size) / (stream_data_width_p / 8), 1'b1);
  wire single_data_beat = (num_stream == data_len_width_lp'(1));

  logic ready_r, cnt_up, is_last_cnt;
  logic [data_len_width_lp-1:0] first_cnt, last_cnt, current_cnt;

  bsg_dff_reset_en
   #(.width_p(1))
   streaming_reg
    (.clk_i(clk_i)
    ,.reset_i(reset_i | (cnt_up & ~done_o))
    ,.en_i(done_o)
    ,.data_i(done_o)
    ,.data_o(ready_r)
    );
  wire set_cnt = ~single_data_beat & fsm_v_i & ready_r;

  bsg_counter_set_en
   #(.max_val_p(stream_words_lp-1), .reset_val_p(0))
   data_counter
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.set_i(set_cnt) 
     ,.en_i(cnt_up)
     ,.val_i(first_cnt + 1'b1)
     ,.count_o(current_cnt)
     );
  assign first_cnt = fsm_base_header_cast_i.addr[stream_offset_width_lp+:data_len_width_lp];
  assign last_cnt  = first_cnt + num_stream - 1'b1;
  
  assign cnt_o = set_cnt ? first_cnt : current_cnt;
  assign is_last_cnt = (cnt_o == last_cnt);


  logic is_single, is_stream;
  always_comb 
    begin
      mem_header_cast_o = fsm_base_header_cast_i;
      mem_data_o = fsm_data_i;
      mem_v_o = fsm_v_i;

      if (single_data_beat | (is_master & ~has_data))
        begin
          is_single = 1'b1;
          is_stream = 1'b0;
          // handle message size < stream_data_width_p & read command w/o data payload
          mem_lock_o = '0;
          
          fsm_yumi_o = mem_yumi_i;

          cnt_up  = '0;       
          done_o = mem_yumi_i;
        end
      else
        begin
          is_single = 1'b0;
          is_stream = 1'b1;
          
          if (has_data)
            begin
              // handle message size > stream_data_width_p w/ data payload
              mem_header_cast_o.addr = { fsm_base_header_cast_i.addr[paddr_width_p-1:stream_offset_width_lp+data_len_width_lp]
                                      , cnt_o
                                      , fsm_base_header_cast_i.addr[0+:stream_offset_width_lp] };
              mem_lock_o = ~is_last_cnt;

              cnt_up     = mem_yumi_i;
              fsm_yumi_o = mem_yumi_i;
            end
          else
            begin
              // handle message size > stream_data_width_p w/o data payload (combines write responses into one)
              mem_v_o = is_last_cnt & fsm_v_i;

              cnt_up     = fsm_v_i;
              fsm_yumi_o = is_last_cnt ?  mem_yumi_i : fsm_v_i;
            end

          done_o  = is_last_cnt & mem_yumi_i;
        end
    end

endmodule