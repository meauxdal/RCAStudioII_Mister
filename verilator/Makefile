#
#
#

V = verilator
#V = /usr/local/bin/verilator
#V = /usr/local/src/verilator-3.876/bin/verilator
COSIM = n

TOP = --top-module top
RTL = ../rtl
V_INC = +incdir+$(RTL) 

V_DEFINE = +define+debug=1 +define+SIMULATION=1   -CFLAGS "-I../sim/imgui -I../sim/ -O3" 
#V_DEFINE += --converge-limit 2000 -Wno-WIDTH -Wno-IMPLICIT -Wno-MODDUP -Wno-UNSIGNED -Wno-CASEINCOMPLETE -Wno-CASEX -Wno-SYMRSVDWORD -Wno-COMBDLY -Wno-INITIALDLY -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-SELRANGE -Wno-CMPCONST -Wno-CASEOVERLAP -Wno-PINMISSING -Wno-MULTIDRIVEN
#V_DEFINE += --threads 8  # this slows it way down
V_DEFINE += 

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S), Darwin) #APPLE
	ECHO_MESSAGE = "Mac OS X"
	LIBS += -framework OpenGL -framework Cocoa -framework IOKit -framework CoreVideo `sdl2-config --libs`
	LIBS += -L/usr/local/lib -L/opt/local/lib

	CXXFLAGS += `sdl2-config --cflags` -Iimgui
	# imgui_impl_sdl.cpp includes <SDL.h>, sim_video.cpp includes <SDL2/SDL.h>; add the parent
	# of SDL2/ as well so both spellings resolve (same fix as Apple-IIgs_MiSTer/vsim).
	CXXFLAGS += `sdl2-config --cflags | sed 's|include/SDL2|include/|'`
	CXXFLAGS += -I/usr/local/include -I/opt/local/include
	CFLAGS = $(CXXFLAGS) -Iimgui
endif

ifeq ($(UNAME_S), Linux) #LINUX
	ECHO_MESSAGE = "Linux"
	LIBS += -lGL -ldl `sdl2-config --libs`

	CXXFLAGS += `sdl2-config --cflags` -Iimgui
	CFLAGS = $(CXXFLAGS)
endif

ifeq ($(findstring MINGW,$(UNAME_S)),MINGW)
	ECHO_MESSAGE = "MinGW"
	LIBS += -lgdi32 -lopengl32 -limm32 `pkg-config --static --libs sdl2`

	CXXFLAGS += `pkg-config --cflags sdl2`
	CFLAGS = $(CXXFLAGS)
endif

CFLAGS += $(CC_OPT) $(CC_DEFINE) -Iimgui
LDFLAGS = $(LIBS)
EXE = ./obj_dir/Vtop
V_OPT = -O3 --x-assign fast --x-initial fast --noassert --public-flat-rw \
	-Wno-fatal -Wno-PINMISSING -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE
CC_OPT = -O
#V_OPT = 
#CC_OPT =   

# Keep this list in sync with ../files.qip. Only files that are part of the
# synthesised design belong here -- cdp1861.v, dma.v, rom.v, cosmac.v etc. are
# unused reference code and must NOT be compiled in.
V_SRC = \
	sim.v \
	$(RTL)/rcastudioii.sv \
	$(RTL)/cdp1802.v \
	$(RTL)/dpram.sv \
	$(RTL)/pixie/cdp1861.v \
	$(RTL)/pixie/cdp1864.v \
	$(RTL)/pixie/cdp1863.v \
	$(RTL)/pixie/cdp1862.v \
	$(RTL)/pixie/pixie_video.v

C_SRC = \
	sim_main.cpp \
	sim/sim_bus.cpp sim/sim_clock.cpp sim/sim_console.cpp sim/sim_video.cpp sim/sim_input.cpp \
	sim/imgui/imgui_impl_sdl.cpp sim/imgui/imgui_impl_opengl2.cpp sim/imgui/imgui_draw.cpp \
	sim/imgui/imgui_widgets.cpp sim/imgui/imgui_tables.cpp sim/imgui/imgui.cpp \
	sim/imgui/ImGuiFileDialog.cpp
VOUT = obj_dir/Vtop.cpp

# ---------------------------------------------------------------------------
# Headless simulator: no SDL/ImGui, frame counting, screenshots, state dumps.
# This is the target used for regression testing -- see ./run_tests.sh
# ---------------------------------------------------------------------------
HL_DIR = obj_dir_headless
HL_EXE = ./$(HL_DIR)/Vtop
HL_SRC = sim_headless.cpp
HL_VOPT = -O3 --x-assign fast --x-initial fast --noassert --public-flat-rw \
	-Wno-fatal -Wno-PINMISSING -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE

all: $(EXE)

headless: $(HL_EXE)

$(HL_EXE): $(V_SRC) $(HL_SRC) Makefile
	$V -cc $(HL_VOPT) -exe --Mdir ./$(HL_DIR) $(V_INC) $(TOP) \
		-CFLAGS "-O2 -std=c++17" -LDFLAGS "-lz" $(V_SRC) $(HL_SRC)
	$(MAKE) -C $(HL_DIR) -f Vtop.mk

$(VOUT): $(V_SRC)  Makefile
	$V -cc $(V_OPT) -LDFLAGS "$(LDFLAGS)" -exe --trace --savable --Mdir ./obj_dir $(V_DEFINE) $(V_INC) $(TOP) -CFLAGS "$(CFLAGS)" $(V_SRC) $(C_SRC)

$(EXE): $(VOUT) $(C_SRC)
#	(cd obj_dir; make OPT="-fauto-inc-dec -fdce -fdefer-pop -fdse -ftree-ccp -ftree-ch -ftree-fre -ftree-dce -ftree-dse" -f Vtop.mk)
	(cd obj_dir; make -f Vtop.mk)

fast:
	(cd obj_dir; rm -f *.o ; make OPT="-fcompare-elim -fcprop-registers -fguess-branch-probability -fauto-inc-dec -fif-conversion2 -fif-conversion -fipa-pure-const -fdce -fipa-profile -fipa-reference -fmerge-constants -fsplit-wide-types -fdefer-pop -fdse -ftree-ccp -ftree-ch -ftree-fre -ftree-dce -ftree-dse -ftree-builtin-call-dce -ftree-copyrename -ftree-dominator-opts -ftree-forwprop -ftree-phiprop -ftree-sra -ftree-pta -ftree-ter -funit-at-a-time -ftree-bit-ccp -falign-functions  -falign-jumps -falign-loops  -falign-labels -fcaller-saves -fcrossjumping -fcse-follow-jumps -fcse-skip-blocks -fdelete-null-pointer-checks -fdevirtualize -fexpensive-optimizations -fgcse  -fgcse-lm -finline-small-functions -findirect-inlining -fipa-sra -foptimize-sibling-calls -fpartial-inlining -fpeephole2 -fregmove -freorder-blocks  -freorder-functions -frerun-cse-after-loop -fsched-interblock  -fsched-spec -fschedule-insns -fschedule-insns2 -fstrict-aliasing -fstrict-overflow -ftree-switch-conversion -ftree-pre -ftree-vrp" -f Vtop.mk)

lint:
	$V --lint-only -Wall -Wno-DECLFILENAME -Wno-fatal $(V_INC) $(TOP) $(V_SRC)

clean:
	rm -rf obj_dir $(HL_DIR)

.PHONY: all headless lint fast clean