# -----------------------------------------------------------------------------
# File: rtlnet_nexys_video_cpu_only.xdc
# Purpose: constraints that hold only for the CPU-only Nexys Video build (no
#   RTLNET_WITH_NETWORK): the RGMII receive pins are sampled as asynchronous
#   levels by an rtlnet_sync chain in the system registers, so they carry no
#   timing relationship. The network build does not read this file; there the
#   MAC owns those pins and the RGMII timing block constrains them.
# Revision: 10-22-2026
#   * 10-22-2026: initial version.
# -----------------------------------------------------------------------------
set_false_path -from [get_ports {eth_rxck eth_rxctl eth_rxd[*]}]
