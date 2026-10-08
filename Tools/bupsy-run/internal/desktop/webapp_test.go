package desktop

import (
	"errors"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite webapp.html from the Mac app's RemoteWebApp.swift")

// The desktop app serves the same page as the Mac, byte for byte. The Mac's copy is the original
// (it ships with the API it calls); this one is a copy so it can be embedded without Swift. A copy
// drifts, so this test reads the page out of the Swift source and fails if the two differ.
//
// To take the Mac's latest page:
//
//	go test ./internal/desktop -run TestWebAppMatchesTheMac -update
func TestWebAppMatchesTheMac(t *testing.T) {
	source := filepath.Join(repoRoot(t), "Apps", "BupsyMac", "Sources", "RemoteWebApp.swift")
	data, err := os.ReadFile(source)
	if err != nil {
		t.Fatalf("read the Mac's page: %v", err)
	}
	// Line endings are not content: a Windows checkout with autocrlf gives both files CRLF.
	mac, err := swiftRawString(strings.ReplaceAll(string(data), "\r\n", "\n"), "static let html = ")
	if err != nil {
		t.Fatalf("%s: %v", source, err)
	}
	if *update {
		if err := os.WriteFile("webapp.html", []byte(mac), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	embedded := strings.ReplaceAll(webApp, "\r\n", "\n")
	if embedded != mac {
		line := 1
		for i := 0; i < len(embedded) && i < len(mac) && embedded[i] == mac[i]; i++ {
			if mac[i] == '\n' {
				line++
			}
		}
		t.Fatalf("internal/desktop/webapp.html differs from the page in RemoteWebApp.swift, first at "+
			"line %d. The Mac's page is the original: run `go test ./internal/desktop -run "+
			"TestWebAppMatchesTheMac -update` to take it, and if the desktop needs something different, "+
			"change the page there so both apps get it", line)
	}
}

// The extraction itself, pinned on a small sample, so a quiet bug in it cannot make the drift
// test compare two wrong copies and pass.
func TestSwiftRawString(t *testing.T) {
	source := "enum X {\n    static let html = #\"\"\"\n    <p>\n      \"quoted\" \\n stays\n\n    </p>\n    \"\"\"#\n}\n"
	got, err := swiftRawString(source, "static let html = ")
	if err != nil {
		t.Fatal(err)
	}
	want := "<p>\n  \"quoted\" \\n stays\n\n</p>"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if _, err := swiftRawString("let html = \"\"\"\nx\n\"\"\"", "let html = "); err == nil {
		t.Error("accepted a non-raw string, whose escapes this does not interpret")
	}
}

// swiftRawString reads a Swift multi-line raw string literal (#"""…"""#) that follows marker,
// applying Swift's rules: the content starts on the line after the opening delimiter, ends before
// the line holding the closing one, and loses exactly the closing delimiter's indentation from
// every line. A raw string has no escapes to interpret unless it uses \#, which it refuses.
func swiftRawString(source, marker string) (string, error) {
	start := strings.Index(source, marker+"#\"\"\"\n")
	if start < 0 {
		return "", errors.New("no raw multi-line string after " + marker)
	}
	body := source[start+len(marker)+len("#\"\"\"\n"):]
	end := strings.Index(body, "\"\"\"#")
	if end < 0 {
		return "", errors.New("the string never closes")
	}
	lineStart := strings.LastIndex(body[:end], "\n") + 1
	indent := body[lineStart:end]
	if strings.Trim(indent, " ") != "" {
		return "", errors.New("the closing delimiter is not on a line of its own")
	}
	content := body[:lineStart]
	content = strings.TrimSuffix(content, "\n")
	if strings.Contains(content, `\#`) {
		return "", errors.New(`the string uses \# escapes, which this does not interpret`)
	}
	lines := strings.Split(content, "\n")
	for i, line := range lines {
		switch {
		case strings.HasPrefix(line, indent):
			lines[i] = line[len(indent):]
		case strings.Trim(line, " \t") == "":
			lines[i] = ""
		default:
			return "", errors.New("line " + line + " is indented less than the closing delimiter")
		}
	}
	return strings.Join(lines, "\n"), nil
}

// repoRoot walks up to the repository, as the conformance suite does: the original is read in
// place rather than copied, which is the point.
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "Apps", "BupsyMac")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("Apps/BupsyMac not found above the working directory")
		}
		dir = parent
	}
}
