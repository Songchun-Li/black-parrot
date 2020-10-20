module bp_stream_pump_in
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
   , localparam block_offset_width_lp = `BSG_SAFE_CLOG2(block_width_p >> 3)

   , localparam stream_words_lp = block_width_p / stream_data_width_p
   , localparam data_len_width_lp = `BSG_SAFE_CLOG2(stream_words_lp)
   , localparam stream_offset_width_lp = `BSG_SAFE_CLOG2(stream_data_width_p / 8)
   )
  ( input clk_i
  , input reset_i

  // bus side
  , input         [bp_bedrock_xce_mem_msg_header_width_lp-1:0] mem_header_i
  , input         [stream_data_width_p-1:0]                    mem_data_i
  , input                                                      mem_v_i
  , input                                                      mem_lock_i
  , output logic                                               mem_ready_o
  
  // FSM side
  , output logic [bp_bedrock_xce_mem_msg_header_width_lp-1:0] fsm_base_header_o
  , output logic [paddr_width_p-1:0]                          fsm_addr_o
  , output logic [stream_data_width_p-1:0]                    fsm_data_o
  , output logic                                              fsm_v_o
  , input                                                     fsm_yumi_i

  // control signals
  , output logic                               new_o
  , output logic                               done_o
  );

  `declare_bp_bedrock_mem_if(paddr_width_p, stream_data_width_p, lce_id_width_p, lce_assoc_p, xce);
  
  `bp_cast_o(bp_bedrock_xce_mem_msg_header_s, fsm_base_header);

  bp_bedrock_xce_mem_msg_header_s mem_header_lo;
  logic [stream_data_width_p-1:0] mem_data_lo;
  logic mem_v_lo, mem_yumi_li, mem_lock_lo;

  bsg_two_fifo
   #(.width_p($bits(bp_bedrock_xce_mem_msg_s)+1))
   input_fifo
    (.clk_i(clk_i)
      ,.reset_i(reset_i)

      ,.data_i({mem_lock_i, mem_header_i, mem_data_i})
      ,.v_i(mem_v_i)
      ,.ready_o(mem_ready_o)

      ,.data_o({mem_lock_lo, mem_header_lo, mem_data_lo})
      ,.v_o(mem_v_lo)
      ,.yumi_i(mem_yumi_li)
      );

  wire is_master = (payload_mask_p == mem_resp_payload_mask_gp);
  wire has_data = payload_mask_p[mem_header_lo.msg_type];
  wire [data_len_width_lp-1:0] num_stream = `BSG_MAX((1'b1 << mem_header_lo.size) / (stream_data_width_p / 8), 1'b1);
  wire single_data_beat = (num_stream == data_len_width_lp'(1));
  
  logic cnt_up, is_last_cnt;
  logic [data_len_width_lp-1:0] first_cnt, last_cnt, current_cnt;
  bsg_counter_set_en
   #(.max_val_p(stream_words_lp-1), .reset_val_p(0))
   data_counter
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.set_i(new_o) 
     ,.en_i(cnt_up)
     ,.val_i(first_cnt + 1'b1)
     ,.count_o(current_cnt)
     );
  assign first_cnt = fsm_base_header_cast_o.addr[stream_offset_width_lp+:data_len_width_lp];
  assign last_cnt  = first_cnt + num_stream - 1'b1;
  
  logic [data_len_width_lp-1:0] cnt_o;
  assign cnt_o = new_o ? first_cnt : current_cnt;
  assign is_last_cnt = (cnt_o == last_cnt);

  logic [block_offset_width_lp-1:0] critical_addr, critical_addr_r;
  assign critical_addr = mem_header_lo.addr[0+:block_offset_width_lp];

  // store this addr for stream state
  bsg_dff_en_bypass 
   #(.width_p(block_offset_width_lp))
   critical_addr_reg
    (.clk_i(clk_i)
    ,.data_i(critical_addr)
    ,.en_i(new_o)
    ,.data_o(critical_addr_r)
    );

  logic ready_r;
  bsg_dff_reset_en
   #(.width_p(1))
   ready_reg
    (.clk_i(clk_i)
    ,.reset_i(reset_i | (cnt_up & ~done_o))
    ,.en_i(done_o)
    ,.data_i(done_o)
    ,.data_o(ready_r)
    );

  logic is_single, is_stream;
  always_comb
    begin
      fsm_base_header_cast_o = mem_header_lo;
      fsm_data_o = mem_data_lo;
      fsm_v_o = mem_v_lo;
      if (single_data_beat | (is_master & ~has_data))
          begin
            is_single = 1'b1;
            is_stream = 1'b0;
            // handle message size < stream_data_width_p & write response w/o data payload
            fsm_addr_o = '0;
            
            mem_yumi_li = fsm_yumi_i;

            new_o = '0;
            cnt_up = '0;
            done_o = fsm_yumi_i; // used for UCE to send credits return
          end
        else
          begin
            is_single = 1'b0;
            is_stream = 1'b1;
            // handle message size > stream_data_width_p w/ data payload or commands reading more than data than stream_data_width_p
            fsm_base_header_cast_o.addr[0+:block_offset_width_lp] = critical_addr_r; // keep the address to be the critical word address
            fsm_addr_o = { mem_header_lo.addr[paddr_width_p-1:stream_offset_width_lp+data_len_width_lp]
                         , cnt_o
                         , mem_header_lo.addr[0+:stream_offset_width_lp]};        

            new_o =  fsm_yumi_i & ready_r;
            cnt_up = fsm_yumi_i;
            done_o = is_last_cnt & fsm_yumi_i;

            mem_yumi_li =  has_data ? fsm_yumi_i : done_o;
          end
    end
    // TODO: assertion to identify whether critical_addr is aligned to the bus_data_width/burst_width

endmodule