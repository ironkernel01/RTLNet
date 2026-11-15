"""Purpose: build standalone Cortex-A9/lwIP BSP from the supplied board XSA.
Overview: invoked by resolved Vitis in a workspace below this CPU build folder.
Revision: 11-14-2026. Initial BSP recipe.
"""
import os, json, hashlib
from pathlib import Path
import vitis
cfg = json.loads(Path(os.environ['RTLNET_ZYNQ_BUILD_CONFIG']).read_text(encoding='utf-8-sig'))
client = vitis.create_client()
try:
    client.set_workspace(path=cfg['workspace'])
    client.add_embedded_sw_repo(level='LOCAL', path=str(Path(__file__).resolve().parents[1]/'build/sdk'))
    platform = client.create_platform_component(name='rtlnet_zybo', hw_design=cfg['xsa'],
        os='standalone', cpu='ps7_cortexa9_0', domain_name='rtlnet_arm')
    domain = platform.get_domain('rtlnet_arm')
    domain.set_config('os','standalone_stdin','ps7_uart_1')
    domain.set_config('os','standalone_stdout','ps7_uart_1')
    local_lwip = str(Path(__file__).resolve().parents[1]/'build/sdk/lib/sw_services/lwip220')
    domain.set_lib('lwip220', path=local_lwip)
    domain.set_config('lib','lwip220_api_mode','RAW_API','lwip220')
    domain.set_config('lib','lwip220_dhcp','true','lwip220')
    domain.set_config('lib','lwip220_no_sys_no_timers','false','lwip220')
    result = platform.build()
    if result is False: raise RuntimeError('platform.build failed')
    print('RTLNET_ARM_BSP: PASS standalone Cortex-A9 and raw lwIP DHCP built')
    digest=hashlib.sha256(Path(cfg['xsa']).read_bytes()).hexdigest()
    (Path(cfg['workspace'])/'rtlnet_bsp_pass.txt').write_text(
        'RTLNET_ARM_BSP: PASS\nxsa_sha256 '+digest+'\n',encoding='utf-8')
finally:
    vitis.dispose()
