// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Description: I2C finite state machine
`include "prim_assert.sv"
module i2c_fsm import i2c_pkg::*;
#(
  parameter int FifoDepth = 64,
  parameter int AcqFifoDepth = 64,
  localparam int FifoDepthWidth = $clog2(FifoDepth+1),
  localparam int AcqFifoDepthWidth = $clog2(AcqFifoDepth+1)
) (
  input        clk_i,  // clock
  input        rst_ni, // active low reset

  input        scl_i,  // serial clock input from i2c bus
  output logic scl_o,  // serial clock output to i2c bus
  input        sda_i,  // serial data input from i2c bus
  output logic sda_o,  // serial data output to i2c bus

  input        host_enable_i, // enable host functionality
  input        target_enable_i, // enable target functionality
  output logic host_disable_o, // disable host mode

  input                      fmt_fifo_rvalid_i, // indicates there is valid data in fmt_fifo
  input [FifoDepthWidth-1:0] fmt_fifo_depth_i,  // fmt_fifo_depth
  output logic               fmt_fifo_rready_o, // populates fmt_fifo
  input [7:0]                fmt_byte_i,        // byte in fmt_fifo to be sent to target
  input                      fmt_flag_start_before_i, // issue start before sending byte
  input                      fmt_flag_stop_after_i,   // issue stop after sending byte
  input                      fmt_flag_read_bytes_i,   // indicates byte is an number of reads
  input                      fmt_flag_read_continue_i,// host to send Ack to final byte read
  input                      fmt_flag_nak_ok_i,       // no Ack is expected
  input                      unhandled_unexp_nak_i,

  output logic                     rx_fifo_wvalid_o, // high if there is valid data in rx_fifo
  output logic [RX_FIFO_WIDTH-1:0] rx_fifo_wdata_o,  // byte in rx_fifo read from target

  input                      tx_fifo_rvalid_i, // indicates there is valid data in tx_fifo
  output logic               tx_fifo_rready_o, // pop entry from tx_fifo
  input [TX_FIFO_WIDTH-1:0]  tx_fifo_rdata_i,  // byte in tx_fifo to be sent to host

  output logic                      acq_fifo_wvalid_o, // high if there is valid data in acq_fifo
  output logic [ACQ_FIFO_WIDTH-1:0] acq_fifo_wdata_o,  // data to write to acq_fifo from target
  input [AcqFifoDepthWidth-1:0]     acq_fifo_depth_i,  // fill level of acq_fifo
  output logic                      acq_fifo_wready_o, // local version of ready
  input [ACQ_FIFO_WIDTH-1:0]        acq_fifo_rdata_i,  // only used for assertion

  output logic       host_idle_o,      // indicates the host is idle
  output logic       target_idle_o,    // indicates the target is idle

  input [15:0] thigh_i,    // high period of the SCL in clock units
  input [15:0] tlow_i,     // low period of the SCL in clock units
  input [15:0] t_r_i,      // rise time of both SDA and SCL in clock units
  input [15:0] t_f_i,      // fall time of both SDA and SCL in clock units
  input [15:0] thd_sta_i,  // hold time for (repeated) START in clock units
  input [15:0] tsu_sta_i,  // setup time for repeated START in clock units
  input [15:0] tsu_sto_i,  // setup time for STOP in clock units
  input [15:0] tsu_dat_i,  // data setup time in clock units
  input [15:0] thd_dat_i,  // data hold time in clock units
  input [15:0] t_buf_i,    // bus free time between STOP and START in clock units
  input [30:0] stretch_timeout_i,  // max time target connected to this host may stretch the clock
  input        timeout_enable_i,   // assert if target stretches clock past max
  input [31:0] host_timeout_i,     // max time target waits for host to pull clock down
  input [30:0] nack_timeout_i,     // max time target may stretch until it should NACK
  input        nack_timeout_en_i,  // enable nack timeout
  input [30:0] host_nack_handler_timeout_i, // Timeout threshold for unhandled Host-Mode 'nak' irq.
  input        host_nack_handler_timeout_en_i,

  input logic [6:0] target_address0_i,
  input logic [6:0] target_mask0_i,
  input logic [6:0] target_address1_i,
  input logic [6:0] target_mask1_i,

  output logic target_sr_p_cond_o,       // Saw RSTART/STOP in Target-Mode.
  output logic event_target_nack_o,      // this target sent a NACK (this is used to keep count)
  output logic event_nak_o,              // target didn't Ack when expected
  output logic event_scl_interference_o, // other device forcing SCL low
  output logic event_sda_interference_o, // other device forcing SDA low
  output logic event_stretch_timeout_o,  // target stretches clock past max time
  output logic event_sda_unstable_o,     // SDA is not constant during SCL pulse
  output logic event_cmd_complete_o,     // Command is complete
  output logic event_tx_stretch_o,       // tx transaction is being stretched
  output logic event_unexp_stop_o,       // target received an unexpected stop
  output logic event_host_timeout_o      // host ceased sending SCL pulses during ongoing transactn
);

  // I2C bus clock timing variables
  logic [19:0] tcount_q;      // current counter for setting delays
  logic [19:0] tcount_d;      // next counter for setting delays
  logic        load_tcount;   // indicates counter must be loaded
  logic [31:0] stretch_idle_cnt; // counter for clock being stretched by target
                                 // or clock idle by host.
  logic [30:0] stretch_active_cnt; // In target mode keep track of how long it has stretched for
                                   // the NACK timeout feature.
  logic [30:0] unhandled_nak_cnt; // In Host-mode, count cycles where the FSM is halted awaiting
                                  // the nak irq to be handled by SW.

  // (IP in HOST-Mode) This bit is active when the FSM is in a state where a TARGET might
  // be trying to stretch the clock, preventing the controller FSM from continuing.
  logic        stretch_en;
  logic        actively_stretching; // Only high when this target is holding SCL low to stretch.

  logic        nack_next_byte_q;     // Flop whether the next byte needs to be nack'ed.
  logic        set_nack_next_byte;   // Set the nack next byte flag.
  logic        clear_nack_next_byte; // Clear the nack next byte flag.

  // Bit and byte counter variables
  logic [2:0]  bit_index;     // bit being transmitted to or read from the bus
  logic        bit_decr;      // indicates bit_index must be decremented by 1
  logic        bit_clr;       // indicates bit_index must be reset to 7
  logic [8:0]  byte_num;      // number of bytes to read
  logic [8:0]  byte_index;    // byte being read from the bus
  logic        byte_decr;     // indicates byte_index must be decremented by 1
  logic        byte_clr;      // indicates byte_index must be reset to byte_num

  // Stop / Start detection counter
  logic [15:0] ctrl_det_count;

  // Other internal variables
  logic        scl_q;         // scl internal flopped
  logic        sda_q;         // data internal flopped
  logic        scl_d;         // scl internal
  logic        sda_d;         // data internal
  logic        scl_i_q;       // scl_i delayed by one clock
  logic        sda_i_q;       // sda_i delayed by one clock
  logic [7:0]  read_byte;     // register for reads from target
  logic        read_byte_clr; // clear read_byte contents
  logic        shift_data_en; // indicates data must be shifted in from the bus
  logic        trans_started; // indicates a transaction has started
  logic        pend_restart;  // there is a pending restart waiting to be processed
  logic        req_restart;   // request restart
  logic        log_start;     // indicates start is been issued
  logic        log_stop;      // indicates stop is been issued

  // Target specific variables
  logic        start_det_trigger, start_det_pending;
  logic        start_det;     // indicates start or repeated start is detected on the bus
  logic        stop_det_trigger, stop_det_pending;
  logic        stop_det;      // indicates stop is detected on the bus
  logic        address0_match;// indicates target's address0 matches the one sent by host
  logic        address1_match;// indicates target's address1 matches the one sent by host
  logic        address_match; // indicates one of target's addresses matches the one sent by host
  logic [7:0]  input_byte;    // register for reads from host
  logic        input_byte_clr;// clear input_byte contents
  logic        acq_fifo_plenty_space;
  logic        acq_fifo_full_or_last_space;
  logic        stretch_addr;
  logic        stretch_rx;
  logic        stretch_tx;
  logic        nack_timeout;
  logic        expect_stop;

  // Target bit counter variables
  logic [3:0]  bit_idx;       // bit index including ack/nack
  logic        bit_ack;       // indicates ACK bit been sent or received
  logic        rw_bit;        // indicates host wants to read (1) or write (0)
  logic        host_ack;      // indicates host acknowledged transmitted byte


  // Clock counter implementation
  typedef enum logic [3:0] {
    tSetupStart,
    tHoldStart,
    tSetupData,
    tClockStart,
    tClockLow,
    tClockPulse,
    tClockHigh,
    tHoldBit,
    tClockStop,
    tSetupStop,
    tHoldStop,
    tNoDelay
  } tcount_sel_e;

  tcount_sel_e tcount_sel;

  always_comb begin : counter_functions
    tcount_d = tcount_q;
    if (load_tcount) begin
      unique case (tcount_sel)
        tSetupStart : tcount_d = 20'(t_r_i) + 20'(tsu_sta_i);
        tHoldStart  : tcount_d = 20'(t_f_i) + 20'(thd_sta_i);
        tSetupData  : tcount_d = 20'(t_r_i) + 20'(tsu_dat_i);
        tClockStart : tcount_d = 20'(thd_dat_i);
        tClockLow   : tcount_d = 20'(tlow_i) - 20'(thd_dat_i);
        tClockPulse : tcount_d = 20'(t_r_i) + 20'(thigh_i);
        tClockHigh  : tcount_d = 20'(thigh_i);
        tHoldBit    : tcount_d = 20'(t_f_i) + 20'(thd_dat_i);
        tClockStop  : tcount_d = 20'(t_f_i) + 20'(tlow_i) - 20'(thd_dat_i);
        tSetupStop  : tcount_d = 20'(t_r_i) + 20'(tsu_sto_i);
        tHoldStop   : tcount_d = 20'(t_r_i) + 20'(t_buf_i) - 20'(tsu_sta_i);
        tNoDelay    : tcount_d = 20'h00001;
        default     : tcount_d = 20'h00001;
      endcase
    end else if (
      host_enable_i ||
      target_enable_i ||
      // If we disable Host-Mode mid-txn, keep counting until the end of
      // byte, at which point we create a STOP condition then return to Idle.
      (!host_idle_o && !host_enable_i)) begin
      tcount_d = tcount_q - 1'b1;
    end
  end

  always_ff @ (posedge clk_i or negedge rst_ni) begin : clk_counter
    if (!rst_ni) begin
      tcount_q <= '1;
    end else begin
      tcount_q <= tcount_d;
    end
  end

  // Clock stretching/idle detection when i2c_ctrl.
  // When in host mode, this is a stretch count for how long an external target
  // has stretched the clock.
  // When in target mode, this is an idle count for how long an external host
  // has kept the clock idle after a START indication.
  always_ff @ (posedge clk_i or negedge rst_ni) begin : clk_stretch
    if (!rst_ni) begin
      stretch_idle_cnt <= '0;
    end else if (stretch_en) begin
      // HOST-mode count of clock stretching
      stretch_idle_cnt <= stretch_idle_cnt + 1'b1;
    end else if (!target_idle_o && event_host_timeout_o) begin
      // If the host has timed out, reset the counter and try again
      stretch_idle_cnt <= '0;
    end else if (!target_idle_o && scl_i) begin
      stretch_idle_cnt <= stretch_idle_cnt + 1'b1;
    end else begin
      stretch_idle_cnt <= '0;
    end
  end

  // Keep track of how long the target has been stretching. This is used to
  // timeout and send a NACK instead.
  always_ff @ (posedge clk_i or negedge rst_ni) begin : clk_nack_after_stretch
    if (!rst_ni) begin
      stretch_active_cnt <= '0;
    end else if (actively_stretching) begin
      stretch_active_cnt <= stretch_active_cnt + 1'b1;
    end else begin
      stretch_active_cnt <= '0;
    end
  end

  // The TARGET can stretch the clock during any time that the host drives SCL to 0.
  // However, we (the HOST) cannot know it is being stretched until we release SCL,
  // usually trying to create the next clock pulse.
  // There is a minimum 3-cycle round trip (1-cycle output flop, 2-cycle input synchronizer),
  // between releasing the clock and observing the effect of releasing the clock on
  // the inputs. However, this is really '1 + t_r + 2' as the bus also needs to slew to '1
  // before can observe it. Even if the TARGET is not stretching the clock, we cannot
  // confirm it until at-least this amount of time has elapsed.
  //
  // 'stretch_predict_cnt_expired' becomes active once we have observed (4 + t_r) cycles of
  // delay, and if !scl_i at this point we know that the TARGET is stretching the clock.
  // > This implementation requires 'thigh >= 4' to guarantee we don't miss stretching.
  logic [31:0] stretch_cnt_threshold;
  assign stretch_cnt_threshold = 32'd2 + 32'(t_r_i);

  logic stretch_predict_cnt_expired;
  always_ff @ (posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stretch_predict_cnt_expired <= 1'b0;
    end else begin
      if (stretch_idle_cnt == stretch_cnt_threshold) begin
        stretch_predict_cnt_expired <= 1'b1;
      end else if (!stretch_en) begin
        stretch_predict_cnt_expired <= 1'b0;
      end
    end
  end

  // While the FSM is halted due to an unhandled 'nak' irq in Host-Mode, this counter can
  // be used to trigger a timeout which disables Host-Mode and creates a STOP condition to
  // end the transaction.
  logic unhandled_nak_cnt_expired;
  always_ff @ (posedge clk_i or negedge rst_ni) begin : unhandled_nak_cnt_b
    if (!rst_ni) begin
      unhandled_nak_cnt <= '0;
      unhandled_nak_cnt_expired <= 1'b0;
    end else if (unhandled_unexp_nak_i && host_enable_i && host_nack_handler_timeout_en_i) begin
      // Increment the counter while the FSM is halted.
      unhandled_nak_cnt <= unhandled_nak_cnt + 1'b1;
      if (unhandled_nak_cnt > host_nack_handler_timeout_i) begin
        unhandled_nak_cnt_expired <= 1'b1;
      end
    end else begin
      unhandled_nak_cnt <= '0;
      unhandled_nak_cnt_expired <= 1'b0;
    end
  end

  // Latch the nack next byte value when we receive an address to write to but
  // there is no space in the ACQ FIFO. The address is still ack'ed to be
  // compatible with the
  always_ff @ (posedge clk_i or negedge rst_ni) begin : clk_nack_next_byte
    if (!rst_ni) begin
      nack_next_byte_q <= 1'b0;
    end else if (set_nack_next_byte) begin
      nack_next_byte_q <= 1'b1;
    end else if (clear_nack_next_byte) begin
      nack_next_byte_q <= 1'b0;
    end
  end

  // Bit index implementation
  always_ff @ (posedge clk_i or negedge rst_ni) begin : bit_counter
    if (!rst_ni) begin
      bit_index <= 3'd7;
    end else if (bit_clr) begin
      bit_index <= 3'd7;
    end else if (bit_decr) begin
      bit_index <= bit_index - 1'b1;
    end else begin
      bit_index <= bit_index;
    end
  end

  // Deserializer for a byte read from the bus
  always_ff @ (posedge clk_i or negedge rst_ni) begin : read_register
    if (!rst_ni) begin
      read_byte <= 8'h00;
    end else if (read_byte_clr) begin
      read_byte <= 8'h00;
    end else if (shift_data_en) begin
      read_byte[7:0] <= {read_byte[6:0], sda_i};  // MSB goes in first
    end
  end

  // Number of bytes to read
  always_comb begin : byte_number
    if (!fmt_flag_read_bytes_i) byte_num = 9'd0;
    else if (fmt_byte_i == '0) byte_num = 9'd256;
    else byte_num = 9'(fmt_byte_i);
  end

  // Byte index implementation
  always_ff @ (posedge clk_i or negedge rst_ni) begin : byte_counter
    if (!rst_ni) begin
      byte_index <= '0;
    end else if (byte_clr) begin
      byte_index <= byte_num;
    end else if (byte_decr) begin
      byte_index <= byte_index - 1'b1;
    end else begin
      byte_index <= byte_index;
    end
  end

  // SDA and SCL at the previous clock edge
  always_ff @ (posedge clk_i or negedge rst_ni) begin : bus_prev
    if (!rst_ni) begin
      scl_i_q <= 1'b1;
      sda_i_q <= 1'b1;
    end else begin
      scl_i_q <= scl_i;
      sda_i_q <= sda_i;
    end
  end

  // Registers whether a transaction start has been observed.
  // A transaction start does not include a "restart", but rather
  // the first start after enabling i2c, or a start observed after a
  // stop.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      trans_started <= '0;
    end else if (trans_started && !host_enable_i) begin
      trans_started <= '0;
    end else if (log_start) begin
      trans_started <= 1'b1;
    end else if (log_stop) begin
      trans_started <= 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pend_restart <= '0;
    end else if (pend_restart && !host_enable_i) begin
      pend_restart <= '0;
    end else if (req_restart) begin
      pend_restart <= 1'b1;
    end else if (log_start) begin
      pend_restart <= '0;
    end
  end

  // To resolve ambiguity with early SDA arrival, reject control symbols when
  // SCL goes low too soon. The hold time for ordinary data/ACK bits is too
  // short to reliably see SCL change before SDA. Use the hold time for
  // control signals to ensure a Start or Stop symbol was actually received.
  // Requirements: thd_dat + 1 < thd_sta
  //   The extra (+1) here is to account for a late SDA arrival due to CDC
  //   skew.
  //
  // Note that this counter combines Start and Stop detection into one
  // counter. A controller-only reset scenario could end up with a Stop
  // following shortly after a Start, with the requisite setup time not
  // observed.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ctrl_det_count <= '0;
    end else if (start_det_trigger || stop_det_trigger) begin
      ctrl_det_count <= 16'd1;
    end else if (start_det_pending || stop_det_pending) begin
      ctrl_det_count <= ctrl_det_count + 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      start_det_pending <= 1'b0;
    end else if (start_det_trigger) begin
      start_det_pending <= 1'b1;
    end else if (!target_enable_i || !scl_i || start_det || stop_det_trigger) begin
      start_det_pending <= 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stop_det_pending <= 1'b0;
    end else if (stop_det_trigger) begin
      stop_det_pending <= 1'b1;
    end else if (!target_enable_i || !scl_i || stop_det || start_det_trigger) begin
      stop_det_pending <= 1'b0;
    end
  end

  // (Repeated) Start condition detection by target
  assign start_det_trigger = target_enable_i && (scl_i_q && scl_i) & (sda_i_q && !sda_i);
  assign start_det = target_enable_i && start_det_pending && (ctrl_det_count >= thd_dat_i);

  // Stop condition detection by target
  assign stop_det_trigger = target_enable_i && (scl_i_q && scl_i) & (!sda_i_q && sda_i);
  assign stop_det = target_enable_i && stop_det_pending && (ctrl_det_count >= thd_dat_i);

  // Bit counter on the target side
  assign bit_ack = (bit_idx == 4'd8); // ack

  // Increment counter on negative SCL edge
  always_ff @ (posedge clk_i or negedge rst_ni) begin : tgt_bit_counter
    if (!rst_ni) begin
      bit_idx <= 4'd0;
    end else if (start_det) begin
      bit_idx <= 4'd0;
    end else if (scl_i_q && !scl_i) begin
      // input byte clear is always asserted on a "start"
      // condition.
      if (input_byte_clr || bit_ack) bit_idx <= 4'd0;
      else bit_idx <= bit_idx + 1'b1;
    end else begin
      bit_idx <= bit_idx;
    end
  end

  // Deserializer for a byte read from the bus on the target side
  assign address0_match = ((input_byte[7:1] & target_mask0_i) == target_address0_i);
  assign address1_match = ((input_byte[7:1] & target_mask1_i) == target_address1_i);
  assign address_match = (address0_match || address1_match);

  // Shift data in on positive SCL edge
  always_ff @ (posedge clk_i or negedge rst_ni) begin : tgt_input_register
    if (!rst_ni) begin
      input_byte <= 8'h00;
    end else if (input_byte_clr) begin
      input_byte <= 8'h00;
    end else if (!scl_i_q && scl_i) begin
      if (!bit_ack) input_byte[7:0] <= {input_byte[6:0], sda_i};  // MSB goes in first
    end
  end

  // Detection by the target of ACK bit sent by the host
  always_ff @ (posedge clk_i or negedge rst_ni) begin : host_ack_register
    if (!rst_ni) begin
      host_ack <= 1'b0;
    end else if (!scl_i_q && scl_i) begin
      if (bit_ack) host_ack <= ~sda_i;
    end
  end

  // An artificial acq_fifo_wready is used here to ensure we always have
  // space to asborb a stop / repeat start format byte.  Without guaranteeing
  // space for this entry, the target module would need to stretch the
  // repeat start / stop indication.  If a system does not support stretching,
  // there's no good way for a stop to be NACK'd.
  // Besides the space necessary for the stop format byte, we also need one
  // space to send a NACK. This means that we can notify software that a NACK
  // has happened while still keeping space for a subsequent stop or repeated
  // start.
  logic [AcqFifoDepthWidth-1:0] acq_fifo_remainder;
  assign acq_fifo_remainder = AcqFifoDepth - acq_fifo_depth_i;
  // This is used for acq_fifo_wready_o to send the ACQ FIFO full alert to
  // software.
  assign acq_fifo_plenty_space = acq_fifo_remainder > AcqFifoDepthWidth'(2);
  assign acq_fifo_full_or_last_space = acq_fifo_remainder <= AcqFifoDepthWidth'(1);

  // State definitions
  typedef enum logic [5:0] {
    Idle,
    ///////////////////////
    // Host function states
    ///////////////////////
    Active, PopFmtFifo,
    // Host function starts a transaction
    SetupStart, HoldStart, ClockStart,
    // Host function stops a transaction
    SetupStop, HoldStop, ClockStop,
    // Host function transmits a bit to the external target
    ClockLow, ClockPulse, HoldBit,
    // Host function recevies an ack from the external target
    ClockLowAck, ClockPulseAck, HoldDevAck,
    // Host function reads a bit from the external target
    ReadClockLow, ReadClockPulse, ReadHoldBit,
    // Host function transmits an ack to the external target
    HostClockLowAck, HostClockPulseAck, HostHoldBitAck,

    /////////////////////////
    // Target function states
    /////////////////////////

    // Target function receives start and address from external host
    AcquireStart, AddrRead,
    // Target function acknowledges the address and returns an ack to external host
    AddrAckWait, AddrAckSetup, AddrAckPulse, AddrAckHold,
    // Target function sends read data to external host-receiver
    TransmitWait, TransmitSetup, TransmitPulse, TransmitHold,
    // Target function receives ack from external host
    TransmitAck, TransmitAckPulse, WaitForStop,
    // Target function receives write data from the external host
    AcquireByte,
    // Target function sends ack to external host
    AcquireAckWait, AcquireAckSetup, AcquireAckPulse, AcquireAckHold,
    // Target function sends not acknowledge to external host
    NackWait, NackSetup, NackPulse, NackHold,
    // Target function clock stretch handling.
    StretchAddr,
    StretchTx, StretchTxSetup,
    StretchAcqFull
  } state_e;

  state_e state_q, state_d;


  // enable sda interference detection
  // Detects when the controller releases sda to be pulled high, but the line
  // is unexpectedly held low by another driver.
  logic en_sda_interf_det;
  logic [16:0] sda_rise_cnt;

  // sda_rise_latency refers to the time between
  // changing sda_o to 1 and sampling sda_i as 1.
  // This value is a combination of the bus rise time and the
  // input sychronization delay
  logic [16:0] sda_rise_latency;
  assign sda_rise_latency = t_r_i + 16'h2;

  // When detection is enabled, count through the rise time.
  // Once rise time count is reached, hold in place until disabled.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sda_rise_cnt <= '0;
    end else if (!en_sda_interf_det && |sda_rise_cnt) begin
      // When detection is disabled, 0 the count.
      // Only 0 the count if the count is currently non-zero to avoid
      // unnecessary toggling.
      sda_rise_cnt <= '0;
    end else if (en_sda_interf_det && sda_rise_cnt < sda_rise_latency) begin
      sda_rise_cnt <= sda_rise_cnt + 1'b1;
    end
  end

  // There are two conditions of sda interference:
  // 1. When the host function is first enabled, but for some reason sda_i is already 0.
  // 2. Any time the host function is trying to drive a 1 but it observes a 0 instead.
  //
  // When the count is reached, we are pass the rise time period.
  // Now check for any inconsistency in the sda value.
  assign event_sda_interference_o = (host_idle_o & host_enable_i & !sda_i) |
                                    ((sda_rise_cnt == sda_rise_latency) & (sda_o & !sda_i));

  logic rw_bit_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rw_bit_q <= '0;
    end else if (bit_ack && address_match) begin
      rw_bit_q <= rw_bit;
    end
  end

  // Reverse the bit order since data should be sent out MSB first
  logic [TX_FIFO_WIDTH-1:0] tx_fifo_rdata;
  assign tx_fifo_rdata = {<<1{tx_fifo_rdata_i}};

  // The usage of target_idle_o directly confuses xcelium and leads the
  // the simulator to a combinational loop. While it may be a tool recognized
  // loop, it is not an actual physical loop, since target_idle affects only
  // state_d, which is not used directly by any logic in this module.
  // This is a work around for a known tool limitation.
  logic target_idle;
  assign target_idle = target_idle_o;

  // During a host issued read, a stop was received without first seeing a nack.
  // This may be harmless but is technically illegal behavior, notify software.
  assign event_unexp_stop_o = !target_idle & rw_bit_q & stop_det & !expect_stop;

  // Outputs for each state
  always_comb begin : state_outputs
    host_idle_o = 1'b1;
    target_idle_o = 1'b1;
    sda_d = 1'b1;
    scl_d = 1'b1;
    fmt_fifo_rready_o = 1'b0;
    rx_fifo_wvalid_o = 1'b0;
    rx_fifo_wdata_o = RX_FIFO_WIDTH'(0);
    tx_fifo_rready_o = 1'b0;
    acq_fifo_wvalid_o = 1'b0;
    acq_fifo_wdata_o = ACQ_FIFO_WIDTH'(0);
    event_nak_o = 1'b0;
    event_scl_interference_o = 1'b0;
    event_sda_unstable_o = 1'b0;
    event_cmd_complete_o = 1'b0;
    event_target_nack_o = 1'b0;
    rw_bit = rw_bit_q;
    stretch_en = 1'b0;
    expect_stop = 1'b0;
    actively_stretching = 1'b0;
    unique case (state_q)
      // Idle: initial state, SDA is released (high), SCL is released if the
      // bus is idle. Otherwise, if no STOP condition has been sent yet,
      // continue pulling SCL low in host mode.
      Idle : begin
        sda_d = 1'b1;
        if (host_enable_i && trans_started) begin
          host_idle_o = 1'b0;
          scl_d = 1'b0;
        end else begin
          host_idle_o = 1'b1;
          scl_d = 1'b1;
        end
      end

      ///////////////
      // HOST MODE //
      ///////////////

      // SetupStart: SDA and SCL are released
      SetupStart : begin
        host_idle_o = 1'b0;
        sda_d = 1'b1;
        scl_d = 1'b1;
        if (log_start) event_cmd_complete_o = pend_restart;
      end
      // HoldStart: SDA is pulled low, SCL is released
      HoldStart : begin
        host_idle_o = 1'b0;
        sda_d = 1'b0;
        scl_d = 1'b1;
      end
      // ClockStart: SCL is pulled low, SDA stays low
      ClockStart : begin
        host_idle_o = 1'b0;
        sda_d = 1'b0;
        scl_d = 1'b0;
      end
      ClockLow : begin
        host_idle_o = 1'b0;
        if (pend_restart) begin
          sda_d = 1'b1;
        end else begin
          sda_d = fmt_byte_i[bit_index];
        end
        scl_d = 1'b0;
      end
      // ClockPulse: SCL is released, SDA keeps the indexed bit value
      ClockPulse : begin
        host_idle_o = 1'b0;
        sda_d = fmt_byte_i[bit_index];
        scl_d = 1'b1;
        stretch_en = 1'b1;
        if (scl_i_q && !scl_i)  event_scl_interference_o = 1'b1;
        if (sda_i_q != sda_i)   event_sda_unstable_o = 1'b1;
      end
      // HoldBit: SCL is pulled low
      HoldBit : begin
        host_idle_o = 1'b0;
        sda_d = fmt_byte_i[bit_index];
        scl_d = 1'b0;
      end
      // ClockLowAck: SCL pulled low, SDA is released
      ClockLowAck : begin
        host_idle_o = 1'b0;
        sda_d = 1'b1;
        scl_d = 1'b0;
      end
      // ClockPulseAck: SCL is released
      ClockPulseAck : begin
        host_idle_o = 1'b0;
        sda_d = 1'b1;
        scl_d = 1'b1;
        if (!scl_i_q && scl_i && sda_i && !fmt_flag_nak_ok_i) event_nak_o = 1'b1;
        stretch_en = 1'b1;
        if (scl_i_q && !scl_i)  event_scl_interference_o = 1'b1;
        if (sda_i_q != sda_i)   event_sda_unstable_o = 1'b1;
      end
      // HoldDevAck: SCL is pulled low
      HoldDevAck : begin
        host_idle_o = 1'b0;
        sda_d = 1'b1;
        scl_d = 1'b0;
      end
      // ReadClockLow: SCL is pulled low, SDA is released
      ReadClockLow : begin
        host_idle_o = 1'b0;
        sda_d = 1'b1;
        scl_d = 1'b0;
      end
      // ReadClockPulse: SCL is released, the indexed bit value is read off SDA
      ReadClockPulse : begin
        host_idle_o = 1'b0;
        scl_d = 1'b1;
        stretch_en = 1'b1;
        if (scl_i_q && !scl_i)  event_scl_interference_o = 1'b1;
        if (sda_i_q != sda_i)   event_sda_unstable_o = 1'b1;
      end
      // ReadHoldBit: SCL is pulled low
      ReadHoldBit : begin
        host_idle_o = 1'b0;
        scl_d = 1'b0;
        if (bit_index == '0 && tcount_q == 20'd1) begin
          rx_fifo_wvalid_o = 1'b1;      // assert that rx_fifo has valid data
          rx_fifo_wdata_o = read_byte;  // transfer read data to rx_fifo
        end
      end
      // HostClockLowAck: SCL pulled low, SDA is conditional
      HostClockLowAck : begin
        host_idle_o = 1'b0;
        scl_d = 1'b0;

        // If it is the last byte of a read, send a NAK before the stop.
        // Otherwise send the ack.
        if (fmt_flag_read_continue_i) sda_d = 1'b0;
        else if (byte_index == 9'd1) sda_d = 1'b1;
        else sda_d = 1'b0;
      end
      // HostClockPulseAck: SCL is released
      HostClockPulseAck : begin
        host_idle_o = 1'b0;
        if (fmt_flag_read_continue_i) sda_d = 1'b0;
        else if (byte_index == 9'd1) sda_d = 1'b1;
        else sda_d = 1'b0;
        scl_d = 1'b1;
        stretch_en = 1'b1;
        if (scl_i_q && !scl_i)  event_scl_interference_o = 1'b1;
        if (sda_i_q != sda_i)   event_sda_unstable_o = 1'b1;
      end
      // HostHoldBitAck: SCL is pulled low
      HostHoldBitAck : begin
        host_idle_o = 1'b0;
        if (fmt_flag_read_continue_i) sda_d = 1'b0;
        else if (byte_index == 9'd1) sda_d = 1'b1;
        else sda_d = 1'b0;
        scl_d = 1'b0;
      end
      // ClockStop: SCL is pulled low, SDA stays low
      ClockStop : begin
        host_idle_o = 1'b0;
        sda_d = 1'b0;
        scl_d = 1'b0;
      end
      // SetupStop: SDA is pulled low, SCL is released
      SetupStop : begin
        host_idle_o = 1'b0;
        sda_d = 1'b0;
        scl_d = 1'b1;
      end
      // HoldStop: SDA and SCL are released
      HoldStop : begin
        host_idle_o = 1'b0;
        sda_d = 1'b1;
        scl_d = 1'b1;
        event_cmd_complete_o = 1'b1;
      end
      // Active: continue while keeping SCL low
      Active : begin
        host_idle_o = 1'b0;

        // If this is a transaction start, do not drive scl low
        // since in the next state we will drive it high to initiate
        // the start bit.
        // If this is a restart, continue driving the clock low.
        scl_d = fmt_flag_start_before_i && !trans_started;
      end
      // PopFmtFifo: populate fmt_fifo
      PopFmtFifo : begin
        host_idle_o = 1'b0;
        if (fmt_flag_stop_after_i) scl_d = 1'b1;
        else scl_d = 1'b0;
        fmt_fifo_rready_o = 1'b1;
      end

      /////////////////
      // TARGET MODE //
      /////////////////

      // AcquireStart: hold start condition
      AcquireStart : begin
        target_idle_o = 1'b0;
      end
      // AddrRead: read and compare target address
      AddrRead : begin
        target_idle_o = 1'b0;
        rw_bit = input_byte[0];
      end
      // AddrAckWait: pause before acknowledging
      AddrAckWait : begin
        target_idle_o = 1'b0;
      end
      // AddrAckSetup: target pulls SDA low while SCL is low
      AddrAckSetup : begin
        target_idle_o = 1'b0;
        sda_d = 1'b0;
      end
      // AddrAckPulse: target pulls SDA low while SCL is released
      AddrAckPulse : begin
        target_idle_o = 1'b0;
        sda_d = 1'b0;
      end
      // AddrAckHold: target pulls SDA low while SCL is pulled low
      AddrAckHold : begin
        target_idle_o = 1'b0;
        sda_d = 1'b0;

        // Upon transition to next state, populate the acquisition fifo
        if (tcount_q == 20'd1) begin
          if (nack_next_byte_q) begin
            // If we're here because the ACQ FIFO is nearly full but we need
            // to acknowlegde our address because this is a write, then
            // record this.
            acq_fifo_wvalid_o = 1'b1;
            acq_fifo_wdata_o = {AcqNackStart, input_byte};
          end else begin
            // Only write to fifo if stretching conditions are not met
            acq_fifo_wvalid_o = ~stretch_addr;
            acq_fifo_wdata_o = {AcqStart, input_byte};
          end
        end
      end
      // TransmitWait: Check if data is available prior to transmit
      TransmitWait : begin
        target_idle_o = 1'b0;
      end
      // TransmitSetup: target shifts indexed bit onto SDA while SCL is low
      TransmitSetup : begin
        target_idle_o = 1'b0;
        sda_d = tx_fifo_rdata[3'(bit_idx)];
      end
      // TransmitPulse: target holds indexed bit onto SDA while SCL is released
      TransmitPulse : begin
        target_idle_o = 1'b0;

        // Hold value
        sda_d = sda_q;
      end
      // TransmitHold: target holds indexed bit onto SDA while SCL is pulled low, for the hold time
      TransmitHold : begin
        target_idle_o = 1'b0;

        // Hold value
        sda_d = sda_q;
      end
      // TransmitAck: target waits for host to ACK transmission
      TransmitAck : begin
        target_idle_o = 1'b0;
      end
      TransmitAckPulse : begin
        target_idle_o = 1'b0;
        if (!scl_i) begin
          // Pop Fifo regardless of ack/nack
          tx_fifo_rready_o = 1'b1;
        end
      end
      // WaitForStop just waiting for host to trigger a stop after nack
      WaitForStop : begin
        target_idle_o = 1'b0;
        expect_stop = 1'b1;
        sda_d = 1'b1;
      end
      // AcquireByte: target acquires a byte
      AcquireByte : begin
        target_idle_o = 1'b0;
      end
      // AcquireAckWait: pause before acknowledging
      AcquireAckWait : begin
        target_idle_o = 1'b0;
      end
      // AcquireAckSetup: target pulls SDA low while SCL is low
      AcquireAckSetup : begin
        target_idle_o = 1'b0;
        sda_d = 1'b0;
      end
      // AcquireAckPulse: target pulls SDA low while SCL is released
      AcquireAckPulse : begin
        target_idle_o = 1'b0;
        sda_d = 1'b0;
      end
      // AcquireAckHold: target pulls SDA low while SCL is pulled low
      AcquireAckHold : begin
        target_idle_o = 1'b0;
        sda_d = 1'b0;

        if (tcount_q == 20'd1) begin
          acq_fifo_wvalid_o = ~stretch_rx;          // assert that acq_fifo has space
          acq_fifo_wdata_o = {AcqData, input_byte}; // transfer data to acq_fifo
        end
      end
      // NackWait: pause before not acknowledge.
      NackWait : begin
        target_idle_o = 1'b0;
      end
      // NackSetup: target holds SDA high while SCL is low.
      NackSetup : begin
        target_idle_o = 1'b0;
        sda_d = 1'b1;
      end
      // NackPulse: target holds SDA high while SCL is released.
      NackPulse : begin
        target_idle_o = 1'b0;
        sda_d = 1'b1;
      end
      // NackHold: target holds SDA high while SCL is pulled low.
      NackHold : begin
        target_idle_o = 1'b0;
        sda_d = 1'b1;

        if (tcount_q == 20'd1) begin
          // Stretching happens with two spaces left in the ACQ FIFO: one for
          // a stop/restart and the other for this NACK message. There might
          // not be any space left if there already is a NACK message in the
          // FIFO and software has not responded to the full interrupt. In
          // that case this message won't make it into the ACQ FIFO.
          acq_fifo_wvalid_o = 1'b1;                 // Write to acq_fifo.
          acq_fifo_wdata_o = {AcqNack, input_byte}; // Put NACK into acq_fifo.
          // Because we go to idle mode after this we will not get a command
          // complete notification from a restart or a stop. We must notify
          // software that it needs to start processing the ACQ FIFO.
          event_cmd_complete_o = 1'b1;
          event_target_nack_o = 1'b1;
        end
      end
      // StretchAddr: target stretches the clock if matching address cannot be
      // deposited yet.
      StretchAddr : begin
        target_idle_o = 1'b0;
        scl_d = 1'b0;

        acq_fifo_wvalid_o = !stretch_addr || nack_timeout;
        acq_fifo_wdata_o = {AcqStart, input_byte};
        actively_stretching = stretch_addr;
      end
      // StretchTx: target stretches the clock when tx_fifo is empty
      StretchTx : begin
        target_idle_o = 1'b0;
        scl_d = 1'b0;
      end
      // StretchTxSetup: drive the return data
      StretchTxSetup : begin
        target_idle_o = 1'b0;
        scl_d = 1'b0;
        sda_d = tx_fifo_rdata[3'(bit_idx)];
      end
      // StretchAcqFull: target stretches the clock when acq_fifo is full
      StretchAcqFull : begin
        target_idle_o = 1'b0;
        scl_d = 1'b0;

        // When space becomes available, deposit entry
        acq_fifo_wvalid_o = ~stretch_rx;          // assert that acq_fifo has space
        acq_fifo_wdata_o = {AcqData, input_byte}; // transfer data to acq_fifo
        actively_stretching = stretch_rx;
      end
      // default
      default : begin
        host_idle_o = 1'b1;
        target_idle_o = 1'b1;
        sda_d = 1'b1;
        scl_d = 1'b1;
        fmt_fifo_rready_o = 1'b0;
        rx_fifo_wvalid_o = 1'b0;
        rx_fifo_wdata_o = RX_FIFO_WIDTH'(0);
        tx_fifo_rready_o = 1'b0;
        acq_fifo_wvalid_o = 1'b0;
        acq_fifo_wdata_o = ACQ_FIFO_WIDTH'(0);
        event_nak_o = 1'b0;
        event_scl_interference_o = 1'b0;
        event_sda_unstable_o = 1'b0;
        event_cmd_complete_o = 1'b0;
        event_target_nack_o = 1'b0;
        actively_stretching = 1'b0;
      end
    endcase // unique case (state_q)

    // start / stop override
    if (start_det || stop_det) begin
      // Only add an entry if this is a repeated start or stop.
      acq_fifo_wvalid_o = !target_idle_o;
      acq_fifo_wdata_o = start_det ? {AcqRestart, input_byte} :
                                     {AcqStop, input_byte};
      event_cmd_complete_o = !target_idle_o;
    end
  end

  assign stretch_rx   = !acq_fifo_plenty_space;
  assign stretch_addr = stretch_rx;

  // This condition determines whether this target has stretched beyond the
  // timeout in which case it must now send a NACK to the host.
  assign nack_timeout = nack_timeout_en_i && stretch_active_cnt >= nack_timeout_i;

  // Stretch Tx phase when:
  // 1. When there is no data to return to host
  // 2. When the acq_fifo contains any entry other than a singular start condition
  //    read command.
  //
  // Only the fifo depth is checked here, because stretch_tx is only evaluated by the
  // fsm on the read path. This means a read start byte has already been deposited.
  assign stretch_tx = ~tx_fifo_rvalid_i |
                      (acq_fifo_depth_i > AcqFifoDepthWidth'(1'b1));

  // Only used for assertion
  logic unused_acq_rdata;
  assign unused_acq_rdata = |acq_fifo_rdata_i;

  // Conditional state transition
  always_comb begin : state_functions
    state_d = state_q;
    load_tcount = 1'b0;
    tcount_sel = tNoDelay;
    bit_decr = 1'b0;
    bit_clr = 1'b0;
    byte_decr = 1'b0;
    byte_clr = 1'b0;
    read_byte_clr = 1'b0;
    shift_data_en = 1'b0;
    log_start = 1'b0;
    log_stop = 1'b0;
    req_restart = 1'b0;
    input_byte_clr = 1'b0;
    en_sda_interf_det = 1'b0;
    event_tx_stretch_o = 1'b0;
    set_nack_next_byte = 1'b0;
    clear_nack_next_byte = 1'b0;
    host_disable_o = 1'b0;

    unique case (state_q)
      // Idle: initial state, SDA and SCL are released (high)
      Idle : begin
        if (!host_enable_i && !target_enable_i) state_d = Idle; // Idle unless host is enabled
        else if (host_enable_i) begin
          if (fmt_fifo_rvalid_i) state_d = Active;
        end
        clear_nack_next_byte = 1'b1;
      end

      ///////////////
      // HOST MODE //
      ///////////////

      // SetupStart: SDA and SCL are released
      SetupStart : begin
        if (tcount_q == 20'd1) begin
          state_d = HoldStart;
          load_tcount = 1'b1;
          tcount_sel = tHoldStart;
          log_start = 1'b1;
        end
      end
      // HoldStart: SDA is pulled low, SCL is released
      HoldStart : begin
        if (tcount_q == 20'd1) begin
          state_d = ClockStart;
          load_tcount = 1'b1;
          tcount_sel = tClockStart;
        end
      end
      // ClockStart: SCL is pulled low, SDA stays low
      ClockStart : begin
        if (tcount_q == 20'd1) begin
          state_d = ClockLow;
          load_tcount = 1'b1;
          tcount_sel = tClockLow;
        end
      end
      // ClockLow: SCL stays low, shift indexed bit onto SDA
      ClockLow : begin
        en_sda_interf_det = 1'b1;
        if (tcount_q == 20'd1) begin
          load_tcount = 1'b1;
          if (pend_restart) begin
            state_d = SetupStart;
            tcount_sel = tSetupStart;
          end else begin
            state_d = ClockPulse;
            tcount_sel = tClockPulse;
          end
        end
      end
      // ClockPulse: SCL is released, SDA keeps the indexed bit value
      ClockPulse : begin
        en_sda_interf_det = 1'b1;
        if (!scl_i && stretch_predict_cnt_expired) begin
          // Saw stretching. Remain in this state and don't count down until we see SCL high.
          load_tcount = 1'b1;
          tcount_sel = tClockHigh;
        end else if (tcount_q == 20'd1) begin
          state_d = HoldBit;
          load_tcount = 1'b1;
          tcount_sel = tHoldBit;
        end
      end
      // HoldBit: SCL is pulled low
      HoldBit : begin
        en_sda_interf_det = 1'b1;
        if (tcount_q == 20'd1) begin
          en_sda_interf_det = 1'b0;
          load_tcount = 1'b1;
          tcount_sel = tClockLow;
          if (bit_index == '0) begin
            state_d = ClockLowAck;
            bit_clr = 1'b1;
          end else begin
            state_d = ClockLow;
            bit_decr = 1'b1;
          end
        end
      end
      // ClockLowAck: Target is allowed to drive ack back
      // to host (dut)
      ClockLowAck : begin
        if (tcount_q == 20'd1) begin
          state_d = ClockPulseAck;
          load_tcount = 1'b1;
          tcount_sel = tClockPulse;
        end
      end
      // ClockPulseAck: SCL is released
      ClockPulseAck : begin
        if (!scl_i && stretch_predict_cnt_expired) begin
          // Saw stretching. Remain in this state and don't count down until we see SCL high.
          load_tcount = 1'b1;
          tcount_sel = tClockHigh;
        end else begin
          if (unhandled_unexp_nak_i) begin
            // If we are awaiting software to handle an unexpected NACK, halt the FSM here.
            // The current transaction does not end, and SCL remains released so the observed
            // bus behaviour is a very long 9th clock pulse. The next entry from the FMTFIFO
            // is not popped until the NACK is acknowledged by software.
            load_tcount = 1'b1;
            tcount_sel = tClockHigh;
            if (unhandled_nak_cnt_expired) begin
              // If our timeout counter expires, generate a STOP condition and disable Host-Mode.
              state_d = ClockStop;
              load_tcount = 1'b1;
              tcount_sel = tClockStop;
              host_disable_o = 1'b1;
            end
          end else if (tcount_q == 20'd1) begin
            state_d = HoldDevAck;
            load_tcount = 1'b1;
            tcount_sel = tHoldBit;
          end
        end
      end
      // HoldDevAck: SCL is pulled low
      HoldDevAck : begin
        if (tcount_q == 20'd1) begin
          if (fmt_flag_stop_after_i) begin
            state_d = ClockStop;
            load_tcount = 1'b1;
            tcount_sel = tClockStop;
          end else begin
            state_d = PopFmtFifo;
            load_tcount = 1'b1;
            tcount_sel = tNoDelay;
          end
        end
      end
      // ReadClockLow: SCL is pulled low, SDA is released
      ReadClockLow : begin
        if (tcount_q == 20'd1) begin
          state_d = ReadClockPulse;
          load_tcount = 1'b1;
          tcount_sel = tClockPulse;
        end
      end
      // ReadClockPulse: SCL is released, the indexed bit value is read off SDA
      ReadClockPulse : begin
        if (!scl_i && stretch_predict_cnt_expired) begin
          // Saw stretching. Remain in this state and don't count down until we see SCL high.
          load_tcount = 1'b1;
          tcount_sel = tClockHigh;
        end else if (tcount_q == 20'd1) begin
          state_d = ReadHoldBit;
          load_tcount = 1'b1;
          tcount_sel = tHoldBit;
          shift_data_en = 1'b1; // SDA is sampled on the final clk_i cycle of the SCL pulse.
        end
      end
      // ReadHoldBit: SCL is pulled low
      ReadHoldBit : begin
        if (tcount_q == 20'd1) begin
          load_tcount = 1'b1;
          tcount_sel = tClockLow;
          if (bit_index == '0) begin
            state_d = HostClockLowAck;
            bit_clr = 1'b1;
            read_byte_clr = 1'b1;
          end else begin
            state_d = ReadClockLow;
            bit_decr = 1'b1;
          end
        end
      end
      // HostClockLowAck: SCL is pulled low, SDA is conditional based on
      // byte position
      HostClockLowAck : begin
        en_sda_interf_det = 1'b1;
        if (tcount_q == 20'd1) begin
          state_d = HostClockPulseAck;
          load_tcount = 1'b1;
          tcount_sel = tClockPulse;
        end
      end
      // HostClockPulseAck: SCL is released
      HostClockPulseAck : begin
        en_sda_interf_det = 1'b1;
        if (!scl_i && stretch_predict_cnt_expired) begin
          // Saw stretching. Remain in this state and don't count down until we see SCL high.
          load_tcount = 1'b1;
          tcount_sel = tClockHigh;
        end else if (tcount_q == 20'd1) begin
          state_d = HostHoldBitAck;
          load_tcount = 1'b1;
          tcount_sel = tHoldBit;
        end
      end
      // HostHoldBitAck: SCL is pulled low
      HostHoldBitAck : begin
        en_sda_interf_det = 1'b1;
        if (tcount_q == 20'd1) begin
          en_sda_interf_det = 1'b0;
          if (byte_index == 9'd1) begin
            if (fmt_flag_stop_after_i) begin
              state_d = ClockStop;
              load_tcount = 1'b1;
              tcount_sel = tClockStop;
            end else begin
              state_d = PopFmtFifo;
              load_tcount = 1'b1;
              tcount_sel = tNoDelay;
            end
          end else begin
            state_d = ReadClockLow;
            load_tcount = 1'b1;
            tcount_sel = tClockLow;
            byte_decr = 1'b1;
          end
        end
      end
      // ClockStop: SCL is pulled low, SDA stays low
      ClockStop : begin
        if (tcount_q == 20'd1) begin
          state_d = SetupStop;
          load_tcount = 1'b1;
          tcount_sel = tSetupStop;
        end
      end
      // SetupStop: SDA is pulled low, SCL is released
      SetupStop : begin
        if (tcount_q == 20'd1) begin
          state_d = HoldStop;
          load_tcount = 1'b1;
          tcount_sel = tHoldStop;
          log_stop = 1'b1;
        end
      end
      // HoldStop: SDA and SCL are released
      HoldStop : begin
        en_sda_interf_det = 1'b1;
        if (tcount_q == 20'd1) begin
          en_sda_interf_det = 1'b0;
          if (!host_enable_i) begin
            state_d = Idle;
            load_tcount = 1'b1;
            tcount_sel = tNoDelay;
          end else begin
            state_d = PopFmtFifo;
            load_tcount = 1'b1;
            tcount_sel = tNoDelay;
          end
        end
      end
      // Active: continue while keeping SCL low
      Active : begin
        if (fmt_flag_read_bytes_i) begin
          byte_clr = 1'b1;
          state_d = ReadClockLow;
          load_tcount = 1'b1;
          tcount_sel = tClockLow;
        end else if (fmt_flag_start_before_i && !trans_started) begin
          state_d = SetupStart;
          load_tcount = 1'b1;
          tcount_sel = tSetupStart;
        end else begin
          state_d = ClockLow;
          load_tcount = 1'b1;
          req_restart = fmt_flag_start_before_i;
          tcount_sel = tClockLow;
        end
      end
      // PopFmtFifo: populate fmt_fifo
      PopFmtFifo : begin
        if (!host_enable_i) begin
          state_d = ClockStop;
          load_tcount = 1'b1;
          tcount_sel = tClockStop;
        end else if (fmt_fifo_depth_i == 7'h1) begin
          state_d = Idle;
          load_tcount = 1'b1;
          tcount_sel = tNoDelay;
        end else begin
          state_d = Active;
          load_tcount = 1'b1;
          tcount_sel = tNoDelay;
        end
      end


      /////////////////
      // TARGET MODE //
      /////////////////

      // AcquireStart: hold start condition
      AcquireStart : begin
        if (scl_i_q && !scl_i) begin
          // If we are not able to accept the start bit, stretch or nak
          state_d = AddrRead;
          input_byte_clr = 1'b1;
        end
        clear_nack_next_byte = 1'b1;
      end
      // AddrRead: read and compare target address
      AddrRead : begin
        if (bit_ack) begin
          if (address_match) begin
            if (acq_fifo_full_or_last_space) begin
              // We must have stretched before, and software has been notified
              // through and ACQ FIFO full event. Now we must NACK
              // unconditionally for reads. For writes we should NACK the
              // next byte unconditionally but still acknowledge the address.
              if (rw_bit_q) begin
                state_d = NackWait;
              end else begin
                state_d = AddrAckWait;
                set_nack_next_byte = 1'b1;
              end
            end else begin
              state_d = AddrAckWait;
            end
            load_tcount = 1'b1;
            tcount_sel = tClockStart;
          end else begin
            // This means this transaction is not meant for us.
            state_d = Idle;
          end
        end
      end
      // AddrAckWait: pause before acknowledging
      AddrAckWait : begin
        if (tcount_q == 20'd1 && !scl_i) begin
          state_d = AddrAckSetup;
        end
      end
      // AddrAckSetup: target pulls SDA low while SCL is low
      AddrAckSetup : begin
        if (scl_i) state_d = AddrAckPulse;
      end
      // AddrAckPulse: target pulls SDA low while SCL is released
      AddrAckPulse : begin
        if (!scl_i) begin
          state_d = AddrAckHold;
          load_tcount = 1'b1;
          tcount_sel = tClockStart;
        end
      end
      // AddrAckHold: target pulls SDA low while SCL is pulled low
      AddrAckHold : begin
        if (tcount_q == 20'd1) begin
          // Stretch when requested by software or when there is insufficient
          // space to hold the start / address format byte.
          // If there is sufficient space, the format byte is written into the acquisition fifo.
          // Don't stretch when we are unconditionally nacking the next byte
          // anyways.
          if (stretch_addr && !nack_next_byte_q) begin
            state_d = StretchAddr;
          end else if (rw_bit_q) begin
            state_d = TransmitWait;
          end else if (!rw_bit_q) begin
            state_d = AcquireByte;
          end
        end
      end
      // TransmitWait: Evaluate whether there are entries to send first
      TransmitWait : begin
        if (stretch_tx) begin
          state_d = StretchTx;
        end else begin
          state_d = TransmitSetup;
          load_tcount = 1'b1;
          tcount_sel = tClockStart;
        end
      end
      // TransmitSetup: target shifts indexed bit onto SDA while SCL is low
      TransmitSetup : begin
        if (scl_i) state_d = TransmitPulse;
      end
      // TransmitPulse: target shifts indexed bit onto SDA while SCL is released
      TransmitPulse : begin
        if (!scl_i) begin
          state_d = TransmitHold;
          load_tcount = 1'b1;
          tcount_sel = tClockStart;
        end
      end
      // TransmitHold: target shifts indexed bit onto SDA while SCL is pulled low
      TransmitHold : begin
        if (tcount_q == 20'd1) begin
          if (bit_ack) begin
            state_d = TransmitAck;
          end else begin
            load_tcount = 1'b1;
            tcount_sel = tClockStart;
            state_d = TransmitSetup;
          end
        end
      end
      // Wait for clock to become positive.
      TransmitAck : begin
        if (scl_i) begin
          state_d = TransmitAckPulse;
        end
      end
      // TransmitAckPulse: target waits for host to ACK transmission
      // If a nak is received, that means a stop is incoming.
      TransmitAckPulse : begin
        if (!scl_i) begin
          // If host acknowledged, that means we must continue
          if (host_ack) begin
            state_d = TransmitWait;
          end else begin
            // If host nak'd then the transaction is about to terminate, go to a wait state
            state_d = WaitForStop;
          end
        end
      end
      // An inert state just waiting for host to issue a stop
      // Cannot cycle back to idle directly as other events depend on the system being
      // non-idle.
      WaitForStop : begin
        state_d = WaitForStop;
      end
      // AcquireByte: target acquires a byte
      AcquireByte : begin
        if (bit_ack) begin
          // We can get to this spot if we have enabled NACK timeout. It must
          // mean that we have stretched when there were only two spaces left.
          // Now we must NACK unconditionally.
          // The other option is the ACQ FIFO was already full on the previous
          // address read. We now must NACK this byte and drop it
          // completely.
          if (acq_fifo_full_or_last_space || nack_next_byte_q) begin
            state_d = NackWait;
          end else begin
            state_d = AcquireAckWait;
          end
          load_tcount = 1'b1;
          tcount_sel = tClockStart;
        end
      end
      // AcquireAckWait: pause before acknowledging
      AcquireAckWait : begin
        if (tcount_q == 20'd1 && !scl_i) begin
          state_d = AcquireAckSetup;
        end
      end
      // AcquireAckSetup: target pulls SDA low while SCL is low
      AcquireAckSetup : begin
        if (scl_i) state_d = AcquireAckPulse;
      end
      // AcquireAckPulse: target pulls SDA low while SCL is released
      AcquireAckPulse : begin
        if (!scl_i) begin
          state_d = AcquireAckHold;
          load_tcount = 1'b1;
          tcount_sel = tClockStart;
        end
      end
      // AcquireAckHold: target pulls SDA low while SCL is pulled low
      AcquireAckHold : begin
        if (tcount_q == 20'd1) begin
          // If there is no space for the current entry, stretch clocks and
          // wait for software to make space.
          state_d = stretch_rx ? StretchAcqFull : AcquireByte;
        end
      end
      // NackWait: pause before not acknowledge.
      NackWait : begin
        if (tcount_q == 20'd1 && !scl_i) begin
          state_d = NackSetup;
        end
      end
      // NackSetup: target holds SDA high while SCL is low.
      NackSetup : begin
        if (scl_i) begin
          state_d = NackPulse;
        end
      end
      // NackPulse: target holds SDA high while SCL is released.
      NackPulse : begin
        if (!scl_i) begin
          state_d = NackHold;
          load_tcount = 1'b1;
          tcount_sel = tClockStart;
        end
      end
      // NackHold: target holds SDA high while SCL is pulled low.
      NackHold : begin
        if (tcount_q == 20'd1) begin
          // After sending NACK go back to Idle state.
          state_d = Idle;
        end
      end
      // StretchAddr: The address phase can not yet be completed, stretch
      // clock and wait.
      StretchAddr : begin
        // When there is space in the FIFO go to the next state.
        // If we hit our nack timeout, we must continue and NACK the next
        // byte (or in the case of a transmit we notify software and wait for
        // it to empty the ACQ FIFO).
        if (!stretch_addr || nack_timeout) begin
          // When transmitting after an address stretch, we need to assume
          // that is looks like a Tx stretch.  This is because if we try
          // to follow the normal path, the logic will release the clock
          // too early relative to driving the data.  This will cause a
          // setup violation.  This is the same case to needing StretchTxSetup.
          state_d = rw_bit_q ? StretchTx : AcquireByte;
        end
      end
      // StretchTx: target stretches the clock when tx conditions are not satisfied.
      StretchTx : begin
        // When in stretch state, always notify software that help is required.
        event_tx_stretch_o = 1'b1;
        if (!stretch_tx) begin
          // When data becomes available, we must first drive it onto the line
          // for at least the "setup" period.  If we do not, once the clock is released, the
          // pull-up in the system will likely immediately trigger a rising clock
          // edge (since the stretch likely pushed us way beyond the original intended
          // rise).  If we do not artificially create the setup period here, it will
          // likely create a timing violation.
          state_d = StretchTxSetup;
          load_tcount = 1'b1;
          tcount_sel = tSetupData;

          // When leaving stretch state, de-assert software notification
          event_tx_stretch_o = 1'b0;
        end
      end
      // StretchTxSetup: Wait for tSetupData before going to transmit
      StretchTxSetup : begin
        if (tcount_q == 20'd1) begin
          state_d = TransmitSetup;
        end
      end
      // StretchAcqFull: target stretches the clock when acq_fifo is full
      // When space becomes available, deposit the entry into the acqusition fifo
      // and move on to receive the next byte.
      // If we hit our NACK timeout we must continue and unconditionally NACK
      // the next one.
      StretchAcqFull : begin
        if (~stretch_rx || nack_timeout) begin
          state_d = AcquireByte;
        end
      end
      // default
      default : begin
        state_d = Idle;
        load_tcount = 1'b0;
        tcount_sel = tNoDelay;
        bit_decr = 1'b0;
        bit_clr = 1'b0;
        byte_decr = 1'b0;
        byte_clr = 1'b0;
        read_byte_clr = 1'b0;
        shift_data_en = 1'b0;
        log_start = 1'b0;
        log_stop = 1'b0;
        input_byte_clr = 1'b0;
        event_tx_stretch_o = 1'b0;
        host_disable_o = 1'b0;
      end
    endcase // unique case (state_q)

    // When a start is detected, always go to the acquire start state.
    // Differences in repeated start / start handling are done in the
    // other FSM.
    if (!target_idle && !target_enable_i) begin
      // If the target function is currently not idle but target_enable is suddenly dropped,
      // (maybe because the host locked up and we want to cycle back to an initial state),
      // transition immediately.
      // The same treatment is not given to the host mode because it already attempts to
      // gracefully terminate.  If the host cannot gracefully terminate for whatever reason,
      // (the other side is holding SCL low), we may need to forcefully reset the module.
      // ICEBOX(#18004): It may be worth having a force stop condition to force the host back to
      // Idle in case graceful termination is not possible.
      state_d = Idle;
    end else if (start_det) begin
      state_d = AcquireStart;
    end else if (stop_det) begin
      state_d = Idle;
    end
  end

  // TARGET-Mode -> RSTART or STOP condition observed
  // This output is used to (optionally) reset the TXFIFO, as any data populated by
  // software is now highly-unlikely to be applicable to the next transaction.
  assign target_sr_p_cond_o = target_enable_i && !target_idle && (stop_det | start_det);

  // Synchronous state transition
  always_ff @ (posedge clk_i or negedge rst_ni) begin : state_transition
    if (!rst_ni) begin
      state_q <= Idle;
    end else begin
      state_q <= state_d;
    end
  end

  // I2C bus outputs
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      scl_q <= 1'b1;
      sda_q <= 1'b1;
    end else begin
      scl_q <= scl_d;
      sda_q <= sda_d;
    end
  end

  assign scl_o = scl_q;
  assign sda_o = sda_q;

  // Host ceased sending SCL pulses during ongoing transaction
  assign event_host_timeout_o = !target_idle_o & (stretch_idle_cnt > host_timeout_i);

  // Target stretched clock beyond timeout
  assign event_stretch_timeout_o = stretch_en &&
                                   (stretch_idle_cnt[30:0] > stretch_timeout_i) && timeout_enable_i;

  // Fed out for interrupt purposes
  assign acq_fifo_wready_o = acq_fifo_plenty_space;

  // Check to make sure scl_i is never a single cycle glitch
  `ASSERT(SclInputGlitch_A, $rose(scl_i) |-> ##1 scl_i)

  // Make sure we never attempt to send a single cycle glitch
  `ASSERT(SclOutputGlitch_A, $rose(scl_o) |-> ##1 scl_o)

  // If we are actively transmitting, that must mean that there are no
  // unhandled write commands and if there is a command present it must be
  // a read.
  `ASSERT(AcqDepthRdCheck_A, ((state_q == TransmitSetup) && (acq_fifo_depth_i > '0)) |->
          (acq_fifo_depth_i == 1) && acq_fifo_rdata_i[0])

  // Check that we don't change SCL and SDA in the same clock cycle in host mode.
  `ASSERT(SclSdaChangeNotSimultaneous_A, !(host_enable_i && (scl_d != scl_q) && (sda_d != sda_q)))

  // Check that ACQ FIFO is deep enough to support a stop/rstart as well as
  // a nack when it is full.
  `ASSERT(AcqFifoDeepEnough_A, AcqFifoDepth > 2)

endmodule
