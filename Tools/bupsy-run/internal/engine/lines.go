package engine

import (
	"bufio"
	"io"
	"strings"
)

// ScanLines reads r and calls emit for each complete line.
//
// Engine output is line-delimited JSON, so a line split across two reads would be unparseable —
// a failure that only shows up under load, on a long reply. bufio.Scanner handles the
// reassembly; the buffer is raised because a single event carrying a large tool result can be far
// longer than the default 64KB limit, and a scanner that stops mid-stream would look like the
// engine simply went quiet.
func ScanLines(r io.Reader, emit func(string)) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)

	for scanner.Scan() {
		// Trailing carriage returns, so Windows line endings read the same as Unix ones.
		emit(strings.TrimRight(scanner.Text(), "\r"))
	}
	return scanner.Err()
}
