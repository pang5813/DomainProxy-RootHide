"""Exercise the real core's HTTP API and proxy traffic entirely on loopback."""
import base64
import contextlib
import json
import os
from pathlib import Path
import secrets
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request


def receive(sock, count):
    data = b''
    while len(data) < count:
        part = sock.recv(count - len(data))
        if not part:
            raise EOFError('proxy closed connection')
        data += part
    return data


def header(sock):
    data = bytearray()
    while not data.endswith(b'\r\n\r\n'):
        data += receive(sock, 1)
        if len(data) > 8192:
            raise ValueError('header too long')
    return bytes(data)


class HTTPProxy(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        sock.settimeout(10)
        try:
            request = header(sock)
            assert request.startswith(b'CONNECT echo.invalid:443 ')
            expected = b'Proxy-Authorization: Basic ' + base64.b64encode(b'alice:secret')
            assert expected.lower() in request.lower()
            sock.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            while data := sock.recv(1024):
                sock.sendall(data)
        except (OSError, EOFError):
            pass


class SOCKSProxy(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        sock.settimeout(10)
        try:
            version, count = receive(sock, 2)
            assert version == 5 and 0 in receive(sock, count)
            sock.sendall(b'\x05\x00')  # No authentication required.
            version, command, _, kind = receive(sock, 4)
            assert version == 5 and command == 1 and kind == 3
            host = receive(sock, receive(sock, 1)[0])
            assert host == b'echo.invalid' and receive(sock, 2) == b'\x01\xbb'
            sock.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x01')
            while data := sock.recv(1024):
                sock.sendall(data)
        except (OSError, EOFError):
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with contextlib.ExitStack() as stack:
        proxies = []
        for handler in (HTTPProxy, SOCKSProxy):
            server = stack.enter_context(Server(('127.0.0.1', 0), handler))
            threading.Thread(target=server.serve_forever, daemon=True).start()
            stack.callback(server.shutdown)
            proxies.append(server.server_address[1])
        folder = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='domainproxy-test-')))
        api_port, inbound_port = free_port(), free_port()
        while inbound_port == api_port:
            inbound_port = free_port()
        token = secrets.token_hex(32)
        config = {
            'log': {'level': 'error'},
            'inbounds': [{'type': 'mixed', 'tag': 'test', 'listen': '127.0.0.1', 'listen_port': inbound_port}],
            'outbounds': [{'type': 'domainproxy', 'tag': 'proxy', 'upstream_type': 'http',
                           'server': '127.0.0.1', 'server_port': proxies[0], 'username': 'alice', 'password': 'secret',
                           'api_listen': f'127.0.0.1:{api_port}', 'api_secret': token,
                           'state_path': str(folder / 'upstream.json')}],
            'route': {'final': 'proxy'},
        }
        config_path = folder / 'config.json'
        config_path.write_text(json.dumps(config))
        logfile = stack.enter_context(open(folder / 'core.log', 'wb'))
        process = subprocess.Popen([binary, 'run', '-c', str(config_path)], stdout=logfile, stderr=logfile)
        def cleanup():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        stack.callback(cleanup)
        url = f'http://127.0.0.1:{api_port}/v1/proxy'
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def call(body=None, authorized=True):
            data = json.dumps(body).encode() if body is not None else None
            request = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json'})
            if authorized:
                request.add_header('Authorization', 'Bearer ' + token)
            with opener.open(request, timeout=3) as response:
                return json.load(response)

        deadline = time.monotonic() + 15
        while True:
            try:
                before = call()
                break
            except (OSError, urllib.error.URLError):
                if process.poll() is not None or time.monotonic() > deadline:
                    logfile.flush()
                    raise RuntimeError((folder / 'core.log').read_text(errors='replace'))
                time.sleep(.1)
        assert before['pid'] == process.pid and before['type'] == 'http'
        try:
            call(authorized=False)
            raise AssertionError('unauthenticated request accepted')
        except urllib.error.HTTPError as error:
            assert error.code == 401

        def connection():
            sock = socket.create_connection(('127.0.0.1', inbound_port), timeout=3)
            stack.callback(sock.close)
            sock.sendall(b'CONNECT echo.invalid:443 HTTP/1.1\r\nHost: echo.invalid:443\r\n\r\n')
            assert header(sock).split(b'\r\n')[0].split()[1] == b'200'
            sock.sendall(b'hello')
            assert receive(sock, 5) == b'hello'
            return sock

        old = connection()
        switched = call({'type': 'socks5', 'ip': '127.0.0.1', 'port': proxies[1], 'username': '', 'password': ''})
        assert switched['ok'] and switched['pid'] == process.pid and switched['closed_connections'] == 1
        try:
            assert old.recv(1) == b''
        except ConnectionResetError:
            pass
        retained = connection()
        back = call({'type': 'http', 'ip': '127.0.0.1', 'port': proxies[0],
                     'username': 'alice', 'password': 'secret', 'close_existing': False})
        assert back['pid'] == process.pid and back['closed_connections'] == 0
        retained.sendall(b'kept')
        assert receive(retained, 4) == b'kept'
        connection().close()
        state = call()
        assert state['generation'] == 2 and state['type'] == 'http' and process.poll() is None
        assert 'password' not in state and token not in json.dumps(state)
        print('Real core passed: HTTP(auth) -> SOCKS5(no auth) -> HTTP(auth), API auth, old connection close/keep, unchanged PID')


if __name__ == '__main__':
    main()
