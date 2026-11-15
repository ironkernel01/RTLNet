# Purpose: own-receiver board video wrapper RTL dependencies.
# Overview: board-independent cores (including the CSI-2 camera receiver) plus capture/HP glue. Revision: 11-15-2026.
-f cores/rtlnet_common/hdl/rtlnet_common.f
-f cores/rtlnet_vdma_s2mm/hdl/rtlnet_vdma_s2mm.f
-f cores/rtlnet_framebuf/hdl/rtlnet_framebuf.f
-f cores/rtlnet_axi_arbiter/hdl/rtlnet_axi_arbiter.f
-f cores/rtlnet_h264_enc/hdl/rtlnet_h264_enc.f
-f cores/rtlnet_csi2_rx/hdl/rtlnet_csi2_rx.f
boards/zybo_z7_20/hdl/rtlnet_axi_hp_bridge.sv
boards/zybo_z7_20/hdl/rtlnet_zybo_video_own.sv
boards/zybo_z7_20/hdl/rtlnet_zybo_video_own_bd.v
