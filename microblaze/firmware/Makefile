# RTLNet Nexys Video firmware: CLI desktop harness (host gcc) and MicroBlaze
# firmware (mb-gcc, no vendor BSP). Run from microblaze/firmware.
#   make            build/menu.exe (host harness)
#   make run        build + interactive mode
#   make demo       build + scripted --demo session (TEST PASS/FAIL)
#   make clean      remove build artifacts
#   make firmware   build/firmware.elf
#   make check      CLI tables against cli/cli_commands.txt
# Revision: 10-22-2026 (initial version)

CC       ?= gcc
CFLAGS   ?= -std=c11 -Wall -Wextra -Werror -pedantic -O2
INCLUDES := -Isrc -Icli -Ihost -I../../cores/rtlnet_common/driver -I../driver
TARGET   := build/menu.exe
OBJS     := build/main.o build/host_platform.o build/menu.o build/menu_table.o \
            build/cli_commands.o build/rtlnet_board.o build/rtlnet_fmt.o

MB_CC    ?= mb-gcc
MB_FLAGS := -mcpu=v11.0 -mlittle-endian -mxl-barrel-shift -mxl-pattern-compare \
            -mno-xl-soft-mul -mno-xl-soft-div
MB_CFLAGS := -std=c11 -Wall -Wextra -Werror -pedantic -Os -g -ffreestanding \
             -ffunction-sections -fdata-sections
FW_SRCS  := src/crt0.S src/main.c src/rtlnet_platform.c src/uart_lite.c src/timer.c \
            src/rtlnet_board.c src/rtlnet_fmt.c src/rtlnet_string.c \
            cli/menu.c cli/menu_table.c cli/cli_commands.c
FW_ELF   := build/firmware.elf

HDRS     := cli/menu.h cli/menu_commands.h cli/cli_commands.h src/rtlnet_platform.h \
            src/rtlnet_board.h src/rtlnet_fmt.h src/rtlnet_nexys_video_sysregs.h host/host_platform.h

.PHONY: all clean run demo firmware check

all: $(TARGET)

build:
	mkdir -p build

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS)

build/main.o: host/main.c $(HDRS) | build
	$(CC) $(CFLAGS) -DRTLNET_HOST_TEST $(INCLUDES) -c $< -o $@

build/host_platform.o: host/host_platform.c $(HDRS) | build
	$(CC) $(CFLAGS) -DRTLNET_HOST_TEST $(INCLUDES) -c $< -o $@

build/menu.o: cli/menu.c cli/menu.h | build
	$(CC) $(CFLAGS) -DRTLNET_HOST_TEST $(INCLUDES) -c $< -o $@

build/menu_table.o: cli/menu_table.c cli/menu.h cli/menu_commands.h | build
	$(CC) $(CFLAGS) -DRTLNET_HOST_TEST $(INCLUDES) -c $< -o $@

build/cli_commands.o: cli/cli_commands.c $(HDRS) | build
	$(CC) $(CFLAGS) -DRTLNET_HOST_TEST $(INCLUDES) -c $< -o $@

build/rtlnet_board.o: src/rtlnet_board.c $(HDRS) | build
	$(CC) $(CFLAGS) -DRTLNET_HOST_TEST $(INCLUDES) -c $< -o $@

build/rtlnet_fmt.o: src/rtlnet_fmt.c $(HDRS) | build
	$(CC) $(CFLAGS) -DRTLNET_HOST_TEST $(INCLUDES) -c $< -o $@

run: $(TARGET)
	./$(TARGET)

demo: $(TARGET)
	./$(TARGET) --demo

check:
	python cli/check_menu.py

firmware: check | build
	$(MB_CC) $(MB_FLAGS) $(MB_CFLAGS) $(INCLUDES) -nostdlib -nostartfiles -Tsrc/rtlnet_fw.ld \
	  -Wl,--gc-sections -Wl,-Map=build/firmware.map -o $(FW_ELF) $(FW_SRCS) -lgcc

clean:
	rm -f $(OBJS) $(TARGET) $(FW_ELF) build/firmware.map
