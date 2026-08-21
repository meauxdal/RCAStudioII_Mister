//*******************************************************************************************************
//*******************************************************************************************************
//
//      Name:       Cpu.H
//      Purpose:    1802 Processor Emulation Header
//      Author:     Paul Robson
//      Date:       24th February 2013
//
//*******************************************************************************************************
//*******************************************************************************************************

#ifndef _CPU_H
#define _CPU_H

#include "general.h"

//  Which machine is being emulated. The Studio II is the CDP1861 original; MPT02
//  covers the CDP1864 colour family (Soundic Victory MPT-02 and its Hanimex,
//  Mustang, Sheen, Academy and Trevi badges, and Studio III). See
//  docs/succession-plan.md §6 for where the numbers come from.
#define MACHINE_STUDIO2 (0)
#define MACHINE_MPT02   (1)

//  Rows are shown 4x on the NTSC Studio II and 6x on the PAL colour machines
//  (32 logical rows x 6 = the 192 display lines both Emma 02 and the CDP1864
//  datasheet give). The logical framebuffer is 64x32 either way.
#define ROW_SCALE_STUDIO2 (4)
#define ROW_SCALE_MPT02   (6)

BYTE8 CPU_Execute();
void CPU_Reset();
BYTE8  CPU_ReadMemory(WORD16 address);
void CPU_WriteMemory(WORD16 address,BYTE8 data);
BYTE8 *CPU_GetScreenMemoryAddress();
WORD16 CPU_ReadProgramCounter();
BYTE8 CPU_GetScreenScrollOffset();
void CPU_LoadBinaryImage(char *fileName);
void CPU_LoadBios(char *fileName);          // system ROM at $0000, overrides the embedded BIOS
BYTE8 CPU_GetCartVideoFlag();

void  CPU_SetMachine(BYTE8 machine);        // call before CPU_Reset()
BYTE8 CPU_GetMachine();
BYTE8 CPU_GetRowScale();                    // scanlines per logical row: 4 or 6

//  CDP1864 colour. The colour RAM is 64 cells; the cell for a display byte at
//  page offset `off` is {off[7:5], off[2:0]} -- 8 columns by 8 groups of 4 rows.
//  Colours are 3-bit {R,G,B}; the background is one of 4 and steps on OUT 1.
BYTE8 CPU_GetColour(BYTE8 pageOffset);      // 0-7, dot colour for that byte
BYTE8 CPU_GetBackgroundColour();            // 0-7, current background
BYTE8 CPU_GetColourEnabled();               // colour RAM written since reset (CON)
BYTE8 CPU_GetColourCell(BYTE8 cell);        // raw colour RAM cell 0..63, in 1864 pin order

#ifdef CPUSTATECODE

typedef struct _CPU1802_STATE
{
    int D,DF,X,P,T,IE,Q,R[16];
    int Cycles,State;
} CPU1802STATE;

CPU1802STATE *CPU_ReadState(CPU1802STATE *s);

#endif

#endif // _CPU_H



