"""Check that iOS uses split routes, not only the previously patched gateways."""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
rules = (root / 'tun_rules.go').read_text()
match = re.search(r'const autoRouteUseSubRanges = (.*)', rules)
assert match and '"ios"' in match[1] and '"darwin"' in match[1], 'iOS must preserve 0/0 via Darwin split routing'
for name in ['tun.go', 'tun_rules.go']:
    text = (root / name).read_text()
    assert not re.search(r'runtime.GOOS == "darwin"\s*[\{\n]', text), f'Unpatched standalone Darwin branch: {name}'
monitor = (root / 'monitor_darwin.go').read_text()
assert 'routeInterface.Name == m.MyInterface()' in monitor
assert 'strings.HasPrefix(routeInterface.Name, "utun")' in monitor
print('Verified iOS split-route and physical-interface regression guards')
