#!/usr/bin/env python3
"""Select an installed available iPhone from the newest installed iOS runtime."""
import json, subprocess, sys
inventory=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','--json']))
choices=[]
for runtime, devices in inventory['devices'].items():
    if '.iOS-' not in runtime: continue
    version=tuple(int(part) for part in runtime.rsplit('iOS-',1)[1].split('-'))
    if version < (17,): continue
    for device in devices:
        if device.get('isAvailable') and device['name'].startswith('iPhone'):
            choices.append((version,device['name'],device['udid']))
if not choices: sys.exit('No available iPhone simulator with iOS 17+ was found')
print(sorted(choices,reverse=True)[0][2])
