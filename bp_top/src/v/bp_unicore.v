
module bp_unicore
 import bsg_wormhole_router_pkg::*;
 import bp_common_pkg::*;
 import bp_common_aviary_pkg::*;
 import bp_be_pkg::*;
 import bp_fe_pkg::*;
 import bp_common_rv64_pkg::*;
 import bp_me_pkg::*;
 import bp_cce_pkg::*;
 import bsg_noc_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
  
   , localparam uce_mem_data_width_lp = `BSG_MAX(icache_fill_width_p, dcache_fill_width_p) 
   `declare_bp_bedrock_mem_if_widths(paddr_width_p, cce_block_width_p, lce_id_width_p, lce_assoc_p, cce)
   `declare_bp_bedrock_mem_if_widths(paddr_width_p, uce_mem_data_width_lp, lce_id_width_p, lce_assoc_p, uce)
   )
  (  input                                             clk_i
   , input                                             reset_i

   // Outgoing I/O
   , output [bp_bedrock_uce_mem_msg_width_lp-1:0]      io_cmd_o
   , output                                            io_cmd_v_o
   , input                                             io_cmd_ready_i

   , input [bp_bedrock_uce_mem_msg_width_lp-1:0]       io_resp_i
   , input                                             io_resp_v_i
   , output                                            io_resp_yumi_o

   // Incoming I/O
   , input [bp_bedrock_uce_mem_msg_width_lp-1:0]       io_cmd_i
   , input                                             io_cmd_v_i
   , output                                            io_cmd_yumi_o

   , output [bp_bedrock_uce_mem_msg_width_lp-1:0]      io_resp_o
   , output                                            io_resp_v_o
   , input                                             io_resp_ready_i

   // Memory Requests
   , output logic [bp_bedrock_cce_mem_msg_header_width_lp-1:0] mem_cmd_header_o
   , output logic                                              mem_cmd_header_v_o
   , input                                                     mem_cmd_header_ready_i

   // Only supports dword width cache
   , output logic [dword_width_p-1:0]                   mem_cmd_data_o
   , output logic                                       mem_cmd_data_v_o
   , input                                              mem_cmd_data_ready_i

   , input [bp_bedrock_cce_mem_msg_header_width_lp-1:0] mem_resp_header_i
   , input                                              mem_resp_header_v_i
   , output                                             mem_resp_header_yumi_o

   // Only supports dword width cache
   , input [dword_width_p-1:0]                          mem_resp_data_i
   , input                                              mem_resp_data_v_i
   , output logic                                       mem_resp_data_yumi_o
   );

  `declare_bp_fe_be_if(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p);
  `declare_bp_cfg_bus_s(vaddr_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, cce_pc_width_p, cce_instr_width_p);

  `declare_bp_cache_service_if(paddr_width_p, ptag_width_p, dcache_sets_p, dcache_assoc_p, dword_width_p, dcache_block_width_p, dcache_fill_width_p, dcache);
  `declare_bp_cache_service_if(paddr_width_p, ptag_width_p, icache_sets_p, icache_assoc_p, dword_width_p, icache_block_width_p, icache_fill_width_p, icache);
  `declare_bp_bedrock_mem_if(paddr_width_p, uce_mem_data_width_lp, lce_id_width_p, lce_assoc_p, uce)
  `declare_bp_bedrock_mem_if(paddr_width_p, cce_block_width_p, lce_id_width_p, lce_assoc_p, cce)

  bp_dcache_req_s dcache_req_lo;
  bp_icache_req_s icache_req_lo;
  logic dcache_req_v_lo, dcache_req_ready_li;
  logic icache_req_v_lo, icache_req_ready_li;

  bp_dcache_req_metadata_s dcache_req_metadata_lo;
  bp_icache_req_metadata_s icache_req_metadata_lo;
  logic dcache_req_metadata_v_lo, icache_req_metadata_v_lo;

  bp_dcache_tag_mem_pkt_s dcache_tag_mem_pkt_li;
  bp_icache_tag_mem_pkt_s icache_tag_mem_pkt_li;
  logic dcache_tag_mem_pkt_v_li, dcache_tag_mem_pkt_yumi_lo;
  logic icache_tag_mem_pkt_v_li, icache_tag_mem_pkt_yumi_lo;
  logic [ptag_width_p-1:0] dcache_tag_mem_lo, icache_tag_mem_lo;

  bp_dcache_data_mem_pkt_s dcache_data_mem_pkt_li;
  bp_icache_data_mem_pkt_s icache_data_mem_pkt_li;
  logic dcache_data_mem_pkt_v_li, dcache_data_mem_pkt_yumi_lo;
  logic icache_data_mem_pkt_v_li, icache_data_mem_pkt_yumi_lo;
  logic [dcache_block_width_p-1:0] dcache_data_mem_lo;
  logic [icache_block_width_p-1:0] icache_data_mem_lo;

  bp_dcache_stat_mem_pkt_s dcache_stat_mem_pkt_li;
  bp_icache_stat_mem_pkt_s icache_stat_mem_pkt_li;
  logic dcache_stat_mem_pkt_v_li, dcache_stat_mem_pkt_yumi_lo;
  logic icache_stat_mem_pkt_v_li, icache_stat_mem_pkt_yumi_lo;
  bp_dcache_stat_info_s dcache_stat_mem_lo;
  bp_icache_stat_info_s icache_stat_mem_lo;

  logic dcache_req_complete_li, icache_req_complete_li;
  logic dcache_req_critical_li, icache_req_critical_li;

  logic [1:0] credits_full_li, credits_empty_li;
  logic timer_irq_li, software_irq_li, external_irq_li;

  bp_bedrock_uce_mem_msg_s [2:0] proc_cmd_lo;
  logic [2:0] proc_cmd_v_lo, proc_cmd_ready_li;

  bp_bedrock_uce_mem_msg_s [2:0] proc_resp_li;
  logic [2:0] proc_resp_v_li, proc_resp_ready_lo;
  logic [2:0] proc_cmd_lock_lo, proc_resp_lock_li;

  bp_bedrock_uce_mem_msg_s cfg_cmd_li;
  logic cfg_cmd_v_li, cfg_cmd_ready_lo;
  bp_bedrock_uce_mem_msg_s cfg_resp_lo;
  logic cfg_resp_v_lo, cfg_resp_yumi_li;

  bp_bedrock_uce_mem_msg_s clint_cmd_li;
  logic clint_cmd_v_li, clint_cmd_ready_lo;
  bp_bedrock_uce_mem_msg_s clint_resp_lo;
  logic clint_resp_v_lo, clint_resp_yumi_li;

  bp_bedrock_uce_mem_msg_s cache_cmd_li;
  logic cache_cmd_v_li, cache_cmd_ready_lo;
  bp_bedrock_uce_mem_msg_s cache_resp_lo;
  logic cache_resp_v_lo, cache_resp_yumi_li, cache_resp_lock_lo;

  bp_bedrock_uce_mem_msg_s loopback_cmd_li;
  logic loopback_cmd_v_li, loopback_cmd_ready_lo;
  bp_bedrock_uce_mem_msg_s loopback_resp_lo;
  logic loopback_resp_v_lo, loopback_resp_yumi_li;

  bp_cfg_bus_s cfg_bus_lo;
  bp_fe_queue_s fe_queue_li, fe_queue_lo;
  logic fe_queue_v_li, fe_queue_ready_lo;

  bp_fe_cmd_s fe_cmd_lo;
  logic fe_cmd_v_lo, fe_cmd_yumi_li;

  bp_fe_top
   #(.bp_params_p(bp_params_p))
   fe
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.cfg_bus_i(cfg_bus_lo)

     ,.fe_queue_o(fe_queue_li)
     ,.fe_queue_v_o(fe_queue_v_li)
     ,.fe_queue_ready_i(fe_queue_ready_lo)

     ,.fe_cmd_i(fe_cmd_lo)
     ,.fe_cmd_v_i(fe_cmd_v_lo)
     ,.fe_cmd_yumi_o(fe_cmd_yumi_li)

     ,.cache_req_o(icache_req_lo)
     ,.cache_req_v_o(icache_req_v_lo)
     ,.cache_req_ready_i(icache_req_ready_li)
     ,.cache_req_metadata_o(icache_req_metadata_lo)
     ,.cache_req_metadata_v_o(icache_req_metadata_v_lo)
     ,.cache_req_complete_i(icache_req_complete_li)
     ,.cache_req_critical_i(icache_req_critical_li)

     ,.data_mem_pkt_i(icache_data_mem_pkt_li)
     ,.data_mem_pkt_v_i(icache_data_mem_pkt_v_li)
     ,.data_mem_pkt_yumi_o(icache_data_mem_pkt_yumi_lo)
     ,.data_mem_o(icache_data_mem_lo)

     ,.tag_mem_pkt_i(icache_tag_mem_pkt_li)
     ,.tag_mem_pkt_v_i(icache_tag_mem_pkt_v_li)
     ,.tag_mem_pkt_yumi_o(icache_tag_mem_pkt_yumi_lo)
     ,.tag_mem_o(icache_tag_mem_lo)

     ,.stat_mem_pkt_v_i(icache_stat_mem_pkt_v_li)
     ,.stat_mem_pkt_i(icache_stat_mem_pkt_li)
     ,.stat_mem_pkt_yumi_o(icache_stat_mem_pkt_yumi_lo)
     ,.stat_mem_o(icache_stat_mem_lo)
     );

  bp_be_top
   #(.bp_params_p(bp_params_p))
   be
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.cfg_bus_i(cfg_bus_lo)

     ,.fe_queue_i(fe_queue_li)
     ,.fe_queue_v_i(fe_queue_v_li)
     ,.fe_queue_ready_o(fe_queue_ready_lo)

     ,.fe_cmd_o(fe_cmd_lo)
     ,.fe_cmd_v_o(fe_cmd_v_lo)
     ,.fe_cmd_yumi_i(fe_cmd_yumi_li)

     ,.cache_req_o(dcache_req_lo)
     ,.cache_req_v_o(dcache_req_v_lo)
     ,.cache_req_ready_i(dcache_req_ready_li)
     ,.cache_req_metadata_o(dcache_req_metadata_lo)
     ,.cache_req_metadata_v_o(dcache_req_metadata_v_lo)

     ,.cache_req_complete_i(dcache_req_complete_li)
     ,.cache_req_critical_i(dcache_req_critical_li)

     ,.data_mem_pkt_i(dcache_data_mem_pkt_li)
     ,.data_mem_pkt_v_i(dcache_data_mem_pkt_v_li)
     ,.data_mem_pkt_yumi_o(dcache_data_mem_pkt_yumi_lo)
     ,.data_mem_o(dcache_data_mem_lo)

     ,.tag_mem_pkt_i(dcache_tag_mem_pkt_li)
     ,.tag_mem_pkt_v_i(dcache_tag_mem_pkt_v_li)
     ,.tag_mem_pkt_yumi_o(dcache_tag_mem_pkt_yumi_lo)
     ,.tag_mem_o(dcache_tag_mem_lo)

     ,.stat_mem_pkt_v_i(dcache_stat_mem_pkt_v_li)
     ,.stat_mem_pkt_i(dcache_stat_mem_pkt_li)
     ,.stat_mem_pkt_yumi_o(dcache_stat_mem_pkt_yumi_lo)
     ,.stat_mem_o(dcache_stat_mem_lo)

     ,.credits_full_i(credits_full_li[1])
     ,.credits_empty_i(credits_empty_li[1])

     ,.timer_irq_i(timer_irq_li)
     ,.software_irq_i(software_irq_li)
     ,.external_irq_i(external_irq_li)
     );

  wire [1:0][lce_id_width_p-1:0] lce_id_li = {cfg_bus_lo.dcache_id, cfg_bus_lo.icache_id};
  bp_uce
   #(.bp_params_p(bp_params_p)
    ,.uce_mem_data_width_p(uce_mem_data_width_lp)
    ,.assoc_p(dcache_assoc_p)
    ,.sets_p(dcache_sets_p)
    ,.block_width_p(dcache_block_width_p)
    ,.fill_width_p(dcache_fill_width_p)
    ,.data_mem_invert_clk_p(1)
    ,.tag_mem_invert_clk_p(1)
    )
   dcache_uce
   (.clk_i(clk_i)
    ,.reset_i(reset_i)

     ,.lce_id_i(lce_id_li[1])

     ,.cache_req_i(dcache_req_lo)
     ,.cache_req_v_i(dcache_req_v_lo)
     ,.cache_req_ready_o(dcache_req_ready_li)
     ,.cache_req_metadata_i(dcache_req_metadata_lo)
     ,.cache_req_metadata_v_i(dcache_req_metadata_v_lo)

     ,.tag_mem_pkt_o(dcache_tag_mem_pkt_li)
     ,.tag_mem_pkt_v_o(dcache_tag_mem_pkt_v_li)
     ,.tag_mem_pkt_yumi_i(dcache_tag_mem_pkt_yumi_lo)
     ,.tag_mem_i(dcache_tag_mem_lo)

     ,.data_mem_pkt_o(dcache_data_mem_pkt_li)
     ,.data_mem_pkt_v_o(dcache_data_mem_pkt_v_li)
     ,.data_mem_pkt_yumi_i(dcache_data_mem_pkt_yumi_lo)
     ,.data_mem_i(dcache_data_mem_lo)

     ,.stat_mem_pkt_o(dcache_stat_mem_pkt_li)
     ,.stat_mem_pkt_v_o(dcache_stat_mem_pkt_v_li)
     ,.stat_mem_pkt_yumi_i(dcache_stat_mem_pkt_yumi_lo)
     ,.stat_mem_i(dcache_stat_mem_lo)

     ,.cache_req_complete_o(dcache_req_complete_li)
     ,.cache_req_critical_o(dcache_req_critical_li)

     ,.credits_full_o(credits_full_li[1])
     ,.credits_empty_o(credits_empty_li[1])

     ,.mem_cmd_header_o(proc_cmd_lo[1].header)
     ,.mem_cmd_data_o(proc_cmd_lo[1].data)
     ,.mem_cmd_lock_o(proc_cmd_lock_lo[1])
     ,.mem_cmd_v_o(proc_cmd_v_lo[1])
     ,.mem_cmd_ready_i(proc_cmd_ready_li[1])

     ,.mem_resp_header_i(proc_resp_li[1].header)
     ,.mem_resp_data_i(proc_resp_li[1].data)
     ,.mem_resp_lock_i(proc_resp_lock_li[1])
     ,.mem_resp_v_i(proc_resp_v_li[1])
     ,.mem_resp_ready_o(proc_resp_ready_lo[1])
     );

  bp_uce
   #(.bp_params_p(bp_params_p)
     ,.uce_mem_data_width_p(uce_mem_data_width_lp)
     ,.assoc_p(icache_assoc_p)
     ,.sets_p(icache_sets_p)
     ,.block_width_p(icache_block_width_p)
     ,.fill_width_p(icache_fill_width_p)
     )
   icache_uce
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.lce_id_i(lce_id_li[0])

     ,.cache_req_i(icache_req_lo)
     ,.cache_req_v_i(icache_req_v_lo)
     ,.cache_req_ready_o(icache_req_ready_li)
     ,.cache_req_metadata_i(icache_req_metadata_lo)
     ,.cache_req_metadata_v_i(icache_req_metadata_v_lo)

     ,.tag_mem_pkt_o(icache_tag_mem_pkt_li)
     ,.tag_mem_pkt_v_o(icache_tag_mem_pkt_v_li)
     ,.tag_mem_pkt_yumi_i(icache_tag_mem_pkt_yumi_lo)
     ,.tag_mem_i(icache_tag_mem_lo)

     ,.data_mem_pkt_o(icache_data_mem_pkt_li)
     ,.data_mem_pkt_v_o(icache_data_mem_pkt_v_li)
     ,.data_mem_pkt_yumi_i(icache_data_mem_pkt_yumi_lo)
     ,.data_mem_i(icache_data_mem_lo)

     ,.stat_mem_pkt_o(icache_stat_mem_pkt_li)
     ,.stat_mem_pkt_v_o(icache_stat_mem_pkt_v_li)
     ,.stat_mem_pkt_yumi_i(icache_stat_mem_pkt_yumi_lo)
     ,.stat_mem_i(icache_stat_mem_lo)

     ,.cache_req_complete_o(icache_req_complete_li)
     ,.cache_req_critical_o(icache_req_critical_li)

     ,.credits_full_o(credits_full_li[0])
     ,.credits_empty_o(credits_empty_li[0])

     ,.mem_cmd_header_o(proc_cmd_lo[0].header)
     ,.mem_cmd_data_o(proc_cmd_lo[0].data)
     ,.mem_cmd_lock_o(proc_cmd_lock_lo[0])
     ,.mem_cmd_v_o(proc_cmd_v_lo[0])
     ,.mem_cmd_ready_i(proc_cmd_ready_li[0])

     ,.mem_resp_header_i(proc_resp_li[0].header)
     ,.mem_resp_data_i(proc_resp_li[0].data)
     ,.mem_resp_lock_i(proc_resp_lock_li[0])
     ,.mem_resp_v_i(proc_resp_v_li[0])
     ,.mem_resp_ready_o(proc_resp_ready_lo[0])
     );

  bp_clint_slice
   #(.bp_params_p(bp_params_p))
   clint
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.mem_cmd_i(clint_cmd_li)
     ,.mem_cmd_v_i(clint_cmd_v_li)
     ,.mem_cmd_ready_o(clint_cmd_ready_lo)

     ,.mem_resp_o(clint_resp_lo)
     ,.mem_resp_v_o(clint_resp_v_lo)
     ,.mem_resp_yumi_i(clint_resp_yumi_li)

     ,.timer_irq_o(timer_irq_li)
     ,.software_irq_o(software_irq_li)
     ,.external_irq_o(external_irq_li)
     );

  bp_cfg
   #(.bp_params_p(bp_params_p))
   cfg
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.mem_cmd_i(cfg_cmd_li)
     ,.mem_cmd_v_i(cfg_cmd_v_li)
     ,.mem_cmd_ready_o(cfg_cmd_ready_lo)

     ,.mem_resp_o(cfg_resp_lo)
     ,.mem_resp_v_o(cfg_resp_v_lo)
     ,.mem_resp_yumi_i(cfg_resp_yumi_li)

     ,.cfg_bus_o(cfg_bus_lo)
     ,.did_i('0)
     ,.host_did_i('0)
     ,.cord_i({coh_noc_y_cord_width_p'(1), coh_noc_x_cord_width_p'(0)})

     ,.cce_ucode_v_o()
     ,.cce_ucode_w_o()
     ,.cce_ucode_addr_o()
     ,.cce_ucode_data_o()
     ,.cce_ucode_data_i('0)
     );

  // Assign incoming I/O as basically another UCE interface
  assign proc_cmd_lo[2] = io_cmd_i[0+:bp_bedrock_uce_mem_msg_width_lp];
  assign proc_cmd_v_lo[2] = io_cmd_v_i;
  assign io_cmd_yumi_o = proc_cmd_ready_li[2] & proc_cmd_v_lo[2];
  assign proc_cmd_lock_lo[2] = '0;

  // Command/response FIFOs for timing and helpfulness
  bp_bedrock_uce_mem_msg_s [2:0] cmd_fifo_lo;
  logic [2:0] cmd_fifo_lock_lo, cmd_fifo_v_lo, cmd_fifo_yumi_li;
  for (genvar i = 0; i < 3; i++)
    begin : fifo
      bsg_two_fifo
       #(.width_p($bits(bp_bedrock_uce_mem_msg_s)+1))
       cmd_fifo
        (.clk_i(clk_i)
         ,.reset_i(reset_i)

         ,.data_i({proc_cmd_lock_lo[i], proc_cmd_lo[i]})
         ,.v_i(proc_cmd_v_lo[i])
         ,.ready_o(proc_cmd_ready_li[i])

         ,.data_o({cmd_fifo_lock_lo[i], cmd_fifo_lo[i]})
         ,.v_o(cmd_fifo_v_lo[i])
         ,.yumi_i(cmd_fifo_yumi_li[i])
         );
    end

    // resp fifo for I/O only
    bp_bedrock_uce_mem_msg_s io_resp_lo;
    logic io_resp_ready_lo;
    bsg_two_fifo
     #(.width_p($bits(bp_bedrock_uce_mem_msg_s)))
     io_resp_fifo
      (.clk_i(clk_i)
      ,.reset_i(reset_i)

      ,.data_i(proc_resp_li[2])
      ,.v_i(proc_resp_v_li[2])
      ,.ready_o(proc_resp_ready_lo[2])

      ,.data_o(io_resp_lo) 
      ,.v_o(io_resp_v_o)
      ,.yumi_i(io_resp_ready_i & io_resp_v_o)
      );
    assign io_resp_o = bp_bedrock_uce_mem_msg_width_lp'(io_resp_lo);
    wire io_resp_lock_unused = proc_resp_lock_li[2] & proc_resp_v_li[2]; 

  // Command arbitration logic
  // This is suboptimal for performance, because a blocked I/O channel will put backpressure on the
  //   cache.
  wire cmd_arb_ready_li = &{cfg_cmd_ready_lo, clint_cmd_ready_lo, io_cmd_ready_i, cache_cmd_ready_lo, loopback_cmd_ready_lo};
  logic cmd_selected_lock_li;
  bsg_locking_arb_fixed_new 
   #(.inputs_p(3)
   ,.unlock_type_p(0)
   ,.lo_to_hi_p(0))
   cmd_locking_arb_fixed
    (.clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.ready_i(cmd_arb_ready_li)

    ,.switch_lock_i(cmd_fifo_lock_lo & cmd_fifo_v_lo)
    ,.reqs_i(cmd_fifo_v_lo)
    ,.grants_o(cmd_fifo_yumi_li)
    ,.lock_o(cmd_selected_lock_li)
    ); 

  bp_bedrock_uce_mem_msg_s cmd_fifo_selected_lo;
  bsg_mux_one_hot
   #(.width_p($bits(bp_bedrock_uce_mem_msg_s)), .els_p(3))
   cmd_select
    (.data_i(cmd_fifo_lo)
     ,.sel_one_hot_i(cmd_fifo_yumi_li)
     ,.data_o(cmd_fifo_selected_lo)
     );
  assign {loopback_cmd_li, cache_cmd_li, io_cmd_o, clint_cmd_li, cfg_cmd_li} = {5{cmd_fifo_selected_lo}};

  // Response arbitration logic
  // UCEs may send two commands as part of a writeback routine. Responses can come back in
  //   arbitrary orders, especially when considering CLINT or I/O responses
  // This is also suboptimal. Theoretically, we could dequeue into each fifo at once, but this
  //   would require more complex arbitration logic
  wire resp_arb_ready_li = &proc_resp_ready_lo;
  logic resp_selected_lock_lo;
  bsg_locking_arb_fixed_new 
   #(.inputs_p(5)
   ,.unlock_type_p(0)
   ,.lo_to_hi_p(0))
   resp_locking_arb_fixed
    (.clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.ready_i(resp_arb_ready_li)

    ,.switch_lock_i({1'b0, cache_resp_lock_lo, 3'b000}) // Only L2 sends the locking signal
    ,.reqs_i({loopback_resp_v_lo, cache_resp_v_lo, io_resp_v_i, clint_resp_v_lo, cfg_resp_v_lo})
    ,.grants_o({loopback_resp_yumi_li, cache_resp_yumi_li, io_resp_yumi_o, clint_resp_yumi_li, cfg_resp_yumi_li})
    ,.lock_o(resp_selected_lock_lo)
    ); 

  for (genvar i = 0; i < 3; i++)
    begin : resp_match
      bp_bedrock_uce_mem_msg_s proc_resp_selected_li;
      bp_bedrock_uce_mem_payload_s proc_resp_selected_payload_li;
      assign proc_resp_selected_payload_li = proc_resp_selected_li.header.payload;
      bsg_mux_one_hot
       #(.width_p($bits(bp_bedrock_uce_mem_msg_s)), .els_p(5))
       resp_select
        (.data_i({loopback_resp_lo, cache_resp_lo, io_resp_i, clint_resp_lo, cfg_resp_lo})
         ,.sel_one_hot_i({loopback_resp_yumi_li, cache_resp_yumi_li, io_resp_yumi_o, clint_resp_yumi_li, cfg_resp_yumi_li})
         ,.data_o(proc_resp_selected_li)
         );
      wire resp_selected_v_li = |{loopback_resp_yumi_li, cache_resp_yumi_li, io_resp_yumi_o, clint_resp_yumi_li, cfg_resp_yumi_li};

      assign proc_resp_v_li[i] = resp_selected_v_li & (proc_resp_selected_payload_li.lce_id == i);
      assign proc_resp_li[i] = proc_resp_selected_li;
      assign proc_resp_lock_li[i] = resp_selected_lock_lo;
    end

  /* TODO: Extract local memory map to module */
  wire local_cmd_li        = (cmd_fifo_selected_lo.header.addr < dram_base_addr_gp);
  wire [3:0] device_cmd_li = cmd_fifo_selected_lo.header.addr[20+:4];
  wire is_other_domain     = (cmd_fifo_selected_lo.header.addr[paddr_width_p-1-:io_noc_did_width_p] != 0);
  wire is_cfg_cmd          = local_cmd_li & (device_cmd_li == cfg_dev_gp);
  wire is_clint_cmd        = local_cmd_li & (device_cmd_li == clint_dev_gp);
  wire is_io_cmd           = (local_cmd_li & (device_cmd_li inside {boot_dev_gp, host_dev_gp})) | is_other_domain;
  wire is_cache_cmd        = ~local_cmd_li || (local_cmd_li & (device_cmd_li == cache_dev_gp));
  wire is_loopback_cmd     = local_cmd_li & ~is_cfg_cmd & ~is_clint_cmd & ~is_io_cmd & ~is_cache_cmd;

  assign cfg_cmd_v_li      = is_cfg_cmd   & |cmd_fifo_yumi_li;
  assign clint_cmd_v_li    = is_clint_cmd & |cmd_fifo_yumi_li;
  assign io_cmd_v_o        = is_io_cmd    & |cmd_fifo_yumi_li;
  assign cache_cmd_v_li    = is_cache_cmd & |cmd_fifo_yumi_li;
  assign loopback_cmd_v_li = is_loopback_cmd & |cmd_fifo_yumi_li;
  assign cache_cmd_lock_li = cache_cmd_v_li & cmd_selected_lock_li; // Only L2 will used the locking signal

  bp_cce_loopback
   #(.bp_params_p(bp_params_p))
   loopback
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.mem_cmd_i(loopback_cmd_li)
     ,.mem_cmd_v_i(loopback_cmd_v_li)
     ,.mem_cmd_ready_o(loopback_cmd_ready_lo)

     ,.mem_resp_o(loopback_resp_lo)
     ,.mem_resp_v_o(loopback_resp_v_lo)
     ,.mem_resp_yumi_i(loopback_resp_yumi_li)
     );

  if (l2_en_p)
    begin : l2
      logic mem_resp_header_ready_lo, mem_resp_data_ready_lo;
      bp_me_cache_slice_new
       #(.bp_params_p(bp_params_p)
       ,.cache_data_width_p(uce_mem_data_width_lp)) //TODO
       l2s
        (.clk_i(clk_i)
        ,.reset_i(reset_i)

        ,.mem_cmd_header_i(cache_cmd_li.header)
        ,.mem_cmd_data_i(cache_cmd_li.data)
        ,.mem_cmd_lock_i(cache_cmd_lock_li)
        ,.mem_cmd_v_i(cache_cmd_v_li)
        ,.mem_cmd_ready_o(cache_cmd_ready_lo)

        ,.mem_resp_header_o(cache_resp_lo.header)
        ,.mem_resp_data_o(cache_resp_lo.data)
        ,.mem_resp_lock_o(cache_resp_lock_lo)
        ,.mem_resp_v_o(cache_resp_v_lo)
        ,.mem_resp_yumi_i(cache_resp_yumi_li)

        ,.mem_cmd_header_o(mem_cmd_header_o)
        ,.mem_cmd_header_v_o(mem_cmd_header_v_o)
        ,.mem_cmd_header_yumi_i(mem_cmd_header_ready_i & mem_cmd_header_v_o)

        ,.mem_cmd_data_o(mem_cmd_data_o)
        ,.mem_cmd_data_v_o(mem_cmd_data_v_o)
        ,.mem_cmd_data_yumi_i(mem_cmd_data_ready_i & mem_cmd_data_v_o)

        ,.mem_resp_header_i(mem_resp_header_i)
        ,.mem_resp_header_v_i(mem_resp_header_v_i)
        ,.mem_resp_header_ready_o(mem_resp_header_ready_lo)

        ,.mem_resp_data_i(mem_resp_data_i)
        ,.mem_resp_data_v_i(mem_resp_data_v_i)
        ,.mem_resp_data_ready_o(mem_resp_data_ready_lo)
        );
      assign mem_resp_header_yumi_o = mem_resp_header_ready_lo & mem_resp_header_v_i;
      assign mem_resp_data_yumi_o = mem_resp_data_ready_lo & mem_resp_data_v_i;
    end
  else
    begin : no_l2 // streamt_to_burst pending
      bp_lite_to_burst
       #(.bp_params_p(bp_params_p)
         ,.in_data_width_p(cce_block_width_p)
         ,.out_data_width_p(dword_width_p)
         ,.payload_mask_p(mem_cmd_payload_mask_gp)
         )
       lite2burst
        (.clk_i(clk_i)
         ,.reset_i(reset_i)

         ,.mem_i(cache_cmd_li)
         ,.mem_v_i(cache_cmd_v_li)
         ,.mem_ready_o(cache_cmd_ready_lo)

         ,.mem_header_o(mem_cmd_header_o)
         ,.mem_header_v_o(mem_cmd_header_v_o)
         ,.mem_header_ready_i(mem_cmd_header_ready_i)

         ,.mem_data_o(mem_cmd_data_o)
         ,.mem_data_v_o(mem_cmd_data_v_o)
         ,.mem_data_ready_i(mem_cmd_data_ready_i)
         );

      logic mem_resp_header_ready_lo, mem_resp_data_ready_lo;
      bp_burst_to_lite
       #(.bp_params_p(bp_params_p)
         ,.in_data_width_p(dword_width_p)
         ,.out_data_width_p(cce_block_width_p)
         ,.payload_mask_p(mem_resp_payload_mask_gp)
         )
       burst2lite
        (.clk_i(clk_i)
         ,.reset_i(reset_i)

         ,.mem_header_i(mem_resp_header_i)
         ,.mem_header_v_i(mem_resp_header_v_i)
         ,.mem_header_ready_o(mem_resp_header_ready_lo)

         ,.mem_data_i(mem_resp_data_i)
         ,.mem_data_v_i(mem_resp_data_v_i)
         ,.mem_data_ready_o(mem_resp_data_ready_lo)

         ,.mem_o(cache_resp_lo)
         ,.mem_v_o(cache_resp_v_lo)
         ,.mem_ready_i(cache_resp_yumi_li)
         );
       assign mem_resp_header_yumi_o = mem_resp_header_ready_lo & mem_resp_header_v_i;
       assign mem_resp_data_yumi_o = mem_resp_data_ready_lo & mem_resp_data_v_i;
    end

endmodule

module bsg_locking_arb_fixed_new #( parameter inputs_p="inv"
                                 , parameter unlock_type_p = 0
                                 , parameter lo_to_hi_p=0
                                 , parameter num_locks_p = (unlock_type_p == 0) ? inputs_p : 1
                                 )
  ( input   clk_i
  , input   reset_i
  , input   ready_i

  , input        [num_locks_p-1:0] switch_lock_i

  , input        [inputs_p-1:0] reqs_i
  , output logic [inputs_p-1:0] grants_o

  , output logic lock_o
  );  

  wire [inputs_p-1:0] not_req_mask_r, req_mask_r;
  wire unlock;  
  
  if (unlock_type_p == 0) // Implicit operating mode
    begin
      wire is_locked = |not_req_mask_r;
      wire lock_onlocked_lo, lock_selected_lo;
      bsg_mux_one_hot #(.width_p(1) ,.els_p(inputs_p) )
      lock_onlocked_mux
      (.data_i(switch_lock_i)
        ,.sel_one_hot_i(req_mask_r)
        ,.data_o(lock_onlocked_lo)
        );
      // unlock when the lock input on the locked channel is low
      assign unlock = is_locked & ~lock_onlocked_lo;

      bsg_mux_one_hot #(.width_p(1) ,.els_p(inputs_p) )
      lock_output_mux
        (.data_i(switch_lock_i)
        ,.sel_one_hot_i(grants_o)
        ,.data_o(lock_selected_lo)
        );
      // The lock_i can be passed to lock_o at the same cycle
      assign lock_o = (is_locked) ? lock_onlocked_lo : lock_selected_lo;
    end
  else  // Explicit operating mode
    begin
      assign unlock = switch_lock_i;
      assign lock_o = 1'b0;
    end

  bsg_dff_reset_en #( .width_p(inputs_p) )
    req_words_reg
      ( .clk_i  ( clk_i )
      , .reset_i( reset_i | unlock ) 
      , .en_i   ( (&req_mask_r) & (|grants_o) ) // update the lock when it is not locked & a req is granted
      , .data_i ( ~grants_o )
      , .data_o ( not_req_mask_r )
      );

  assign req_mask_r = ~not_req_mask_r;

  bsg_arb_fixed #( .inputs_p(inputs_p), .lo_to_hi_p(lo_to_hi_p) )
    fixed_arb
      ( .ready_i ( ready_i )
      , .reqs_i  ( reqs_i & req_mask_r )
      , .grants_o( grants_o )
      );  
      
endmodule
