# Nexys Video board top, CPU-only sources in compile order (paths relative to the repository root).
-f cores/rtlnet_common/hdl/rtlnet_common.f
-f microblaze/hdl/rtlnet_cpu_microblaze.f
-f cores/rtlnet_axi_arbiter/hdl/rtlnet_axi_arbiter.f
-f cores/rtlnet_axi_cdc/hdl/rtlnet_axi_cdc.f
-f cores/rtlnet_ddr/hdl/rtlnet_ddr.f
-f cores/rtlnet_csi2_rx/hdl/rtlnet_csi2_rx.f
-f cores/rtlnet_vdma_s2mm/hdl/rtlnet_vdma_s2mm.f
-f cores/rtlnet_framebuf/hdl/rtlnet_framebuf.f
boards/nexys_video/hdl/rtlnet_nexys_video_clk_beacon.sv
boards/nexys_video/hdl/rtlnet_nexys_video_sysregs.sv
boards/nexys_video/hdl/rtlnet_nexys_video_top.sv
