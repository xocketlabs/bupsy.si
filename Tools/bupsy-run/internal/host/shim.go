package host

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// unshim turns a Windows batch-file shim into the program it wraps, so a prompt is never parsed
// by cmd.exe.
//
// `claude` and `codex` installed with npm on Windows are `.cmd` files. Windows can only run a
// batch file through cmd.exe, and cmd.exe re-reads every argument with its own rules: `&`, `|`,
// `%VAR%` and `"` in a prompt — text a person or another bot wrote — would be run as commands.
// Go's os/exec quotes arguments for ordinary programs, not for cmd.exe, so it cannot make that
// safe (this is the "BatBadBut" class of bug).
//
// npm's shims all end the same way: run node on a script beside the shim, passing every argument
// through. Recognising that line lets us run node directly with the script, which is exactly what
// the shim would have done, minus cmd.exe. A batch file we do not recognise is still run, but
// only when no argument holds a character cmd.exe treats specially; otherwise it is refused,
// because guessing wrong here runs a stranger's text as a command.
func unshim(path string, args []string) (string, []string, error) {
	ext := strings.ToLower(filepath.Ext(path))
	if ext != ".cmd" && ext != ".bat" {
		return path, args, nil
	}
	if data, err := os.ReadFile(path); err == nil {
		if script, ok := npmShimTarget(string(data)); ok {
			dir := filepath.Dir(path)
			script = filepath.Join(dir, filepath.FromSlash(strings.ReplaceAll(script, `\`, "/")))
			// The shim prefers a node.exe beside itself, then whatever node is on PATH.
			node := filepath.Join(dir, "node.exe")
			if _, err := os.Stat(node); err != nil {
				if found, err := exec.LookPath("node"); err == nil {
					node = found
				} else {
					return "", nil, fmt.Errorf("%s runs on node, and node was not found", filepath.Base(path))
				}
			}
			return node, append([]string{script}, args...), nil
		}
	}
	for _, arg := range args {
		if strings.ContainsAny(arg, "\"%!^&|<>()\r\n") {
			return "", nil, fmt.Errorf("%s is a batch file bupsy does not recognise, and Windows "+
				"would read parts of this message as commands. Point bupsy at the engine's .exe "+
				"instead", filepath.Base(path))
		}
	}
	return path, args, nil
}

// npmShim matches the line npm's cmd-shim writes, in its current and older forms:
//
//	"%_prog%"  "%dp0%\node_modules\@anthropic-ai\claude-code\cli.js" %*
//	"%~dp0\node.exe"  "%~dp0\..\some\cli.js" %*
var npmShim = regexp.MustCompile(`"%~?dp0%?\\([^"%]+)"\s+%\*`)

func npmShimTarget(text string) (string, bool) {
	var target string
	for _, match := range npmShim.FindAllStringSubmatch(text, -1) {
		// The node.exe line matches too; the script is the one that is not node itself.
		if strings.EqualFold(match[1], "node.exe") {
			continue
		}
		target = match[1]
	}
	return target, target != ""
}
