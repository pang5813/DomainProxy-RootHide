"""Use Darwin gateways AND split routes on standalone iOS; never replace 0/0."""
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
old = 'runtime.GOOS == "darwin"'
new = '(runtime.GOOS == "darwin" || runtime.GOOS == "ios")'
for filename, count in [('tun.go', 1), ('tun_rules.go', 5)]:
    path = Path(sys.argv[1]) / filename
    source = path.read_text()
    assert source.count(old) == count, f'Pinned {filename} Darwin branches changed'
    path.chmod(path.stat().st_mode | 0o200)
    path.write_text(source.replace(old, new))

path = Path(sys.argv[1]) / 'monitor_darwin.go'
source = path.read_text()
anchor = '\t\t\tif routeMessage.Flags&unix.RTF_UP == 0 {'
assert source.count(anchor) == 1
source = source.replace('\t"os"', '\t"os"\n\t"strings"')
source = source.replace(anchor, '''\t\t\t// A standalone iOS tunnel must never become its own egress interface.
\t\t\tif routeInterface.Name == m.MyInterface() || strings.HasPrefix(routeInterface.Name, "utun") {
\t\t\t\tcontinue
\t\t\t}
''' + anchor)
path.chmod(path.stat().st_mode | 0o200)
path.write_text(source)
print('Patched iOS gateways, split routes, interface names, and physical egress detection')
