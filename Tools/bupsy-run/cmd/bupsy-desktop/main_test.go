package main

import (
	"net"
	"testing"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/store"
)

// Scout arrives on the first launch only. Someone who has made their own bots, or put Scout
// away, does not want it back each time.
func TestSeedOnce(t *testing.T) {
	dir := t.TempDir()
	st, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := seed(st, dir); err != nil {
		t.Fatal(err)
	}
	bots := st.Bots()
	if len(bots) != 1 || bots[0].Name != "Scout" || bots[0].Engine != "claude" || bots[0].Autonomy != "ask" {
		t.Fatalf("starter bots %+v", bots)
	}
	if err := seed(st, dir); err != nil {
		t.Fatal(err)
	}
	if len(st.Bots()) != 1 {
		t.Error("a second launch made another starter bot")
	}

	// A bot made with --new-bot before the first launch does not stop Scout arriving.
	dir = t.TempDir()
	st, _ = store.Open(dir)
	if _, err := st.AddBot(store.Bot{Name: "Inbox", Engine: "codex"}); err != nil {
		t.Fatal(err)
	}
	if err := seed(st, dir); err != nil {
		t.Fatal(err)
	}
	if bots := st.Bots(); len(bots) != 2 || bots[1].Name != "Scout" {
		t.Errorf("bots after first launch %+v", bots)
	}
}

// Loopback only, and a taken port is not a reason to fail.
func TestListenStaysOnLoopback(t *testing.T) {
	taken, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer taken.Close()
	port := taken.Addr().(*net.TCPAddr).Port
	listener, err := listen(port)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	addr := listener.Addr().(*net.TCPAddr)
	if !addr.IP.IsLoopback() || addr.Port == port {
		t.Errorf("listening on %v", addr)
	}
}
