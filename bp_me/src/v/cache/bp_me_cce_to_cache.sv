/*
 * bp_me_cce_to_cache.v
 *
 */

`include "bp_common_defines.svh"
`include "bp_me_defines.svh"

module bp_me_cce_to_cache

  import bp_common_pkg::*;
  import bp_me_pkg::*;
  import bsg_cache_pkg::*;

  #(parameter bp_params_e bp_params_p = e_bp_default_cfg
    `declare_bp_proc_params(bp_params_p)
    `declare_bp_bedrock_mem_if_widths(paddr_width_p, cce_block_width_p, lce_id_width_p, lce_assoc_p, cce)

    , localparam lg_sets_lp=`BSG_SAFE_CLOG2(l2_sets_p)
    , localparam lg_ways_lp=`BSG_SAFE_CLOG2(l2_assoc_p)
    , localparam word_offset_width_lp=`BSG_SAFE_CLOG2(l2_block_size_in_words_p)
    , localparam data_mask_width_lp=(l2_data_width_p>>3)
    , localparam byte_offset_width_lp=`BSG_SAFE_CLOG2(l2_data_width_p>>3)
    , localparam block_offset_width_lp=(word_offset_width_lp+byte_offset_width_lp)

    , localparam bsg_cache_pkt_width_lp=`bsg_cache_pkt_width(caddr_width_p, l2_data_width_p)
    , localparam counter_width_lp=`BSG_SAFE_CLOG2(l2_block_size_in_fill_p)
  )
  (
    input clk_i
    , input reset_i

    // manycore-side
    , input  [cce_mem_msg_width_lp-1:0]   mem_cmd_i
    , input                               mem_cmd_v_i
    , output logic                        mem_cmd_ready_and_o

    , output [cce_mem_msg_width_lp-1:0]   mem_resp_o
    , output logic                        mem_resp_v_o
    , input                               mem_resp_yumi_i

    // cache-side
    , output [bsg_cache_pkt_width_lp-1:0] cache_pkt_o
    , output logic                        v_o
    , input                               ready_i

    , input [l2_data_width_p-1:0]         data_i
    , input                               v_i
    , output logic                        yumi_o
  );

  // at the reset, this module intializes all the tags and valid bits to zero.
  // After all the tags are completedly initialized, this module starts
  // accepting packets from manycore network.
  `declare_bsg_cache_pkt_s(caddr_width_p, l2_data_width_p);

  // cce logics
  `declare_bp_bedrock_mem_if(paddr_width_p, cce_block_width_p, lce_id_width_p, lce_assoc_p, cce);
  `declare_bp_memory_map(paddr_width_p, caddr_width_p);

  bsg_cache_pkt_s cache_pkt;
  assign cache_pkt_o = cache_pkt;

  typedef enum logic [1:0] {
    RESET
    ,CLEAR_TAG
    ,READY
    ,SEND
  } cmd_state_e;

  cmd_state_e cmd_state_r, cmd_state_n;
  logic [lg_sets_lp+lg_ways_lp:0] tagst_sent_r, tagst_sent_n;
  logic [lg_sets_lp+lg_ways_lp:0] tagst_received_r, tagst_received_n;
  logic [counter_width_lp-1:0] cmd_counter_r, cmd_counter_n;
  logic [counter_width_lp-1:0] cmd_max_count_r, cmd_max_count_n;

  bp_bedrock_cce_mem_msg_s mem_cmd_cast_i, mem_resp_cast_o;

  assign mem_cmd_cast_i = mem_cmd_i;
  assign mem_resp_o = mem_resp_cast_o;
  
  // TODO the size can be shrink
  bp_bedrock_cce_mem_msg_s mem_cmd_lo;
  logic mem_cmd_v_lo, mem_cmd_yumi_li;
  bsg_fifo_1r1w_small
   #(.width_p(cce_mem_msg_width_lp), .els_p(l2_outstanding_reqs_p))
   cmd_fifo
    (.clk_i(clk_i)
    ,.reset_i(reset_i)

    ,.data_i(mem_cmd_i)
    ,.v_i(mem_cmd_v_i)
    ,.ready_o(mem_cmd_ready_and_o)

    ,.data_o(mem_cmd_lo)
    ,.v_o(mem_cmd_v_lo)
    ,.yumi_i(mem_cmd_yumi_li)
    );
  wire [caddr_width_p-1:0] cmd_addr = mem_cmd_lo.header.addr;
  wire [l2_block_size_in_words_p-1:0][l2_data_width_p-1:0] cmd_data = mem_cmd_lo.data;

  // synopsys sync_set_reset "reset_i"
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      cmd_state_r      <= RESET;
      tagst_sent_r     <= '0;
      tagst_received_r <= '0;
      cmd_counter_r    <= '0;
    end
    else begin
      cmd_state_r      <= cmd_state_n;
      tagst_sent_r     <= tagst_sent_n;
      tagst_received_r <= tagst_received_n;
      cmd_counter_r    <= cmd_counter_n;
    end
  end

  // new resp count control
  logic max_cnt_en_li;
  bsg_dff_en_bypass
   #(.width_p(counter_width_lp))
   cmd_max_count_reg
    (.clk_i(clk_i)
    ,.en_i(max_cnt_en_li) // key: when to update the max
    ,.data_i(cmd_max_count_n)
    ,.data_o(cmd_max_count_r)
    );
  

  bp_local_addr_s local_addr_cast;
  assign local_addr_cast = mem_cmd_lo.header.addr;

  wire cmd_word_op = (mem_cmd_lo.header.size == e_bedrock_msg_size_4);

  // Control logic for resp header
  logic mem_resp_header_v_li, mem_resp_header_ready_lo;
  logic mem_resp_header_v_lo, mem_resp_header_yumi_li;
  logic is_clear_tag;

  always_comb begin
    cache_pkt.mask = '0;
    cache_pkt.data = '0;
    cache_pkt.addr = '0;
    cache_pkt.opcode = TAGST;
    tagst_sent_n = tagst_sent_r;
    tagst_received_n = tagst_received_r;
    v_o = 1'b0;

    is_clear_tag = 1'b0;
    mem_cmd_yumi_li = 1'b0;

    cmd_state_n = cmd_state_r;
    cmd_counter_n = cmd_counter_r;
    cmd_max_count_n = '0;
    max_cnt_en_li = 1'b0;

    mem_resp_header_v_li = '0;

    case (cmd_state_r)
      RESET: begin
        cmd_state_n = CLEAR_TAG;
      end
      CLEAR_TAG: begin
        v_o = tagst_sent_r != (l2_assoc_p*l2_sets_p);

        cache_pkt.opcode = TAGST;
        cache_pkt.data = '0;
        cache_pkt.addr = {
          {(caddr_width_p-lg_sets_lp-lg_ways_lp-block_offset_width_lp){1'b0}},
          tagst_sent_r[0+:lg_sets_lp+lg_ways_lp],
          {(block_offset_width_lp){1'b0}}
        };

        tagst_sent_n = (v_o & ready_i)
          ? tagst_sent_r + 1
          : tagst_sent_r;
        tagst_received_n = v_i
          ? tagst_received_r + 1
          : tagst_received_r;

        cmd_state_n = (tagst_sent_r == l2_assoc_p*l2_sets_p) & (tagst_received_r == l2_assoc_p*l2_sets_p)
          ? READY
          : CLEAR_TAG;
        is_clear_tag = 1'b1;
      end
      READY: begin
        // Technically possible to bypass and save a cycle
        if (mem_cmd_v_lo & mem_resp_header_ready_lo)
          begin
            case (mem_cmd_lo.header.size)
              e_bedrock_msg_size_1
              ,e_bedrock_msg_size_2
              ,e_bedrock_msg_size_4
              ,e_bedrock_msg_size_8: cmd_max_count_n = '0;
              e_bedrock_msg_size_16: cmd_max_count_n = counter_width_lp'(1);
              e_bedrock_msg_size_32: cmd_max_count_n = counter_width_lp'(3);
              e_bedrock_msg_size_64: cmd_max_count_n = counter_width_lp'(7);
              default: cmd_max_count_n = '0;
            endcase
            max_cnt_en_li = 1'b1;
            mem_resp_header_v_li = 1'b1;
            cmd_state_n = SEND;
          end
      end
      SEND: begin
        v_o = 1'b1;
        case (mem_cmd_lo.header.msg_type)
          e_bedrock_mem_rd
          ,e_bedrock_mem_uc_rd:
            case (mem_cmd_lo.header.size)
              e_bedrock_msg_size_1: cache_pkt.opcode = LB;
              e_bedrock_msg_size_2: cache_pkt.opcode = LH;
              e_bedrock_msg_size_4: cache_pkt.opcode = LW;
              e_bedrock_msg_size_8
              ,e_bedrock_msg_size_16
              ,e_bedrock_msg_size_32
              ,e_bedrock_msg_size_64: cache_pkt.opcode = LM;
              default: cache_pkt.opcode = LB;
            endcase
          e_bedrock_mem_uc_wr
          ,e_bedrock_mem_wr
          ,e_bedrock_mem_amo:
            case (mem_cmd_lo.header.size)
              e_bedrock_msg_size_1: cache_pkt.opcode = SB;
              e_bedrock_msg_size_2: cache_pkt.opcode = SH;
              e_bedrock_msg_size_4, e_bedrock_msg_size_8:
                case (mem_cmd_lo.header.subop)
                  e_bedrock_store  : cache_pkt.opcode = cmd_word_op ? SW : SD;
                  e_bedrock_amoswap: cache_pkt.opcode = cmd_word_op ? AMOSWAP_W : AMOSWAP_D;
                  e_bedrock_amoadd : cache_pkt.opcode = cmd_word_op ? AMOADD_W : AMOADD_D;
                  e_bedrock_amoxor : cache_pkt.opcode = cmd_word_op ? AMOXOR_W : AMOXOR_D;
                  e_bedrock_amoand : cache_pkt.opcode = cmd_word_op ? AMOAND_W : AMOAND_D;
                  e_bedrock_amoor  : cache_pkt.opcode = cmd_word_op ? AMOOR_W : AMOOR_D;
                  e_bedrock_amomin : cache_pkt.opcode = cmd_word_op ? AMOMIN_W : AMOMIN_D;
                  e_bedrock_amomax : cache_pkt.opcode = cmd_word_op ? AMOMAX_W : AMOMAX_D;
                  e_bedrock_amominu: cache_pkt.opcode = cmd_word_op ? AMOMINU_W : AMOMINU_D;
                  e_bedrock_amomaxu: cache_pkt.opcode = cmd_word_op ? AMOMAXU_W : AMOMAXU_D;
                  default : begin end
                endcase
              e_bedrock_msg_size_16
              ,e_bedrock_msg_size_32
              ,e_bedrock_msg_size_64: cache_pkt.opcode = SM;
              default: cache_pkt.opcode = LB;
            endcase
          default: cache_pkt.opcode = LB;
        endcase

        if ((mem_cmd_lo.header.addr < dram_base_addr_gp) && (local_addr_cast.dev == cache_tagfl_base_addr_gp))
          begin
            cache_pkt.opcode = TAGFL;
            cache_pkt.addr = {cmd_data[0][0+:lg_sets_lp+lg_ways_lp], block_offset_width_lp'(0)};
          end
        else
          begin
            cache_pkt.data = cmd_data[cmd_counter_r];
            cache_pkt.addr = cmd_addr + cmd_counter_r*data_mask_width_lp;
            cache_pkt.mask = '1;
          end

        if (ready_i)
          begin
            cmd_counter_n = cmd_counter_r + 1;
            if (cmd_counter_r == cmd_max_count_r)
              begin
                cmd_counter_n = '0;
                cmd_state_n = READY;
                mem_cmd_yumi_li = 1'b1;
              end
          end
      end
    endcase
  end

  bsg_fifo_1r1w_small
   #(.width_p(cce_mem_msg_header_width_lp), .els_p(2))
   resp_header_fifo
    (.clk_i(clk_i)
    ,.reset_i(reset_i)

    ,.data_i(mem_cmd_lo.header)
    ,.v_i(mem_resp_header_v_li)
    ,.ready_o(mem_resp_header_ready_lo)

    ,.data_o(mem_resp_cast_o.header)
    ,.v_o(mem_resp_header_v_lo)
    ,.yumi_i(mem_resp_header_yumi_li)
    );
  assign mem_resp_header_yumi_li = mem_resp_yumi_i;

  logic [counter_width_lp-1:0] resp_counter_r, resp_counter_n;
  logic [counter_width_lp-1:0] resp_max_count_r, resp_max_count_n;
  logic [l2_block_size_in_words_p-1:0] resp_data_en;
  logic [l2_block_size_in_words_p-1:0][l2_data_width_p-1:0] resp_data_r;
  logic resp_busy_r;

  // synopsys sync_set_reset "reset_i"
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      resp_counter_r    <= '0;
    end
    else begin
      resp_counter_r    <= resp_counter_n;
    end
  end

  bsg_dff_reset_set_clear
   #(.width_p(1)
   ,.clear_over_set_p(1))
    resp_busy_reg
    (.clk_i(clk_i)
    ,.reset_i(reset_i | is_clear_tag)
    ,.set_i(yumi_o)
    ,.clear_i(mem_resp_yumi_i)
    ,.data_o(resp_busy_r)
    );
  
  bsg_dff_en_bypass
   #(.width_p(counter_width_lp))
   resp_max_count_reg
    (.clk_i(clk_i)
    ,.en_i(mem_resp_header_v_lo & ~resp_busy_r) // TOCHECK can be opt out?
    ,.data_i(resp_max_count_n)
    ,.data_o(resp_max_count_r)
    );

  // This is register is used to identify whether data is ready and 
  // set barrier between data for different request.
  logic resp_data_done_li, resp_data_done_r;
  bsg_dff_reset_set_clear
   #(.width_p(1)
   ,.clear_over_set_p(1)
   )
   resp_data_done_reg
    (.clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.set_i(resp_data_done_li)
    ,.clear_i(mem_resp_yumi_i)
    ,.data_o(resp_data_done_r)
    );

  bsg_decode 
   #(.num_out_p(l2_block_size_in_words_p))
   resp_count_decode
    (.i(resp_counter_r)
    ,.o(resp_data_en)
    );

  for (genvar i = 0; i < 8; i++)
    begin : data_slice
      bsg_dff_en_bypass
       #(.width_p(l2_data_width_p))
       resp_data_reg
        (.clk_i(clk_i)
        ,.en_i(resp_data_en[i] & yumi_o)
        ,.data_i(data_i)
        ,.data_o(resp_data_r[i])
        );
    end

  wire [cce_block_width_p-1:0] resp_data_slice = resp_data_r;
  bsg_bus_pack
   #(.width_p(cce_block_width_p))
   repl_mux
    (.data_i(resp_data_slice)
     // Response data is always aggregated from zero in this module
     ,.sel_i('0)
     ,.size_i(mem_resp_cast_o.header.size)
     ,.data_o(mem_resp_cast_o.data)
     );

  assign yumi_o = is_clear_tag ? v_i : v_i & ~resp_data_done_r; // cache "acks" TAGST commands with zero-data responses
  always_comb begin
    resp_counter_n = '0;
    resp_max_count_n = '0;

    resp_data_done_li = 1'b0;
    mem_resp_v_o = 1'b0;

    if (~is_clear_tag)
      begin
        case (mem_resp_cast_o.header.size)
          e_bedrock_msg_size_1
          ,e_bedrock_msg_size_2
          ,e_bedrock_msg_size_4
          ,e_bedrock_msg_size_8: resp_max_count_n = '0;
          e_bedrock_msg_size_16: resp_max_count_n = counter_width_lp'(1);
          e_bedrock_msg_size_32: resp_max_count_n = counter_width_lp'(3);
          e_bedrock_msg_size_64: resp_max_count_n = counter_width_lp'(7);
          default: resp_max_count_n = '0;
        endcase
        resp_data_done_li = (resp_counter_r == resp_max_count_r) & yumi_o;
        // valid mem_resp when all the data and header is ready
        mem_resp_v_o = mem_resp_header_v_lo & (resp_data_done_li | resp_data_done_r);
        // mem_resp is sent
        resp_counter_n = mem_resp_yumi_i ? '0 : resp_counter_r + yumi_o;
      end
  end
  
  //synopsys translate_off
  always_ff @(negedge clk_i)
    begin
      if (mem_cmd_v_lo & mem_cmd_lo.header.msg_type inside {e_bedrock_mem_wr, e_bedrock_mem_uc_wr})
        assert (~(mem_cmd_lo.header.subop inside {e_bedrock_amolr, e_bedrock_amosc}))
          else $error("LR/SC not supported in bsg_cache");
    end
  //synopsys translate_on


endmodule
