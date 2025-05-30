// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Description: entropy_src main state machine module
//
//   determines when new entropy is ready to be forwarded
`include "prim_assert.sv"
`include "prim_flop_macros.sv"
module entropy_src_main_sm
  import entropy_src_main_sm_pkg::*;
(
  input logic                   clk_i,
  input logic                   rst_ni,

  input logic                   enable_i,
  input logic                   fw_ov_ent_insert_i,
  input logic                   fw_ov_sha3_start_i,
  input logic                   ht_done_pulse_i,
  input logic                   ht_fail_pulse_i,
  input logic                   alert_thresh_fail_i,
  output logic                  rst_alert_cntr_o,
  input logic                   bypass_mode_i,
  input logic                   bypass_stage_rdy_i,
  input logic                   sha3_state_vld_i,
  output logic                  main_stage_push_o,
  output logic                  bypass_stage_pop_o,
  output logic                  boot_phase_done_o,
  output logic                  sha3_start_o,
  output logic                  sha3_process_o,
  output prim_mubi_pkg::mubi4_t sha3_done_o,
  input logic                   local_escalate_i,
  output logic                  main_sm_alert_o,
  output logic                  main_sm_idle_o,
  output logic [StateWidth-1:0] main_sm_state_o,
  output logic                  main_sm_err_o
);

  // The definition of state_e, the sparse FSM state enum, is in entropy_src_main_sm_pkg.sv
  state_e state_d, state_q;

  `PRIM_FLOP_SPARSE_FSM(u_state_regs, state_d, state_q, state_e, Idle)

  assign main_sm_state_o = state_q;

  always_comb begin
    state_d = state_q;
    rst_alert_cntr_o = 1'b0;
    main_stage_push_o = 1'b0;
    bypass_stage_pop_o = 1'b0;
    boot_phase_done_o = 1'b0;
    sha3_start_o = 1'b0;
    sha3_process_o = 1'b0;
    sha3_done_o = prim_mubi_pkg::MuBi4False;
    main_sm_alert_o = 1'b0;
    main_sm_idle_o = 1'b0;
    main_sm_err_o = 1'b0;
    unique case (state_q)
      Idle: begin
        main_sm_idle_o = 1'b1;
        if (enable_i) begin
          // running fw override mode and in sha3 mode
          if (fw_ov_ent_insert_i && !bypass_mode_i) begin
            sha3_start_o = 1'b1;
            if (fw_ov_sha3_start_i) begin
              state_d = FWInsertMsg;
            end else begin
              state_d = FWInsertStart;
            end
          // running in bypass_mode and not fw override mode
          end else if (bypass_mode_i && !fw_ov_ent_insert_i) begin
            state_d = BootHTRunning;
          // running in bypass_mode and fw override mode
          end else if (bypass_mode_i && fw_ov_ent_insert_i) begin
            state_d = Idle;
          end else begin
            state_d = StartupHTStart;
          end
        end
      end
      BootHTRunning: begin
        if (!enable_i) begin
          state_d = Idle;
        end else if (ht_done_pulse_i) begin
          if (ht_fail_pulse_i) begin
            if (bypass_stage_rdy_i) begin
              // Remove failed data
              bypass_stage_pop_o = 1'b1;
            end
            if (alert_thresh_fail_i) begin
              state_d = AlertState;
            end else begin
              state_d = Idle;
            end
          end else begin
            // Window sizes other than 384 bits (the seed length) are currently not tested nor
            // supported in bypass or boot-time mode.
            state_d = BootPostHTChk;
            rst_alert_cntr_o = 1'b1;
          end
        end
      end
      BootPostHTChk: begin
        if (!enable_i) begin
          state_d = Idle;
        end else begin
          if (!bypass_stage_rdy_i) begin
          end else begin
            bypass_stage_pop_o = 1'b1;
            main_stage_push_o = 1'b1;
            state_d = BootPhaseDone;
          end
        end
      end
      BootPhaseDone: begin
        boot_phase_done_o = 1'b1;
        if (!enable_i) begin
          state_d = Idle;
        end
        // Even when stalled we keep monitoring for alerts and maintaining  alert statistics.
        // However, we don't signal alerts or clear HT stats in FW_OV mode.
        if(!fw_ov_ent_insert_i && ht_done_pulse_i) begin
          if (alert_thresh_fail_i) begin
            state_d = AlertState;
          end else if (!ht_fail_pulse_i) begin
            rst_alert_cntr_o = 1'b1;
          end
        end
      end
      StartupHTStart: begin
        if (!enable_i) begin
          state_d = Idle;
        end else begin
          sha3_start_o = 1'b1;
          state_d = StartupPhase1;
        end
      end
      StartupPhase1: begin
        if (!enable_i) begin
          state_d = Idle;
        end else begin
          if (ht_done_pulse_i) begin
            if (ht_fail_pulse_i) begin
              state_d = StartupFail1;
            end else begin
              state_d = StartupPass1;
              rst_alert_cntr_o = 1'b1;
            end
          end
        end
      end
      StartupPass1: begin
        if (!enable_i) begin
          state_d = Idle;
        end else begin
          if (ht_done_pulse_i) begin
            if (ht_fail_pulse_i) begin
              state_d = StartupFail1;
            end else begin
              // We've now passed two consecutive test windows of the configured window length.
              // Next, we're going to compress the collected entropy to produce a single seed.
              state_d = Sha3Process;
              rst_alert_cntr_o = 1'b1;
            end
          end
        end
      end
      StartupFail1: begin
        if (!enable_i) begin
          state_d = Idle;
        end else begin
          if (ht_done_pulse_i) begin
            if (ht_fail_pulse_i) begin
              // Failed two consecutive tests
              state_d = AlertState;
            end else begin
              state_d = StartupPass1;
              rst_alert_cntr_o = 1'b1;
            end
          end
        end
      end
      ContHTStart: begin
        if (!enable_i) begin
          state_d = Idle;
        end else begin
          // Send the Start trigger to the SHA3 engine. After this point, collected raw entropy is
          // going to be moved into the conditioner in chunks of 64 bits. The SHA3 engine itself
          // will hash the received raw entropy whenever either of the following two conditions are
          // met:
          // 1) 13 64-bit chunks have been received (13 x 64 = 832 = the rate or block size of
          //    the employed SHA3-384 engine). This condition is checked internally to the SHA3
          //    engine.
          // 2) The total amount of received entropy is equal to the configured health test window
          //    size. This condition is checked by this FSM which then triggers the SHA3 engine
          //    using the sha3_process_o signal.
          sha3_start_o = 1'b1;
          state_d = ContHTRunning;
        end
      end
      ContHTRunning: begin
        if (!enable_i) begin
          state_d = Idle;
        end else begin
          if (ht_done_pulse_i) begin
            // We've finished testing the current window and all the collected and tested entropy
            // has been forwarded to the SHA3 engine and has at least partially been absorbed.
            if (alert_thresh_fail_i) begin
              state_d = AlertState;
            end else if (!ht_fail_pulse_i) begin
              // Move forward and get the conditioner ready to finish the absorption process.
              state_d = Sha3Process;
              rst_alert_cntr_o = 1'b1;
            end
          end
        end
      end
      FWInsertStart: begin
        if (!enable_i) begin
          state_d = Idle;
        end else if (fw_ov_sha3_start_i) begin
          state_d = FWInsertMsg;
        end
      end
      FWInsertMsg: begin
        if (!enable_i) begin
          state_d = Idle;
        end else if (!fw_ov_sha3_start_i) begin
          state_d = Sha3Process;
        end
      end
      Sha3Process: begin
        // Trigger the final absorption operation of the SHA3 engine.
        sha3_process_o = 1'b1;
        state_d = Sha3Valid;
      end
      Sha3Valid: begin
        if (sha3_state_vld_i) begin
          state_d = Sha3Done;
        end
      end
      Sha3Done: begin
        if (!enable_i) begin
          sha3_done_o = prim_mubi_pkg::MuBi4True;
          state_d = Sha3MsgDone;
        end else begin
          // Push the digest produced by the SHA3 engine into the final FIFO and clear the
          // internal state of the SHA3 engine to start from scratch for the next seed.
          sha3_done_o = prim_mubi_pkg::MuBi4True;
          main_stage_push_o = 1'b1;
          state_d = Sha3MsgDone;
        end
      end
      Sha3MsgDone: begin
        if (!enable_i || fw_ov_ent_insert_i) begin
          state_d = Idle;
        end else begin
          state_d = ContHTStart;
        end
      end
      AlertState: begin
        main_sm_alert_o = 1'b1;
        state_d = AlertHang;
      end
      AlertHang: begin
        if (!enable_i) begin
          state_d = Idle;
        end
      end
      Error: begin
        main_sm_err_o = 1'b1;
      end
      default: begin
        state_d = Error;
        main_sm_err_o = 1'b1;
      end
    endcase
    if (local_escalate_i) begin
      state_d = Error;
    end
  end

endmodule
