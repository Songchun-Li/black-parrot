
module bp_burst_to_lite
 import bp_common_pkg::*;
 import bp_common_aviary_pkg::*;
 import bp_me_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)

   , parameter in_data_width_p  = "inv"
   , parameter out_data_width_p = "inv"
   , parameter payload_width_p  = "inv"

   // Bitmask which determines which message types have a data payload
   // Constructed as (1 << e_payload_msg1 | 1 << e_payload_msg2)
   , parameter int payload_mask_p = 0

   `declare_bp_bedrock_if_widths(paddr_width_p, payload_width_p, in_data_width_p, lce_id_width_p, lce_assoc_p, in)
   `declare_bp_bedrock_if_widths(paddr_width_p, payload_width_p, out_data_width_p, lce_id_width_p, lce_assoc_p, out)

   )
  (input                                     clk_i
   , input                                   reset_i

   // Master BP Burst
   // ready-valid-and
   , input [in_msg_header_width_lp-1:0]      in_msg_header_i
   , input                                   in_msg_header_v_i
   , output logic                            in_msg_header_ready_and_o

   // ready-valid-and
   , input [in_data_width_p-1:0]             in_msg_data_i
   , input                                   in_msg_data_v_i
   , output logic                            in_msg_data_ready_and_o

   // Client BP Lite
   // ready-valid-and
   , output logic [out_msg_width_lp-1:0]     out_msg_o
   , output logic                            out_msg_v_o
   , input                                   out_msg_ready_and_i
   );

  `declare_bp_bedrock_if(paddr_width_p, payload_width_p, in_data_width_p, lce_id_width_p, lce_assoc_p, in);
  `declare_bp_bedrock_if(paddr_width_p, payload_width_p, out_data_width_p, lce_id_width_p, lce_assoc_p, out);

  localparam in_data_bytes_lp = in_data_width_p/8;
  localparam out_data_bytes_lp = out_data_width_p/8;
  localparam burst_words_lp = out_data_width_p/in_data_width_p;
  localparam burst_offset_width_lp = `BSG_SAFE_CLOG2(out_data_bytes_lp);

  bp_bedrock_in_msg_header_s header_lo;
  logic header_v_r, header_clear;
  bsg_dff_en_bypass
   #(.width_p($bits(bp_bedrock_in_msg_header_s)))
   header_reg
    (.clk_i(clk_i)
    ,.en_i(in_msg_header_ready_and_o & in_msg_header_v_i)
    ,.data_i(in_msg_header_i)
    ,.data_o(header_lo)
    );

  bsg_dff_reset_set_clear
   #(.width_p(1)
   ,.clear_over_set_p(1))
    header_v_reg
    (.clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.set_i(in_msg_header_v_i)
    ,.clear_i(header_clear)
    ,.data_o(header_v_r) 
    );

  assign header_v_lo = in_msg_header_v_i | header_v_r;
  assign header_clear = out_msg_v_o & out_msg_ready_and_i;

  // Accept no new header as long as a valid header exists
  assign in_msg_header_ready_and_o = ~header_v_r; 

  localparam data_len_width_lp = `BSG_SAFE_CLOG2(burst_words_lp);

  logic [data_len_width_lp-1:0] num_burst_cmds;
  assign num_burst_cmds = `BSG_MAX(1, ((1'b1 << header_lo.size) / in_data_bytes_lp));

  logic [out_data_width_p-1:0] data_lo;
  logic data_v_lo;
  bsg_serial_in_parallel_out_passthrough_dynamic
   #(.width_p(in_data_width_p)
   ,.max_els_p(burst_words_lp))
   sipo_passthrough
    (.clk_i(clk_i)
    ,.reset_i(reset_i)

    ,.data_i(in_msg_data_i)
    ,.v_i(in_msg_data_v_i)
    ,.ready_and_o(in_msg_data_ready_and_o)
    ,.len_i(num_burst_cmds-1'b1)
   
    ,.data_o(data_lo)
    ,.v_o(data_v_lo)
    ,.ready_and_i(out_msg_ready_and_i)
    ,.first_o(/* unused */)
    );

  bp_bedrock_out_msg_s msg_cast_o;
  assign msg_cast_o = '{header: header_lo, data: data_lo};
  assign out_msg_o = msg_cast_o;
  wire has_data_out = payload_mask_p[header_lo.msg_type];
  assign out_msg_v_o = header_v_lo & (data_v_lo | ~has_data_out);

  //synopsys translate_off
  initial
    begin
      assert (in_data_width_p < out_data_width_p)
        else $error("Master data cannot be larger than client");
      assert (out_data_width_p % in_data_width_p == 0)
        else $error("Client data must be a multiple of master data");
    end

  always_ff @(negedge clk_i)
    begin
    //  if (in_msg_header_ready_and_o & in_msg_header_v_i)
    //    $display("[%t] Burst received: %p %x", $time, header_lo, in_msg_data_i);

    //  if (out_msg_ready_and_i & out_msg_v_o)
    //    $display("[%t] Msg sent: %p", $time, msg_cast_o);
    end
  //synopsys translate_on

endmodule

