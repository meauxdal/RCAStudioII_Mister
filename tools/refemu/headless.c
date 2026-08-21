//*******************************************************************************************************
//*******************************************************************************************************
//
//      Name:       Headless.C
//      Purpose:    Headless front end - runs N frames, dumps PNGs, no SDL.
//      Author:     Added for the RCAStudioII MiSTer core, as a golden reference for the RTL.
//
//      Replaces main.c + hardware.c + debug*.c in the "headless" makefile target, so the binary links
//      nothing but libc.  Frame boundaries come from CPU_Execute(), which returns 1 on the State 2 ->
//      State 1 switch -- exactly where the 1802 latches R(0) as the display pointer for the new frame.
//
//*******************************************************************************************************
//*******************************************************************************************************

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "general.h"
#include "cpu.h"
#include "hardware.h"

#define SCREEN_W        (64)                                                        // Studio 2 is 64x32 logical pixels,
#define SCREEN_H        (32)                                                        // each row shown 4x on a real TV.
#define VRAM_BYTES      (SCREEN_W/8*SCREEN_H)                                       // 8 bytes a line, 32 lines = 256.

//*******************************************************************************************************
//                          PNG writer -- 8 bit greyscale, no libpng/zlib needed
//*******************************************************************************************************
//
//  The deflate stream uses *stored* (uncompressed) blocks only.  That is a legal zlib stream, costs a
//  few bytes on a 64x32 image, and keeps this file dependency free so the headless build never breaks
//  on a machine without zlib development headers.

static unsigned long PNG_Crc(const unsigned char *p,unsigned long n,unsigned long crc)
{
    static unsigned long table[256];
    static int built = 0;
    unsigned long c,i;
    int k;
    if (!built)                                                                     // Build the CRC32 table once.
    {
        for (i = 0;i < 256;i++)
        {
            c = i;
            for (k = 0;k < 8;k++) c = (c & 1) ? (0xEDB88320UL ^ (c >> 1)) : (c >> 1);
            table[i] = c;
        }
        built = 1;
    }
    for (i = 0;i < n;i++) crc = table[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);
    return crc;
}

static void PNG_Put32(FILE *f,unsigned long v)
{
    fputc((int)((v >> 24) & 0xFF),f);fputc((int)((v >> 16) & 0xFF),f);
    fputc((int)((v >>  8) & 0xFF),f);fputc((int)( v        & 0xFF),f);
}

static void PNG_Chunk(FILE *f,const char *type,const unsigned char *data,unsigned long len)
{
    unsigned long crc;
    PNG_Put32(f,len);
    fwrite(type,1,4,f);
    if (len != 0) fwrite(data,1,len,f);
    crc = PNG_Crc((const unsigned char *)type,4,0xFFFFFFFFUL);
    if (len != 0) crc = PNG_Crc(data,len,crc);
    PNG_Put32(f,crc ^ 0xFFFFFFFFUL);
}

//  Write a truecolour image.  "rgb" is w*h*3 bytes.  This used to be greyscale
//  (colour type 0, one byte a pixel); it became RGB when the CDP1864 machines
//  arrived. Nothing diffs these files byte-for-byte -- tools/compare-game.sh
//  compares the --ascii output, not the PNGs -- so widening them is safe.

static BOOL PNG_Write(const char *path,const unsigned char *rgb,int w,int h)
{
    static const unsigned char sig[8] = { 137,'P','N','G','\r','\n',26,'\n' };
    unsigned char ihdr[13],*raw,*z;
    unsigned long rawLen,zLen,pos,a = 1,b = 0,i;
    int y;
    FILE *f;

    rawLen = (unsigned long)h * (unsigned long)(w * 3 + 1);                         // Each scanline gets a leading filter byte.
    raw = (unsigned char *)malloc(rawLen);
    if (raw == NULL) return FALSE;
    for (y = 0;y < h;y++)
    {
        raw[(unsigned long)y * (w * 3 + 1)] = 0;                                    // Filter type 0 (none).
        memcpy(raw + (unsigned long)y * (w * 3 + 1) + 1,
               rgb + (unsigned long)y * w * 3,(size_t)w * 3);
    }

    for (i = 0;i < rawLen;i++)                                                      // Adler-32 over the raw stream.
    {
        a = (a + raw[i]) % 65521;
        b = (b + a) % 65521;
    }

    zLen = 2 + 4 + rawLen + 5 * ((rawLen + 65534) / 65535);                          // hdr + adler + data + block headers
    z = (unsigned char *)malloc(zLen);
    if (z == NULL) { free(raw); return FALSE; }
    pos = 0;
    z[pos++] = 0x78; z[pos++] = 0x01;                                               // zlib header, 0x7801 % 31 == 0.
    i = 0;
    while (i < rawLen)                                                              // Stored blocks, max 65535 bytes each.
    {
        unsigned long n = rawLen - i;
        if (n > 65535) n = 65535;
        z[pos++] = (unsigned char)((i + n >= rawLen) ? 1 : 0);                       // BFINAL on the last block, BTYPE 00.
        z[pos++] = (unsigned char)( n        & 0xFF);
        z[pos++] = (unsigned char)((n >> 8)  & 0xFF);
        z[pos++] = (unsigned char)((~n)      & 0xFF);
        z[pos++] = (unsigned char)((~n >> 8) & 0xFF);
        memcpy(z + pos,raw + i,n);
        pos += n; i += n;
    }
    z[pos++] = (unsigned char)((b >> 8) & 0xFF); z[pos++] = (unsigned char)(b & 0xFF);
    z[pos++] = (unsigned char)((a >> 8) & 0xFF); z[pos++] = (unsigned char)(a & 0xFF);

    f = fopen(path,"wb");
    if (f == NULL) { free(raw); free(z); return FALSE; }
    fwrite(sig,1,8,f);
    ihdr[0] = (unsigned char)((w >> 24) & 0xFF); ihdr[1] = (unsigned char)((w >> 16) & 0xFF);
    ihdr[2] = (unsigned char)((w >>  8) & 0xFF); ihdr[3] = (unsigned char)( w        & 0xFF);
    ihdr[4] = (unsigned char)((h >> 24) & 0xFF); ihdr[5] = (unsigned char)((h >> 16) & 0xFF);
    ihdr[6] = (unsigned char)((h >>  8) & 0xFF); ihdr[7] = (unsigned char)( h        & 0xFF);
    ihdr[8] = 8;                                                                    // 8 bits per sample
    ihdr[9] = 2;                                                                    // colour type 2 = truecolour RGB
    ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;                                       // deflate / no filter / no interlace
    PNG_Chunk(f,"IHDR",ihdr,13);
    PNG_Chunk(f,"IDAT",z,pos);
    PNG_Chunk(f,"IEND",NULL,0);
    fclose(f);
    free(raw); free(z);
    return TRUE;
}

//*******************************************************************************************************
//                                        Frame buffer capture
//*******************************************************************************************************
//
//  Unpack the 256 byte display window into one byte per pixel, applying the vertical scroll the same way
//  hardware.c does.  Note the index is masked per byte: hardware.c wraps the *line* start with & 0xFF but
//  then reads 8 bytes straight on, which runs past the window when scrollOffset is not a multiple of 8.

//  Each pixel comes out as a 3-bit {R,G,B} colour, 0-7, matching the RTL's video
//  bus. A monochrome Studio II only ever produces 0 (black) and 7 (white), which
//  is what keeps every existing capture and the whole §9 comparison identical.
//
//  On a CDP1864 machine the dot colour comes from colour RAM, indexed by the
//  display byte's page offset, and lit pixels take that colour while unlit ones
//  take the background. The datasheet has the colour latched "concurrent with the
//  latching of the luminance information ... during the display interval", so
//  colour is a pure function of where the byte is -- which is why it can be
//  resolved here at render time even though this emulator models the frame as a
//  screen pointer rather than per-byte DMA.

static void HL_ReadScreen(unsigned char *pix)
{
    BYTE8 *screen = CPU_GetScreenMemoryAddress();                                   // NULL when the display is off.
    BYTE8 scroll = CPU_GetScreenScrollOffset();
    BOOL colour = (CPU_GetMachine() == MACHINE_MPT02) && CPU_GetColourEnabled();
    BYTE8 background = colour ? CPU_GetBackgroundColour() : 0;
    int x,y,bit;

    memset(pix,0,SCREEN_W * SCREEN_H);
    if (screen == NULL) return;                                                     // Display off -> a black frame.
    for (y = 0;y < SCREEN_H;y++)
    {
        for (x = 0;x < SCREEN_W / 8;x++)
        {
            BYTE8 offset = (BYTE8)((y * 8 + x + scroll) & 0xFF);
            BYTE8 byte = screen[offset];
            BYTE8 on = colour ? CPU_GetColour(offset) : 7;                          // dot colour, white if monochrome
            for (bit = 0;bit < 8;bit++)                                             // Bit 7 is the leftmost pixel.
                pix[y * SCREEN_W + x * 8 + bit] =
                    (byte & (0x80 >> bit)) ? on : background;
        }
    }
}

static unsigned long HL_Hash(const unsigned char *pix)                              // FNV-1a over the unpacked frame.
{
    unsigned long h = 2166136261UL;
    int i;
    for (i = 0;i < SCREEN_W * SCREEN_H;i++)
    {
        h ^= (pix[i] != 0);
        h = (h * 16777619UL) & 0xFFFFFFFFUL;
    }
    return h;
}

static BOOL HL_Shot(const char *dir,const char *prefix,int frame,const unsigned char *pix,int scale)
{
    char path[512];
    unsigned char *big;
    int x,y,w,h,rowScale;
    BOOL ok;

    if (scale < 1) scale = 1;
    //  Each logical row covers several scanlines on a real set -- 4 on the NTSC
    //  Studio II, 6 on the PAL colour machines -- so the saved image uses that as
    //  its vertical scale to come out the shape the TV showed.
    rowScale = CPU_GetRowScale();
    w = SCREEN_W * scale; h = SCREEN_H * scale * rowScale;
    big = (unsigned char *)malloc((size_t)w * h * 3);
    if (big == NULL) return FALSE;
    for (y = 0;y < h;y++)                                                           // Nearest neighbour, so pixels stay square.
        for (x = 0;x < w;x++)
        {
            unsigned char c = pix[(y / (scale * rowScale)) * SCREEN_W + (x / scale)];
            size_t o = ((size_t)y * w + x) * 3;
            big[o + 0] = (c & 4) ? 0xFF : 0x00;                                     // R
            big[o + 1] = (c & 2) ? 0xFF : 0x00;                                     // G
            big[o + 2] = (c & 1) ? 0xFF : 0x00;                                     // B
        }
    snprintf(path,sizeof(path),"%s/%s_%05d.png",dir,prefix,frame);
    ok = PNG_Write(path,big,w,h);
    free(big);
    if (ok) printf("    shot frame %d -> %s (%dx%d)\n",frame,path,w,h);
    else    printf("    shot frame %d FAILED to write %s\n",frame,path);
    return ok;
}

//  Hexdump the Studio 2 RAM window: $0800-$08FF is program/system RAM, $0900-$09FF the display memory
//  the BIOS streams out over DMA.  Compare against the verilator sim's --vram.

//  The 64 CDP1864 colour cells, laid out as they appear on screen: 8 columns
//  across by 8 row-groups down, each cell covering 8 pixels by 4 logical rows.
//  Printed in the 1864's own pin order (bit0 red, bit1 blue, bit2 green) so it can
//  be compared against the RTL's colour_ram without a permutation in the way.
static void HL_DumpColour(int frame)
{
    int g,c;
    printf("--- frame %d: colour RAM (row group x column), 1864 pin order ---\n",frame);
    for (g = 0;g < 8;g++)
    {
        printf("  g%d:",g);
        for (c = 0;c < 8;c++) printf(" %d",CPU_GetColourCell((BYTE8)(g*8+c)));
        printf("\n");
    }
}

static void HL_DumpVram(int frame)
{
    int a,i;
    printf("--- frame %d: $0800-$09FF ---\n",frame);
    for (a = 0x800;a < 0xA00;a += 16)
    {
        printf("%04X:",a);
        for (i = 0;i < 16;i++) printf(" %02X",CPU_ReadMemory((WORD16)(a + i)));
        printf("\n");
    }
}

//  One line per instruction, laid out to line up with verilator/sim_headless.cpp's --trace-cpu.  That
//  one leads with sim time and ends with EF; this one leads with an instruction count and ends with T
//  (the 1802 has no EF register to read back here, and T matters for RET/SAV).  To diff the two, drop
//  the first and last fields from each:
//      diff <(awk '{$1="";$NF="";print}' a.trace) <(awk '{$1="";$NF="";print}' b.trace)

static void HL_TraceLine(unsigned long count)
{
    CPU1802STATE st;
    WORD16 pc = CPU_ReadProgramCounter();
    CPU_ReadState(&st);
    printf("%08lu  PC=%04X  op=%02X  P=%X X=%X D=%02X DF=%d  "
           "R0=%04X R1=%04X R2=%04X R3=%04X R4=%04X R5=%04X R8=%04X RB=%04X  "
           "IE=%d Q=%d T=%02X\n",
           count,pc,CPU_ReadMemory(pc),
           st.P,st.X,st.D,st.DF,
           st.R[0],st.R[1],st.R[2],st.R[3],st.R[4],st.R[5],st.R[8],st.R[0x0B],
           st.IE,st.Q,st.T);
}

//  Black stays '.' and white stays '#', exactly as before, so a monochrome frame
//  prints byte-identically and tools/compare-game.sh keeps working unchanged. The
//  six chromatic colours get their initials and can only appear on a 1864 machine.
static char HL_AsciiFor(unsigned char rgb)
{
    switch (rgb & 7)
    {
        case 0: return '.';                                                         // black
        case 1: return 'B';                                                         // blue
        case 2: return 'G';                                                         // green
        case 3: return 'C';                                                         // cyan
        case 4: return 'R';                                                         // red
        case 5: return 'M';                                                         // magenta
        case 6: return 'Y';                                                         // yellow
        default: return '#';                                                        // white
    }
}

static void HL_Ascii(const unsigned char *pix)
{
    int x,y;
    for (y = 0;y < SCREEN_H;y++)
    {
        putchar(' ');putchar(' ');
        for (x = 0;x < SCREEN_W;x++) putchar(HL_AsciiFor(pix[y * SCREEN_W + x]));
        putchar('\n');
    }
}

//*******************************************************************************************************
//                                        Injected keypad input
//*******************************************************************************************************
//
//  SYSTEM_Command(HWC_SETKEYPAD) picks one of two strings that map a Studio 2 key number (0-9) to a host
//  character, then HWC_READKEYBOARD asks IF_KeyPressed about that character.  We reverse the same tables
//  to decide whether the key is currently held, so these must stay in step with the strings in system.c.
//
//  Player B's table there is one character short ("M678YUIHJ"), so its key 9 can never be reported.

#define KEYPAD_KEYS     (10)
#define MAX_KEYS        (64)

static const char *KEYMAP_A = "X123QWEASD";                                         // Player A: 0=X, 1-9 = 1 2 3 Q W E A S D
static const char *KEYMAP_B = "M678YUIHJ";                                          // Player B: 0=M, 1-8 = 6 7 8 Y U I H J

typedef struct { int frame,hold,player,key; } KEYEVENT;                             // player 0 = A, 1 = B

static KEYEVENT keyEvent[MAX_KEYS];
static int      keyEventCount = 0;
static BYTE8    keyHeld[2][KEYPAD_KEYS];

static void HL_UpdateKeys(int frame)                                                // Recompute what is held for this frame.
{
    int i;
    memset(keyHeld,0,sizeof(keyHeld));
    for (i = 0;i < keyEventCount;i++)
        if (frame >= keyEvent[i].frame && frame < keyEvent[i].frame + keyEvent[i].hold)
            keyHeld[keyEvent[i].player][keyEvent[i].key] = 1;
}

//  Parse "a5@60:8", "b3@120" or "5@60" -- key, frame, and an optional hold in frames.

static BOOL HL_AddPress(char *spec)
{
    char *at,*colon,*k = spec;
    int player = 0,key,frame,hold = 4;

    at = strchr(spec,'@');
    if (at == NULL) { printf("error: --press needs KEY@FRAME (got \"%s\")\n",spec); return FALSE; }
    *at = '\0';
    colon = strchr(at+1,':');
    if (colon != NULL) { *colon = '\0'; hold = atoi(colon+1); }
    frame = atoi(at+1);

    if (*k == 'a' || *k == 'A') { player = 0; k++; }                                // Default to player A when unprefixed.
    else if (*k == 'b' || *k == 'B') { player = 1; k++; }
    if (*k < '0' || *k > '9' || k[1] != '\0')
    {
        printf("error: --press key must be 0-9, optionally prefixed a/b (got \"%s\")\n",spec);
        return FALSE;
    }
    key = *k - '0';
    if (hold < 1) hold = 1;
    if (keyEventCount >= MAX_KEYS) { printf("error: more than %d --press events\n",MAX_KEYS); return FALSE; }
    if (player == 1 && key == 9)
        printf("warning: player B key 9 is unmapped in system.c, it will never register\n");
    keyEvent[keyEventCount].frame = frame;   keyEvent[keyEventCount].hold = hold;
    keyEvent[keyEventCount].player = player; keyEvent[keyEventCount].key = key;
    keyEventCount++;
    return TRUE;
}

//*******************************************************************************************************
//              Hardware interface stubs -- system.c calls these, we are not driving a screen
//*******************************************************************************************************

static int  hlClock = 0;                                                            // Fake clock, see IF_GetTime.

void IF_Initialise(void) {}
void IF_Terminate(void) {}
void IF_Write(int x,int y,char ch,int colour) { (void)x;(void)y;(void)ch;(void)colour; }
BOOL IF_Render(BOOL debugMode) { (void)debugMode; return FALSE; }
BOOL IF_ShiftPressed(void) { return FALSE; }

BOOL IF_KeyPressed(char ch)
{
    const char *p;
    if (ch == '\0' || ch == '_') return FALSE;                                      // Unmapped slot in the system.c tables.
    if ((p = strchr(KEYMAP_A,ch)) != NULL) return keyHeld[0][p - KEYMAP_A];
    if ((p = strchr(KEYMAP_B,ch)) != NULL) return keyHeld[1][p - KEYMAP_B];
    return FALSE;
}
//  Q drives the Studio II's beeper (an NE555 astable gated by Q). Log every edge
//  with the frame it happened on, so the RTL core's Q can be diffed against it.
static BOOL   q_state    = FALSE;
static BOOL   q_trace    = FALSE;
static int    q_frame    = 0;        // set from the main loop
static long   q_edges    = 0;
static double q_on_time  = 0.0;      // frames Q spent high, for a duty-cycle figure
static int    q_last_chg = 0;

void IF_SetSound(BOOL isOn)
{
    if ((isOn != 0) == (q_state != 0)) return;
    if (q_state) q_on_time += (q_frame - q_last_chg);
    q_last_chg = q_frame;
    q_state = (isOn != 0);
    q_edges++;
    if (q_trace) printf("Q %s frame %d\n", q_state ? "1" : "0", q_frame);
}
void IF_DisplayScreen(BOOL isDebugMode,BYTE8 *screenData,BYTE8 scrollOffset)
{
    (void)isDebugMode;(void)screenData;(void)scrollOffset;
}

//  system.c throttles to 60Hz with "while (nextTime > IF_GetTime()) {}".  Returning an ever increasing
//  value makes that loop fall straight through, so we run at whatever speed the host manages.

int IF_GetTime(void)
{
    hlClock += 1000;
    return hlClock;
}

//*******************************************************************************************************
//                                          Argument handling
//*******************************************************************************************************

#define MAX_SHOTS       (256)

static int  shotList[MAX_SHOTS];
static int  shotCount = 0;

static void HL_AddShots(char *spec)                                                 // "10,20,30"
{
    char *p = spec;
    while (*p != '\0' && shotCount < MAX_SHOTS)
    {
        shotList[shotCount++] = atoi(p);
        while (*p != '\0' && *p != ',') p++;
        if (*p == ',') p++;
    }
}

static BOOL HL_IsShotFrame(int frame,int every,int frames,BOOL last)
{
    int i;
    for (i = 0;i < shotCount;i++) if (shotList[i] == frame) return TRUE;
    if (every > 0 && frame % every == 0) return TRUE;
    if (last && frame == frames) return TRUE;
    return FALSE;
}

static void HL_Usage(const char *argv0)
{
    printf(
"Usage: %s [options] <image.st2 | image.bin>\n"
"\n"
"Runs the Studio II headless and captures frames as PNGs.\n"
"\n"
"  --machine NAME    studio2 (default) or mpt02 -- mpt02/studio3 selects the\n"
"                    CDP1864 colour machine: PAL 312-line frame, 192 display\n"
"                    lines (rows shown 6x), colour RAM at $B00, background on\n"
"                    OUT 1, display off on INP 4\n"
"  --colour          dump the 64 CDP1864 colour cells at each shot frame\n"
"  --bios FILE       system ROM at $0000, replacing the embedded Studio II BIOS\n"
"                    (needed for mpt02: studio3_ntsc.bin / victory.rom)\n"
"  --frames N        stop after N frames (default 300)\n"
"  --shot N[,N...]   capture at these frame numbers (repeatable)\n"
"  --shot-every N    capture every N frames\n"
"  --shot-last       capture the final frame\n"
"  --outdir DIR      output directory (default ./out)\n"
"  --prefix NAME     filename prefix (default: the image's base name)\n"
"  --scale N         pixel scale for the PNGs (default 4)\n"
"  --ascii           also print each captured frame as ASCII art\n"
"  --vram            hexdump $0800-$09FF at each captured frame\n"
"  --frame-log       one line per frame: number, display state, scroll, hash\n"
"  --press KEY@F[:H] press KEY at frame F, hold H frames (default 4).\n"
"                    KEY is 0-9, optionally prefixed a/b for the two keypads\n"
"                    (a5@60, b3@120:10, 7@30).  Repeatable, max %d events.\n"
"  --trace-cpu N     log the first N instructions (PC, opcode, registers)\n"
"  --trace-from F    only start the CPU trace once frame F is reached\n"
"  --trace-q         log every Q (beeper) edge with its frame number\n"
"  --quiet           only print captures and the summary\n"
"  --help\n"
"\n"
"Frame numbers are 1-based and counted at the State 2 -> State 1 switch, where\n"
"the 1802 latches R(0) as the display pointer for the new frame.\n"
"\n"
"Caveat for timing work: this emulator approximates a frame as one long run of\n"
"cycles plus a 29 cycle interrupt window, rather than modelling the 1861's\n"
"per scanline DMA.  Instruction *order* is a sound reference; instruction\n"
"*timing* within a frame is not.\n",argv0,MAX_KEYS);
}

//*******************************************************************************************************
//                                             Main Program
//*******************************************************************************************************

int main(int argc,char *argv[])
{
    const char *image = NULL,*outdir = "out";
    char prefix[256] = "frame";
    int frames = 300,every = 0,scale = 4;
    BYTE8 machine = MACHINE_STUDIO2;
    const char *bios = NULL;
    BOOL last = FALSE,ascii = FALSE,frameLog = FALSE,quiet = FALSE,vram = FALSE;
    BOOL colourDump = FALSE;
    int i,frame = 0,captured = 0,traceFrom = 0;
    long traceCpu = 0;
    unsigned long instructions = 0;
    unsigned char pix[SCREEN_W * SCREEN_H];

    for (i = 1;i < argc;i++)
    {
        if      (strcmp(argv[i],"--frames") == 0 && i+1 < argc) frames = atoi(argv[++i]);
        else if (strcmp(argv[i],"--shot") == 0 && i+1 < argc)   HL_AddShots(argv[++i]);
        else if (strcmp(argv[i],"--shot-every") == 0 && i+1 < argc) every = atoi(argv[++i]);
        else if (strcmp(argv[i],"--shot-last") == 0)            last = TRUE;
        else if (strcmp(argv[i],"--outdir") == 0 && i+1 < argc)  outdir = argv[++i];
        else if (strcmp(argv[i],"--prefix") == 0 && i+1 < argc)
        {
            strncpy(prefix,argv[++i],sizeof(prefix)-1); prefix[sizeof(prefix)-1] = '\0';
        }
        else if (strcmp(argv[i],"--scale") == 0 && i+1 < argc)  scale = atoi(argv[++i]);
        else if (strcmp(argv[i],"--ascii") == 0)                ascii = TRUE;
        else if (strcmp(argv[i],"--frame-log") == 0)            frameLog = TRUE;
        else if (strcmp(argv[i],"--vram") == 0)                 vram = TRUE;
        else if (strcmp(argv[i],"--quiet") == 0)                quiet = TRUE;
        else if (strcmp(argv[i],"--trace-q") == 0)              q_trace = TRUE;
        else if (strcmp(argv[i],"--press") == 0 && i+1 < argc)
        {
            if (!HL_AddPress(argv[++i])) return 1;
        }
        else if (strcmp(argv[i],"--colour") == 0)                colourDump = TRUE;
        else if (strcmp(argv[i],"--bios") == 0 && i+1 < argc)   bios = argv[++i];
        else if (strcmp(argv[i],"--machine") == 0 && i+1 < argc)
        {
            const char *m = argv[++i];
            if      (strcmp(m,"studio2") == 0) machine = MACHINE_STUDIO2;
            else if (strcmp(m,"mpt02") == 0 || strcmp(m,"studio3") == 0) machine = MACHINE_MPT02;
            else { printf("error: --machine must be studio2 or mpt02\n"); return 1; }
        }
        else if (strcmp(argv[i],"--trace-cpu") == 0 && i+1 < argc)  traceCpu = atol(argv[++i]);
        else if (strcmp(argv[i],"--trace-from") == 0 && i+1 < argc) traceFrom = atoi(argv[++i]);
        else if (strcmp(argv[i],"--help") == 0 || strcmp(argv[i],"-h") == 0)
        {
            HL_Usage(argv[0]); return 0;
        }
        else if (argv[i][0] == '-')
        {
            printf("error: unknown option %s\n",argv[i]); return 1;
        }
        else image = argv[i];
    }

    if (frames <= 0) { printf("error: --frames must be positive\n"); return 1; }

    IF_Initialise();
    CPU_SetMachine(machine);                                                        // Must precede CPU_Reset: it sets the frame timing.
    CPU_Reset();                                                                    // Also copies the BIOS into the 4k space.
    if (bios != NULL) CPU_LoadBios((char *)bios);                                   // ...which --bios then overrides.
    if (image != NULL)
    {
        const char *base,*dot;
        CPU_LoadBinaryImage((char *)image);
        base = strrchr(image,'/'); base = (base == NULL) ? image : base + 1;
        if (strcmp(prefix,"frame") == 0)                                            // Default the prefix from the image name.
        {
            strncpy(prefix,base,sizeof(prefix)-1); prefix[sizeof(prefix)-1] = '\0';
            dot = strrchr(prefix,'.');
            if (dot != NULL) prefix[dot - prefix] = '\0';
        }
    }

    if (shotCount > 0 || every > 0 || last)                                         // Only make the directory if we will use it.
    {
#ifdef WINDOWS
        mkdir(outdir);
#else
        mkdir(outdir,0755);
#endif
    }

    if (!quiet)
    {
        printf("== Studio II headless ==\n");
        printf("   image  : %s\n",(image == NULL) ? "<none, built-in games>" : image);
        printf("   frames : %d, scale %d, outdir %s\n",frames,scale,outdir);
        printf("\n");
    }

    HL_UpdateKeys(frame);                                                           // Nothing held before frame 1.

    while (frame < frames)
    {
        if (traceCpu > 0 && frame >= traceFrom)                                     // Trace *before* executing, so PC is the
        {                                                                           // address of the instruction about to run.
            HL_TraceLine(instructions);
            if (--traceCpu == 0) printf("[trace-cpu limit reached]\n");
        }
        instructions++;
        if (CPU_Execute() == 1)                                                     // 1 = switched back into the main frame state.
        {
            frame++;
            q_frame = frame;
            HL_UpdateKeys(frame);                                                   // Apply key holds for the frame about to run.
            HL_ReadScreen(pix);
            if (frameLog)
                printf("frame %5d  display %s  scroll $%02X  hash %08lX\n",
                       frame,(CPU_GetScreenMemoryAddress() == NULL) ? "off" : "on ",
                       CPU_GetScreenScrollOffset(),HL_Hash(pix));
            if (HL_IsShotFrame(frame,every,frames,last))
            {
                if (HL_Shot(outdir,prefix,frame,pix,scale)) captured++;
                if (ascii) HL_Ascii(pix);
                if (vram)  HL_DumpVram(frame);
            if (colourDump) HL_DumpColour(frame);
            }
        }
    }

    HL_ReadScreen(pix);
    if (!quiet)
    {
        printf("== Q: %ld edges, %.1f%% duty ==\n", q_edges,
               frame ? 100.0 * q_on_time / frame : 0.0);
        printf("\n== %d frames, %d PNG(s) written, final hash %08lX, display %s ==\n",
               frame,captured,HL_Hash(pix),
               (CPU_GetScreenMemoryAddress() == NULL) ? "off" : "on");
    }
    IF_Terminate();
    return 0;
}
