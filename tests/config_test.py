import json
from pathlib import Path

config = json.loads(Path('layout/Library/DomainProxy/global-config.json').read_text())
tun = config['inbounds'][0]
assert tun['type'] == 'tun' and tun['auto_route']
assert any(':' in address for address in tun['address']), 'IPv6 must be routed into tunnel'
rules = config['route']['rules']
domains = ['zijieapi.com', 'fqnovel.com', 'ip138.com']
assert rules[0]['ip_version'] == 6 and rules[0]['action'] == 'reject'
assert any(r.get('action') == 'hijack-dns' for r in rules)
assert any(r.get('domain_suffix') == domains and r.get('outbound') == 'proxy' for r in rules)
assert any(r.get('domain_suffix') == domains and r.get('network') == 'udp' and r.get('action') == 'reject' for r in rules)
assert config['route']['final'] == 'direct'
assert config['outbounds'][1]['type'] == 'http'
assert any(r.get('domain_suffix') == domains and r.get('server') == 'fake' for r in config['dns']['rules'])
print('Global routing, fake DNS, HTTP outbound and IPv6 rejection rules verified')
