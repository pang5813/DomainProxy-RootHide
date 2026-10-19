"""Treat GOOS=ios as Darwin when choosing utun gateways in pinned sing-tun."""
from pathlib import Path
import sys

path = Path(sys.argv[1]) / 'tun.go'
source = path.read_text()
old = 'case "darwin":'
new = 'case "darwin", "ios":'
assert source.count(old) == 2, 'Pinned sing-tun gateway branches changed; inspect before patching'
source = source.replace(old, new)
path.chmod(path.stat().st_mode | 0o200)
path.write_text(source)
assert source.count(new) == 2
print('Patched IPv4 and IPv6 gateways: iOS now uses Darwin utun peer addresses')
