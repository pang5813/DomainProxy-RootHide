"""Add the in-process dynamic outbound to the pinned sing-box source tree."""
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1])
source = Path(__file__).parent / "dynamic"
target = root / "protocol" / "domainproxy"
target.mkdir(parents=True, exist_ok=True)
for path in source.glob("*.go"):
    shutil.copy2(path, target / path.name)
registry = root / "include" / "registry.go"
text = registry.read_text()
anchor = '\t"github.com/sagernet/sing-box/protocol/direct"'
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '\n\t"github.com/sagernet/sing-box/protocol/domainproxy"')
anchor = '\tdirect.RegisterOutbound(registry)'
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '\n\tdynamic.RegisterOutbound(registry)')
registry.write_text(text)
print("Dynamic HTTP/SOCKS5 outbound and authenticated control API installed")
