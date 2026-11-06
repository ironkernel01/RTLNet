# Host unit test of the rtlnet_eth_mac driver (host gcc, mocked register map).
#   make -C cores/rtlnet_eth_mac/driver/test          build and run
#   make -C cores/rtlnet_eth_mac/driver/test mb       compile the driver with mb-gcc (MicroBlaze)
# The binary goes to .sim/ (not committed). Strict C11 with every warning an
# error, the same flags the firmware build uses.
REPO      := ../../../..
BUILD_DIR := $(REPO)/.sim/rtlnet_eth_mac_driver
CC        := gcc
# mb-gcc: from RTLNET_XILINX (install root) when set, else from PATH.
MBGCC     := $(if $(RTLNET_XILINX),$(RTLNET_XILINX)/gnu/microblaze/nt/bin/mb-gcc.exe,mb-gcc)
CFLAGS    := -std=c11 -Wall -Wextra -Werror -O2
INCLUDES  := -I.. -I$(REPO)/cores/rtlnet_common/driver

.PHONY: all run mb clean

all: run

$(BUILD_DIR)/test_rtlnet_eth_mac: test_rtlnet_eth_mac.c ../rtlnet_eth_mac.c ../rtlnet_eth_mac.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -DRTLNET_HOST_TEST $(INCLUDES) -o $@ test_rtlnet_eth_mac.c ../rtlnet_eth_mac.c

run: $(BUILD_DIR)/test_rtlnet_eth_mac
	$(BUILD_DIR)/test_rtlnet_eth_mac

mb:
	mkdir -p $(BUILD_DIR)
	$(MBGCC) -mlittle-endian -mcpu=v11.0 $(CFLAGS) $(INCLUDES) -c ../rtlnet_eth_mac.c -o $(BUILD_DIR)/rtlnet_eth_mac.o

clean:
	rm -rf $(BUILD_DIR)
