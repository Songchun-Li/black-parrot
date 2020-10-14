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
  , output logic [bp_bedrock_xce_mem_msg_header_width_lp-1:0] fsm_header_o
  , output logic [stream_data_width_p-1:0]                    fsm_data_o
  , output logic                                              fsm_v_o
  , input                                                     fsm_yumi_i

  // control signals
  , output logic [paddr_width_p-1:0]           fsm_addr_o
  , output logic                               new_o
  , output logic                               done_o
  );

  `declare_bp_bedrock_mem_if(paddr_width_p, stream_data_width_p, lce_id_width_p, lce_assoc_p, xce);
  
  `bp_cast_o(bp_bedrock_xce_mem_msg_header_s, fsm_header);

  enum logic [1:0] {e_reset, e_single, e_stream} state_n, state_r;

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

  wire is_read_op  = mem_header_lo.msg_type inside {e_bedrock_mem_uc_rd, e_bedrock_mem_rd};
  wire is_write_op = mem_header_lo.msg_type inside {e_bedrock_mem_uc_wr, e_bedrock_mem_wr};
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
  assign first_cnt = fsm_header_cast_o.addr[stream_offset_width_lp+:data_len_width_lp];
  assign last_cnt  = first_cnt + num_stream - 1'b1;
  
  logic [data_len_width_lp-1:0] cnt_o;
  assign cnt_o = new_o ? first_cnt : current_cnt;
  assign is_last_cnt = (cnt_o == last_cnt);

  logic [block_offset_width_lp-1:0] critical_addr, critical_addr_r;
  assign critical_addr = mem_header_lo.addr[0+:block_offset_width_lp];

  // store this addr for stream state
  bsg_dff_en 
   #(.width_p(block_offset_width_lp))
   critical_addr_reg
    (.clk_i(clk_i)
    ,.data_i(critical_addr)
    ,.en_i(new_o)
    ,.data_o(critical_addr_r)
    );

  always_comb 
    begin
      mem_yumi_li  = '0;

      fsm_header_cast_o = '0;
      fsm_data_o = '0;
      fsm_v_o = '0;

      fsm_addr_o = '0;
      new_o = '0;
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
            // handle message size < stream_data_width_p & write response w/o data payload
            fsm_header_cast_o = mem_header_lo;
            fsm_data_o = mem_data_lo;
            fsm_v_o = mem_v_lo;

            mem_yumi_li = ~(is_read_op & ~mem_lock_lo & ~has_data & ~single_data_beat) & fsm_yumi_i;
            new_o = ~single_data_beat & ~(is_write_op & ~has_data) & fsm_yumi_i; 
            done_o = fsm_yumi_i & ~new_o; // used for UCE to send credits return
            cnt_up = new_o;
            state_n = new_o ? e_stream : e_single;
          end
        e_stream:
          begin
            // handle message size > stream_data_width_p w/ data payload or commands reading more than data than stream_data_width_p
            fsm_header_cast_o = mem_header_lo;
            fsm_header_cast_o.addr[0+:block_offset_width_lp] = critical_addr_r; // keep the address to be the critical word address
            fsm_data_o = mem_data_lo;
            fsm_v_o = mem_v_lo;

            fsm_addr_o = { mem_header_lo.addr[paddr_width_p-1:stream_offset_width_lp+data_len_width_lp]
                         , cnt_o
                         , mem_header_lo.addr[0+:stream_offset_width_lp]};

            cnt_up = fsm_yumi_i;
            done_o = is_last_cnt & fsm_yumi_i;
            mem_yumi_li = (is_read_op & ~mem_lock_lo & ~has_data) ? done_o : fsm_yumi_i;
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

    // TODO: assertion to identify whether critical_addr is aligned to the bus_data_width/burst_width

endmodule