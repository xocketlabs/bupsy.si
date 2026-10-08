package desktop

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/fakeengine"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/pairing"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/runner"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/store"
)

func TestMain(m *testing.M) {
	fakeengine.RunIfRequested()
	os.Exit(m.Run())
}

type harness struct {
	t      *testing.T
	srv    *httptest.Server
	server *Server
	store  *store.Store
	client *http.Client
	scout  store.Bot
	opened []string
}

// newHarness serves a real Server on loopback, with the fake engine standing in for claude.
func newHarness(t *testing.T) *harness {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(fakeengine.Env, "1")
	dir := t.TempDir()
	st, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	scout, err := st.AddBot(store.Bot{Name: "Scout", Engine: "claude", Job: "Research."})
	if err != nil {
		t.Fatal(err)
	}
	devices, err := pairing.Open(filepath.Join(dir, "devices.json"), nil)
	if err != nil {
		t.Fatal(err)
	}
	run := runner.New(st, runner.Options{
		Binaries: map[string]string{"claude": self}, GateTimeout: 20,
		GateRoot: t.TempDir(), Poll: 20 * time.Millisecond, Logf: t.Logf,
	})
	h := &harness{t: t, store: st, scout: scout}
	h.server = &Server{Store: st, Runner: run, Devices: devices, Machine: "test-box",
		OpenBrowser: func(u string) error { h.opened = append(h.opened, u); return nil }}
	h.srv = httptest.NewServer(h.server)
	h.server.SetAddr(strings.TrimPrefix(h.srv.URL, "http://"))
	t.Cleanup(func() { h.srv.Close(); run.Close(5 * time.Second) })
	jar, _ := cookiejar.New(nil)
	h.client = &http.Client{Jar: jar}
	return h
}

// call makes a request the way the page does and decodes the JSON answer.
func (h *harness) call(method, path string, body any) (int, map[string]any) {
	h.t.Helper()
	var reader io.Reader
	if body != nil {
		data, _ := json.Marshal(body)
		reader = bytes.NewReader(data)
	}
	req, _ := http.NewRequest(method, h.srv.URL+path, reader)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Origin", h.srv.URL)
	}
	resp, err := h.client.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func (h *harness) pair() {
	h.t.Helper()
	link, _ := url.Parse(h.server.PairingURL())
	if status, out := h.call("POST", "/api/pair", map[string]any{"code": link.Query().Get("code"), "name": "Firefox"}); status != 200 {
		h.t.Fatalf("pair: %d %v", status, out)
	}
}

func TestPageAndAssetsArePublic(t *testing.T) {
	h := newHarness(t)
	resp, err := h.client.Get(h.srv.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	page, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(page) != webApp || resp.Header.Get("Content-Type") != "text/html; charset=utf-8" {
		t.Error("the page is not served as embedded")
	}
	if resp.Header.Get("X-Frame-Options") != "DENY" {
		t.Error("the page can be framed by another site")
	}
	for _, path := range []string{"/manifest.webmanifest", "/icon.png"} {
		resp, err := h.client.Get(h.srv.URL + path)
		if err != nil || resp.StatusCode != 200 {
			t.Errorf("%s: %v %v", path, err, resp.StatusCode)
		}
		resp.Body.Close()
	}
}

// Every /api route needs a paired browser's key; pairing hands one out once, in an HttpOnly,
// SameSite=Strict cookie.
func TestPairingGuardsTheAPI(t *testing.T) {
	h := newHarness(t)
	for _, route := range []struct{ method, path string }{
		{"GET", "/api/session"}, {"GET", "/api/bots"},
		{"GET", "/api/bots/" + h.scout.ID + "/messages"},
		{"POST", "/api/bots/" + h.scout.ID + "/messages"},
		{"POST", "/api/bots/" + h.scout.ID + "/approvals/1-2-3"},
		{"POST", "/api/bots/" + h.scout.ID + "/stop"},
	} {
		if status, _ := h.call(route.method, route.path, map[string]any{}); status != 401 {
			t.Errorf("%s %s unpaired: %d, want 401", route.method, route.path, status)
		}
	}

	// A wrong code is refused with the server's own words.
	h.server.PairingURL()
	if status, out := h.call("POST", "/api/pair", map[string]any{"code": "WRONG1"}); status != 401 || out["error"] == "" {
		t.Errorf("wrong code: %d %v", status, out)
	}

	link, _ := url.Parse(h.server.PairingURL())
	code := link.Query().Get("code")
	req, _ := http.NewRequest("POST", h.srv.URL+"/api/pair", strings.NewReader(`{"code":"`+code+`","name":"Firefox"}`))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	set := resp.Header.Get("Set-Cookie")
	for _, want := range []string{Cookie + "=", "HttpOnly", "SameSite=Strict", "Path=/"} {
		if !strings.Contains(set, want) {
			t.Errorf("cookie %q lacks %s", set, want)
		}
	}
	// The same code a second time does nothing.
	if status, _ := h.call("POST", "/api/pair", map[string]any{"code": code}); status != 401 {
		t.Errorf("a used code paired again: %d", status)
	}
	// A forged key does nothing either.
	jar, _ := cookiejar.New(nil)
	u, _ := url.Parse(h.srv.URL)
	jar.SetCookies(u, []*http.Cookie{{Name: Cookie, Value: strings.Repeat("A", 43)}})
	h.client.Jar = jar
	if status, _ := h.call("GET", "/api/session", nil); status != 401 {
		t.Errorf("a made-up key got in: %d", status)
	}
	// The real one does.
	jar.SetCookies(u, (&http.Response{Header: http.Header{"Set-Cookie": {set}}}).Cookies())
	if status, out := h.call("GET", "/api/session", nil); status != 200 || out["mac"] != "test-box" {
		t.Errorf("paired session: %d %v", status, out)
	}
}

// A web page that rebinds its own name to 127.0.0.1 reaches this port with its name in the Host
// header; another origin's POST carries its Origin. Both are refused before anything else.
func TestOnlyItsOwnNameAndOrigin(t *testing.T) {
	h := newHarness(t)
	req, _ := http.NewRequest("GET", h.srv.URL+"/", nil)
	req.Host = "evil.example:80"
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMisdirectedRequest {
		t.Errorf("foreign Host: %d", resp.StatusCode)
	}

	link, _ := url.Parse(h.server.PairingURL())
	req, _ = http.NewRequest("POST", h.srv.URL+"/api/pair", strings.NewReader(`{"code":"`+link.Query().Get("code")+`"}`))
	req.Header.Set("Origin", "http://evil.example")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("foreign Origin: %d", resp.StatusCode)
	}

	// Addressed as localhost is fine: it is the same server.
	_, port, _ := strings.Cut(strings.TrimPrefix(h.srv.URL, "http://"), ":")
	req, _ = http.NewRequest("GET", h.srv.URL+"/", nil)
	req.Host = "localhost:" + port
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Errorf("localhost Host: %d", resp.StatusCode)
	}
}

// The whole loop through the API, as the page drives it: list, send, see the approval card,
// answer it, see the result — once allowed, once denied.
func TestAPIRunsABotThroughTheGate(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the approval hook is a sh script; these run on Linux and macOS")
	}
	h := newHarness(t)
	h.pair()

	status, list := h.call("GET", "/api/bots", nil)
	bots, _ := list["bots"].([]any)
	if status != 200 || len(bots) != 1 {
		t.Fatalf("bots: %d %v", status, list)
	}
	scout := bots[0].(map[string]any)
	for _, key := range []string{"id", "name", "role", "section", "colour", "mood", "running", "needsYou", "unread", "preview"} {
		if _, ok := scout[key]; !ok {
			t.Errorf("bot JSON lacks %q: %v", key, scout)
		}
	}
	if scout["role"] != nil || scout["mood"] != "idle" {
		t.Errorf("fresh bot %v", scout)
	}
	base := "/api/bots/" + h.scout.ID

	if status, out := h.call("POST", base+"/messages", map[string]any{"text": "  "}); status != 400 || out["error"] != "Write something first." {
		t.Errorf("empty message: %d %v", status, out)
	}

	for _, allow := range []bool{true, false} {
		if status, _ := h.call("POST", base+"/messages", map[string]any{"text": "go [tool]"}); status != 200 {
			t.Fatalf("send: %d", status)
		}
		var approval map[string]any
		deadline := time.Now().Add(10 * time.Second)
		for approval == nil && time.Now().Before(deadline) {
			_, list := h.call("GET", "/api/bots", nil)
			if list["waiting"] == 1.0 {
				_, msgs := h.call("GET", base+"/messages", nil)
				for _, e := range msgs["entries"].([]any) {
					entry := e.(map[string]any)
					if a, ok := entry["approval"].(map[string]any); ok && a["decided"] == nil {
						approval = a
					}
				}
			}
			time.Sleep(20 * time.Millisecond)
		}
		if approval == nil {
			t.Fatal("no approval card appeared")
		}
		if approval["tool"] != "Bash" || approval["summary"] != "echo fake" {
			t.Errorf("card %v", approval)
		}
		path := base + "/approvals/" + approval["id"].(string)
		if status, out := h.call("POST", path, map[string]any{"allow": "yes"}); status != 400 || out["error"] != "Allow or deny?" {
			t.Errorf("non-bool answer: %d %v", status, out)
		}
		if status, _ := h.call("POST", path, map[string]any{"allow": allow}); status != 200 {
			t.Fatalf("answer: %d", status)
		}
		if status, out := h.call("POST", path, map[string]any{"allow": allow}); status != 409 {
			t.Errorf("second answer: %d %v", status, out)
		}
		h.server.Runner.Wait(h.scout.ID)
	}

	_, msgs := h.call("GET", base+"/messages", nil)
	var shape []string
	var decided []any
	for _, e := range msgs["entries"].([]any) {
		entry := e.(map[string]any)
		shape = append(shape, entry["kind"].(string))
		if a, ok := entry["approval"].(map[string]any); ok {
			decided = append(decided, a["decided"])
		}
		if _, err := time.Parse(time.RFC3339, entry["at"].(string)); err != nil {
			t.Errorf("at %v", entry["at"])
		}
	}
	if got := strings.Join(shape, ","); got != "you,tool,approval,bot,you,tool,approval,bot" {
		t.Errorf("entries %s", got)
	}
	if len(decided) != 2 || decided[0] != "allowed" || decided[1] != "denied" {
		t.Errorf("decisions %v", decided)
	}
	bot := msgs["bot"].(map[string]any)
	if bot["unread"] != false || bot["needsYou"] != false || bot["running"] != false {
		t.Errorf("bot after reading %v", bot)
	}

	if status, _ := h.call("POST", base+"/stop", map[string]any{}); status != 200 {
		t.Errorf("stop with nothing running: %d", status)
	}
	if status, _ := h.call("POST", base+"/questions/q1", map[string]any{"answer": "A"}); status != 409 {
		t.Errorf("unknown question: %d", status)
	}
	if status, _ := h.call("GET", "/api/bots/NOPE/messages", nil); status != 404 {
		t.Errorf("unknown bot: %d", status)
	}
}

// A second launch asks the running one to open the browser; the code goes to the browser only.
func TestControlOpen(t *testing.T) {
	h := newHarness(t)
	req, _ := http.NewRequest("POST", h.srv.URL+"/control/open", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 204 || len(h.opened) != 1 || !strings.Contains(h.opened[0], "?code=") {
		t.Fatalf("open: %d %q, opened %v", resp.StatusCode, body, h.opened)
	}
	if strings.Contains(string(body), "code") {
		t.Error("the pairing code went back to the caller")
	}
	resp, _ = http.DefaultClient.Do(req)
	resp.Body.Close()
	if resp.StatusCode != 429 || len(h.opened) != 1 {
		t.Errorf("a second open straight after was not limited: %d", resp.StatusCode)
	}
}
