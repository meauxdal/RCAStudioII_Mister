`timescale 1ns/1ns
// top end ff for verilator

module top(

   input clk_48 /*verilator public_flat*/,
   input clk_24,
   input [11:0]  inputs/*verilator public_flat*/,
   input [31:0]  joystick_0/*verilator public_flat*/,
   input [31:0]  joystick_1/*verilator public_flat*/,
   input [3:0]   joy_override/*verilator public_flat*/,
   input         joy_manual/*verilator public_flat*/,
   input [1:0]   players/*verilator public_flat*/,
   input [1:0]   machine/*verilator public_flat*/,

   output [7:0] VGA_R/*verilator public_flat*/,
   output [7:0] VGA_G/*verilator public_flat*/,
   output [7:0] VGA_B/*verilator public_flat*/,
   
   output VGA_HS,
   output VGA_VS,
   output VGA_HB,
   output VGA_VB,
   output VGA_DE,

   output [15:0] AUDIO_L,
   output [15:0] AUDIO_R,
   
   input        ioctl_download,
   input        ioctl_upload,
   input        ioctl_wr,
   input [24:0] ioctl_addr,
   input [7:0]  ioctl_dout,
   input [7:0]  ioctl_din,   
   input [7:0]  ioctl_index,
   output  reg  ioctl_wait=1'b0,

   input [10:0] ps2_key,

   // Run the hardware's /4 pixel enable instead of the tied-high default.
   // The frame content is normally identical either way, but the phase between
   // cpu_ce and the pixie's counters is a real degree of freedom on hardware
   // that ce_pix=1 never exercises -- the Visicom display-base rotation
   // (2026-08-19) was invisible in sim until this existed. 4x slower.
   input ce_div4/*verilator public_flat*/
);
   
   // Core inputs/outputs
wire audio;   // 1-bit beeper, gated by the 1802's Q line
   wire [3:0] led/*verilator public_flat*/;

   wire VSync, HSync;
   wire VBlank, HBlank;
   wire video_de;
   // The bitmap window, which the harness captures instead of the full raster --
   // see rtl/rcastudioii.sv. Keeps captured frames at 64x128 / 64x192.
   wire bitmap_de/*verilator public_flat*/;

   assign VGA_VS = VSync;
   assign VGA_HS = HSync;
   assign VGA_VB = VBlank;
   assign VGA_HB = HBlank;
   assign VGA_DE = video_de;

   // Convert 1bpp output to 8bpp
   // {R,G,B} from the core, one bit per channel -- see rtl/rcastudioii.sv.
   // The Studio II's 1861 is mono and drives all three together, so this is
   // still white on black.
   wire [2:0] video/*verilator public_flat*/;
   // BCKGND: background pixels at half luminance, as in the FPGA top level. The
   // frame grabber thresholds on non-zero, so this does not disturb captures.
   wire       video_bg/*verilator public_flat*/;
   wire [7:0] vid_lvl = video_bg ? 8'h80 : 8'hFF;
   assign VGA_R = video[2] ? vid_lvl : 8'h00;
   assign VGA_G = video[1] ? vid_lvl : 8'h00;
   assign VGA_B = video[0] ? vid_lvl : 8'h00;
    
   // MAP OUTPUTS
   assign AUDIO_L = audio ? 16'sd6000 : -16'sd6000;
   assign AUDIO_R = AUDIO_L;

// The sim keeps ce_pix tied high by default: one pixel per clk_48 edge. Frame
// content is normally identical to hardware (everything inside the core is
// gated on ce_pix), the sim just doesn't burn 4 host cycles per pixel.
// Studio-II.sv divides by 4 for the real 1.76MHz timebase. With ce_div4 set,
// the sim runs the same /4 divider as the FPGA top so phase-sensitive
// behaviour can be reproduced (see the port comment).
reg [1:0] ce_cnt = 2'd0;
always @(posedge clk_48) ce_cnt <= ce_cnt + 2'd1;
wire ce_pix = ce_div4 ? (ce_cnt == 2'd0) : 1'b1;
// CLEAR, exactly as the FPGA top wires it: F3 (PS/2 0x04) sets clear_key,
// which is folded into reset while also going to the core's clear_key input
// so the pixie keeps running through it. The sim never modelled this: during
// CLEAR the CPU's machine-cycle divider is held in reset while the pixie's
// counters free-run, so the machine-cycle grid re-locks at an arbitrary
// pixel phase on release -- a degree of freedom that only ever existed on
// hardware until now (docs/handoff.md, 2026-08-19).
reg clear_key = 1'b0;
always @(posedge clk_48) begin
	reg old_clrstb;
	old_clrstb <= ps2_key[10];
	if (old_clrstb != ps2_key[10] && ps2_key[7:0] == 8'h04) clear_key <= ps2_key[9];
end

wire reset = ioctl_download | clear_key;

wire key_strobe = old_keystb ^ ps2_key[10];
reg old_keystb = 0;
always @(posedge clk_48) old_keystb <= ps2_key[10];

rcastudioii rcastudio
(
	.clk_sys(clk_48),
	.reset(reset),
	// Match the FPGA top's original CLEAR carve-out: downloads restart video
	// timing, while CLEAR resets the machine without interrupting raster sync.
	.video_reset(ioctl_download),
	
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),

	.ps2_key(ps2_key),
	.ce_pix(ce_pix),

	.HBlank(HBlank),
	.HSync(HSync),
	.VBlank(VBlank),
	.VSync(VSync),

	.video_de(video_de),
	.bitmap_de(bitmap_de),
	.video_bg(video_bg),

	.video(video),
	.audio(audio),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joy_override(joy_override),
	.joy_manual(joy_manual),
	.auto_profile(),
	.players(players),
	.machine(machine),
	.osk_a(10'd0),
	.osk_b(10'd0),
	.clear_key(clear_key)
);

endmodule
