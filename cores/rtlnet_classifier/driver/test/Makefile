# -----------------------------------------------------------------------------
# File: Makefile
# Purpose: build and run the rtlnet_classifier driver host unit test, and prove
#   that the driver compiles for the MicroBlaze target.
# Targets:
#   run     (default) build with host gcc and run; fails unless the test prints
#           an anchored "TEST PASS: rtlnet_classifier_host" line
#   neg     run with --inject-failure; fails unless the test reports TEST FAIL
#   target  mb-gcc -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra -Werror -c
#   clean   remove build/
# Usage (POSIX shell, e.g. Git Bash):
#   mingw32-make -C cores/rtlnet_classifier/driver/test [run|neg|target|clean]
#   build_test.ps1 in this folder does the same from PowerShell.
# Revision: 10-22-2026
#   * 10-22-2026: initial version.
# -----------------------------------------------------------------------------
CC      := gcc
MBCC    := C:/Xilinx/2025.2/gnu/microblaze/nt/bin/mb-gcc.exe
BUILD   := build
INC     := -I.. -I../../../rtlnet_common/driver
CFLAGS  := -std=c11 -Wall -Wextra -Werror -pedantic -O2 -DRTLNET_HOST_TEST
MBFLAGS := -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra -Werror -O2
SRCS    := test_rtlnet_classifier_host.c ../rtlnet_classifier.c
HDRS    := ../rtlnet_classifier.h ../../../rtlnet_common/driver/rtlnet_mmio.h
EXE     := $(BUILD)/test_rtlnet_classifier_host.exe

.PHONY: run neg target clean

run: $(EXE)
	$(EXE) > $(BUILD)/run.log; status=$$?; cat $(BUILD)/run.log; \
	grep -Eq '^TEST PASS: rtlnet_classifier_host checks=[0-9]+' $(BUILD)/run.log && [ $$status -eq 0 ] \
	  || { echo "FAIL: no TEST PASS line"; exit 1; }

neg: $(EXE)
	$(EXE) --inject-failure > $(BUILD)/neg.log; cat $(BUILD)/neg.log; \
	grep -Eq '^TEST FAIL: rtlnet_classifier_host' $(BUILD)/neg.log \
	  || { echo "FAIL: negative control did not report TEST FAIL"; exit 1; }

target: | $(BUILD)
	$(MBCC) $(MBFLAGS) $(INC) -c ../rtlnet_classifier.c -o $(BUILD)/rtlnet_classifier.mb.o

$(EXE): $(SRCS) $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) $(INC) $(SRCS) -o $@

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
