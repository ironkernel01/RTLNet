# Purpose: portable GNU Make build of the same MenuBuilder host harness.
# Overview: supply CC from the tool resolver (or the target host's compiler).
# Revision: 11-14-2026. Windows validation uses build.bat / PowerShell resolver.
ifeq ($(origin CC),default)
$(error Supply CC explicitly, using Resolve-RtlnetHostCc on the configured workstation)
endif
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -pedantic -O2
TARGET ?= ../build/menu.exe
REPO := ../../../..
INC := -I. -I../src -I../src/video -I../src/drivers -I../src/lwip \
 -I$(REPO)/cores/rtlnet_common/driver -I$(REPO)/cores/rtlnet_framebuf/driver \
 -I$(REPO)/cores/rtlnet_vdma_s2mm/driver
SRC := menu.c menu_table.c rtlnet_commands.c ../src/rtlnet_camera.c ../src/rtlnet_dphy.c ../test/rtlnet_cli_host_test.c \
 ../test/rtlnet_host_stubs.c $(wildcard ../src/video/*.c) $(wildcard ../src/drivers/*.c) \
 $(REPO)/cores/rtlnet_framebuf/driver/rtlnet_framebuf.c \
 $(REPO)/cores/rtlnet_vdma_s2mm/driver/rtlnet_vdma_s2mm.c
HDR := menu.h menu_commands.h $(wildcard ../src/*.h ../src/video/*.h ../src/drivers/*.h)
.PHONY: all demo run clean
all: $(TARGET)
$(TARGET): $(SRC) $(HDR)
	mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -DRTLNET_HOST_TEST $(INC) $(SRC) -o $@
demo: $(TARGET)
	$(TARGET)
run: $(TARGET)
	$(TARGET) --run
clean:
	$(RM) $(TARGET)
