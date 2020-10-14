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
  , input        [bp_bedrock_xce_mem_msg_header_width_lp-1:0] fsm_header_i
  , input        [stream_data_width_p-1:0]                    fsm_data_i
  , input                                                     fsm_v_i
  , output logic                                              fsm_yumi_o

  // control signals
  , output logic [data_len_width_lp-1:0]       cnt_o
  , output logic                               done_o
  );

  `declare_bp_bedrock_mem_if(paddr_width_p, stream_data_width_p, lce_id_width_p, lce_assoc_p, xce);
  
  `bp_cast_i(bp_bedrock_xce_mem_msg_header_s, fsm_header);
  `bp_cast_o(bp_bedrock_xce_mem_msg_header_s, mem_header);

  enum logic [1:0] {e_reset, e_single, e_stream, e_combine_stream} state_n, state_r;
  
  wire is_read_op  = fsm_header_cast_i.msg_type inside {e_bedrock_mem_uc_rd, e_bedrock_mem_rd};
  wire is_write_op = fsm_header_cast_i.msg_type inside {e_bedrock_mem_uc_wr, e_bedrock_mem_wr};
  wire has_data = payload_mask_p[fsm_header_cast_i.msg_type];
  wire [data_len_width_lp-1:0] num_stream = `BSG_MAX((1'b1 << fsm_header_cast_i.size) / (stream_data_width_p / 8), 1'b1);
  wire single_data_beat = (num_stream == data_len_width_lp'(1));

  wire set_cnt = ~single_data_beat & fsm_v_i & state_r inside {e_single};

  logic cnt_up, is_last_cnt;
  logic [data_len_width_lp-1:0] first_cnt, last_cnt, current_cnt;
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
  assign first_cnt = fsm_header_cast_i.addr[stream_offset_width_lp+:data_len_width_lp];
  assign last_cnt  = first_cnt + num_stream - 1'b1;
  
  assign cnt_o = set_cnt ? first_cnt : current_cnt;
  assign is_last_cnt = (cnt_o == last_cnt);

  always_comb 
    begin
      mem_header_cast_o = '0;
      mem_data_o = '0;
      mem_v_o = '0;
      mem_lock_o = '0;

      fsm_yumi_o = '0;
      cnt_up = '0; 
      done_o = '0;

      state_n = state_r;
      case (state_r)
        e_reset:
          begin
            state_n = e_single;
          end
        e_single:
          begin
            mem_header_cast_o = fsm_header_cast_i;
            mem_data_o = fsm_data_i;
            mem_lock_o = ~single_data_beat & has_data & fsm_v_i;
            mem_v_o = ~(is_write_op & ~single_data_beat & ~has_data) & fsm_v_i;

            cnt_up  = ~single_data_beat & ((has_data & mem_yumi_i) | (is_write_op & ~has_data & fsm_v_i));
            fsm_yumi_o = (is_write_op & ~has_data & ~single_data_beat) ? cnt_up : mem_yumi_i;
            done_o = mem_yumi_i & ~cnt_up;

            state_n = cnt_up ? e_stream : e_single;
          end
        e_stream:
          begin
            mem_header_cast_o = fsm_header_cast_i;
            mem_data_o = fsm_data_i;
            
            if (has_data)
              begin
                mem_header_cast_o.addr = { fsm_header_cast_i.addr[paddr_width_p-1:stream_offset_width_lp+data_len_width_lp]
                                        , cnt_o
                                        , fsm_header_cast_i.addr[0+:stream_offset_width_lp] };
                mem_v_o    = fsm_v_i;
                mem_lock_o = ~is_last_cnt;

                cnt_up     = mem_yumi_i;
                fsm_yumi_o = mem_yumi_i;
              end
            else
              begin
                mem_v_o = is_last_cnt & fsm_v_i;

                cnt_up     = fsm_v_i;
                fsm_yumi_o = is_last_cnt ?  mem_yumi_i : fsm_v_i;
              end

            done_o  = is_last_cnt & mem_yumi_i;
            state_n = done_o ? e_single : e_stream;
          end
      endcase
    end

  // synopsys sync_set_reset "reset_i"
  always_ff @(posedge clk_i)
    if (reset_i)
      state_r <= e_reset;
    else
      state_r <= state_n;

endmodule