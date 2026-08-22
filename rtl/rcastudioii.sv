//============================================================================
//
//  RCA Studio II core glue: CPU + CDP1861 + RAM + keypad.
//
//  Original implementation by Jason Coombes (JasonA-dev), 2022, with MiSTer
//  framework integration by Flandango. Extended 2026 by Alan Steremberg and
//  Elle Ball.
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

module rcastudioii
(
	input              clk_sys,
	input              reset,
	
	input wire         ioctl_download,
	input wire   [7:0] ioctl_index,
	input wire         ioctl_wr,
	input       [24:0] ioctl_addr,
	input        [7:0] ioctl_dout,

	input       [10:0] ps2_key,
	input       [31:0] joystick_0,
	input       [31:0] joystick_1,
	input        [3:0] joy_override,   // OSD "Joystick" row: the profile to use when joy_manual
	input              joy_manual,     // OSD "Mapping": 0 = auto-detect, 1 = use joy_override
	output       [3:0] auto_profile,   // the detected profile, for the top level to show in the OSD
	input        [1:0] players,        // OSD: 0 = auto, 1 = one player, 2 = two players
	input        [9:0] osk_a,          // on-screen keypad presses for keypad A (bit = key)
	input        [9:0] osk_b,          // and for keypad B
	input  reg         ce_pix,
	input              clear_key,      // CLEAR button input from top-level; keep video alive during CLEAR
	//  Which machine, from the OSD:
	//    0  Studio II          CDP1861, NTSC, monochrome
	//    1  Studio III PAL     CDP1864 -- video, colour and tone in one part
	//    2  Studio III NTSC    CDP1861 + CDP1862 colour + CDP1863 tone
	//    3  Visicom		    CDP1861, NTSC, colour from second RAM plane
	input        [1:0] machine,

	output reg         HBlank,
	output reg         HSync,
	output reg         VBlank,
	output reg         VSync,
	output reg         video_de,
	// DE for the bitmap alone, as distinct from video_de (the whole raster). The
	// simulation harness captures this so its frames stay 64x128 / 64x192 and the
	// recorded scores keep their meaning. Unused by the FPGA top level.
	output reg         bitmap_de,
	// {R,G,B}, one bit per channel -- this mirrors the hardware rather than
	// inventing a format. The CDP1864 in the successor machines has exactly one
	// RDATA, GDATA and BDATA pin, fed from colour RAM. The CDP1861
	// here is a mono part, so the Studio II drives all three together and the
	// picture is unchanged.
	output       [2:0] video,
	// Visicom only: which of its four colours this pixel is. The palette is
	// four fixed RGB values that a 1-bit-per-channel bus cannot carry, so the
	// top level applies it; `video` above still gets a 3-bit approximation for
	// anything that only has three wires (the simulation harness).
	output       [1:0] vis_index,
	// BCKGND from the CDP1864: this pixel's colour came from the background
	// select rather than a lit bit, so it should be shown at lower luminance.
	// Always low on the monochrome Studio II, which has no background colour.
	output reg         video_bg,
	output             audio
);


//  Derived from `machine`. Most of the machine-dependent behaviour keys off
//  "is this a Studio III" (the memory map, colour RAM, the tone generator)
//  rather than off which video part it has, which is only the PAL one.
localparam [1:0] MACHINE_STUDIO2   = 2'd0;
localparam [1:0] MACHINE_S3_PAL    = 2'd1;
localparam [1:0] MACHINE_S3_NTSC   = 2'd2;
localparam [1:0] MACHINE_VISICOM   = 2'd3;

// The Visicom is NOT a Studio III despite Robson's visicom.txt calling it a
// "clone of the Studio 3". It has a plain CDP1861 and no colour RAM at all: its
// colour comes from a second bit plane in main RAM, so none of the Studio III
// memory map, colour RAM or tone generator applies to it. Keeping is_studio3 as
// "not a Studio II" would have handed it all three.
wire is_studio3      = (machine == MACHINE_S3_PAL) || (machine == MACHINE_S3_NTSC);
wire machine_mpt02   = (machine == MACHINE_S3_PAL);   // has the CDP1864
wire machine_visicom = (machine == MACHINE_VISICOM);

////////////////// VIDEO //////////////////////////////////////////////////////////////////

wire        Disp_On;
wire        Disp_Off;
// SC is driven by the CPU's output port, so it must be a net -- declaring it a reg with an
// initial value of 2'b10 meant the 1861 saw a constant "DMA" state code.
wire [1:0]  SC;

wire        INT;
wire        DMAO;
wire        EFx;


pixie_video pixie_video (
    // front end, CDP1802 bus clock domain
    .clk        (clk_sys),    // I
    .reset      (reset & ~clear_key),      // I: keep pixie running while CLEAR (clear_key==1) so VSYNC doesn't lose sync

    .clk_enable (ce_pix),     // I
    .cpu_ce     (cpu_ce),     // I  CPU machine-cycle enable, for sampling DMA bytes

    .SC         (SC),         // I [1:0]
    // INP 1 turns the display on, OUT 1 turns it off (the BIOS enables it via CALL $0066). These
    // were tied on/off, so the display could never be disabled and the 1861 started generating
    // interrupts from reset instead of from the moment the BIOS enabled it. The earlier commented
    // version keyed off io_n[0] alone, which cannot tell INP 1 from OUT 1.
    // The Visicom enables the display with OUT 1 rather than INP 1, and has no
    // disable port at all -- Emma 02's config carries a single <out type="on">1
    // where the Studio II carries <out>1 and <in>1, which its parser turns into
    // PIXIE_OUT_OUT with only the enable populated.
    .disp_on    (machine_visicom ? (io_out && (io_n == 3'd1))
                                 : (io_inp && (io_n == 3'd1))),  // I
    .disp_off   ((!machine_visicom && io_out && (io_n == 3'd1)) || clear_key),  // I: also blank display while CLEAR is asserted


    .data_in    (ram_q),      // I [7:0]  byte the CPU delivers during a DMA-OUT cycle
    .vis_mode   (machine_visicom),  // I
    .data_in2   (pl1_q),      // I [7:0]  Visicom plane 1: the byte $200 higher
    .colour_in  (colour_dot), // I  CDP1862 colour for that byte (NTSC Studio III)
    .con        (colour_on),  // I
    .bg_step    (io_out && (io_n == 3'd1) && !machine_visicom),  // I  OUT 1 steps the background

    .DMAO       (DMAO_61),    // O
    .INT        (INT_61),     // O
    .EFx        (EFx_61),     // O

    // back end, video clock domain
    .video_clk  (clk_sys),    // I
    .csync      (),           // O
    .video      (video_dot),  // O  one bit: the 1861 is a monochrome part
    .colour_out    (col61_dot),
    .vis_index     (vis_index),
    .bg_active     (col61_bg),
    .bg_colour_out (col61_bgc),

    .VSync      (VSync_61),   // O
    .HSync      (HSync_61),   // O
    .VBlank     (VBlank_61),  // O
    .HBlank     (HBlank_61),  // O
    .video_de   (de_61),      // O
    .bitmap_de  (bde_61)      // O
);

// ---- CDP1864, the colour machines' video ---------------------------------
// Both parts are instantiated and the active one selected, rather than making
// one module's geometry runtime-switchable: the 1861's timing is delicately
// tuned and documented as such, and both parts are tiny. See the header of
// rtl/pixie/cdp1864.v.
//
// Note the different I/O decode. On the 1864 the display is turned off by INP 4,
// not OUT 1 -- OUT 1 is taken over by the background colour step. The datasheet
// gives the opcodes: 61 or 69 enable interrupt and DMA, 6C disables them.
wire       DMAO_64, INT_64, EFx_64;
wire       VSync_64, HSync_64, VBlank_64, HBlank_64, de_64, bde_64, bg_64;
wire [2:0] video_64;

cdp1864 cdp1864
(
    .clk        (clk_sys),
    .ce_pix     (ce_pix),
    .cpu_ce     (cpu_ce),
    .reset      (reset & ~clear_key),

    .SC         (SC),
    .data_in    (ram_q),
    .colour_in  (colour_dot),
    .con        (colour_on),
    .disp_on    (io_inp && (io_n == 3'd1)),
    .disp_off   ((io_inp && (io_n == 3'd4)) || clear_key),
    .bg_step    (io_out && (io_n == 3'd1)),

    .DMAO       (DMAO_64),
    .INT        (INT_64),
    .EFx        (EFx_64),

    .csync      (),
    .video      (video_64),
    .bckgnd     (bg_64),
    .VSync      (VSync_64),
    .HSync      (HSync_64),
    .VBlank     (VBlank_64),
    .HBlank     (HBlank_64),
    .video_de   (de_64),
    .bitmap_de  (bde_64)
);

// ---- tone generator -------------------------------------------------------
// The CDP1864 integrates this; the NTSC Studio III has it as a separate CDP1863
// beside its 1861 and 1862. Same latch on OUT 4 and the same gate on Q either
// way, differing only by one division stage -- so one instance serves both, with
// div4 picking the chain. Straight from the datasheet's control-line truth table
// and Weisbecker's Studio III notes ("64 instruction sets sound frequency
// (inverse)", "Q gates sound output").
wire aud_tone;
cdp1863 cdp1863
(
    .clk     (clk_sys),
    .cpu_ce  (cpu_ce),
    .reset   (reset & ~clear_key),
    // The 1864's integrated generator has an extra divide-by-4 that the
    // standalone 1863 does not, so the same latch sounds four times higher on
    // the NTSC machine. MAME: cdp1864 f = clk/8/4/(latch+1)/2 against cdp1863
    // f = clk/8/(latch+1)/2 from its clock2 input, which is where TPB goes.
    .div4    (machine == MACHINE_S3_PAL),
    .tone_we (io_out && (io_n == 3'd4)),
    .tone_d  (cpu_dout),
    .aoe     (Q),
    .aud     (aud_tone)
);

// ---- select ---------------------------------------------------------------
// The Studio II's 1861 has no colour, so every channel follows its single dot
// bit -- white on black, unchanged from before the video path widened.
wire       video_dot;
wire       DMAO_61, INT_61, EFx_61;
wire       VSync_61, HSync_61, VBlank_61, HBlank_61, de_61, bde_61;
wire [2:0] col61_dot, col61_bgc;
wire       col61_bg;
wire [2:0] video_61;
wire       bg_61;

// The CDP1862 beside the 1861, fitted only on the NTSC Studio III. On a Studio II
// `enable` is low and it passes the luminance bit straight through as white.
cdp1862 cdp1862
(
    .enable     (machine == MACHINE_S3_NTSC),
    .luminance  (video_dot),
    .in_raster  (de_61),
    .dot_colour (col61_dot),
    .bg_active  (col61_bg),
    .bg_colour  (col61_bgc),
    .video      (video_61),
    .bckgnd     (bg_61)
);

// The Visicom's four colours do not fit a 1-bit-per-channel bus, so the exact
// palette is applied at the top level (RCAStudioII.sv) from vis_index. What
// goes out here is the nearest 3-bit approximation, which is what the Verilator
// harness captures -- the four colours stay distinguishable in a PNG or an
// ASCII dump, which is all that side needs.
reg  [2:0] vis_approx;
always @(*) begin
	case (vis_index)
		2'd0:    vis_approx = 3'b010;   // background: dark green
		2'd1:    vis_approx = 3'b011;   // cyan
		2'd2:    vis_approx = 3'b110;   // yellow
		default: vis_approx = 3'b100;   // red
	endcase
end

assign video    = machine_visicom ? vis_approx : (machine_mpt02 ? video_64 : video_61);
assign DMAO     = machine_mpt02 ? DMAO_64  : DMAO_61;
assign INT      = machine_mpt02 ? INT_64   : INT_61;
assign EFx      = machine_mpt02 ? EFx_64   : EFx_61;

always @(*) begin
	VSync    = machine_mpt02 ? VSync_64  : VSync_61;
	HSync    = machine_mpt02 ? HSync_64  : HSync_61;
	VBlank   = machine_mpt02 ? VBlank_64 : VBlank_61;
	HBlank   = machine_mpt02 ? HBlank_64 : HBlank_61;
	video_de = machine_mpt02 ? de_64     : de_61;
	bitmap_de = machine_mpt02 ? bde_64   : bde_61;
	video_bg  = machine_mpt02 ? bg_64    : bg_61;
end

////////////////// KEYPAD //////////////////////////////////////////////////////////////////

//The CPU selects the key to scan with OUT 2, latched into a CD4515.
reg  [3:0] keylatch = 4'h0;
always @(posedge clk_sys) if(io_out && (io_n == 3'd2)) keylatch <= cpu_dout[3:0];

wire       pressed = ps2_key[9];
wire [7:0] code    = ps2_key[7:0];
always @(posedge clk_sys) begin
	reg old_state;
	old_state <= ps2_key[10];

	if(old_state != ps2_key[10]) begin
		case(code)
			// Keypad A
			'h16: playerA[1] <= pressed; // 1 → 1
			'h1E: playerA[2] <= pressed; // 2 → 2
			'h26: playerA[3] <= pressed; // 3 → 3
			'h15: playerA[4] <= pressed; // Q → 4
			'h1D: playerA[5] <= pressed; // W → 5
			'h24: playerA[6] <= pressed; // E → 6
			'h1C: playerA[7] <= pressed; // A → 7
			'h1B: playerA[8] <= pressed; // S → 8
			'h23: playerA[9] <= pressed; // D → 9
			'h22: playerA[0] <= pressed; // X → 0
		
			// Keypad B
			'h3D: playerB[1] <= pressed; // 7 → 1
			'h3E: playerB[2] <= pressed; // 8 → 2
			'h46: playerB[3] <= pressed; // 9 → 3
			'h3C: playerB[4] <= pressed; // U → 4
			'h43: playerB[5] <= pressed; // I → 5
			'h44: playerB[6] <= pressed; // O → 6
			'h3B: playerB[7] <= pressed; // J → 7
			'h42: playerB[8] <= pressed; // K → 8
			'h4B: playerB[9] <= pressed; // L → 9
			'h41: playerB[0] <= pressed; // , → 0
		endcase
	end
end
reg  [9:0] playerA = 10'h0;
reg  [9:0] playerB = 10'h0;


////////////////// JOYSTICK -> KEYPAD ///////////////////////////////////////
//
// The Studio II has no joystick: every game is played on the 10-key pads, and
// keys vary by game. A CRC16 of the image is taken while it downloads and looked up
// in a table below; the result selects one of a few profiles.
//
// MiSTer joystick bits, per the CONF_STR "J1,..." list in RCAStudioII.sv:
//   [0]=right [1]=left [2]=down [3]=up   [4]=Fire   [5]=Extra   [6]=Start
//   [7]=Select(CLEAR, folded into reset by the top level)
//   [17:8]=A0..A9   [27:18]=B0..B9.
// Fire/Extra mirror the MPT-02 joystick (the Soundic/Hanimex Studio III
// machines' swappable keypad controller): fire on 5, a second button on 0.
// A0..B9 are direct per-key bindings with no default mapping: they are inert
// until the user binds them in Define Buttons, and then they always work, on
// top of whatever profile is active.

// The profile is 4 bits internally; the OSD override (joy_override) is 4, so
// the menu can force any of the 16 encoded profiles, including Gunfighter.
// Keep the numeric values aligned with the OSD list so a user selection selects
// the correct profile.
localparam [3:0] MAP_NONE       = 4'd0;   // no controller mapping; keep keypad/OSK input only
localparam [3:0] MAP_CROSS      = 4'd1;   // 2/8/4/6 + 5 fire, both pads
localparam [3:0] MAP_SPACEWAR   = 4'd2;   // fire A2, steer B4/B6
localparam [3:0] MAP_FREEWAY    = 4'd3;   // steer B4/B6, throttle A2, brake A8
localparam [3:0] MAP_BOWLING    = 4'd4;   // roll A5, hook A2/A8
localparam [3:0] MAP_BASEBALL   = 4'd5;   // bat A5; pitch B5 straight, B2/B8 curve
localparam [3:0] MAP_HOMEBREW   = 4'd6;   // Paul Robson's 1P games: 8-way on pad A
                                          // (diagonals are keys 1/3/7/9), fire B0
localparam [3:0] MAP_GUNFIGHTER = 4'd7;   // vertical cross: 2/8 + fire 5, one-player
localparam [3:0] MAP_8WAY       = 4'd8;   // CROSS plus diagonals: 1/3/7/9, fire 5 + extra 0
localparam [3:0] MAP_DOODLE     = 4'd9;   // Doodle/Patterns: B-side 8-way, fire 5, extra 0
localparam [3:0] MAP_HB2P       = 4'd10;  // 2P homebrew (Hockey, Combat): cross plus
                                          // fire-on-0, each player's own pad. Normally
                                          // chosen by CRC, but also exposed in the OSD
                                          // list as "2P Homebrew" for manual override.
localparam [3:0] MAP_CLEAR_ONLY = 4'd11;  // explicit no-controller mapping: only Clear/Select
                                          // from the pad; numstick/keyboard still work.
localparam [3:0] MAP_PADDLE     = 4'd12;  // TODO: fix 2-player to work when selecting 
										  // that mode. Single-player, keypad B
                                          // only. Up/down map to 2/8; left/fire/right map
                                          // to the one-time racket-size choices B4/B5/B6.

reg [3:0] map_profile = MAP_NONE;

// ---- CRC16-CCITT over the cartridge image, computed during ioctl_download ----
// Seed on the first byte and hold the result after the download ends -- clearing
// it whenever ioctl_download is low would wipe the CRC before it could be used.
reg [15:0] cart_crc = 16'hFFFF;
reg        dl_d;
wire       dl_done = dl_d & ~ioctl_download;      // falling edge: download finished

always @(posedge clk_sys) begin
	integer i;
	reg [15:0] c;
	dl_d <= ioctl_download;
	if (cart_dl && ioctl_download && !dl_d) begin
		cart_crc <= 16'hFFFF;
	end
	if (cart_dl && ioctl_wr) begin
		c = (ioctl_addr == 0) ? 16'hFFFF : cart_crc;
		c = c ^ {ioctl_dout, 8'h00};
		for (i = 0; i < 8; i = i + 1)
			c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
		cart_crc <= c;
	end
end

// ---- CRC → profile + Start key ------------------------------------------------
// Add a cartridge by running tools/cart-crc.sh and dropping one line into the
// matching group below.  Groups are ordered by (map_profile, start_key) so
// related dumps stay together.  Comments list the human names.
//
// start_key is the keypad-A digit that the gamepad Start button presses.
// Default / no-cart = 1 (most common).

reg [3:0] start_key = 4'd1;

always @(posedge clk_sys) begin
	if (dl_done) begin
		case (cart_crc)

			// ----------------------------------------------------------------
			// Retail / known controller mappings
			// ----------------------------------------------------------------

			// TV Arcade I - Space War
			16'h45B5, 16'h977C: begin
				map_profile <= MAP_SPACEWAR;
				start_key   <= 4'd1;
			end

			// Pinball
			// Speedway + Tag
			// Star Wars
			// These cartridges use the MPT-02 joystick cross layout.
			16'h03E6, 16'h8404, 16'h92BA, 16'hD0DA, 16'hD13E, 16'hD3E2, 16'hE153: begin
				map_profile <= MAP_CROSS;
				start_key   <= 4'd1;
			end

			// TV Arcade IV - Baseball
			16'h2526, 16'hF837: begin
				map_profile <= MAP_BASEBALL;
				start_key   <= 4'd0;
			end

			// TV Arcade Series - Gunfighter + Moonship Battle
			16'h043E, 16'h3CDC: begin
				map_profile <= MAP_GUNFIGHTER;
				start_key   <= 4'd1;
			end

			// TV Arcade III - Tennis + Squash
			16'h88FB, 16'hFB76: begin
				map_profile <= MAP_PADDLE;
				start_key   <= 4'd1;
			end


			// ----------------------------------------------------------------
			// Homebrew: single-player (Paul Robson scheme)
			// ----------------------------------------------------------------

			// Asteroids
			16'h1943, 16'hFBEF, 16'h1973, 16'h2B4D: begin
				map_profile <= MAP_HOMEBREW;
				start_key   <= 4'd5;
			end

			// Berzerk
			16'h4F61, 16'hAEC7, 16'h787D, 16'hE080: begin
				map_profile <= MAP_HOMEBREW;
				start_key   <= 4'd5;
			end

			// Invaders v1/v2/v3
			16'h6F69, 16'hADAB, 16'h0D1D, 16'h69AA, 16'h2D86, 16'h5AC5: begin
				map_profile <= MAP_HOMEBREW;
				start_key   <= 4'd0;
			end

			// Kaboom
			16'h6793, 16'hDFCF, 16'h8551: begin
				map_profile <= MAP_HOMEBREW;
				start_key   <= 4'd0;
			end

			// Pacman
			16'hC556, 16'h5359, 16'hF4A1, 16'hE00A: begin
				map_profile <= MAP_HOMEBREW;
				start_key   <= 4'd0;
			end

			// Scramble
			16'hBA0B, 16'hE45F, 16'hFAA9, 16'h1280: begin
				map_profile <= MAP_HOMEBREW;
				start_key   <= 4'd6;
			end


			// ----------------------------------------------------------------
			// Homebrew: two-player (Paul Robson scheme)
			// ----------------------------------------------------------------

			// Combat v1/v2/v3
			16'h4ADA, 16'h188E, 16'hD87F,
			16'h54C7, 16'h4AA2, 16'hABBA, 16'h4009: begin
				map_profile <= MAP_HB2P;
				start_key   <= 4'd1;
			end

			// Hockey v1/v2/v3
			16'h114A, 16'h4F55, 16'hD5DE,
			16'h554B, 16'h1154, 16'hDE71, 16'hD753: begin
				map_profile <= MAP_HB2P;
				start_key   <= 4'd1;
			end


			// ----------------------------------------------------------------
			// No explicit profile set (8WAY) but known cartridge names
			// ----------------------------------------------------------------

			// 86677b (Europe) (unknown)
			16'hFC72: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// 87201 (Europe) (unknown)
			16'h74AB: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// RCA Studio II Resident Games
			16'hB5BF: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// A Cheap Graphics Computer
			16'hBBC8, 16'hEE76: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Climber v1.00
			16'hAD6A, 16'h1139: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Concentration + Match
			16'h7A43, 16'h0ECC: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Fifteen Puzzle
			16'h3244: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Flappy Pixel
			16'h6D1D, 16'hD124: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Invasion, The v1.00
			16'h2DDB: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Outbreak v1.00
			16'hA83F, 16'hBE58: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Race
			16'h5638, 16'h47EA: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Rocket v1.01
			16'h127F, 16'hD2F0: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Space Explorer
			16'h0C03, 16'h92C7: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Studio II Point of Sale Demonstration Cartridge
			16'hB334, 16'h3EAF: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Studio II Programming Examples - Move 1
			16'hD8C2: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Studio II Programming Examples - Move 2
			16'hFF76: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Studio II Programming Examples - Move 3
			16'h0856: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Studio II Programming Examples - Random 1
			16'h51A6: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Studio II Programming Examples - Random 2
			16'h4447: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Studio II Programming Examples - Show Key
			16'hC78E: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Studio II Programming Examples - Tone
			16'hC903: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// Studio II Test Cartridge
			16'h7BB6, 16'h79C5: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// TV Arcade 2012
			16'hE3CF, 16'h4B55: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// TV Arcade II - Fun with Numbers
			16'h29B8, 16'hCEC2: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// TV Casino Series - Blackjack
			16'hAF65, 16'hC8B4: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// TV Casino Series - TV Bingo
			16'h3731, 16'h31AE: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// TV Mystic Series - Biorhythm
			16'h8CDE, 16'hDA69: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// TV School House I
			16'h7D85, 16'h9D0D: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end

			// TV School House II - Math Fun
			16'hBD53, 16'hB2FF: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end


			// ----------------------------------------------------------------
			// Existing recognized no-controller entries
			//
			// These hashes were present in the previous mapping table but
			// are not identified by name in the supplied CRC inventory.
			// Preserve their existing behavior rather than guessing.
			// ----------------------------------------------------------------

			16'h1634, 16'hB76F: begin
				map_profile <= MAP_CLEAR_ONLY;
				start_key   <= 4'd1;
			end


			// ----------------------------------------------------------------
			// Existing recognized hash with no supplied inventory identity
			// ----------------------------------------------------------------

			// Identity not present in supplied CRC inventory.
			16'hE4C4: begin
				map_profile <= MAP_8WAY;
				start_key   <= 4'd1;
			end


			// ----------------------------------------------------------------
			// Fallback
			// ----------------------------------------------------------------

			// Every Visicom cartridge dumped so far starts on 0, not 1 -- Emma
			// 02's FaqVisicomCartridges says "to start press 0" (or space, which
			// is its keypad-A 0) for all of them, and the built-in games use
			// 1/2/3/4/7 instead. There is no CRC entry for any of them yet, so
			// the machine decides rather than the table.
			default: begin
				map_profile <= MAP_8WAY;
				start_key   <= machine_visicom ? 4'd0 : 4'd1;
			end

		endcase
	end
end

// ---- built-in games -------------------------------------------------------
// With no cartridge there is nothing to CRC, so the five BIOS games are told
// apart by the key that starts them (service manual pp.7-8): A1 Doodle,
// A2 Patterns, A3 Bowling, A4 Freeway, A5 Addition. Only the *first* such press
// after reset counts -- those keys are reused during play (A5 rolls the ball in
// Bowling, for instance). 

wire       no_cart = (cart_crc == 16'hFFFF);
reg        builtin_sel;
reg  [3:0] builtin_profile;

// Consider on-screen keypad (osk_a) as well as the physical keypad for
// selecting built-in games. Treat the on-screen keypad's key at
// active_start_key as a Start press so numstick users can activate by the OSK.
wire [9:0] builtin_padA = playerA | osk_a;
wire        builtin_start_press = start_press | osk_a[active_start_key];

always @(posedge clk_sys) begin
	if (reset) begin
		builtin_sel     <= 1'b0;
		builtin_profile <= MAP_NONE;
	end
	else if (no_cart && !builtin_sel) begin
		if      (builtin_padA[1] || (builtin_start_press && (active_start_key == 4'd1))) begin builtin_profile <= MAP_DOODLE; builtin_sel <= 1'b1; end  // Doodle: B-side 8-way
		else if (builtin_padA[2] || (builtin_start_press && (active_start_key == 4'd2))) begin builtin_profile <= MAP_DOODLE; builtin_sel <= 1'b1; end  // Patterns: B-side 8-way
		// A3 = BOWLING; A4 = FREEWAY. If the service manual claims otherwise, it's wrong.
		else if (builtin_padA[3]) begin builtin_profile <= MAP_BOWLING; builtin_sel <= 1'b1; end  // Bowling
		else if (builtin_padA[4]) begin builtin_profile <= MAP_FREEWAY; builtin_sel <= 1'b1; end  // Freeway
		else if (builtin_padA[5]) begin builtin_profile <= MAP_CLEAR_ONLY; builtin_sel <= 1'b1; end  // Addition: digits
	end
end

// ---- effective profile ------------------------------------------------------
// Two independent OSD rows now: "Mapping" chooses between auto-detection and
// the menu, and "Joystick" is the profile itself. There is no longer a magic
// "0 = auto" value inside the profile enum, so every one of the 16 encodings --
// MAP_NONE included -- is selectable, and the top level can display the
// detected profile in the same row the user would edit (see RCAStudioII.sv).
assign     auto_profile = no_cart ? builtin_profile : map_profile;
wire [3:0] profile      = joy_manual ? joy_override : auto_profile;

// ---- profile -> keypad presses ---------------------------------------------
// Each profile is two halves: the keys it lands on keypad A and on keypad B.
// Which stick drives the B half is the Players setting. One player runs the
// whole machine from stick 0 (Space War fires on pad A and steers on pad B);
// two players get one stick per pad. Auto keeps each profile's natural
// default, which is exactly the behaviour the joystick regression verified:
// the asymmetric single-player profiles (Space War, Freeway, Bowling) act as
// one-player, the symmetric ones (Cross, Baseball) as two.

function automatic [9:0] map_padA(input [3:0] prof, input [31:0] j);
	reg [9:0] k;
	begin
		k = 10'd0;
		case (prof)
		MAP_CROSS: begin                     // the MPT-02 joystick layout
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;           // Extra
		end
		MAP_SPACEWAR:                        // fire
			if (j[4]) k[2] = 1'b1;
		MAP_FREEWAY: begin                   // throttle/brake
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
		end
		MAP_BOWLING: begin                   // roll straight, or hook up/down
			if (j[4]) k[5] = 1'b1;
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
		end
		MAP_BASEBALL:                        // bat
			if (j[4]) k[5] = 1'b1;
		MAP_HOMEBREW: begin
			// 8-way: a held diagonal is its corner key (Berzerk moves on
			// 1/3/7/9), a cardinal is the cross. The corner keys are unused
			// in the 4-way homebrews, so a passing diagonal is harmless.
			case (j[3:0])
			4'b1010: k[1] = 1'b1;            // up+left
			4'b1001: k[3] = 1'b1;            // up+right
			4'b0110: k[7] = 1'b1;            // down+left
			4'b0101: k[9] = 1'b1;            // down+right
			default: begin
				if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
				if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			end
			endcase
		end
		MAP_HB2P: begin                      // own pad: cross + fire on 0
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[0] = 1'b1;
		end
		MAP_CLEAR_ONLY: ;                   // no controller presses: on-screen keypad
											  // and keyboard still work, but the stick stays quiet
		MAP_GUNFIGHTER: begin                // 2P behaves like CROSS; Auto/1P uses the
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;   // right-hand B-only mapping
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;
		end
		MAP_8WAY: begin                      // CROSS + 8-way diagonals: 1/3/7/9 on corners
			case (j[3:0])
			4'b1010: k[1] = 1'b1;            // up+left
			4'b1001: k[3] = 1'b1;            // up+right
			4'b0110: k[7] = 1'b1;            // down+left
			4'b0101: k[9] = 1'b1;            // down+right
			default: begin
				if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
				if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			end
			endcase
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;
		end
		MAP_DOODLE: begin                   // Doodle/Patterns: B-side 8-way, single-player
			case (j[3:0])
			4'b1010: k[1] = 1'b1;            // up+left
			4'b1001: k[3] = 1'b1;            // up+right
			4'b0110: k[7] = 1'b1;            // down+left
			4'b0101: k[9] = 1'b1;            // down+right
			default: begin
				if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
				if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			end
			endcase
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;
		end
		MAP_PADDLE: ;                        // no A-side function: Start alone lives on
										  // keypad A, gameplay is entirely keypad B
		default: ;
		endcase
		map_padA = k;
	end
endfunction

function automatic [9:0] map_padB(input [3:0] prof, input [31:0] j);
	reg [9:0] k;
	begin
		k = 10'd0;
		case (prof)
		MAP_CROSS: begin                     // the MPT-02 joystick layout
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;           // Extra
		end
		MAP_SPACEWAR: begin                  // steering
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
		end
		MAP_FREEWAY: begin                   // steering
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
		end
		MAP_BASEBALL: begin                  // pitch
			if (j[4]) k[5] = 1'b1;
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
		end
		MAP_HOMEBREW: begin
			// Fire is 0 on the right pad -- never A0, which restarts Invaders.
			// The cross is repeated here because Pacman reads "down" on B8;
			// pad B directions are unused in the other one-player homebrews.
			if (j[4]) k[0] = 1'b1;
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
		end
		MAP_HB2P: begin                      // own pad: cross + fire on 0
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[0] = 1'b1;
		end
		MAP_CLEAR_ONLY: ;                   // no controller presses: the on-screen keypad
											// and keyboard still work, but the stick stays quiet
		MAP_GUNFIGHTER: begin               // 2P behaves like CROSS; Auto/1P uses the
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;   // right-hand B-only mapping
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;
		end
		MAP_8WAY: begin                      // CROSS + 8-way diagonals: 1/3/7/9 on corners
			case (j[3:0])
			4'b1010: k[1] = 1'b1;            // up+left
			4'b1001: k[3] = 1'b1;            // up+right
			4'b0110: k[7] = 1'b1;            // down+left
			4'b0101: k[9] = 1'b1;            // down+right
			default: begin
				if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
				if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			end
			endcase
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;
		end
		MAP_DOODLE: begin                   // Doodle/Patterns: B-side 8-way, single-player
			case (j[3:0])
			4'b1010: k[1] = 1'b1;            // up+left
			4'b1001: k[3] = 1'b1;            // up+right
			4'b0110: k[7] = 1'b1;            // down+left
			4'b0101: k[9] = 1'b1;            // down+right
			default: begin
				if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
				if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			end
			endcase
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;
		end
		MAP_PADDLE: begin                    // vertical movement plus racket-size setup.
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[5] = 1'b1;
		end
		default: ;                           // Bowling: keypad B unused
		endcase
		map_padB = k;
	end
endfunction

// TODO: Make MAP_PADDLE 2-player-compatible: the right-hand stick should drive the 
// B-side, and the left-hand stick should drive the A-side. The current implementation 
// is single-player only. 
wire profile_1p = (profile == MAP_SPACEWAR) || (profile == MAP_FREEWAY) ||
                  (profile == MAP_BOWLING)  || (profile == MAP_NONE) ||
                  (profile == MAP_HOMEBREW) || (profile == MAP_GUNFIGHTER) ||
                  (profile == MAP_8WAY)     || (profile == MAP_DOODLE) ||
                  (profile == MAP_CLEAR_ONLY) || (profile == MAP_PADDLE);
wire one_player = (players == 2'd1) || ((players == 2'd0) && profile_1p);

// Direct A0..A9/B0..B9 bindings and Start work from either stick: MiSTer maps
// each input device independently, so a binding only exists where the user
// made one. Start presses the cartridge's start key on keypad A.
reg [9:0] directA, directB;
integer dk;
always @* begin
	for (dk = 0; dk < 10; dk = dk + 1) begin
		directA[dk] = joystick_0[8+dk]  | joystick_1[8+dk];
		directB[dk] = joystick_0[18+dk] | joystick_1[18+dk];
	end
end
wire       start_press = joystick_0[6] | joystick_1[6];
wire [3:0] active_start_key = ((profile == MAP_GUNFIGHTER) || (profile == MAP_DOODLE) || (profile == MAP_8WAY)) ? 4'd1 : start_key;
wire [9:0] start_keys       = ((profile != MAP_CLEAR_ONLY) && start_press) ? (10'd1 << active_start_key) : 10'd0;

// Gunfighter is the special case: in Auto/1P it is B-only (2/4/6/8 + 5 + 0 on
// the right-hand pad), while in 2P it splits exactly like CROSS across both
// pads. 8WAY follows the normal CROSS path (A-side in 1P). The explicit Clear-only profile 
// stays quiet unless the user binds a direct A/B key manually.
wire [9:0] joyA = ((profile == MAP_NONE) ? 10'd0
                : ((profile == MAP_GUNFIGHTER) && one_player) ? 10'd0
                : ((profile == MAP_DOODLE) ? 10'd0
                                          : ((profile == MAP_GUNFIGHTER) ? map_padA(MAP_CROSS, joystick_0)
                                                                        : map_padA(profile, joystick_0))));

wire [9:0] joyB = ((profile == MAP_NONE) ? 10'd0
                : ((profile == MAP_GUNFIGHTER) && one_player) ? map_padB(MAP_CROSS, joystick_0)
                : ((profile == MAP_DOODLE) ? map_padB(MAP_DOODLE, joystick_0)
                                          : ((profile == MAP_GUNFIGHTER) ? map_padB(MAP_CROSS, joystick_1)
                                                                        : (one_player ? map_padB(profile, joystick_0)
                                                                                       : map_padB(profile, joystick_1)))));
wire [9:0] joyA_active = joyA | directA | start_keys;
wire [9:0] joyB_active = joyB | directB;

////////////////// CPU //////////////////////////////////////////////////////////////////

// EF4=player B, EF3=player A, EF2 unused (high), EF1=1861 display status. Only keys 0-9 exist, so
// guard the index: keylatch 10-15 used to read off the end of the 10-bit playerA/playerB vectors.
wire  [3:0] EF;
wire        key_valid = (keylatch < 4'd10);
wire  [9:0] padA = playerA | joyA_active | osk_a;
wire  [9:0] padB = playerB | joyB_active | osk_b;
assign EF = {key_valid & padB[keylatch], key_valid & padA[keylatch], 1'b1, EFx};

// The Studio II has no input port that returns data -- the keypads are read through EF3/EF4,
// and INP 1 only toggles the display, discarding the byte. 
wire [7:0] cpu_din = 8'h00;
reg  [7:0] cpu_dout;
wire       Q;
wire       unsupported;
wire [2:0] io_n;
wire       io_inp;
wire       io_out;

reg [15:0] cpu_ram_addr;
reg  [7:0] cpu_ram_din;
reg  [7:0] cpu_ram_dout;

reg WAIT_N      = 1'b1;   // Clear=1, Wait=1 is Run. Was 0, which only worked because cdp1802.v
                          // had its run/pause test inverted; both are fixed now.

// ---- CPU machine-cycle enable -------------------------------------------------------------
// The CDP1861 shifts one pixel per CPU clock and a 1802 machine cycle is 8 clocks, so the CPU
// advances one state every 8 pixel times. Deriving this from ce_pix rather than counting clk_sys
// keeps it correct whatever clk_sys is running at. 112 pixels x 262 lines / 8 = 3668 machine
// cycles per frame, which is what a real Studio II gets.
reg  [2:0] cpu_div = 3'd0;
wire       cpu_ce  = ce_pix & (cpu_div == 3'd7);
// The divider's reset carries the same CLEAR carve-out as the pixie's, and it
// must: CLEAR keeps the pixie's counters running (so video sync survives) but
// used to zero cpu_div, so on release the machine-cycle grid re-locked at an
// arbitrary pixel phase -- a relationship that is fixed in silicon, where
// CLEAR resets the 1802 and the 1861 together (RCA block diagram, CLAUDE.md
// §2.1). Three of the eight release phases left the Visicom blank or its
// display base rotated (the 13/16-byte rotations seen on hardware,
// docs/handoff.md 2026-08-19); the Studio II titles merely tolerated the
// misalignment thanks to the ISR-phase work. Keeping the divider counting
// through CLEAR keeps cpu_ce locked to the pixie across it; on every other
// reset both still start together from zero.
always @(posedge clk_sys) begin
	if (reset & ~clear_key) cpu_div <= 3'd0;
	else if (ce_pix)        cpu_div <= cpu_div + 3'd1;
end
reg dma_in_req  = 1'b0;
//reg dma_out_req = 1'b0;

//wire TPA;
//wire TPB;
wire MWR_N;
wire MRD_N;
cdp1802 cdp1802 (
  .CLOCK        (clk_sys),
  .clk_enable   (cpu_ce),
  .CLEAR_N      (~reset),

  .Q            (Q),            // O external pin Q Turns the sound off and on. When logic '1', the beeper is on.
  .EF           (EF),           // I 3:0 external flags EF1 to EF4

  .WAIT_N       (WAIT_N),       // I
  .INT_N        (~INT),         // I
  .dma_in_req   (dma_in_req),   // I
  .dma_out_req  (DMAO),         // I  TODO: check
  .SC           (SC),           // O

  .io_din       (cpu_din),      // I
  .io_dout      (cpu_dout),     // O
  .io_n         (io_n),         // O 2:0 IO control lines: N2,N1,N0  (N0 used for display on/off)
  .io_inp       (io_inp),       // O IO input signal
  .io_out       (io_out),       // O IO output signal

  .unsupported  (unsupported),  // O

  .ram_rd       (ram_rd),       // O MRD_N
  .ram_wr       (ram_wr),       // O MWR_N
  .ram_a        (ram_a),        // O cpu_ram_addr
  .ram_q        (ram_q),        // I DI
  .ram_d        (ram_d)        // O cpu_ram_dout

  //.TPA          (TPA),          // O Timing Pulse  (RAM)
  //.TPB          (TPB)           // O Timing Pulse  (IO)
);
/*
cosmac cosmac (
   .clk         (clk_sys),     // I
   .clk_enable  (1'b1),        // I
   .clear       (~reset),      // I
   .dma_in_req  (dma_in_req),  // I
   .dma_out_req (dma_out_req), // I
   .int_req     (INT_N),       // I
   .wait_req    (wait_req),    // I
   .ef          (EF),          // I [4:1]
   .data_in     (ram_q),       // I [7:0]
   .data_out    (ram_d),       // O [7:0]
   .address     (ram_a),       // O [15:0]
   .mem_read    (ram_rd),      // O
   .mem_write   (ram_wr),      // O
   .io_port     (io_n),        // O [2:0]
   .q_out       (Q),           // O
   .sc          (SC)           // O [1:0]
);
*/

////////////////// MEMORY DECODE ////////////////////////////////////////////
//
// docs/memorymap.txt:
//
//   $0000-$07FF  ROM      system ROM, plus the built-in games at $0400-$07FF
//                         (a cartridge takes that half over when plugged in)
//   $0800-$09FF  RAM      512 bytes: system/program memory, then display memory
//   $0A00-$0BFF  cart     multicart window
//   $0C00-$0DFF  RAM/ROM  the RAM mirror by default; a cartridge may page ROM
//                         over it (asteroids/berzerk/pacman/scramble .st2 do)
//   $0E00-$0FFF  cart     multicart window
//
// The rule behind that table is one line: RAM answers wherever A9 = 0 and
// nothing else is decoded, which is why it also reappears at $0C00, $1000,
// $1400, $1800 and so on. A9 = 1 with no cartridge is open bus.
//
// This core previously had no decode at all -- one 4 KB array with the address
// truncated to ram_a[11:0] -- so $1000 read the system ROM, the $0C00 mirror
// did not exist, and a write at $0C00 was dropped.
//
// The ROM/cartridge image and the RAM are now separate arrays, so a cartridge
// can no longer be scribbled on and the mirror costs nothing.

wire         ram_rd; // MRD_N
wire         ram_wr; // MWR_N
wire  [7:0]  ram_d;  // CPU write data
wire [15:0]  ram_a;  // CPU address
wire  [7:0]  ram_q;  // data returned to the CPU (and to the 1861 during DMA)

// Which of pages $0A-$0F the loaded cartridge actually supplies. Only $0C/$0D
// change behaviour: with cartridge ROM paged there they are ROM, without it
// they are the RAM mirror. Cleared when a new cartridge starts downloading;
// deliberately not cleared on reset, since CLEAR does not unplug the cart.
reg  [7:0]  cart_page = 8'h00;    // indexed by address bits [10:8]: page $08..$0F

wire        bank0    = (ram_a[15:12] == 4'h0);
wire        rom_sel  = bank0 && (!ram_a[11] || machine_visicom);   // $0000-$07FF ($0000-$0FFF on the Visicom)
// The CDP1864 machines put a second ROM region at $0C00-$0FFF -- MAME's
// mpt02_map has .rom() there as well as at $0000-$07FF, and the Studio III BIOS
// is a 4K image covering both. On those machines it is ROM whether or not a
// cartridge paged anything in, so it takes precedence over the RAM mirror that
// $0C00-$0DFF would otherwise be.
wire        rom_hi   = is_studio3 && bank0 && (ram_a[11:10] == 2'b11);      // $0C00-$0FFF
// Colour RAM: 64 cells behind a one-page window at $0B00-$0BFF. Only six address
// lines are decoded, which is why MAME names the storage ($0B00-$0B3F) and Emma 02
// the window ($0B00-$0BFF) without disagreeing. See docs/succession-plan.md §6.
wire        col_sel  = is_studio3 && bank0 && (ram_a[11:8] == 4'hB);
wire        cart_sel = bank0 &&  ram_a[11] && cart_page[ram_a[10:8]] && !rom_hi && !col_sel && !machine_visicom;

// ---- Toshiba Visicom COM-100 ----------------------------------------------
// A different map from either Studio, and the only one here that puts RAM above
// $0FFF. From Emma 02's Visicom/standard.xml:
//
//   $0000-$07FF  ROM   2K image: BIOS, and the built-in games at $0400-$07FF
//                      (Emma declares the window as $0000-$03FF and lets the
//                      cartridge overlay $0400-$07FF, which is the Studio II
//                      arrangement stated differently)
//   $0800-$0FFF  ROM   further cartridge space
//   $1000-$11FF  RAM   512 bytes: scratch at $1000-$10FF, bit plane 0 at $1100
//   $1300-$13FF  RAM   256 bytes: bit plane 1
//   $1200-$12FF        nothing
//
// Both RAM windows repeat every $400 all the way to $FFFF -- Emma spells the
// mirrors out one by one in <map>, which is the same statement as decoding
// A9-A0 within each 1K page and ignoring everything above.
wire        vis_ram  = machine_visicom && !bank0 && !ram_a[9];            // 512B, plane 0 in its top half
wire        vis_pl1  = machine_visicom && !bank0 && (ram_a[9:8] == 2'b11);// 256B, plane 1

wire        ram_sel  = machine_visicom
                     ? (vis_ram || vis_pl1)
                     : (!rom_sel && !rom_hi && !col_sel && !cart_sel && !ram_a[9]);

// Plane 1 is its own 256-byte array rather than a second window into the main
// RAM, and it is addressed by A7-A0 in both of its roles: the video reads it
// during a DMA cycle, when the address bus holds R(0) = $11xx, and the CPU
// reads or writes it at $13xx. Same low byte either way, so one single-port
// array serves both and there is never a conflict -- the CPU is not driving the
// bus during a DMA cycle.
//
// This is deliberately NOT port B of the main RAM, which is where it started.
// That array already had a port-B writer (the CLEAR wipe) and so was already
// uninferrable; adding a port-B read doubled it to 1K and doubled the logic it
// was costing. Keeping plane 1 separate keeps both arrays in block RAM, and is
// closer to the machine anyway -- it has separate chips.
wire        cpu_wr   = ram_wr && ram_sel && !vis_pl1;             // RAM is the only writeable thing
wire        pl1_wr   = ram_wr && vis_pl1;                        // ...and the Visicom's second plane
wire        col_wr   = ram_wr && col_sel;

// ---- CDP1864 colour RAM ---------------------------------------------------
// 64 x 3 bits, so a plain register array rather than block RAM. The cell for a
// display byte is {off[7:5], off[2:0]}: the low three bits are the column (8
// bytes across a 64-pixel row) and off[7:5] the row group, so one cell covers 8
// pixels across by 4 logical rows down. Indexing is MAME's, from
// mpt02_state::dma_w(), whose offset is the DMA address (cosmac_device passes
// R[0]). Reads are combinational and off the *current* address, because the
// 1864 latches colour "concurrent with the latching of the luminance
// information" -- the byte and its colour arrive together.
reg  [2:0]  colour_ram [0:63];
// CON, "Color On". The datasheet has this pin "connected to the gated MWR signal
// of the color memory", so colour switches on with the first write to colour RAM
// and the part is monochrome until then. Without it, every game that never
// writes colour RAM came out on a blue field instead of black -- which is how
// this was caught, against the reference emulator's Conic sweep. MAME fakes it
// with con_w(0) on every DMA and flags that as a hack.
reg         colour_on;
always @(posedge clk_sys) begin
	if (reset)       colour_on <= 1'b0;
	else if (col_wr) colour_on <= 1'b1;
end
always @(posedge clk_sys) if (col_wr) colour_ram[ram_a[5:0]] <= ram_d[2:0];
wire [5:0]  col_index = {ram_a[7:5], ram_a[2:0]};
wire [2:0]  colour_cell = colour_ram[col_index];
// Colour RAM bit order is the 1864's pin order, which is NOT {R,G,B}: MAME's
// mpt02_state has rdata_r() = BIT(m_color,0), bdata_r() = BIT(m_color,1) and
// gdata_r() = BIT(m_color,2), i.e. bit0 red, bit1 blue, bit2 green. Permute into
// the {R,G,B} the video bus carries. Getting this wrong renders the right picture
// in the wrong colours -- the pinball table came out magenta-bordered instead of
// yellow, which is how the bug was spotted.
wire [2:0]  colour_dot = {colour_cell[0], colour_cell[2], colour_cell[1]};

// Both arrays have one cycle of latency, so the read mux select has to be
// delayed with the data. The CPU holds an address for a whole machine cycle
// (32 clk_sys), so a registered select is settled long before it is sampled.
wire [7:0]  rom_q;
wire [7:0]  sram_q;
wire [7:0]  pl1_q;
reg         rom_sel_q, ram_sel_q, pl1_sel_q;
always @(posedge clk_sys) begin
	rom_sel_q <= rom_sel | cart_sel | rom_hi;
	ram_sel_q <= ram_sel;
	pl1_sel_q <= vis_pl1;
end
// Open bus reads back as $FF, matching MAME's unmap_value_high and the likely
// floating-bus behaviour of the real machine (nothing drives the lines, and
// the last DMA-driven byte was usually high). This was $00 to match the C
// reference emulator's flat array, but Robson's Hockey and Combat flash the
// screen through the BIOS scroll register with a base that walks the display
// DMA past $09FF into this window: with $00 those frames rendered as a black
// screen with an 8-pixel bar (the reported "flashing strobes"); with $FF they
// render as the full-screen white flash MAME shows. Nothing in the §9 corpus
// reads undecoded space (tools/memdecode-test.sh covers it instead), so the
// frame comparison is unaffected.
assign ram_q = pl1_sel_q ? pl1_q
             : ram_sel_q ? sram_q
             : rom_sel_q ? rom_q : 8'hFF;


////////////////// SOUND ////////////////////////////////////////////////////
//
// The Studio II beeper is an NE555 astable gated by the 1802's Q line (SEQ/REQ).
// Per docs/sound.txt the control pin is tied to 0V through a 10uF electrolytic,
// which decays the pitch to about half over ~0.4s -- that droop is the "warpy"
// power-up sound, and it is what makes it recognisable. MAME just uses a fixed
// 300Hz beeper and flags the discrete circuit as unimplemented, so this follows
// the hardware description instead.
//
// ce_pix is the 1861 pixel rate (~1.76MHz), which is also the CPU clock, so:
//   625Hz  -> half period 1.76e6/(2*625) ~= 1408 ticks
//   312Hz  -> 2816 ticks
//   0.4s   -> ~704000 ticks, so step the half period every ~500; 512 is close
//             enough and is a free shift.

// Measured from refvideo/ rather than taken from docs/sound.txt, whose component
// values do not give a sane frequency. Spectral analysis of the Star Wars direct
// capture puts the fundamental at 545-549 Hz across every beep (the obvious
// zero-crossing answer, ~1570 Hz, is the harmonics -- a 555's asymmetric duty
// cycle gives strong even harmonics, and the TV audio path thins the fundamental).
localparam [15:0] SND_HALF_MIN = 16'd1609;   // ~547 Hz, freshly gated on
localparam [15:0] SND_HALF_MAX = 16'd3218;   // ~274 Hz, fully decayed

reg [15:0] snd_half;
reg [15:0] snd_cnt;
reg  [8:0] snd_decay;
reg        snd_out;

always @(posedge clk_sys) begin
	if (reset) begin
		snd_half  <= SND_HALF_MIN;
		snd_cnt   <= 16'd0;
		snd_decay <= 9'd0;
		snd_out   <= 1'b0;
	end
	else if (ce_pix) begin
		if (!Q) begin                                  // gated off: recharge, output idle
			snd_half  <= SND_HALF_MIN;
			snd_cnt   <= 16'd0;
			snd_decay <= 9'd0;
			snd_out   <= 1'b0;
		end
		else begin
			snd_decay <= snd_decay + 1'b1;
			if (&snd_decay && (snd_half < SND_HALF_MAX)) snd_half <= snd_half + 1'b1;
			if (snd_cnt >= snd_half) begin
				snd_cnt <= 16'd0;
				snd_out <= ~snd_out;
			end
			else snd_cnt <= snd_cnt + 1'b1;
		end
	end
end

// The Studio II's beeper is the discrete NE555 modelled above; the CDP1864
// machines have the tone generator inside the video part instead, so the 555
// goes away with the machine rather than being gated off. Weisbecker's Studio
// III sketch (IMG_1536.JPG) does keep a 555 alongside a "16 pin new chip for
// programmable tones", but that is the III A prototype -- the production
// Studio III and MPT-02 use the CDP1864, which is what this models.
assign audio = is_studio3 ? aud_tone : snd_out;

////////////////// CARTRIDGE LOADER /////////////////////////////////////////
//
// Raw .bin/.rom images are a flat copy to $0400. .st2 images are paged: a
// 256-byte header followed by 256-byte blocks, each block's target page taken
// from the table at header offsets 64-127 (docs/cartridge.txt).
//
// The format is detected purely from the "RCA2" magic in the first four bytes.
// The OSD extension index (ioctl_index[7:6]) is deliberately not used.

wire        bios_dl = ioctl_download && (ioctl_index[5:0] == 6'd0);
wire        cart_dl = ioctl_download && (ioctl_index[5:0] == 6'd1);

reg  [2:0]  st2_magic;                  // running match on "RCA"
reg         st2_mode;                   // "RCA2" seen: treat as paged
reg  [7:0]  st2_page [0:63];            // page table, header offsets 64..127

always @(posedge clk_sys) begin
	if (!ioctl_download) begin
		st2_magic <= 3'b000;
		st2_mode  <= 1'b0;
	end
	else if (cart_dl && ioctl_wr) begin
		case (ioctl_addr[15:0])
			16'd0: st2_magic[0] <=  (ioctl_dout == 8'h52);                    // 'R'
			16'd1: st2_magic[1] <=  (ioctl_dout == 8'h43) & st2_magic[0];     // 'C'
			16'd2: st2_magic[2] <=  (ioctl_dout == 8'h41) & st2_magic[1];     // 'A'
			16'd3: st2_mode     <=  (ioctl_dout == 8'h32) & st2_magic[2];     // '2'
			default: ;
		endcase
		if (ioctl_addr >= 16'd64 && ioctl_addr < 16'd128)
			st2_page[ioctl_addr[5:0]] <= ioctl_dout;
	end
end

// Byte at ioctl_addr belongs to block (addr>>8)-1; its page comes from the table.
wire  [5:0] st2_blk   = ioctl_addr[13:8] - 6'd1;
wire  [7:0] st2_pg    = st2_page[st2_blk];

// A page is loadable if it is cartridge space inside the 4k bank we model: not the
// system ROM ($00-$03), not RAM ($08-$09), and below $10. $0C/$0D ARE legal --
// race.st2 pages ROM over the default RAM mirror there, which is why the memory
// map calls $C00-$DFF "RAM/ROM". $00 is also the format's "unused block" marker.
// Page $0B is the CDP1864's colour RAM, not cartridge space, so a cartridge must
// not be able to page ROM over it on that machine. (On the Studio II $0B is an
// ordinary cartridge window and stays loadable, which is why this is gated.)
// On the Visicom RAM is not in this bank at all -- it sits at $1000 and above --
// so $08 and $09 are ordinary cartridge space there. Every one of Emma 02's six
// Visicom cartridges pages exactly $08-$0F, which the Studio II rule rejects
// outright: without this the whole image is dropped and the machine boots to its
// built-in games as though no cartridge were inserted.
wire        st2_pg_ok = (st2_pg[7:4] == 4'h0) && (st2_pg[3:0] > 4'h3)
                        && (machine_visicom || ((st2_pg[3:0] != 4'h8) && (st2_pg[3:0] != 4'h9)))
                        && !(is_studio3 && (st2_pg[3:0] == 4'hB));

wire        st2_data  = ioctl_addr >= 16'd256;          // past the header
wire [11:0] cart_a    = st2_mode ? {st2_pg[3:0], ioctl_addr[7:0]}
                                 : (ioctl_addr[11:0] + 12'h400);
wire        cart_we   = cart_dl && ioctl_wr && (!st2_mode || (st2_data && st2_pg_ok));

// Pages $0A-$0F, the ones the decode has to be told about. Pages $08/$09 are
// RAM and can never be claimed: st2_pg_ok already rejects them, and the
// (A10|A9) term means an over-long raw .bin cannot claim them either.
wire        cart_hi   = cart_a[11] && (cart_a[10] | cart_a[9]);

always @(posedge clk_sys) begin
	if (cart_dl && ioctl_wr && (ioctl_addr == 0)) cart_page <= 8'h00;   // new cartridge
	if (cart_we && cart_hi)                       cart_page[cart_a[10:8]] <= 1'b1;
end

wire [11:0] dl_a  = bios_dl ? ioctl_addr[11:0] : cart_a;
wire        dl_we = bios_dl ? ioctl_wr : cart_we;

// The ROM/cartridge image: system ROM at $0000-$07FF, then whatever the
// cartridge pages into $0800-$0FFF. Read-only to the CPU.
dpram #(8, 12) dpram
(
	.clock(clk_sys),
	.ram_cs(1'b1),
	.address_a(ioctl_download ? dl_a : ram_a[11:0]),
	.wren_a(dl_we),
	.data_a(ioctl_dout),
	.q_a(rom_q),

	// Port B was only ever the 1861's RAM scraper; the real part is fed by the CPU over DMA.
	.ram_cs_b(1'b0),
	.wren_b(1'b0),
	.address_b(12'd0),
	.data_b(),
	.q_b()
);

// The RAM: 512 bytes ($0800-$08FF program/system, $0900-$09FF display on the
// Studio II and III; $1000-$11FF on the Visicom, whose bit plane 0 is its top
// half). The Visicom's plane 1 is the separate 256-byte array below.
// Selected by A9 = 0, so the address inside it is just A8-A0.
// Add a port-B writer used to clear VRAM on CLEAR without resetting the Pixie
reg [8:0] clear_addr_b = 9'd0;
reg       clear_active = 1'b0;

// The wipe drives port A, not port B. Port B writing is what stopped this array
// inferring as block RAM: two active write ports mean mixed-port read-during-
// write, which an M10K cannot honour, and Quartus reported
//
//   Info (276009): RAM logic "...|dpram:sram|mem" is uninferred due to
//                  unsupported read-during-write behavior
//
// and built all 512 bytes out of logic instead -- 6,119 ALUTs and 4,104
// registers, most of the whole core. The ROM dpram and the Visicom's sram2 use
// this same module with port B tied off and both infer cleanly, which is what
// makes this the fix rather than a ramstyle attribute.
//
// Safe on port A because CLEAR is folded into reset, so the CPU is held in reset
// for the whole wipe and is not driving the bus.
always @(posedge clk_sys) begin
    if (clear_key && !clear_active) begin
        clear_active <= 1'b1;
        clear_addr_b <= 9'd256; // VRAM starts at offset 256 in the 512-byte RAM
    end
    else if (clear_active) begin
        if (clear_addr_b == 9'd511) clear_active <= 1'b0;
        else                        clear_addr_b <= clear_addr_b + 1'b1;
    end
end

wire [8:0] sram_a_addr = clear_active ? clear_addr_b : ram_a[8:0];
wire [7:0] sram_a_data = clear_active ? 8'd0         : ram_d;
wire       sram_a_we   = clear_active ? 1'b1         : cpu_wr;

dpram #(8, 9) sram
(
	.clock(clk_sys),
	.ram_cs(1'b1),
	.address_a(sram_a_addr),
	.wren_a(sram_a_we),
	.data_a(sram_a_data),
	.q_a(sram_q),

	// Port B is tied off entirely, which is what lets this infer as block RAM.
	// Do not give it a write or a read without re-checking the inferred-
	// altsyncram list in output_files/RCAStudioII.map.rpt (CLAUDE.md §8).
	.ram_cs_b(1'b0),
	.wren_b(1'b0),
	.address_b(9'd0),
	.data_b(),
	.q_b()
);

// The Visicom's second bit plane: 256 bytes at $1300-$13FF, read every cycle at
// A7-A0 so the video has it during DMA and the CPU has it at $13xx.
dpram #(8, 8) sram2
(
	.clock(clk_sys),
	.ram_cs(1'b1),
	.address_a(ram_a[7:0]),
	.wren_a(pl1_wr),
	.data_a(ram_d),
	.q_a(pl1_q),

	.ram_cs_b(1'b0),
	.wren_b(1'b0),
	.address_b(8'd0),
	.data_b(),
	.q_b()
);


endmodule
