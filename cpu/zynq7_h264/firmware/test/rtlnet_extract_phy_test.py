"""Purpose: expose the exact ARM PHY replacement functions to a host MDIO model.
Overview: writes only the supplied CPU build output directory. Revision: 11-14-2026.
"""
from pathlib import Path
import re, sys
fw=Path(__file__).resolve().parents[1]
out=Path(sys.argv[1]).resolve()
assert out.is_relative_to(fw/'build')
source=(fw/'src/lwip/rtlnet_xemacpsif_physpeed.c').read_text(encoding='utf-8-sig')
functions=[]
for name in ['Reset_Realtek_Phy','get_Realtek_phy_speed']:
    match=re.search(r'static u32_t '+name+r'\(.*?\n\}',source,re.S)
    if not match: raise RuntimeError('missing local SDK adaptation '+name)
    functions.append(match[0])
(out/'rtlnet_phy_functions.inc').write_text('\n'.join(functions)+'\n',encoding='utf-8')
