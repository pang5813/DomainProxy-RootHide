package tun

import (
	"net/netip"
	"testing"
)

func TestDomainProxySplitRoutesPreservePhysicalDefault(t *testing.T) {
	options := Options{
		AutoRoute: true,
		Inet4Address: []netip.Prefix{netip.MustParsePrefix("172.19.0.1/30")},
		Inet6Address: []netip.Prefix{netip.MustParsePrefix("fdfe:dcba:9876::1/126")},
	}
	routes, err := options.BuildAutoRouteRanges(false)
	if err != nil { t.Fatal(err) }
	for _, route := range routes {
		if route.Bits() == 0 { t.Fatalf("standalone Darwin/iOS must never replace physical default: %s", route) }
	}
	for _, destination := range []string{"1.1.1.1", "218.95.39.66", "223.5.5.5", "2001:4860:4860::8888"} {
		ip := netip.MustParseAddr(destination)
		covered := false
		for _, route := range routes { covered = covered || route.Contains(ip) }
		if !covered { t.Fatalf("tunnel routes do not cover %s", destination) }
	}
}
