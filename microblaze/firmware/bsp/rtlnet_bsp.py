#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# File: rtlnet_bsp.py
# Purpose: generate and build the standalone BSP of the RTLNet MicroBlaze
#   firmware from the hardware export (XSA) with the Vitis 2025.2 Python API.
#   Run by microblaze/firmware/build.ps1 as `vitis -s rtlnet_bsp.py <xsa> <ws>`.
# Overview:
#   * Creates the Vitis workspace <ws> (inside the ignored build folder), a
#     platform component "p" from <xsa> with one standalone domain "d" on
#     microblaze_0, sets stdin/stdout to the console UART (axi_uartlite_0),
#     and builds it. The BSP (headers, libxil.a, libxilstandalone.a,
#     libxiltimer.a, the spec file) is generated from the AMD install; nothing
#     is copied into the repository.
#   * lwIP is not added as a BSP library: the lwip220 library of the install
#     requires a vendor Ethernet MAC instance (emaclite, axiethernet or emacps)
#     in the hardware and refuses a design without one (its validation and its
#     CMakeLists stop with "requires at least one ethernet hardware instance").
#     RTLNet reaches the network through its own wrapper and an AXI DMA, so
#     build.ps1 compiles the lwIP 2.2.0 core of the same install
#     (lwip220_v1_3/src/lwip-2.2.0) in place with the firmware's lwipopts.h.
#   * Names are short on purpose: Windows tools of the BSP build fail on
#     object paths longer than about 250 characters.
#   * Prints one anchored line: RTLNET_BSP: PASS <bsp dir> or RTLNET_BSP: FAIL.
# Usage: vitis -s rtlnet_bsp.py <xsa> <workspace>
# Revision: 10-22-2026
#   * 10-22-2026: initial version.
# -----------------------------------------------------------------------------
import os
import sys

import vitis

PLATFORM = "p"
DOMAIN = "d"
CPU = "microblaze_0"
CONSOLE = "axi_uartlite_0"


def main(argv):
    if len(argv) != 2:
        print("RTLNET_BSP: FAIL usage: vitis -s rtlnet_bsp.py <xsa> <workspace>")
        return 2
    xsa = os.path.abspath(argv[0]).replace("\\", "/")
    ws = os.path.abspath(argv[1]).replace("\\", "/")
    if not os.path.isfile(xsa):
        print(f"RTLNET_BSP: FAIL no XSA at {xsa}")
        return 2
    client = vitis.create_client()
    try:
        client.set_workspace(ws)
        plat = client.create_platform_component(name=PLATFORM, hw_design=xsa, os="standalone", cpu=CPU,
                                                domain_name=DOMAIN)
        dom = plat.get_domain(DOMAIN)
        dom.set_config("os", "standalone_stdin", CONSOLE)
        dom.set_config("os", "standalone_stdout", CONSOLE)
        dom.get_drivers()
        plat.build()
    except Exception as e:  # the Vitis client raises plain Exception
        print(f"RTLNET_BSP: FAIL {e}")
        return 1
    finally:
        vitis.dispose()
    bsp = os.path.join(ws, PLATFORM, CPU, DOMAIN, "bsp").replace("\\", "/")
    for lib in ("libxil.a", "libxilstandalone.a"):
        if not os.path.isfile(os.path.join(bsp, "lib", lib)):
            print(f"RTLNET_BSP: FAIL {lib} not built under {bsp}/lib")
            return 1
    print(f"RTLNET_BSP: PASS {bsp}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
