// Package desktop serves Bupsy to a browser on this computer: the Mac's web app, and the JSON API
// it calls, answered by a local runner rather than by a Mac.
//
// The API is the Mac's (Apps/BupsyMac/Sources/RemoteAccess.swift is the source of truth), route
// for route and field for field, so one page works against either. What differs is where it
// listens and who it trusts:
//
//   - Loopback only. Nothing is offered to the network; there is no Tailscale step, because the
//     browser is on the same machine.
//   - Paired anyway. The bots run as the same user and can reach 127.0.0.1 just as the browser
//     can. Without a key, a bot could call this API and approve its own tool calls. So the browser
//     is paired exactly as a phone pairs with the Mac (package pairing), and every /api route
//     requires its key.
//   - Only by name. A request must name this server in its Host header, which stops a web page
//     from reaching it through DNS rebinding, and a state-changing request from another origin is
//     refused outright.
package desktop

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/pairing"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/runner"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/store"
)

// Cookie is the name of the cookie holding a browser's key — the Mac's name for it.
const Cookie = "bupsy_device"

// Server is the desktop app's HTTP side.
type Server struct {
	Store   *store.Store
	Runner  *runner.Runner
	Devices *pairing.Registry
	// Machine is the name the page shows for where Bupsy runs (the Mac sends its own name).
	Machine string
	// OpenBrowser opens a URL in the person's browser. Nil disables /control/open.
	OpenBrowser func(url string) error

	mu       sync.Mutex
	addr     string
	lastOpen time.Time
}

// SetAddr tells the server the address it is listening on, "127.0.0.1:<port>". Until it is set,
// every request is refused: a server that does not know its own name cannot check the Host header.
func (s *Server) SetAddr(addr string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.addr = addr
}

// URL is the server's root address.
func (s *Server) URL() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return "http://" + s.addr + "/"
}

// PairingURL makes a fresh pairing code and returns the address that pairs a browser with it.
// The page reads ?code= and pairs on its own, then takes the code out of the address bar.
func (s *Server) PairingURL() string {
	code := s.Devices.NewCode()
	return s.URL() + "?code=" + url.QueryEscape(code.Value)
}

func (s *Server) allowedHost(host string) bool {
	s.mu.Lock()
	addr := s.addr
	s.mu.Unlock()
	if addr == "" {
		return false
	}
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	return host == addr || host == "localhost:"+port
}

// ServeHTTP is every request's way in.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	header := w.Header()
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set("Referrer-Policy", "no-referrer")
	header.Set("X-Frame-Options", "DENY")
	header.Set("Content-Security-Policy", "frame-ancestors 'none'")

	if !s.allowedHost(r.Host) {
		// A page on another site, rebound to 127.0.0.1, arrives with its own name here.
		writeError(w, "This address isn't Bupsy's.", http.StatusMisdirectedRequest)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		// Belt and braces beside the SameSite cookie: a state-changing request must come from
		// this page. Browsers send Origin on every cross-origin POST, so its absence means a
		// non-browser client, which the key still has to get past.
		if origin := r.Header.Get("Origin"); origin != "" && origin != "http://"+r.Host {
			writeError(w, "Bupsy only takes requests from its own page.", http.StatusForbidden)
			return
		}
		if r.Header.Get("Sec-Fetch-Site") == "cross-site" {
			writeError(w, "Bupsy only takes requests from its own page.", http.StatusForbidden)
			return
		}
	}

	switch {
	case r.Method == http.MethodGet && (r.URL.Path == "/" || r.URL.Path == "/index.html"):
		header.Set("Content-Type", "text/html; charset=utf-8")
		header.Set("Cache-Control", "no-store")
		io.WriteString(w, webApp)
		return
	case r.Method == http.MethodGet && r.URL.Path == "/manifest.webmanifest":
		s.manifest(w)
		return
	case r.Method == http.MethodGet && r.URL.Path == "/icon.png":
		header.Set("Content-Type", "image/png")
		header.Set("Cache-Control", "max-age=86400")
		w.Write(icon())
		return
	case r.Method == http.MethodPost && r.URL.Path == "/api/pair":
		s.pair(w, r)
		return
	case r.Method == http.MethodPost && r.URL.Path == "/control/open":
		s.open(w)
		return
	}

	if !strings.HasPrefix(r.URL.Path, "/api/") {
		writeError(w, "Not found", http.StatusNotFound)
		return
	}
	cookie, err := r.Cookie(Cookie)
	if err != nil {
		writeError(w, "This browser isn't paired with Bupsy.", http.StatusUnauthorized)
		return
	}
	if _, ok := s.Devices.Device(cookie.Value); !ok {
		writeError(w, "This browser isn't paired with Bupsy.", http.StatusUnauthorized)
		return
	}
	header.Set("Cache-Control", "no-store")
	s.route(w, r)
}

func (s *Server) pair(w http.ResponseWriter, r *http.Request) {
	body := readJSON(w, r)
	code, _ := body["code"].(string)
	name, _ := body["name"].(string)
	_, key, err := s.Devices.Pair(code, name)
	switch {
	case errors.Is(err, pairing.ErrExpired):
		writeError(w, "That code has expired. Open Bupsy again for a new one.", http.StatusUnauthorized)
		return
	case errors.Is(err, pairing.ErrTooManyTries):
		writeError(w, "Too many wrong tries. Open Bupsy again for a new code.", http.StatusTooManyRequests)
		return
	case err != nil:
		writeError(w, "That code didn't work. Check it, or open Bupsy again for a new one.", http.StatusUnauthorized)
		return
	}
	// HttpOnly so the page's own script never handles the key, Strict so no other site can make
	// the browser send it. Not Secure, unlike the Mac's: that one is served over HTTPS by
	// Tailscale, this one over plain HTTP on loopback, where some browsers would drop a Secure
	// cookie. Nothing leaves the machine, so there is no wire to protect it on.
	http.SetCookie(w, &http.Cookie{
		Name: Cookie, Value: key, Path: "/", MaxAge: 365 * 24 * 60 * 60,
		HttpOnly: true, SameSite: http.SameSiteStrictMode,
	})
	writeJSON(w, map[string]any{"ok": true}, http.StatusOK)
}

// open is how a second launch of the app reaches the first: it asks it to open the browser with
// a fresh pairing code. Unauthenticated, because whoever launches the app has no key to offer,
// and harmless for the same reason the code is safe to print: the code goes only to the browser
// this server opens, never back to the caller. Rate-limited, so nothing can use it to fill the
// screen with tabs.
func (s *Server) open(w http.ResponseWriter) {
	if s.OpenBrowser == nil {
		writeError(w, "Not found", http.StatusNotFound)
		return
	}
	s.mu.Lock()
	tooSoon := time.Since(s.lastOpen) < 3*time.Second
	if !tooSoon {
		s.lastOpen = time.Now()
	}
	s.mu.Unlock()
	if tooSoon {
		writeError(w, "Already opening.", http.StatusTooManyRequests)
		return
	}
	if err := s.OpenBrowser(s.PairingURL()); err != nil {
		writeError(w, "Couldn't open a browser: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) manifest(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/manifest+json")
	data, _ := json.Marshal(map[string]any{
		"name": "Bupsy", "short_name": "Bupsy", "start_url": "/", "display": "standalone",
		"background_color": "#202020", "theme_color": "#202020",
		"icons": []any{map[string]any{"src": "/icon.png", "sizes": "512x512", "type": "image/png"}},
	})
	w.Write(data)
}

// readJSON reads a small JSON object body. Anything else reads as an empty object, so a route
// reports the missing field rather than a parse error.
func readJSON(w http.ResponseWriter, r *http.Request) map[string]any {
	var body map[string]any
	_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&body)
	if body == nil {
		body = map[string]any{}
	}
	return body
}

func writeJSON(w http.ResponseWriter, value any, status int) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	encoder := json.NewEncoder(w)
	// Text from bots goes into the page only as text nodes, so escaping <>& here would buy
	// nothing and make the payload differ from the Mac's.
	encoder.SetEscapeHTML(false)
	_ = encoder.Encode(value)
}

func writeError(w http.ResponseWriter, message string, status int) {
	writeJSON(w, map[string]any{"error": message}, status)
}
