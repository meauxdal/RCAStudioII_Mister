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
//  51 Franklin Street, Fifth Floor, Boston, MA 0210-1301 USA.
//
//============================================================================

module pixie_video 
(
    // front end, CDP1802 bus clock domain
    input             clk,
    input             reset,  
    input             clk_enable,   // pixel enable
    input             cpu_ce,       // CPU machine-cycle enable

    input       [1:0] SC,         
    input             disp_on,
    input             disp_off,

    input       [7:0] data_in,     
    // Visicom COM-100: a second bit plane, delivered in the same DMA cycle
    input             vis_mode,
    input       [7:0] data_in2,

    output            DMAO,     
    output            INT,     
    output            EFx,

    // back end, video clock domain
    input             video_clk,
    output            csync,     
    output            video,

    output            VSync,
    output            HSync,    
    output            VBlank,
    output            HBlank,
    output            video_de,
    output            bitmap_de,
    // CDP1862 hand-off, for the NTSC Studio III
    input       [2:0] colour_in,
    input             con,
    input             bg_step,
    output      [2:0] colour_out,
    output      [1:0] vis_index,
    output            bg_active,
    output      [2:0] bg_colour_out  
);

// RCA Studio II
cdp1861 cdp1861 (
    .clk        (clk),          // I  pixel-rate domain
    .ce_pix     (clk_enable),   // I
    .cpu_ce     (cpu_ce),       // I  one pulse per CPU machine cycle
    .reset      (reset),        // I

    .SC         (SC),           // I [1:0]
    .data_in    (data_in),      // I [7:0]  byte the CPU delivers during DMA-OUT
    .vis_mode   (vis_mode),     // I
    .data_in2   (data_in2),     // I [7:0]
    .disp_on    (disp_on),      // I
    .disp_off   (disp_off),     // I

    .DMAO       (DMAO),         // O
    .INT        (INT),          // O
    .EFx        (EFx),          // O

    .csync      (csync),        // O
    .video      (video),        // O
    .VSync      (VSync),        // O
    .HSync      (HSync),        // O
    .VBlank     (VBlank),       // O
    .HBlank     (HBlank),       // O
    .video_de   (video_de),
    .bitmap_de  (bitmap_de),     // O
    .colour_in     (colour_in),
    .con           (con),
    .bg_step       (bg_step),
    .vis_index  (vis_index),
    .colour_out    (colour_out),
    .bg_active     (bg_active),
    .bg_colour_out (bg_colour_out)
);

endmodule
