// Edit these two values in Filza, then fully restart the target app.
var PROXY_IP = "";
var PROXY_PORT = 8080;

function FindProxyForURL(url, host) {
    host = host.toLowerCase().replace(/\.$/, "");
    var matches = host === "ip138.com" || /\.ip138\.com$/.test(host);
    if (!/^https?:\/\//i.test(url) || !matches) return "DIRECT";
    // Empty configuration intentionally leaves networking unchanged.
    if (!PROXY_IP) return "DIRECT";
    // IPv4 literal only: reject PAC directive injection and invalid addresses.
    var parts = PROXY_IP.split(".");
    if (parts.length !== 4 || parts.some(function (p) {
        return !/^\d{1,3}$/.test(p) || Number(p) > 255;
    }) || PROXY_PORT % 1 !== 0 || PROXY_PORT < 1 || PROXY_PORT > 65535) {
        return "PROXY 127.0.0.1:9";
    }
    // No DIRECT fallback for matching domains when configured.
    return "PROXY " + PROXY_IP + ":" + PROXY_PORT;
}
