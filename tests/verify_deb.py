"""Check that the built package includes both the tweak and its settings UI."""
import io
import plistlib
import sys
import tarfile
from pathlib import Path

for filename in sys.argv[1:]:
    raw = Path(filename).read_bytes()
    assert raw[:8] == b"!<arch>\n", "Not a Debian archive"
    offset = 8
    members = {}
    while offset < len(raw):
        header = raw[offset:offset + 60]
        assert header[58:60] == b"`\n", "Invalid ar header"
        name = header[:16].decode().strip().rstrip("/")
        size = int(header[48:58])
        members[name] = raw[offset + 60:offset + 60 + size]
        offset += 60 + size + size % 2
    data = next(v for k, v in members.items() if k.startswith("data.tar"))
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        entries = {m.name.removeprefix("./"): m for m in archive.getmembers()}
        required = [
            "Applications/DomainProxyApp.app/DomainProxyApp",
            "Applications/DomainProxyApp.app/Info.plist",
            "Applications/DomainProxyApp.app/proxy.pac",
            "Library/MobileSubstrate/DynamicLibraries/DomainProxy.dylib",
            "Library/MobileSubstrate/DynamicLibraries/DomainProxy.plist",
        ]
        for name in required:
            assert name in entries, f"Missing UI or tweak file: {name}"
            assert entries[name].size > 0, f"Empty file: {name}"
        info = plistlib.loads(archive.extractfile(entries[required[1]]).read())
        assert info["CFBundleIdentifier"] == "local.domainproxy.settings"
        assert info["CFBundleDisplayName"] == "域名代理"
        assert info["CFBundleShortVersionString"] == "0.2.0"
        pac = archive.extractfile(entries[required[2]]).read().decode()
        assert 'var PROXY_IP = "";' in pac and 'var PROXY_PORT = 8080;' in pac
        assert 'ip138.com' in pac
    control = next(v for k, v in members.items() if k.startswith("control.tar"))
    with tarfile.open(fileobj=io.BytesIO(control)) as archive:
        entries = {m.name.removeprefix("./"): m for m in archive.getmembers()}
        for name in ["postinst", "postrm"]:
            assert entries[name].mode & 0o111, f"{name} must be executable"
    print(f"UI, proxy rules, tweak and installation scripts verified: {filename}")
