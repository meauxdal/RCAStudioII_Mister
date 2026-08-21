//============================================================================
//
//  CDP1862 "COS/MOS Color Generator Controller".
//
//  Written 2026 by Alan Steremberg. The NTSC Studio III pairs this with a
//  CDP1861 to get what the PAL machine gets from a single CDP1864 -- see
//  docs/succession-plan.md §9, and Emma 02's StudioIII/standard-ntsc.xml, which
//  declares <video type="cdp1861"> and <video type="cdp1862"> side by side.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//============================================================================
//
//  This is deliberately thin. The 1861 beside it already does the hard part --
//  it latches a colour with each DMA byte and shifts it alongside the luminance,
//  because that is where the DMA is -- so all that is left here is choosing
//  between the dot colour and the background, which is what the real part does
//  with its RDATA/BDATA/GDATA inputs and its BKG pin.
//
//  MAME's cdp1862.h confirms the interface: rdata_cb / bdata_cb / gdata_cb for
//  the three colour lines, bkg_w for the background step, con_w for Color On,
//  and BKG LUM / BKG CHR pins -- the background at lower luminance so one colour
//  can serve as both background and data, which is the same idea as the 1864's
//  BCKGND and is carried here on bckgnd.
//
//  Colours are {R,G,B} on this bus. Note the colour RAM itself is in the 1864's
//  pin order (bit 0 red, bit 1 blue, bit 2 green); rtl/rcastudioii.sv permutes
//  it once, before either part sees it.
//
//============================================================================

`default_nettype none

module cdp1862
(
    input             enable,       // this machine has an 1862 fitted
    input             luminance,    // the 1861's monochrome video bit
    input             in_raster,    // inside the visible raster
    input       [2:0] dot_colour,   // colour latched with this byte
    input             bg_active,    // this pixel takes the background
    input       [2:0] bg_colour,

    output      [2:0] video,        // {R,G,B}
    output            bckgnd        // show it at background luminance
);

//  Without an 1862 the machine is a plain monochrome Studio II: white dots on
//  black, and no background luminance to qualify.
assign video  = !enable   ? {3{luminance}}
              : !in_raster ? 3'b000
              : luminance  ? dot_colour
              :              (bg_active ? bg_colour : 3'b000);

assign bckgnd = enable && bg_active && !luminance;

endmodule

`default_nettype wire
