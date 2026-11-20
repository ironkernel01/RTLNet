# RTLNet MicroBlaze firmware: CLI desktop harness (host gcc) and, through
# build.ps1, the MicroBlaze firmware on the BSP generated from the XSA.
# Run from cpu/microblaze_v_h264/firmware.
#   make            build/menu.exe (host harness)
#   make run        build + interactive mode
#   make demo       build + scripted --demo session (TEST PASS/FAIL)
#   make clean      remove the harness build artifacts
#   make firmware   build/firmware.elf (build.ps1: BSP from the XSA, lwIP, link)
#   make check      CLI tables against cli/cli_commands.txt
# Revision: 11-14-2026 (initial version 10-22-2026; harness sources follow build.ps1; DDR3 arbiter driver and memory test added; moved to cpu/microblaze_v_h264/ (was microblaze/))

CC       ?= gcc
CFLAGS   ?= -std=c11 -Wall -Wextra -Werror -pedantic -O2
CORES    := rtlnet_eth_mac rtlnet_mdio rtlnet_eth_protocol rtlnet_arp rtlnet_icmp rtlnet_dhcp \
            rtlnet_iperf rtlnet_udp_socket rtlnet_udp_echo rtlnet_classifier rtlnet_tcp_offload rtlnet_axi_arbiter \
            rtlnet_csi2_rx rtlnet_vdma_s2mm rtlnet_framebuf rtlnet_h264_enc
INCLUDES := -Isrc -Isrc/lwip -Isrc/video -Icli -Ihost -I../../../cores/rtlnet_common/driver -I../driver -I../../../ip/rtlnet_csi2_rx/driver -I../../../ip/rtlnet_h264_enc/driver \
            $(foreach c,$(CORES),$(if $(wildcard ../../../cores/$(c)/driver),-I../../../cores/$(c)/driver))
DRV_SRCS := $(wildcard ../../../cores/rtlnet_eth_mac/driver/*.c ../../../cores/rtlnet_mdio/driver/*.c \
            ../../../cores/rtlnet_eth_protocol/driver/*.c ../../../cores/rtlnet_arp/driver/*.c \
            ../../../cores/rtlnet_icmp/driver/*.c ../../../cores/rtlnet_dhcp/driver/*.c \
            ../../../cores/rtlnet_iperf/driver/*.c ../../../cores/rtlnet_udp_socket/driver/*.c \
            ../../../cores/rtlnet_udp_echo/driver/*.c ../../../cores/rtlnet_classifier/driver/*.c \
            ../../../cores/rtlnet_tcp_offload/driver/*.c ../../../cores/rtlnet_axi_arbiter/driver/*.c \
            ../../../ip/rtlnet_csi2_rx/driver/*.c ../../../cores/rtlnet_vdma_s2mm/driver/*.c ../../../cores/rtlnet_framebuf/driver/*.c ../../../ip/rtlnet_h264_enc/driver/*.c)
HOST_SRCS := host/main.c host/host_platform.c host/host_h264_model.c host/host_lwip_stub.c src/rtlnet_board.c src/rtlnet_fmt.c \
             src/rtlnet_netmgr.c src/rtlnet_cpupath.c src/rtlnet_offload.c src/rtlnet_ddrtest.c src/rtlnet_fbcrc.c src/video/rtlnet_tsmux.c src/video/rtlnet_picq.c src/video/rtlnet_muxjob.c src/video/rtlnet_venc.c cli/menu.c cli/menu_table.c cli/cli_commands.c $(DRV_SRCS)
TARGET   := build/menu.exe

.PHONY: all clean run demo firmware check

all: $(TARGET)

build:
	mkdir -p build

$(TARGET): $(HOST_SRCS) | build
	$(CC) $(CFLAGS) -DRTLNET_HOST_TEST $(INCLUDES) -o $@ $(HOST_SRCS)

run: $(TARGET)
	./$(TARGET)

demo: $(TARGET)
	./$(TARGET) --demo

check:
	python cli/check_menu.py

firmware: check
	powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1

clean:
	rm -f $(TARGET)
