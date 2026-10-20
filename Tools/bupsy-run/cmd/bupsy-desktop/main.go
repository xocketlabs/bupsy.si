// Command bupsy-desktop is Bupsy for Windows and Linux: a local Bupsy, with its bots, their
// conversations and the approval gate, used through the same web app the Mac serves to phones.
//
// It is the headless core grown into an app, as docs/03-decisions.md #28 planned: no second GUI
// and no new implementation of the engine, the normaliser or the gate. It serves the page on
// 127.0.0.1 only, opens the person's browser at it, and runs bots on this machine.
//
// The credential rule is the same as everywhere: this process spawns the vendor binary and never
// reads, holds or forwards a vendor credential. Sign-in is the person's own, in their own CLI.
//
//	bupsy-desktop                       start Bupsy and open it in the browser
//	bupsy-desktop --no-browser          start it and print the address to pair with instead
//	bupsy-desktop --new-bot "Inbox" --engine codex --job "Triage my mail folder."
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/desktop"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/engine"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/pairing"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/runner"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/store"
)

// defaultPort is asked for first, so the address — and a bookmark of it — stays the same between
// launches. One above the Mac's 47815, so the two never contend on a machine that has both.
const defaultPort = 47816

// starterJob is Scout's job, the Mac's words for its own Scout.
const starterJob = "You research things and report back plainly. Be concise."

func main() {
	data := flag.String("data", "", "where Bupsy keeps its bots and conversations (default: your config folder/bupsy)")
	port := flag.Int("port", defaultPort, "port on 127.0.0.1 to serve on; if taken, any free one is used")
	noBrowser := flag.Bool("no-browser", false, "don't open a browser; print the pairing address instead")
	claudeBinary := flag.String("claude-binary", "", "path to the claude binary, if it is not on PATH")
	codexBinary := flag.String("codex-binary", "", "path to the codex binary, if it is not on PATH")

	newBot := flag.String("new-bot", "", "make a bot with this name, then exit")
	engineID := flag.String("engine", "claude", "with --new-bot: claude, codex or local")
	job := flag.String("job", "", "with --new-bot: what the bot is for, put before every message it gets")
	role := flag.String("role", "", "with --new-bot: a short tag shown beside its name")
	section := flag.String("section", "", "with --new-bot: the sidebar section to file it under")
	autonomy := flag.String("autonomy", engine.AutonomyAsk,
		"with --new-bot: trust level: "+strings.Join(engine.Autonomies, ", "))
	model := flag.String("model", "", "with --new-bot: model to request; empty means the engine's default")
	workdir := flag.String("workdir", "", "with --new-bot: the folder it works in (default: one of its own)")
	flag.Parse()

	dir, err := dataDir(*data)
	if err != nil {
		fail(err)
	}
	st, err := store.Open(dir)
	if err != nil {
		fail(err)
	}

	if *newBot != "" {
		// The shared web app has no screen for making a bot yet, so it is done here. Safe while
		// the app runs: each bot is its own file, and the app picks a new one up on its next look.
		bot, err := st.AddBot(store.Bot{
			Name: *newBot, Engine: *engineID, Job: *job, Role: *role, Section: *section,
			Autonomy: *autonomy, Model: *model, Workdir: *workdir,
		})
		if err != nil {
			fail(err)
		}
		fmt.Printf("Made %s (%s, autonomy %s). It's in Bupsy now.\n", bot.Name, bot.Engine, bot.Autonomy)
		return
	}

	// One Bupsy per data folder. A second launch — the person clicking the icon again — hands
	// over to the one already running, which opens the browser with a fresh pairing code.
	if handedOver(dir, *noBrowser) {
		return
	}

	if err := seed(st, dir); err != nil {
		fail(err)
	}
	devices, err := pairing.Open(filepath.Join(dir, "devices.json"), nil)
	if err != nil {
		fail(err)
	}
	binaries := map[string]string{}
	if *claudeBinary != "" {
		binaries["claude"] = *claudeBinary
	}
	if *codexBinary != "" {
		binaries["codex"] = *codexBinary
	}
	run := runner.New(st, runner.Options{Binaries: binaries})

	machine, _ := os.Hostname()
	if machine == "" {
		machine = "This computer"
	}
	server := &desktop.Server{Store: st, Runner: run, Devices: devices, Machine: machine}
	if !*noBrowser {
		server.OpenBrowser = desktop.OpenBrowser
	}

	listener, err := listen(*port)
	if err != nil {
		fail(err)
	}
	server.SetAddr(listener.Addr().String())
	instance := filepath.Join(dir, "instance.json")
	writeInstance(instance, listener.Addr().(*net.TCPAddr).Port)
	defer os.Remove(instance)

	link := server.PairingURL()
	fmt.Printf("Bupsy is running at %s\n", server.URL())
	if *noBrowser {
		fmt.Printf("Pair a browser by opening (works once, for %d minutes):\n  %s\n", int(pairing.CodeLifetime/time.Minute), link)
	} else if err := desktop.OpenBrowser(link); err != nil {
		fmt.Printf("Couldn't open a browser (%v). Open this (works once, for %d minutes):\n  %s\n",
			err, int(pairing.CodeLifetime/time.Minute), link)
	}
	fmt.Println("Press Ctrl-C to quit.")

	httpServer := &http.Server{Handler: server, ReadHeaderTimeout: 10 * time.Second}
	served := make(chan error, 1)
	go func() { served <- httpServer.Serve(listener) }()

	// Ctrl-C, or the session ending. os.Interrupt is Ctrl-C on Windows too; SIGTERM is what a
	// Linux session manager or systemd sends.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	select {
	case <-ctx.Done():
	case err := <-served:
		if !errors.Is(err, http.ErrServerClosed) {
			fmt.Fprintln(os.Stderr, "bupsy-desktop:", err)
		}
	}
	fmt.Println("Stopping…")
	shutdown, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = httpServer.Shutdown(shutdown)
	// Running bots are stopped, not abandoned: an engine left running after its app quit is
	// spending the person's subscription with nobody reading it.
	run.Close(10 * time.Second)
}

// dataDir is where everything lives: the person's own config folder, never a shared one.
// ~/.config/bupsy on Linux, %AppData%\bupsy on Windows.
func dataDir(flagged string) (string, error) {
	dir := flagged
	if dir == "" {
		base, err := os.UserConfigDir()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(base, "bupsy")
	}
	dir, err := filepath.Abs(dir)
	if err != nil {
		return "", err
	}
	return dir, os.MkdirAll(dir, 0o700)
}

// seed makes the starter bot on the app's first launch, and only then: a person who renames or
// files away their bots does not want Scout coming back. Bots made with --new-bot before that
// first launch do not count against it; they are the person's, and Scout is the app's hello.
func seed(st *store.Store, dir string) error {
	marker := filepath.Join(dir, ".seeded")
	if _, err := os.Stat(marker); err == nil {
		return nil
	}
	taken := false
	for _, bot := range st.Bots() {
		taken = taken || strings.EqualFold(bot.Name, "Scout")
	}
	if !taken {
		if _, err := st.AddBot(store.Bot{Name: "Scout", Engine: "claude", Job: starterJob, Colour: "#d76abf"}); err != nil {
			return err
		}
	}
	return os.WriteFile(marker, nil, 0o600)
}

// listen takes the preferred port on loopback, or any free one if it is taken. Never a wildcard
// address: nothing here is offered beyond this machine.
func listen(port int) (net.Listener, error) {
	if listener, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port)); err == nil {
		return listener, nil
	}
	return net.Listen("tcp", "127.0.0.1:0")
}

// instanceFile is what a running Bupsy leaves for a second launch to find it by: a port and a
// pid, nothing secret.
type instanceFile struct {
	Port int `json:"port"`
	PID  int `json:"pid"`
}

func writeInstance(path string, port int) {
	data, _ := json.Marshal(instanceFile{Port: port, PID: os.Getpid()})
	if err := store.WriteFileAtomic(path, data); err != nil {
		fmt.Fprintln(os.Stderr, "bupsy-desktop: couldn't record this instance:", err)
	}
}

// handedOver reports whether a Bupsy is already running on this data folder, after asking it to
// open the browser. A file left by one that crashed points at a port nobody answers on, and is
// ignored.
func handedOver(dir string, noBrowser bool) bool {
	raw, err := os.ReadFile(filepath.Join(dir, "instance.json"))
	if err != nil {
		return false
	}
	var instance instanceFile
	if json.Unmarshal(raw, &instance) != nil || instance.Port <= 0 {
		return false
	}
	base := "http://127.0.0.1:" + strconv.Itoa(instance.Port)
	client := &http.Client{Timeout: 3 * time.Second}
	if noBrowser {
		resp, err := client.Get(base + "/manifest.webmanifest")
		if err != nil {
			return false
		}
		resp.Body.Close()
		fmt.Printf("Bupsy is already running at %s/\n", base)
		return true
	}
	resp, err := client.Post(base+"/control/open", "application/json", bytes.NewReader(nil))
	if err != nil {
		return false
	}
	resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusNoContent, http.StatusTooManyRequests:
		fmt.Printf("Bupsy is already running at %s/ — opened it in your browser.\n", base)
	default:
		// Running, but started with --no-browser, so it will not open one.
		fmt.Printf("Bupsy is already running at %s/\n", base)
	}
	return true
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "bupsy-desktop:", err)
	os.Exit(1)
}
