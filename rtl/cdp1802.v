//============================================================================
//
//  CDP1802 "COSMAC" CPU.
//
//  Original implementation by Jason Coombes (JasonA-dev), 2022.
//  Extended 2026 by Alan Steremberg: interrupts, DMA-OUT, RET/DIS/SAV/MARK/IDL,
//  and machine-cycle timing (2 cycles per instruction, 3 for long branch/skip).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

`default_nettype none
/* verilator lint_off UNOPTFLAT */

module cdp1802 (
  input               CLOCK,      // CLOCK
  input               clk_enable, // one pulse per machine cycle (8 CLOCKs on real silicon)
  input               CLEAR_N,    // CLEAR_N   (RESET)

  output reg          Q,          // external pin Q 
  input      [3:0]    EF,         // external flags EF1 to EF4, separate pins negative

  // WAIT CLEAR  Control Lines
  // Clear 0 Wait 0 Load
  // Clear 0 Wait 1 Reset
  // Clear 1 Wait 0 Pause
  // Clear 1 Wait 1 Run

  // SC_1   State Code Line
  // SC_0   State Code Line
  // SC1 0 SC0 0  S0 Fetch
  // SC1 0 SC0 1  S1 Execute
  // SC1 1 SC0 0  S2 DMA
  // SC1 1 SC0 1  S3 Interrupt

  // MRD_N  Read Level
  // DATABUS 0-7  BUS0-BUS7
  // N0     I/O Line
  // N1     I/O Line
  // N2     I/O Line
  // XTAL_N
  // DMA_IN_N
  // DMA_OUT_N
  // MWR_N  Write Pulse
  // TPA    Timing Pulse
  // TPB    Timing Pulse
  // MEMORY_ADDR 0-7 MA0-MA7  Memory Address Lines

  input               WAIT_N,      // WAIT_N
  input               INT_N,       // INT_N
  input               dma_in_req,  // DMA_IN_N
  input               dma_out_req, // DMA_OUT_N
  output reg [1:0]    SC,          // SC1 SC0

  input      [7:0]    io_din,     // IO data in
  output     [7:0]    io_dout,    // IO data out
  output     [2:0]    io_n,       // IO control lines: N2,N1,N0
  output  wire        io_inp,     // IO input signal
  output  wire        io_out,     // IO output signal

  output              unsupported,// unsupported instruction signal

  output              ram_rd,     // RAM read enable      // MRD_N
  output              ram_wr,     // RAM write enable     // MWR_N
  output     [15:0]   ram_a,      // RAM address
  input      [7:0]    ram_q,      // RAM read data
  output     [7:0]    ram_d      // RAM write data

  //output  wire         TPA,        // Timing Pulse  (RAM)
  //output  wire         TPB         // Timing Pulse  (IO)
);

  // ---------- control signals -------------------------- 
  //reg   waiting;
  //assign waiting = (wait_req && resetq) ? 1'b1 : 1'b0;  
  reg   IE;   // Interrupt Enable

  // ---------- execution states -------------------------
  reg [3:0] state, state_n;

  localparam RESET     = 4'd0;    //    hardware reset asserted
  localparam FETCH     = 4'd1;    // S0 fetching opcode from PC
  localparam EXECUTE   = 4'd2;    // S1 main exection state
  localparam BRANCH3   = 4'd5;    //    short branch, new PC lo-byte
  localparam SKIP      = 4'd6;    //    for untaken

  localparam DMA_IN    = 4'd7;    // S2 DMA_IN state
  localparam DMA_OUT   = 4'd8;    // S2 DMA_OUT state
  localparam INTERRUPT = 4'd9;    // S3 Interrupt state
  localparam IDLE      = 4'd10;   //    IDL, waiting for DMA or interrupt
  localparam LSKIP     = 4'd11;   //    long-skip family (C4-C7, CC-CF), 3rd cycle

/*
  localparam RESET [3:0]     = 4'b0000;  // sc_execute
  localparam RESET2 [3:0]    = 4'b0001;  // sc_execute
  localparam LOAD [3:0]      = 4'b0010;  // sc_execute
  localparam FETCH [3:0]     = 4'b0011;  // sc_fetch
  localparam EXECUTE [3:0]   = 4'b0100;  // sc_execute
  localparam EXECUTE2 [3:0]  = 4'b0101;  // sc_execute
  localparam DMA_IN [3:0]    = 4'b0110;  // sc_dma
  localparam DMA_OUT [3:0]   = 4'b0111;  // sc_dma
  localparam INTERRUPT [3:0] = 4'b1000;  // sc_interrupt
*/ 

  // ---------- registers --------------------------------
  reg   [3:0] P;                  // Program Counter
  reg   [3:0] X;                  // Data Pointer
  reg   [7:0] T;                  // Temporary Register

  reg  [15:0] R[0:15];            // 16x16 register file
  wire  [3:0] Ra;                 // which register to work on this clock
  wire [15:0] Rrd = R[Ra];        // read out the selected register
  reg  [15:0] Rwd;                // write-back value for the register

  reg   [7:0] D;                  // data register (accumulator)
  reg         DF;                 // data flag (ALU carry)
  reg   [7:0] B;                  // used for hi-byte of long branch
  wire  [3:0] I, N;               // the current instruction


  // ---------- RAM hookups ------------------------------
  // SAV writes T; MARK writes the (X,P) it is capturing into T this same cycle.
  assign ram_d = (I == 4'h6)      ? io_din :
                 ({I, N} == 8'h78) ? T      :
                 ({I, N} == 8'h79) ? {X, P} : D;
  assign ram_a = Rrd;             // RAM address always one of the 16-bit regs

/*
  // TPA TPB
  // TPA occurs every 8 cycles, TPA precedes TPB
  reg [7:0] TP_counter = 0;
  wire TPA_ = 0;
  wire TPB_ = 1;
  assign TPA = TPA_;
  assign TPB = TPB_;
  always @(posedge CLOCK) begin
    if(TP_counter == 7) begin
      TPA_ <= ~TPA_;
      TPB_ <= ~TPB_;
      TP_counter <= 0;
    end
    else
      TP_counter <= TP_counter + 1;
  end
*/

  // ---------- conditional branch -----------------------
  reg sense;
  always @*
    casez ({I, N})
      // The Cx ??00 row's base condition is IE when N3 is set (reference
      // cosmac.vhdl cond_no_skip_p): that gives CC (LSIE) skip-if-IE, and C8
      // the same silicon quirk the reference models (branch if IE=0, which
      // with IE=1 -- the usual case -- degenerates to the documented LSKP).
      {4'h3, 4'b?000}:                  sense = 1;
      {4'hc, 4'b??00}:                  sense = N[3] ? IE : 1'b1;
      {4'h3, 4'b?001}, {4'hc, 4'b??01}: sense = Q;
      {4'h3, 4'b?010}, {4'hc, 4'b??10}: sense = (D == 8'h00);
      {4'h3, 4'b?011}, {4'hc, 4'b??11}: sense = DF;
      {4'h3, 4'b?1??}:                  sense = EF[N[1:0]];
      default:                          sense = 1'bx;
    endcase
  wire take = sense ^ N[3];

  // ---------- interrupt / DMA arbitration ----------------------------
  // The 1802 samples DMA and interrupt requests at a machine-cycle boundary, DMA first. INT_N is
  // active low -- rcastudioii.sv drives it from ~INT -- so a request is INT_N == 0. The old code
  // tested INT_N == 1'b1, which is why the interrupt was never taken even once it was uncommented.
  // DMA outranks the interrupt, and both are only taken between instructions.
  wire int_pending = ~INT_N & IE;
  wire [3:0] next_cycle = dma_in_req  ? DMA_IN    :
                          dma_out_req ? DMA_OUT   :
                          int_pending ? INTERRUPT : FETCH;

  // ---------- fetch/interrupt/dma/execute ----------------------------
  // state_n is assigned on every path: leaving DMA_IN/DMA_OUT unassigned inferred a latch.
  always @*
    case (state)
    // A real 1802 honours DMA only between instructions -- fetch always
    // proceeds to its execute (reference: cosmac.vhdl state_fetch, and MAME's
    // cosmac). Stealing cycles between S0 and S1 shifted the DMA burst one
    // machine cycle early relative to the instruction stream, which broke the
    // BIOS ISR's cycle-counted display loop for some interrupt-entry phases:
    // its GLO R0 sampled the row pointer before the line's burst instead of
    // after, so R(0) never advanced and whole frames went dark (the homebrew
    // "flicker", diagnosed on Space Invaders rev 2).
    FETCH:      state_n = EXECUTE;
    EXECUTE:
      casez ({I, N})
      8'h00:    state_n = IDLE;                       // IDL: hold until DMA or interrupt
      // Cx splits on N2 (reference cosmac.vhdl): N2=0 is the long-branch family
      // (taken loads the 2-byte target, untaken steps over it), N2=1 is the
      // long-skip family (C4 NOP, C5-C7, CC-CF): 3 cycles that move P by 0 or
      // 2 in total and never read the bytes. Treating the whole row as long
      // branch sent C4 NOP through a taken branch -- Race executes C4 in its
      // custom ISR and sailed into open bus.
      {4'hc, 4'b?1??}: state_n = LSKIP;               // long skip, second cycle next
      {4'hc, 4'b?0??}: state_n = take ? BRANCH3 : SKIP; // long branch takes 3 cycles
      default:  state_n = next_cycle;                 // everything else is 2
      endcase
    BRANCH3:    state_n = next_cycle;
    SKIP:       state_n = next_cycle;
    LSKIP:      state_n = next_cycle;
    IDLE:       state_n = (next_cycle == FETCH) ? IDLE : next_cycle;
    DMA_IN,
    DMA_OUT:    state_n = next_cycle;
    INTERRUPT:  state_n = FETCH;
    default:    state_n = FETCH;
    endcase

  // SC was driven with <= inside this combinational block and left unassigned on most paths, which
  // inferred a latch and meant the 1861 could never see a DMA or interrupt state code.
  always @*
    case (state)
    FETCH:            SC = 2'b00;   // S0 fetch
    DMA_IN, DMA_OUT:  SC = 2'b10;   // S2 DMA
    INTERRUPT:        SC = 2'b11;   // S3 interrupt
    default:          SC = 2'b01;   // S1 execute
    endcase

  reg [7:0] IR;                   // instruction register, latched at the end of FETCH
  assign {I, N} = IR;

  // ---------- decode and execute -----------------------
  wire [3:0] P_n = ((I == 4'hD)) ? N : P;           // SEP
  wire [3:0] X_n = (I == 4'hE)       ? N :          // SEX
                   ({I, N} == 8'h79) ? P : X;       // MARK moves P into X
  wire Q_n = (({I, N} == 8'h7a) | ({I, N} == 8'h7b)) ? N[0] : Q; // REQ, SEQ

  reg [5:0] action;                 // reg. address; RAM rd; RAM wr
  assign {Ra, ram_rd, ram_wr} = action;

  localparam MEM___  = 2'b00;       // no memory access
  localparam MEM_RD  = 2'b10;       // memory read strobe
  localparam MEM_WR  = 2'b01;       // memory write strobe

  // NOTE: Rwd must NOT be written in terms of Rrd. Rrd is R[Ra], Ra comes out
  // of `action`, and `action` is assigned by this very block -- writing
  // {action, Rwd} = {..., Rrd ...} makes Rwd a function of the *previous*
  // evaluation's Ra. Combined with the old `always @(state, I, N)` sensitivity
  // list (which omits Rrd, P and X) that silently wrote the wrong register and
  // the core never got past address $0004 of the BIOS. Each case therefore
  // names the register it reads explicitly.
  always @*
    case (state)
    FETCH, SKIP:                    {action, Rwd} = {P, MEM_RD, R[P] + 16'd1};
    // 8'h00 is IDL, not LDN R0. Handled ahead of the casez so the IDL and LDN patterns do not
    // overlap (they did, which is legal casez priority but warns in both Quartus and verilator).
    EXECUTE:
      if ({I, N} == 8'h00)          {action, Rwd} = {P, MEM___, R[P]};
      else casez ({I, N})
      /* LDN  */ 8'h0?:             {action, Rwd} = {N, MEM_RD, R[N]};
      /* INC  */ 8'h1?:             {action, Rwd} = {N, MEM___, R[N] + 16'd1};
      /* DEC  */ 8'h2?:             {action, Rwd} = {N, MEM___, R[N] - 16'd1};
      /* LDA  */ 8'h4?:             {action, Rwd} = {N, MEM_RD, R[N] + 16'd1};
      /* STR  */ 8'h5?:             {action, Rwd} = {N, MEM_WR, R[N]};
      /* SEP  */ 8'hd?,
      /* SEX  */ 8'he?,
      /* GLO  */ 8'h8?,
      /* GHI  */ 8'h9?:             {action, Rwd} = {N, MEM___, R[N]};
      /* PLO  */ 8'ha?:             {action, Rwd} = {N, MEM___, R[N][15:8], D};
      /* PHI  */ 8'hb?:             {action, Rwd} = {N, MEM___, D, R[N][7:0]};

      /* RET  */ 8'h70,
      /* DIS  */ 8'h71:             {action, Rwd} = {X, MEM_RD, R[X] + 16'd1};
      /* SAV  */ 8'h78:             {action, Rwd} = {X, MEM_WR, R[X]};
      /* MARK */ 8'h79:             {action, Rwd} = {4'd2, MEM_WR, R[2] - 16'd1};

      /* STXD */ 8'h73:             {action, Rwd} = {X, MEM_WR, R[X] - 16'd1};
      /* LDXA */ 8'h72,
      /* OUT  */ {4'h6, 4'b0???}:   {action, Rwd} = {X, MEM_RD, R[X] + 16'd1};
      /* INP  */ {4'h6, 4'b1???}:   {action, Rwd} = {X, MEM_WR, R[X]};

      /* long-skip family (C4-C7, CC-CF): no operand bytes; P moves by 0 or 1
         this cycle and again in LSKIP -- skip means step over two bytes,
         no-skip (C4 NOP included) means P stays put for all 3 cycles. `take`
         here is the reference's cond_no_skip: 1 = do not skip. */
      {4'hc, 4'b?1??}:              {action, Rwd} = {P, MEM___, take ? R[P] : (R[P] + 16'd1)};

      /* immediate and branch instructions must fetch from R[P] */
      /* short branch resolves in this cycle: take it, or step over the address byte */
      8'h3?:                        {action, Rwd} = {P, MEM_RD, take ? {R[P][15:8], ram_q}
                                                                     : (R[P] + 16'd1)};
      8'h7c, 8'h7d, 8'h7f, 8'hf8, 8'hf9, 8'hfa, 8'hfb, 8'hfc, 8'hfd, 8'hff,
      {4'hc, 4'b?0??}:              {action, Rwd} = {P, MEM_RD, R[P] + 16'd1};

      default:                      {action, Rwd} = {X, MEM_RD, R[X]};
      endcase
    BRANCH3:                        {action, Rwd} = {P, MEM___, B, ram_q};
    LSKIP:                          {action, Rwd} = {P, MEM___, take ? R[P] : (R[P] + 16'd1)};
    // A DMA cycle always goes through R(0) and post-increments it -- that is what makes the 1861's
    // 8 bytes per scanline walk through display memory without the CPU touching an address.
    DMA_OUT:                        {action, Rwd} = {4'd0, MEM_RD, R[0] + 16'd1};
    DMA_IN:                         {action, Rwd} = {4'd0, MEM_WR, R[0] + 16'd1};
    default:                        {action, Rwd} = {X, MEM___, R[X]};
    endcase

  wire [8:0] carry = (I[3]) ? 9'd0 : {8'd0, DF};      // 0 or 1 for ADC
  wire [8:0] borrow = (I[3]) ? 9'd0 : ~{9{DF}};       // -1 or 0 for SDB and SMB
  reg [8:0] DFD_n;
  always @*
    casez ({I, N})
    /* LDXA */ 8'h72,
    /* LDX  */ 8'hf0,
    /* LDI  */ 8'hf8,
    /* LDA  */ 8'h4?,
    /* LDN  */ 8'h0?:               DFD_n = {DF, ram_q};
    /* GLO  */ 8'h8?:               DFD_n = {DF, R[N][7:0]};
    /* GHI  */ 8'h9?:               DFD_n = {DF, R[N][15:8]};
    /* INP  */ 8'b0110_1???:        DFD_n = {DF, io_din};
    /* OR   */ 8'b1111_?001:        DFD_n = {DF, D | ram_q};
    /* AND  */ 8'b1111_?010:        DFD_n = {DF, D & ram_q};
    /* XOR  */ 8'b1111_?011:        DFD_n = {DF, D ^ ram_q};
    /* ADD  */ 8'b?111_?100:        DFD_n = {1'b0, D} + {1'b0, ram_q} + carry;
    /* SD   */ 8'b?111_?101:        DFD_n = ({1'b1, ram_q} - {1'b0, D}) + borrow;
    /* SM   */ 8'b?111_?111:        DFD_n = ({1'b1, D} - {1'b0, ram_q}) + borrow;
    /* SHR  */ 8'b?111_0110:        DFD_n = {D[0], carry[0], D[7:1]};
    /* SHL  */ 8'b?111_1110:        DFD_n = {D, carry[0]};
    default:                        DFD_n = {DF, D};
    endcase

  assign io_n = N[2:0];
  // OUT completes in EXECUTE now that memory reads no longer need a second cycle; this still
  // said EXECUTE2, a state that no longer occurs, so OUT 2 never latched the keypad.
  assign io_out = (I == 4'h6) & ~N[3] & (state == EXECUTE) & (N[2:0] != 3'b000);
  assign io_inp = (I == 4'h6) & N[3] & (state == EXECUTE) & (N[2:0] != 3'b000);
  // OUT sends M(R(X)), which is the byte read during this EXECUTE cycle. While OUT completed in
  // EXECUTE2 this was mem_r; now that it completes in EXECUTE, mem_r still holds the *opcode*, so
  // OUT 2 was latching 0x62 into the keypad selector instead of the key number.
  assign io_dout = ram_q;
  assign unsupported = 1'b0;      // RET/DIS/SAV/MARK/IDL are all implemented now
  /*
  always @(posedge CLOCK) begin
    if(unsupported) begin
      $display("Unsupported instruction: %h", {I, N});
    end
  end
  */
  // ---------- cycle commit -----------------------------
  always @(negedge CLEAR_N or posedge CLOCK) begin
    // CLEAR WAIT Control Lines
    // Clear 0 Wait 0 Load
    // Clear 0 Wait 1 Reset
    // Clear 1 Wait 0 Pause
    // Clear 1 Wait 1 Run
    // Reset
    /*
    if (cpuMode_ != RUN)
    {
        if (p_Video != NULL)
            p_Video->reset();
    }
    */
    if (!CLEAR_N) begin
        // 1802 reset leaves I=N=0, Q=0, X=0, P=0, R(0)=0 and *IE=1*. IE was never initialised
        // before, so even a working interrupt path could not have fired.
        {Q, P, X} <= 0;
        {DF, D} <= 9'd0;
        T     <= 8'd0;
        IE    <= 1'b1;
        IR    <= 8'd0;
        R[0]  <= 16'd0;
        state <= RESET;
      end
    else begin
      // Clear=1, Wait=1 is Run (see the table above). This used to be "!WAIT_N && CLEAR_N", i.e.
      // it ran only while WAIT_N was asserted low -- which the same file calls Pause. It worked
      // solely because rcastudioii.sv tied WAIT_N to 0.
      // One state per machine cycle, not one per CLOCK. Free-running, this core executed ~16x more
      // instructions per frame than a real Studio II (CLAUDE.md 6.1/7.3).
      if (WAIT_N && clk_enable) begin
        state <= state_n;
        if (state == FETCH)
          IR <= ram_q;                                  // opcode for the coming EXECUTE
        if (state == EXECUTE && !((I == 4'h7) && (N[3:1] == 3'b000)))
          {Q, P, X} <= {Q_n, P_n, X_n};
        R[Ra] <= Rwd;
        if (state == EXECUTE)
          {DF, D} <= DFD_n;
        if ((state == EXECUTE) && (I == 4'hc))
          B <= ram_q;   // long branch high byte

        // MARK: T gets the (X,P) in force before X_n moves P into X.
        if ((state == EXECUTE) && ({I, N} == 8'h79))
          T <= {X, P};

        // RET (70) and DIS (71) both pop (X,P) from M(R(X)); RET enables interrupts, DIS disables.
        if ((state == EXECUTE) && (I == 4'h7) && (N[3:1] == 3'b000)) begin
          X  <= ram_q[7:4];
          P  <= ram_q[3:0];
          IE <= ~N[0];
        end

        // S3: the interrupt cycle saves (X,P) into T, then forces X=2, P=1 and masks further
        // interrupts. The ISR's RET/DIS undoes this.
        if (state == INTERRUPT) begin
          T  <= {X, P};
          X  <= 4'd2;
          P  <= 4'd1;
          IE <= 1'b0;
        end
      end
    end
  end

endmodule
