//*******************************************************************************************************
//*******************************************************************************************************
//
//      Name:       Cpu.C
//      Purpose:    1802 Processor Emulation
//      Author:     Paul Robson
//      Date:       24th February 2013
//
//*******************************************************************************************************
//*******************************************************************************************************

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "general.h"
#include "cpu.h"
#include "system.h"

#include "macros1802.h"

#define CLOCK_SPEED             (3521280/2)                                         // Clock Frequency (1,760,640Hz)
#define CYCLES_PER_SECOND       (CLOCK_SPEED/8)                                     // There are 8 clocks in each cycle (220,080 Cycles/Second)
#define FRAMES_PER_SECOND       (60)                                                // NTSC Frames Per Second
#define LINES_PER_FRAME         (262)                                               // Lines Per NTSC Frame
#define CYCLES_PER_FRAME        (CYCLES_PER_SECOND/FRAMES_PER_SECOND)               // Cycles per Frame, Complete (3668)
#define CYCLES_PER_LINE         (CYCLES_PER_FRAME/LINES_PER_FRAME)                  // Cycles per Display Line (14)

#define VISIBLE_LINES           (128)                                               // 128 visible lines per frame
#define NON_DISPLAY_LINES       (LINES_PER_FRAME-VISIBLE_LINES)                     // Number of non-display lines per frame. (134)
#define EXEC_CYCLES_PER_FRAME   (NON_DISPLAY_LINES*CYCLES_PER_LINE)                 // Cycles where 1802 not generating video per frame (1876)

// Note: this means that there are 1876*60/2 approximately instructions per second, about 56,280. With an instruction rate of
// approx 8m per second, this means each instruction is limited to 8,000,000 / 56,280 * (128/312.5) about 58 AVR instructions for each
// 1802 instructions.

// State 1 : cycles till interrupt, N1 = 0
// State 2 : 29 cycles with N1 = 1
//
//  The CPU does not stop during the display window -- it loses only the 8 machine
//  cycles a line that DMA actually steals, out of 14. This model has no intra-frame
//  position (no scanline counter), so the display allowance is simply added to
//  State 1's budget: what matters is the total number of cycles the CPU gets
//  between one interrupt and the next.
//
//  Originally the display period was skipped entirely, which cost the CPU 40% of
//  its time: 952 instructions a frame against real hardware's 1321 on the Studio
//  II, and a measured 854 against the RTL's 1485 on the MPT-02. Anything computing
//  during the display window then diverged from hardware for reasons of its own --
//  which is what made the Sarnoff colour demo useless as a check.
//
//      Studio II  (262 lines, 128 displayed): 1876 + 128*6 = 2644 -> 1322 instr
//      MPT-02     (312 lines, 192 displayed): 1680 + 192*6 = 2832 -> 1416 instr
//
//  Both now land on what the RTL and the hardware do.
#define DMA_CYCLES_PER_LINE     (8)                                                 // 8 of the 14 go to display DMA
#define CPU_CYCLES_PER_DISPLAY_LINE (CYCLES_PER_LINE-DMA_CYCLES_PER_LINE)

#define STATE_1_CYCLES          (state1Cycles)
#define STATE_2_CYCLES          (29)

//  The CDP1864 colour machines are PAL and run a different frame: 1.75MHz clock,
//  50Hz, 312 lines a frame, and 192 display lines (32 logical rows shown 6x --
//  Emma 02's MPT-02 config gives display lines 76..267 inclusive, which is
//  exactly 192, and the datasheet advertises "max 192 vertical x 64 horizontal").
//  So the CPU gets (312-192)*14 = 1680 cycles between interrupts where the
//  Studio II gets 1876.
//
//      1750000/8 = 218750 cycles/sec, /50 = 4375 a frame, /312 = 14 a line.
//
//  Held in a variable rather than a #define so one binary can be either machine.
#define MPT02_CYCLES_PER_LINE   (14)
#define MPT02_LINES_PER_FRAME   (312)
#define MPT02_VISIBLE_LINES     (192)
#define MPT02_EXEC_CYCLES       ((MPT02_LINES_PER_FRAME-MPT02_VISIBLE_LINES)*MPT02_CYCLES_PER_LINE)

//  Non-display budget, plus the CPU's share of the display window, less the 29
//  cycles State 2 accounts for separately.
#define STUDIO2_STATE1  (EXEC_CYCLES_PER_FRAME - 29 + VISIBLE_LINES*CPU_CYCLES_PER_DISPLAY_LINE)
#define MPT02_STATE1    (MPT02_EXEC_CYCLES     - 29 + MPT02_VISIBLE_LINES*CPU_CYCLES_PER_DISPLAY_LINE)

static INT16 state1Cycles = STUDIO2_STATE1;                                         // set by CPU_SetMachine()
static BYTE8 machineType  = MACHINE_STUDIO2;
static BYTE8 rowScale     = ROW_SCALE_STUDIO2;

static BYTE8 D,X,P,T;                                                               // 1802 8 bit registers
static BYTE8 DF,IE,Q;                                                               // 1802 1 bit registers
static WORD16 R[16];                                                                // 1802 16 bit registers
static WORD16 _temp;                                                                // Temporary register
static INT16 Cycles;                                                                // Cycles till state switch
static BYTE8 State;                                                                 // Frame position state (NOT 1802 internal state)
static BYTE8 *screenMemory = NULL;                                                  // Current Screen Pointer (NULL = off)
static BYTE8 scrollOffset;                                                          // Vertical scroll offset e.g. R0 = $nnXX at 29 cycles
static BYTE8 screenEnabled;                                                         // Screen on (IN 1 on, OUT 1 off)
static BYTE8 keyboardLatch;                                                         // Value stored in Keyboard Select Latch (Studio 2)

//*******************************************************************************************************
//                          CDP1864 colour state (MPT-02 / Studio III only)
//*******************************************************************************************************
//
//  64 colour cells, not 256. The board decodes six address lines, so $B00-$BFF is
//  the same 64 bytes mirrored four times -- which is why MAME maps $0B00-$0B3F
//  (the storage) and Emma 02 declares $0B00-$0BFF (the decoded window) without
//  the two actually disagreeing.  See docs/succession-plan.md §6.
//
//  The cell for a display byte is {off[7:5], off[2:0]}: the low three bits are
//  the column (8 bytes across a 64 pixel row) and off[7:5] the row group, so one
//  cell covers 8 pixels across by 4 logical rows down. That indexing is MAME's,
//  from mpt02_state::dma_w(), where the offset it is handed is the DMA address
//  (cosmac_device::dma_output passes R[0]).
//
//  Colours are 3-bit {R,G,B}. Bit 0 red, bit 1 blue, bit 2 green in the 1864's
//  own pin order (RDATA/BDATA/GDATA); this keeps them in that order internally
//  and converts to {R,G,B} on the way out so the value matches the RTL's video
//  bus.

#define COLOUR_CELLS            (64)

static BYTE8 colourRAM[COLOUR_CELLS];                                               // 1-of-8 dot colour per cell
static BYTE8 backgroundIndex;                                                       // 0-3, steps on OUT 1
static BYTE8 colourEnabled;                                                         // CON: set by the first colour RAM write

//  The four background colours, as {R,G,B}. Order and values follow Emma 02's
//  soundic_victory_mpt-02.xml, which lists back_blue, back_black, back_green and
//  back_red -- the 1864 steps through them in that order.
static const BYTE8 backgroundColours[4] = { 1, 0, 2, 4 };                           // blue, black, green, red

//  1864 colour RAM holds R/B/G in bits 0/1/2 (the pin order). Convert to the
//  {R,G,B} = bit2/bit1/bit0 form the rest of this program and the RTL use.
static BYTE8 CPU_ColourToRGB(BYTE8 c)
{
    return (BYTE8)(((c & 1) ? 4 : 0) | ((c & 4) ? 2 : 0) | ((c & 2) ? 1 : 0));
}

BYTE8 CPU_GetColour(BYTE8 pageOffset)
{
    BYTE8 cell = (BYTE8)(((pageOffset & 0xE0) >> 2) | (pageOffset & 0x07));
    return CPU_ColourToRGB(colourRAM[cell & (COLOUR_CELLS-1)]);
}

BYTE8 CPU_GetBackgroundColour()
{
    return backgroundColours[backgroundIndex & 3];
}

BYTE8 CPU_GetColourEnabled()
{
    return colourEnabled;
}

BYTE8 CPU_GetColourCell(BYTE8 cell)
{
    return colourRAM[cell & (COLOUR_CELLS-1)];
}

BYTE8 CPU_GetMachine()  { return machineType; }
BYTE8 CPU_GetRowScale() { return rowScale; }

void CPU_SetMachine(BYTE8 machine)
{
    machineType  = machine;
    if (machine == MACHINE_MPT02)
    {
        state1Cycles = MPT02_STATE1;
        rowScale     = ROW_SCALE_MPT02;
    }
    else
    {
        state1Cycles = STUDIO2_STATE1;
        rowScale     = ROW_SCALE_STUDIO2;
    }
}

#ifdef ARDUINO_VERSION
static BYTE8 studio2RAM[512] __attribute__ ((section (".noinit")));                 // Studio 2's internal RAM (ONLY)
#else
static BYTE8 studio24k[4096];                                                       // otherwise the whole 4k.
#endif

//*******************************************************************************************************
//                                      Load Binary image
//*******************************************************************************************************

#ifndef ARDUINO_VERSION

static BYTE8 cartVideoFlag = 0;                                                     // ST2 header video flag (0 = standard driver)

BYTE8 CPU_GetCartVideoFlag()
{
    return cartVideoFlag;
}

//  The ST2 format lets a block target any page in the 64k ROM space; this emulator models the first
//  4k bank only, so pages $10 and up cannot be placed.  Within the bank everything is cartridge space
//  except the system ROM at $000-$3FF and the RAM at $800-$9FF.
//
//  Note docs/cartridge.txt says "in practice this is 400-7FF, A00-BFF and E00-FFF", which would reject
//  $0C/$0D -- but real dumps (race.st2) page ROM in there, over the default $800-$9FF RAM mirror, and
//  the Studio 2 memory map lists $C00-$DFF as RAM/ROM for exactly that reason.  So allow it.

static BOOL CPU_IsLoadablePage(BYTE8 page)
{
    if (page >= 0x10) return FALSE;                                                 // Outside the single 4k bank we model.
    if (page <= 0x03) return FALSE;                                                 // System ROM.
    if (page == 0x08 || page == 0x09) return FALSE;                                 // Studio 2 RAM / display memory.
    if (machineType == MACHINE_MPT02 && page == 0x0B) return FALSE;                 // 1864 colour RAM, not cartridge space.
    return TRUE;
}

//  Load a paged .st2 cartridge (docs/cartridge.txt). Returns FALSE if this is not an ST2 image at all,
//  so the caller can fall back to a flat load.

static BOOL CPU_LoadST2Image(FILE *f)
{
    BYTE8 header[256],block[256];
    int blocks,count,i;

    if (fread(header,1,sizeof(header),f) != sizeof(header)) return FALSE;           // Too short to hold a header.
    if (memcmp(header,"RCA2",4) != 0) return FALSE;                                 // Not an ST2 image.

    blocks = header[4];                                                             // Total blocks, *including* this header.
    cartVideoFlag = header[6];

    printf("ST2 \"%.32s\" catalogue \"%.10s\" format %d, %d block(s), video flag %d\n",
                            header+32,header+16,header[5],blocks-1,cartVideoFlag);

    for (i = 0;i < blocks-1;i++)                                                    // Header counts itself, hence blocks-1 of data.
    {
        BYTE8 page = header[64+i];                                                  // Page table runs from offset 64.
        count = (int)fread(block,1,sizeof(block),f);
        if (count == 0) break;                                                      // File is shorter than its own block count.
        if (page == 0x00) continue;                                                 // $00 is the documented "unused" marker.
        if (!CPU_IsLoadablePage(page))
        {
            printf("    block %d: page $%02X not decodable in a 4k Studio 2, skipped\n",i+1,page);
            continue;
        }
        memcpy(studio24k+(page << 8),block,count);
        printf("    block %d -> $%02X00-$%02X%02X\n",i+1,page,page,count-1);
    }
    fflush(stdout);                                                                 // Loader output must survive a killed/headless run.
    return TRUE;
}

//  Load a system ROM flat at $0000, replacing the Studio II BIOS this program
//  carries embedded. Needed for the colour machines: the Studio III / MPT-02
//  BIOS is a different image (refs/emma_02/data/StudioIII/studio3_{ntsc,pal}.bin,
//  data/Victory/victory.rom), and without it a Studio III cartridge just shows a
//  blank frame. Call after CPU_Reset(), which is what copies the embedded BIOS in.

void CPU_LoadBios(char *fileName)
{
    FILE *f = fopen(fileName,"rb");
    int address = 0x0000;
    int c;
    if (f == NULL)
        exit(printf("Unable to open BIOS: %s\n",fileName));
    //  The Studio II BIOS is 2K and sits at $0000-$07FF. The Studio III / MPT-02
    //  image is 4K, spanning both of that machine's ROM regions -- MAME's
    //  mpt02_map has .rom() at $0000-$07FF *and* $0C00-$0FFF -- so load the whole
    //  4K but step over the RAM at $0800-$09FF and the colour RAM at $0B00-$0BFF
    //  rather than letting ROM bytes land on top of them.
    while ((c = fgetc(f)) != EOF && address < 0x1000)
    {
        if (address < 0x800 || address >= 0xC00) studio24k[address] = (BYTE8)c;
        address++;
    }
    fclose(f);
}

void CPU_LoadBinaryImage(char *fileName)
{
    FILE *f = fopen(fileName,"rb");
    int address = 0x400;
    int c;
    if (f == NULL)                                                                  // Missing/unreadable image is fatal.
        exit(printf("Unable to open image: %s\n",fileName));
    cartVideoFlag = 0;
    if (CPU_LoadST2Image(f))                                                        // .st2 images are paged, not flat.
    {
        fclose(f);
        return;
    }
    rewind(f);                                                                      // Not ST2, so fall back to a flat load at $0400.
    while ((c = fgetc(f)) != EOF && address < 0x1000)                               // Stop at EOF or the end of the 4k space.
    {
        if (address < 0x800 || address >= 0xA00) studio24k[address] = (BYTE8)c;
        address++;
    }
    fclose(f);
}
#endif

//*******************************************************************************************************
//                                 Macros to Read/Write memory
//*******************************************************************************************************

#define READ(a)     CPU_ReadMemory(a)
#define WRITE(a,d)  CPU_WriteMemory(a,d)

//*******************************************************************************************************
//   Macros for fetching 1 + 2 BYTE8 operands, Note 2 BYTE8 fetch stores in _temp, 1 BYTE8 returns value
//*******************************************************************************************************

#define FETCH2()    (CPU_ReadMemory(R[P]++))
#define FETCH3()    { _temp = CPU_ReadMemory(R[P]++);_temp = (_temp << 8) | CPU_ReadMemory(R[P]++); }

//*******************************************************************************************************
//                      Macros translating Hardware I/O to hardwareHandler calls
//*******************************************************************************************************

#define READEFLAG(n)    CPU_ReadEFlag(n)
#define UPDATEIO(p,d)   CPU_OutputHandler(p,d)
#define INPUTIO(p)      CPU_InputHandler(p)

static BYTE8 CPU_ReadEFlag(BYTE8 flag)
{
    BYTE8 retVal = 0;
    switch (flag)
    {
        case 1:                                                                     // EF1 detects not in display
            retVal = 1;                                                             // Permanently set to '1' so BN1 in interrupts always fails
            break;
        case 3:                                                                     // EF3 detects keypressed on VIP and Elf but differently.
            SYSTEM_Command(HWC_SETKEYPAD,1);
            retVal = SYSTEM_Command(HWC_READKEYBOARD,keyboardLatch);
            break;
        case 4:                                                                     // EF4 is !IN Button
            SYSTEM_Command(HWC_SETKEYPAD,2);
            retVal = SYSTEM_Command(HWC_READKEYBOARD,keyboardLatch);
            break;
    }
    return retVal;
}

//  The colour machines move the display-off control. On the Studio II the 1861 is
//  turned on by INP 1 and off by OUT 1. On the CDP1864, per the datasheet, N0
//  with TPB enables interrupt and DMA ("a 61 or 69 instruction") while N2 with
//  MRD and TPB disables them ("a 6C instruction"), and OUT 1 is taken over by the
//  background colour step. MAME's mpt02_io_map and Emma 02's
//  soundic_victory_mpt-02.xml (<in type="on">1</in>, <out type="back">1</out>,
//  <out type="tone">4</out>) both agree.
//
//      Studio II:  INP 1 = on    OUT 1 = off
//      MPT-02:     INP 1 = on    INP 4 = off    OUT 1 = step background
//                                               OUT 4 = tone latch

static BYTE8 CPU_InputHandler(BYTE8 portID)
{
    BYTE8 retVal = 0;
    switch (portID)
    {
        case 1:                                                                     // IN 1 turns the display on.
            screenEnabled = TRUE;
            break;
        case 4:                                                                     // IN 4 turns it off on the 1864 machines.
            if (machineType == MACHINE_MPT02) screenEnabled = FALSE;
            break;
    }
    return retVal;
}

static void CPU_OutputHandler(BYTE8 portID,BYTE8 data)
{
    switch (portID)
    {
        case 0:                                                                     // Called with 0 to set Q
            SYSTEM_Command(HWC_UPDATEQ,data);                                       // Update Q Flag via HW Handler
            break;
        case 1:                                                                     // OUT 1: display off on the Studio II,
            if (machineType == MACHINE_MPT02)                                       // background colour step on the 1864.
                backgroundIndex = (BYTE8)((backgroundIndex + 1) & 3);
            else
                screenEnabled = FALSE;
            break;
        case 2:                                                                     // OUT 2 sets the keyboard latch (both S2 & VIP)
            keyboardLatch = data & 0x0F;                                            // Lower 4 bits only :)
            break;
        case 4:                                                                     // OUT 4 loads the 1864 tone divider latch.
            //  Not generating audio here: the comparison harness only ever diffs
            //  frames, and the RTL's audio is checked separately by measuring Q
            //  edges (CLAUDE.md §10, 2026-08-12). Swallowed so it does not fall
            //  through to anything else.
            break;
    }
}

//*******************************************************************************************************
//                                              Monitor ROM
//*******************************************************************************************************

#ifndef ARDUINO_VERSION                                                             // if not Arduino
#define PROGMEM                                                                     // fix usage of PROGMEM and prog_char
#define prog_uchar BYTE8
#endif

#include "studio2_rom.h"

//*******************************************************************************************************
//                          Reset the 1802 and System Handlers
//*******************************************************************************************************

void CPU_Reset()
{
    X = P = Q = R[0] = 0;                                                           // Reset 1802 - Clear X,P,Q,R0
    IE = 1;                                                                         // Set IE to 1
    DF = DF & 1;                                                                    // Make DF a valid value as it is 1-bit.

    State = 1;                                                                      // State 1
    Cycles = STATE_1_CYCLES;                                                        // Run this many cycles.
    screenEnabled = FALSE;

    memset(colourRAM,0,sizeof(colourRAM));                                          // 1864 colour state: cleared, colour off
    backgroundIndex = 0;                                                            // until the first colour RAM write (CON).
    colourEnabled = FALSE;

    #ifndef ARDUINO
    int i;                                                                          // PC Version copy code into 4k space.
    for (i = 0;i < 2048;i++) studio24k[i] = _studio2[i];
    #endif
}


//*******************************************************************************************************
//                                        Read a BYTE8 in memory
//*******************************************************************************************************

BYTE8 CPU_ReadMemory(WORD16 address)
{
    address &= 0xFFF;
    #ifdef ARDUINO_VERSION
    if (address < 0x800)
    {
        return pgm_read_byte_near(_studio2+address);
    }
    if (address >= 0x800 && address < 0xA00)
        return studio2RAM[address-0x800];
    return 0xFF;
    #else
    return studio24k[address];
    #endif
}

//*******************************************************************************************************
//                                          Write a BYTE8 in memory
//*******************************************************************************************************

void CPU_WriteMemory(WORD16 address,BYTE8 data)
{
    address = address & 0xFFF;
    if (address >= 0x800 && address < 0xA00)                                    // only RAM space is writeable
    {
        #ifdef ARDUINO_VERSION
        studio2RAM[address-0x800] = data;
        #else
        studio24k[address] = data;
        #endif
        return;
    }
    //  Colour RAM on the CDP1864 machines. 64 cells behind a one page window, so
    //  the index is the low six bits (see the colour section above). Writing here
    //  is also what asserts CON on real hardware -- the datasheet has CON tied to
    //  "the gated MWR signal of the color memory" -- so colour switches on with
    //  the first write rather than needing a separate enable.
    if (machineType == MACHINE_MPT02 && address >= 0xB00 && address < 0xC00)
    {
        colourRAM[address & (COLOUR_CELLS-1)] = data;
        colourEnabled = TRUE;
    }
}

//*******************************************************************************************************
//                                         Execute one instruction
//*******************************************************************************************************

BYTE8 CPU_Execute()
{
    BYTE8 rState = 0;
    BYTE8 opCode = CPU_ReadMemory(R[P]++);
    Cycles -= 2;                                                                    // 2 x 8 clock Cycles - Fetch and Execute.
    switch(opCode)                                                                  // Execute dependent on the Operation Code
    {
        #include "cpu1802.h"
    }
    if (Cycles < 0)                                                                 // Time for a state switch.
    {
        switch(State)
        {
        case 1:                                                                     // Main Frame State Ends
            State = 2;                                                              // Switch to Interrupt Preliminary state
            Cycles = STATE_2_CYCLES;                                                // The 29 cycles between INT and DMAOUT.
            if (screenEnabled)                                                      // If screen is on
            {
                if (CPU_ReadMemory(R[P]) == 0) R[P]++;                              // Come out of IDL for Interrupt.
                INTERRUPT();                                                        // if IE != 0 generate an interrupt.
            }
            break;
        case 2:                                                                     // Interrupt preliminary ends.
            State = 1;                                                              // Switch to Main Frame State
            Cycles = STATE_1_CYCLES;
            #ifdef ARDUINO_VERSION
            screenMemory = studio2RAM+(R[0] & 0xFF00)-0x800;                        // masking with $FF00
            #else
            screenMemory = studio24k+(R[0] & 0xFF00);                               // space for PC version
            #endif
            scrollOffset = R[0] & 0xFF;                                             // Get the scrolling offset (for things like the car game)
            SYSTEM_Command(HWC_FRAMESYNC,0);                                        // Synchronise.
            break;
        }
        rState = (BYTE8)State;                                                      // Return state as state has switched
        Cycles--;                                                                   // Time out when cycles goes -ve so deduct 1.
    }
    return rState;
}

//*******************************************************************************************************
//                                              Access CPU State
//*******************************************************************************************************

#ifdef CPUSTATECODE

CPU1802STATE *CPU_ReadState(CPU1802STATE *s)
{
    int i;
    s->D = D;s->DF = DF;s->X = X;s->P = P;s->T = T;s->IE = IE;s->Q = Q;
    s->Cycles = Cycles;s->State = State;
    for (i = 0;i < 16;i++) s->R[i] = R[i];
    return s;
}

#endif // CPUSTATECODE

//*******************************************************************************************************
//                         Get Current Screen Memory Base Address (ignoring scrolling)
//*******************************************************************************************************

BYTE8 *CPU_GetScreenMemoryAddress()
{
    if (scrollOffset != 0)
    {
        scrollOffset *= 1;
    }
    return (screenEnabled != 0) ? (BYTE8 *)screenMemory : NULL;
}

//*******************************************************************************************************
//                               Get Current Screen Memory Scrolling Offset
//*******************************************************************************************************

BYTE8 CPU_GetScreenScrollOffset()
{
    return scrollOffset;
}

//*******************************************************************************************************
//                                        Get Program Counter value
//*******************************************************************************************************

WORD16 CPU_ReadProgramCounter()
{
    return R[P];
}
