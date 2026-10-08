package desktop

import (
	"errors"
	"os/exec"
	"runtime"
	"strings"
)

// OpenBrowser opens a URL in the person's default browser, using what each platform provides for
// exactly this: xdg-open on Linux and the BSDs, the URL protocol handler on Windows, open on a Mac.
//
// Only ever this server's own loopback address. The URL is passed as one argument and never
// through a shell, so nothing in it is interpreted along the way.
func OpenBrowser(url string) error {
	if !strings.HasPrefix(url, "http://127.0.0.1:") {
		return errors.New("bupsy only opens its own address")
	}
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		// rundll32 hands the URL to whatever the person chose as their browser, with no console
		// window, and without `start`, which would need cmd.exe to parse the URL.
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	// Reaped in the background: xdg-open can take a moment to hand over, and nothing here should
	// wait for a browser.
	go cmd.Wait()
	return nil
}
