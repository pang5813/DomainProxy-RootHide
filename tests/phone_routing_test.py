"""USB-only iOS integration test. Run on the phone, never on the desktop.

Reads the saved provider URL without printing it. Leaves the global service stopped.
"""
import ctypes
import ipaddress
import json
from pathlib import Path
import plistlib
import re
import socket
import ssl
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request


def physical_defaults():
    lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    mib = (ctypes.c_int * 6)(4, 17, 0, 2, 1, 0)
    length = ctypes.c_size_t()
    assert lib.sysctl(mib, 6, None, ctypes.byref(length), None, 0) == 0
    buffer = ctypes.create_string_buffer(length.value)
    assert lib.sysctl(mib, 6, buffer, ctypes.byref(length), None, 0) == 0
    raw = buffer.raw[:length.value]
    offset, found = 0, []
    while offset + 92 <= len(raw):
        size = struct.unpack_from('<H', raw, offset)[0]
        if size < 92:
            break
        index = struct.unpack_from('<H', raw, offset + 4)[0]
        flags, mask = struct.unpack_from('<ii', raw, offset + 8)
        cursor, addresses = offset + 92, {}
        for slot in range(8):
            if mask & (1 << slot):
                count, family = raw[cursor:cursor + 2]
                value = raw[cursor:cursor + (count or 4)]
                if family == 2 and count >= 8:
                    addresses[slot] = socket.inet_ntoa(value[4:8])
                elif slot == 2 and not any(value[2:]):
                    addresses[slot] = '0.0.0.0'
                cursor += ((count + 3) & ~3) if count else 4
        if addresses.get(0) == '0.0.0.0' and addresses.get(2, '0.0.0.0') == '0.0.0.0' and flags & 3 == 3 and not flags & 0x1000000:
            name = socket.if_indextoname(index)
            if not name.startswith('utun'):
                found.append((name, addresses.get(1)))
        offset += size
    assert found, 'Physical IPv4 default route missing'
    return found


def ctl(command, body=None):
    data = json.dumps(body).encode() if body is not None else None
    result = subprocess.run(['/usr/bin/domainproxyctl', command], input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=30)
    reply = json.loads(result.stdout)
    assert result.returncode == 0 and reply.get('ok'), reply.get('message', 'controller failed')
    return reply


def response(url):
    # Both normal probes and the provider request originate here, on the phone.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
    try:
        with opener.open(url, timeout=12) as request:
            request.read(256)
            return request.status
    except urllib.error.HTTPError as error:
        return error.code  # An HTTP rejection still proves transport connectivity.


def main():
    assert sys.platform == 'darwin' and Path('/Applications/DomainProxyApp.app').exists(), 'Run this test on the USB iPhone only'
    defaults = plistlib.load(open('/var/mobile/Library/Preferences/local.domainproxy.settings.plist', 'rb'))
    url = defaults.get('ProxyAPIURL', '').strip()
    assert url.startswith(('http://', 'https://')), 'Saved provider URL missing'
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))

    def fetch():
        with opener.open(url, timeout=20) as request:
            body = request.read(16385).decode('utf-8-sig').strip()
        match = re.fullmatch(r'([0-9.]+):([0-9]{1,5})', body)
        assert match, 'Provider did not return IP:port'
        ip, port = str(ipaddress.IPv4Address(match[1])), int(match[2])
        assert 1 <= port <= 65535
        return {'server': ip, 'server_port': port, 'type': defaults.get('ProxyType', 'http'),
                'username': defaults.get('ProxyUsername', ''), 'password': defaults.get('ProxyPassword', ''),
                'api_lan': defaults.get('ProxyAPILAN', True)}

    def assert_no_loop(endpoint):
        log = Path('/var/run/domainproxy/service.log').read_text(errors='replace')[-100000:]
        needle = f'inbound connection to {endpoint["server"]}:{endpoint["server_port"]}'
        assert needle not in log, 'Upstream connection recaptured by TUN'

    print('Before startup:', physical_defaults(), 'direct HTTP', response('http://example.com'), flush=True)
    first = fetch()
    try:
        started = ctl('start-json', first)
        pid = ctl('status')['pid']
        print('Started PID:', pid, 'physical defaults:', physical_defaults(), flush=True)
        print('Running direct HTTP:', response('http://example.com'), flush=True)
        print('Running proxied HTTP:', response('http://ip138.com'), flush=True)
        assert_no_loop(first)
        second = fetch()
        switched = ctl('switch-json', second)
        assert switched['pid'] == pid and ctl('status')['pid'] == pid, 'Switch restarted the service'
        print('Switched with unchanged PID:', pid, 'physical defaults:', physical_defaults(), flush=True)
        print('After switch direct HTTP:', response('http://example.com'), flush=True)
        print('After switch proxied HTTP:', response('http://ip138.com'), flush=True)
        assert_no_loop(first)
        assert_no_loop(second)
    finally:
        ctl('stop')
        print('Stopped; physical defaults:', physical_defaults(), flush=True)
        print('Stopped direct HTTP:', response('http://example.com'), flush=True)
    print('PASS: real iPhone start/switch/stop, direct/proxied traffic, no proxy loop, default route retained', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Do not print provider URL, credentials, or a URL-bearing traceback.
        print('TEST FAILED:', type(error).__name__, flush=True)
        raise SystemExit(1)
