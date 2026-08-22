//============================================================================
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

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM (USE_FB=1 in qsf)
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

///// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;  

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign HDMI_FREEZE = 0;

// Beeper: a square wave gated by the 1802's Q line, generated in rcastudioii.sv.
wire audio;
assign AUDIO_S   = 1'b1;                                   // signed samples
assign AUDIO_L   = audio ? 16'sd6000 : -16'sd6000;
assign AUDIO_R   = AUDIO_L;
assign AUDIO_MIX = 2'd0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
	"RCA-StudioII;v6;",
	"F1,ST2BINROM,Load Cartridge;",
	"F0,BINROM,Load Firmware;",
	"-;",
	// Machine is staged; nothing changes until Apply is pressed
	"O[14:13],Machine,Studio II,Studio III PAL,Studio III NTSC,Visicom;",
	"R[15],Apply and reset;",
	"-;",
	"O[6],Mapping,Auto,Manual;",
	// Value 0 is MAP_NONE, which still passes Start through; Clear-only (11) is the
	// one that silences the pad completely. Paddle (12) is a single-player,
	// keypad-B-only profile for the homebrew tennis.st2, distinct from retail
	// Tennis/Squash's CROSS profile.
	// Order must match the localparams in rtl/rcastudioii.sv -- the row's value
	// IS the profile number.
	"D2O[5:2],Joystick,None,Cross,Space War,Freeway,Bowling,Baseball,Homebrew,Gunfighter,8-way,Doodles,2P Homebrew,Clear-only,Paddle;",
	"O[8:7],Players,Auto,1,2;",
	"O[10:9],Stick Keypad,Off,Pad A,Pad B;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[12:11],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"-;",
//	"T[0],Reset;",
	"T[1],Clear;",
	"R[0],Reset and close OSD;",
	// Non-OSD entries (J/jn/V) must sit below every menu row: the menu's selection
	// pass counts any entry starting >= 'A' (Main menu.cpp), but its drawing pass
	// skips J -- a J placed mid-string shifts every row after it off by one.
	// A0..B9 are direct per-key bindings (see rtl/rcastudioii.sv); jn gives
	// defaults to the first three only, so the direct keys stay unbound until
	// the user maps them deliberately.
	// Fire/Extra mirror the MPT-02 joystick, the closest thing to an official
	// Studio II controller: fire on 5, a second button on 0.
	"J1,Fire,Extra,Start,Select,A0,A1,A2,A3,A4,A5,A6,A7,A8,A9,B0,B1,B2,B3,B4,B5,B6,B7,B8,B9;",
	"jn,A,B,Start,Select;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [21:0] gamma_bus;
wire   [1:0] buttons;
wire [127:0] status;
// Menu mask to gray-out/disable OSD options. Bit i selects the option whose
// status field begins at bit i; Joystick is O[5:2], so it uses mask bit 2.
wire  [15:0] status_menumask;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0, joystick_1;
wire  [15:0] joystick_l_analog_0, joystick_r_analog_0;
wire  [15:0] joystick_l_analog_1, joystick_r_analog_1;

// CLEAR is the Studio II's console button. It resets the CPU and blanks/clears
// the display, but the Pixie's timing generator must keep running or HDMI/analog
// displays can lose sync. Mapped to F3 (0x04), the OSD "Clear" button, and
// gamepad Select.
reg clear_key = 1'b0;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10] && ps2_key[7:0] == 8'h04) clear_key <= ps2_key[9];
end

wire        ioctl_download;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_data;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	//ioctl
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_data),

	.buttons(buttons),
	.status(status),
	.status_in(status_in),
	// DIAGNOSTIC (2026-08-22): tied low to test whether the auto-profile
	// push-back below is what's stomping saved OSD settings on boot. If
	// Aspect Ratio etc. now survive a save/reload with this disabled, that
	// confirms it; revert to status_set once confirmed either way.
	.status_set(1'b0), //.status_set(status_set),
	.status_menumask(status_menumask),

	.ps2_key(ps2_key),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_r_analog_0(joystick_r_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.joystick_r_analog_1(joystick_r_analog_1)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire clk_vid;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_vid)
);

// The CDP1861 emits one pixel per CPU clock: 1.7897725 MHz nominal, 1.760229 MHz
// here (clk_sys/4, and the real Studio II's RC oscillator was tuned by eye anyway).
reg [1:0] ce_cnt = 2'd0;
always @(posedge clk_sys) ce_cnt <= ce_cnt + 2'd1;
wire ce_pix = (ce_cnt == 2'd0);

// Select on the gamepad is CLEAR, same as F3 and the OSD button: every RCA
// manual begins "Press CLEAR", so it belongs on the pad next to Start.
wire joy_clear = joystick_0[7] | joystick_1[7];
wire clear_request = status[1] | clear_key | joy_clear;

wire reset = RESET | status[0] | clear_request | buttons[1] | ioctl_download | download_reset | ~rom_loaded | apply_reset;

// reset after download
reg [7:0] download_reset_cnt;
wire download_reset = download_reset_cnt != 0;

always @(posedge CLK_50M) begin
	if(ioctl_download || status[0] || buttons[1] || RESET ) download_reset_cnt <= 8'd255;
	else if(download_reset_cnt != 0) download_reset_cnt <= download_reset_cnt - 8'd1;
	if(ioctl_download && ioctl_index[5:0] == 0 && ioctl_addr == 24'd100) rom_loaded <= 1'b1;
end

reg rom_loaded = 0;

////////////////// Machine select: staged, applied on request ////////////////
//
// status[14:13] (the OSD "Machine" row) is only the operator's pending
// pick here -- fed nowhere else in this block. "Apply" is R[15], status
// bit 15. R[15] is a
// momentary status bit like R[0] ("Reset and close OSD"), so a plain
// CLK_50M edge-detect + hold, same shape as download_reset_cnt above, both
// stretches it long enough to certainly register in clk_sys (which the PLL
// derives from CLK_50M with no fixed phase relationship, so a single
// CLK_50M-wide pulse is not safe to sample directly over there) and gives
// the reset itself the same duration a download's reset gets.
reg [7:0] apply_reset_cnt;
wire      apply_reset = apply_reset_cnt != 0;
always @(posedge CLK_50M) begin
	reg apply_d;
	apply_d <= status[15];
	if (status[15] && !apply_d) apply_reset_cnt <= 8'd255;
	else if (apply_reset_cnt != 0) apply_reset_cnt <= apply_reset_cnt - 8'd1;
end

// Latched on apply_reset's rising edge in the clk_sys domain -- safe to
// edge-detect because apply_reset is already stretched to 255 CLK_50M
// cycles, comfortably wider than one clk_sys period. This register, not
// status[14:13], is what actually reaches the core and the Visicom palette
// mux below, so nothing about the memory map, video chipset or colour RAM
// reconfigures until the operator asks for it.
reg [1:0] machine_active = 2'd0;
always @(posedge clk_sys) begin
	reg apply_reset_d;
	apply_reset_d <= apply_reset;
	if (apply_reset && !apply_reset_d) machine_active <= status[14:13];
end

//////////////////////////////////////////////////////////////////

wire HBlank;
wire HSync;
wire VBlank;
wire VSync;
wire [2:0] video;   // {R,G,B} from the core

rcastudioii rcastudio
(
	.clk_sys(clk_sys),
	.reset(reset),
	
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_data),

	.ps2_key(ps2_key),
	.ce_pix(ce_pix),

	.HBlank(HBlank),
	.HSync(HSync),
	.VBlank(VBlank),
	.VSync(VSync),
	.video_de(),
	.video(video),
	.audio(audio),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joy_override(status[5:2]),
	.machine(machine_active),
	.video_bg(video_bg),
	.joy_manual(status[6]),
	.auto_profile(auto_profile),
	.players(status[8:7]),
	.osk_a(osk_a),
	.osk_b(osk_b),
	.clear_key(clear_request)
);

////////////////// Joystick profile -> OSD ///////////////////////////////////
//
// On Auto, the core's CRC/built-in-game detection owns the Joystick row and the
// menu is made to agree with it: hps_io's status_set hands the HPS a whole new
// status word, so writing the detected profile into bits [5:2] is what makes the
// OSD read "Gunfighter" after Gunfighter is loaded. On Manual nothing is
// written, so the row holds the last detected profile and the user edits from
// there rather than from a stale selection.
//
// This only changes what the menu *shows*. The mapping itself comes from
// auto_profile directly, so a write-back that never lands costs nothing but a
// stale row, and there is no feedback loop -- on Auto the core ignores the row
// it is writing to.
//
// One pulse per change, not a retry loop that nudges until the row agrees: the
// same shape the NES core (status_in/statusUpdate) and Apple IIgs
// (status_mirror) use. A retry loop would fight the user keystroke-for-keystroke
// if they scrolled that row, and would pulse forever on any Main that ignores
// status_set. Armed at startup and by the two things that change what should be
// displayed: the detection landing on a new profile, or Mapping switching back
// to Auto.
wire [3:0]   auto_profile;
reg  [127:0] status_in;
reg          status_set   = 1'b0;
reg    [3:0] auto_d       = 4'd0;
reg          manual_d     = 1'b0;
reg          auto_sync_done = 1'b0;
reg          push_pending = 1'b0;
reg   [21:0] push_dly     = 22'd0;

always @(posedge clk_sys) begin
	status_set <= 1'b0;
	auto_d     <= auto_profile;
	manual_d   <= status[6];

	// Schedule exactly one write on initial Auto mode, a new detection, or a
	// Manual-to-Auto transition. Do not test whether the row is stale here: that
	// would reload the delay on every clock and prevent the write from firing.
	if ((!auto_sync_done && !status[6]) || (auto_profile != auto_d) ||
	    (manual_d && !status[6])) begin
		auto_sync_done <= 1'b1;
		push_pending <= 1'b1;
		// ~0.3 s at 7.04 MHz. map_profile only settles when the transfer ends,
		// and the HPS is busy with the download until then, so let it finish.
		push_dly     <= 22'd2000000;
	end
	else if (|push_dly) begin
		push_dly <= push_dly - 1'b1;
	end
	else if (push_pending && !status[6] && !ioctl_download) begin
		push_pending <= 1'b0;
		status_in    <= {status[127:6], auto_profile, status[1:0]};
		status_set   <= 1'b1;
	end
end

// Gray-out the Joystick OSD option when Mapping is set to Auto. CONF_STR's
// D[2] prefix consumes this bit from status_menumask; bit 2 is the first status
// bit of the Joystick O[5:2] option.
assign status_menumask = (!status[6]) ? 16'h0004 : 16'h0000;

assign CLK_VIDEO = clk_sys;
// Commented to avoid assigning CE_PIXEL to more than one value
// assign CE_PIXEL   = 1'b1; // 7.04 MHz pixel clock enable (4x pixel repeating)

// The core hands up {R,G,B}, one bit per channel, mirroring the CDP1864's three
// colour pins. The Studio II's 1861 is monochrome and drives all three together,
// so this is still white on black -- expanding each bit to full 8-bit scale
// gives byte-identical output to the old `video ? 8'hFF : 8'h00`.
// BCKGND lowers the luminance of background pixels, so one colour can serve as
// both background and data -- what the datasheet describes and what Emma 02's
// palette shows (back_blue 0,0,128 against blue 0,0,255). Half scale here.
wire [7:0] vid_lvl = video_bg ? 8'h80 : 8'hFF;

// The Visicom is the exception: its four colours are fixed values chosen by
// Toshiba, not combinations of three colour pins, so they cannot be expressed
// on the {R,G,B} bus above.
//
// Emma 02 and MAME disagree on what those values are, and a real machine settles
// it. refvideo/"Freeway [Toshiba Visicom COM-100 Longplay] (1978).mp4" is a
// hardware capture of the built-in Freeway; sampling its four colours gives
// #003700, #B1ECE6, #DCE12D and #FF3D46. Summed RGB distance from that:
//
//              Emma 02   MAME        (MAME's visicom.cpp VISICOM_PALETTE)
//   colour 1      75       13        #70D0FF vs #AFDFE4 -- Emma's leans blue,
//   colour 2      74       45           the hardware is a pale green-cyan
//   colour 3      66       18        #FF7070 vs #EF454A -- Emma's is pink
//   total        225       86
//
// So these are MAME's. The capture is a composite NTSC encode and its absolute
// levels are not trustworthy, but the *hue* of colour 1 is not a capture
// artefact: green-cyan and blue-cyan are not the same colour.
wire machine_visicom = (machine_active == 2'd3);
reg [23:0] vis_rgb;
always @(*) begin
	case (vis_index)
		2'd0:    vis_rgb = 24'h004000;
		2'd1:    vis_rgb = 24'hAFDFE4;
		2'd2:    vis_rgb = 24'hB9C42F;
		default: vis_rgb = 24'hEF454A;
	endcase
end

wire [7:0] vid_r = machine_visicom ? vis_rgb[23:16] : (video[2] ? vid_lvl : 8'h00);
wire [7:0] vid_g = machine_visicom ? vis_rgb[15:8]  : (video[1] ? vid_lvl : 8'h00);
wire [7:0] vid_b = machine_visicom ? vis_rgb[7:0]   : (video[0] ? vid_lvl : 8'h00);

////////////////// On-screen keypad (Jaguar core's numstick, via ColecoAdam) //
//
// Nudge an analog stick and hold ~0.5s to press a key: right stick is the 1-9
// grid, left stick is 0. The OSD picks which Studio II keypad the presses land
// on. The sticks belong to gamepad 0, except that pad B in a two-player game
// belongs to gamepad 1 -- the same ownership rule as the digital mapping.
// Geometry is sized for the 64x128 active area; cycle counts are for the
// 7.04MHz clk_sys (hold ~0.5s, press ~75ms, recenter ~20ms).

wire [1:0] osk_mode   = status[10:9];   // 0 off, 1 pad A, 2 pad B
wire       osk_use_j1 = (osk_mode == 2'd2) && (status[8:7] == 2'd2);
wire [15:0] osk_l = osk_use_j1 ? joystick_l_analog_1 : joystick_l_analog_0;
wire [15:0] osk_r = osk_use_j1 ? joystick_r_analog_1 : joystick_r_analog_0;

wire [11:0] osk_press;
wire  [7:0] osk_vr, osk_vg, osk_vb;

// Generate a 2x pixel clock enable (3.52 MHz) for horizontal stretching
wire ce_pix_2x = !ce_cnt[0]; 

numstick #(
	.HOLD_CYCLES     (3520000),   
	.PRESS_CYCLES    (528000),    
	.RECENTER_CYCLES (141000),    
	.DEFAULT_ACTIVE_W(128),       // 64 * 2
	.DEFAULT_ACTIVE_H(128),
	.CELL_W          (36),        // 18 * 2
	.CELL_H          (12),
	.CELL_GAP        (2),         // 1 * 2
	.BOX_PAD         (4),         // 2 * 2
	.STACK_GAP       (8),         // 4 * 2
	.BORDER_THICKNESS(2)          // 1 * 2
) numstick
(
	.clk_sys  (clk_sys),
	.ce_pix   (ce_pix_2x),        // Feed 2x clock enable here
	.reset    (reset),
	.enable   (osk_mode != 2'd0),
	.hblank   (HBlank),
	.vblank   (VBlank),
	.in_r     (vid_r),
	.in_g     (vid_g),
	.in_b     (vid_b),
	.stick_l_x($signed(osk_l[7:0])),
	.stick_l_y($signed(osk_l[15:8])),
	.stick_r_x($signed(osk_r[7:0])),
	.stick_r_y($signed(osk_r[15:8])),
	.keypad_press(osk_press),
	.out_r    (osk_vr),
	.out_g    (osk_vg),
	.out_b    (osk_vb)
);

// numstick's one-hot runs bit0='1'..bit8='9', bit9='0'; reorder to key number.
wire [9:0] osk_keys = {osk_press[8:0], osk_press[9]};
wire [9:0] osk_a = (osk_mode == 2'd1) ? osk_keys : 10'd0;
wire [9:0] osk_b = (osk_mode == 2'd2) ? osk_keys : 10'd0;

wire       vga_de;
wire       freeze_sync;

video_mixer #(.LINE_LENGTH(280), .GAMMA(1)) video_mixer // 140 * 2
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(ce_pix_2x),         // Feed 2x clock enable here
	.scandoubler(forced_scandoubler),
	.hq2x(1'b0),
	.gamma_bus(gamma_bus),
	.R(osk_vr),
	.G(osk_vg),
	.B(osk_vb),
	.HSync(HSync),
	.VSync(VSync),
	.HBlank(HBlank),
	.VBlank(VBlank),
	.HDMI_FREEZE(HDMI_FREEZE),
	.freeze_sync(freeze_sync),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_VS(VGA_VS),
	.VGA_HS(VGA_HS),
	.VGA_DE(vga_de)
);

// Decode status[122:121] aspect ratio settings
wire [1:0] ar = status[122:121];
reg [11:0] arx, ary;

always @(*) begin
	case (ar)
		2'd0:    begin arx = 12'd4;  ary = 12'd3; end // Original (4:3)
		2'd1:    begin arx = 12'd0;  ary = 12'd0; end // Full Screen (0,0 is safe)
		2'd2:    begin arx = 12'd16; ary = 12'd9; end // 16:9 [ARC1]
		default: begin arx = 12'd1;  ary = 12'd1; end // 1:1  [ARC2]
	endcase
end

video_freak video_freak
(
    .CLK_VIDEO(CLK_VIDEO),
    .CE_PIXEL(CE_PIXEL),
    .VGA_VS(VGA_VS),
    .HDMI_WIDTH(HDMI_WIDTH),
    .HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE(VGA_DE),
    .VIDEO_ARX(VIDEO_ARX),
    .VIDEO_ARY(VIDEO_ARY),
    .VGA_DE_IN(vga_de),
    .ARX(arx),
    .ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
    .SCALE({1'b0, status[12:11]})
);

assign LED_USER = 1'b0;

endmodule
