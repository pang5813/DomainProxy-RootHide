"""Check standalone UI/controller/core packaging, with no injected dylib."""
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
            "usr/bin/domainproxyctl",
            "usr/libexec/domainproxy-core",
            "Library/DomainProxy/global-config.json",
        ]
        for name in required:
            assert name in entries, f"Missing UI or tweak file: {name}"
            assert entries[name].size > 0, f"Empty file: {name}"
        info = plistlib.loads(archive.extractfile(entries[required[1]]).read())
        assert info["CFBundleIdentifier"] == "local.domainproxy.settings"
        assert info["CFBundleDisplayName"] == "域名代理"
        assert info["CFBundleShortVersionString"] == "0.3.1"
        assert not any('MobileSubstrate' in name or name.endswith('.dylib') for name in entries), 'Unexpected injected plugin'
        controller = entries[required[2]]
        assert controller.uid == 0 and controller.mode & 0o4000, f'Root controller must be setuid and root-owned (uid={controller.uid}, mode={oct(controller.mode)})'
        assert entries[required[3]].mode & 0o111, 'Core must be executable'
    control = next(v for k, v in members.items() if k.startswith("control.tar"))
    with tarfile.open(fileobj=io.BytesIO(control)) as archive:
        entries = {m.name.removeprefix("./"): m for m in archive.getmembers()}
        for name in ["postinst", "postrm", "prerm"]:
            assert entries[name].mode & 0o111, f"{name} must be executable"
    print(f"Standalone UI, root controller, core, and uninstall cleanup verified: {filename}")
