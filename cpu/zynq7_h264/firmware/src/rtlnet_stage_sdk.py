#!/usr/bin/env python3
"""Purpose: stage a licensed SDK PHY adapter with local E/F changes.
Overview: installation is read-only; fail if expected SDK functions change.
Revision: 11-14-2026. Initial SDK adaptation.
"""
from pathlib import Path
import sys, re, shutil, hashlib, stat
vitis = Path(sys.argv[1])
here = Path(__file__).resolve().parent
source = sorted((vitis/'data/embeddedsw/ThirdParty/sw_services').glob('lwip220_*/src/lwip-*/contrib/ports/xilinx/netif/xemacpsif_physpeed.c'))[-1]
sdk_library = source.parents[6]
local_library = here.parent/'build/sdk/lib/sw_services/lwip220'
def copy_writable(src, dst):
    if Path(dst).exists(): Path(dst).chmod(stat.S_IWRITE | stat.S_IREAD)
    result = shutil.copyfile(src, dst)
    Path(dst).chmod(stat.S_IWRITE | stat.S_IREAD)
    return result
shutil.copytree(sdk_library, local_library, dirs_exist_ok=True, copy_function=copy_writable)
metadata = local_library/'data/lwip220.yaml'
metadata.chmod(stat.S_IWRITE | stat.S_IREAD)
metadata_text = metadata.read_text(encoding='utf-8-sig')
metadata_text, count = re.subn(r'depends:\n.*?\nexamples:',
    'depends:\n    emacps:\n        - reg\n        - interrupts\n\nexamples:',metadata_text,flags=re.S)
if count != 1: raise RuntimeError('SDK library dependency metadata changed')
metadata.write_text(metadata_text,encoding='utf-8')
text = source.read_text(encoding='utf-8')
def replace_function(name, body):
    global text
    pattern = r'static u32_t '+name+r'\(XEmacPs \*xemacpsp, u32_t phy_addr\)\s*\{.*?\n\}'
    text, n = re.subn(pattern, lambda m: body, text, flags=re.S)
    if n != 1: raise RuntimeError('SDK function changed: '+name)
replace_function('Reset_Realtek_Phy', '''static u32_t Reset_Realtek_Phy(XEmacPs *xemacpsp, u32_t phy_addr)
{
    /* RTLNET_ZYNQ_PORT: bounded reset; propagate MDIO failures. */
    u16_t control;
    if (XEmacPs_PhyRead(xemacpsp, phy_addr, 0, &control) != XST_SUCCESS) return XST_FAILURE;
    if (XEmacPs_PhyWrite(xemacpsp, phy_addr, 0, control | 0x8000) != XST_SUCCESS) return XST_FAILURE;
    for (unsigned n = 0; n < 1000; n++) {
        if (XEmacPs_PhyRead(xemacpsp, phy_addr, 0, &control) != XST_SUCCESS) return XST_FAILURE;
        if (!(control & 0x8000)) { usleep(100000); return XST_SUCCESS; }
        usleep(1000);
    }
    return XST_FAILURE;
}''')
replace_function('get_Realtek_phy_speed', '''static u32_t get_Realtek_phy_speed(XEmacPs *xemacpsp, u32_t phy_addr)
{
    /* RTLNET_ZYNQ_PORT: Digilent PCN E/F status registers differ. */
    u16_t hi, lo, status, page;
    u32_t id, speed;
    if (XEmacPs_PhyRead(xemacpsp, phy_addr, 2, &hi) != XST_SUCCESS ||
        XEmacPs_PhyRead(xemacpsp, phy_addr, 3, &lo) != XST_SUCCESS) return XST_FAILURE;
    id = ((u32_t)hi << 16) | lo;
    if (id != RTLNET_PHY_ID_E && id != RTLNET_PHY_ID_F) return XST_FAILURE;
    Configure_Phy_Speed(xemacpsp, phy_addr, PHY_SPEED_AUTONEG, PHY_AUTONEG_ENABLE);
    if (Reset_Realtek_Phy(xemacpsp, phy_addr) != XST_SUCCESS ||
        Wait_Autoneg_Complete(xemacpsp, phy_addr, PHY_AUTONEG_TIMEOUT_DEFAULT) != XST_SUCCESS) return XST_FAILURE;
    if (id == RTLNET_PHY_ID_F) {
        int rc;
        if (XEmacPs_PhyRead(xemacpsp, phy_addr, 31, &page) != XST_SUCCESS) return XST_FAILURE;
        if (XEmacPs_PhyWrite(xemacpsp, phy_addr, 31, 0xa43) != XST_SUCCESS) return XST_FAILURE;
        rc = XEmacPs_PhyRead(xemacpsp, phy_addr, 0x1a, &status);
        if (XEmacPs_PhyWrite(xemacpsp, phy_addr, 31, page) != XST_SUCCESS || rc != XST_SUCCESS) return XST_FAILURE;
    } else if (XEmacPs_PhyRead(xemacpsp, phy_addr, 0x11, &status) != XST_SUCCESS) return XST_FAILURE;
    speed = rtlnet_phy_speed(id, status);
    return speed ? speed : XST_FAILURE;
}''')
text = '/* Purpose: local emacps E/F adaptation. Overview: retains SDK license below.\n * Revision: 11-14-2026. RTLNET_ZYNQ_PORT marks replacements. */\n#include "rtlnet_phy.h"\n'+text
(here/'lwip/rtlnet_xemacpsif_physpeed.c').write_text(text, encoding='utf-8')
(here/'lwip/NOTICE.txt').write_text('Purpose: local SDK source provenance.\nRevision: 11-14-2026.\nOrigin: '+str(source.relative_to(vitis))+'\nSHA256 original: '+hashlib.sha256(source.read_bytes()).hexdigest()+'\nOriginal BSD license retained. Two Realtek functions replaced; installation unchanged.\nThe local SDK lwIP tree retains its original source/license notices.\nLocal data/lwip220.yaml removes its BOM and restricts dependency metadata to emacps.\nPCN: https://files.digilent.com/resources/programmable-logic/documents/RTL8211F_PCN.pdf\n',encoding='utf-8')
print('RTLNET_SDK_STAGE: PASS E/F PHY adapter staged; installation unchanged')
template = vitis/'data/embeddedsw/scripts/linker_files/lscript_a9.ld.in'
linker = template.read_text(encoding='utf-8')
linker = linker.replace('_IRQ_STACK_SIZE : 1024;', '_IRQ_STACK_SIZE : 8192;')
for a,b in {'@STACK_SIZE@':'0x10000','@HEAP_SIZE@':'0x400000',
    '@MEMORY_SECTION@':'MEMORY { app_ddr : ORIGIN = 0x00100000, LENGTH = 0x0ff00000 }',
    '@CODE@':'app_ddr','@DATA@':'app_ddr'}.items(): linker=linker.replace(a,b)
linker='/* Purpose: ARM application below reserved video DDR 0x10000000.\n * Overview: generated from SDK MIT template. Revision: 11-14-2026. */\n'+linker
(here/'rtlnet_linker.ld').write_text(linker,encoding='utf-8')
