const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ctx = vm.createContext({});
vm.runInContext(fs.readFileSync('layout/Library/DomainProxy/proxy.pac', 'utf8'), ctx);
const run = (host, scheme = 'https') => ctx.FindProxyForURL(`${scheme}://${host}/`, host);
assert.equal(run('ip138.com'), 'DIRECT');
ctx.PROXY_IP = '192.0.2.1';
ctx.PROXY_PORT = 8080;
for (const host of ['ip138.com', 'www.ip138.com', 'a.b.ip138.com', 'IP138.COM.']) {
  assert.equal(run(host), 'PROXY 192.0.2.1:8080');
  assert.equal(run(host, 'http'), 'PROXY 192.0.2.1:8080');
}
for (const host of ['evilip138.com', 'ip138.com.evil.com', 'example.com']) {
  assert.equal(run(host), 'DIRECT');
}
assert.equal(run('ip138.com', 'ftp'), 'DIRECT');
ctx.PROXY_IP = '999.1.1.1';
assert.equal(run('ip138.com'), 'PROXY 127.0.0.1:9');
ctx.PROXY_IP = '192.0.2.1';
ctx.PROXY_PORT = 0;
assert.equal(run('ip138.com'), 'PROXY 127.0.0.1:9');
console.log('PAC routing tests passed');
