// Package host runs engine binaries and hands back their output line by line.
package host

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// Resolve finds an engine binary by name.
//
// exec.LookPath alone is not enough. A GUI app on macOS inherits launchd's minimal PATH, not the
// user's shell PATH, so a tool the user installed and can run in Terminal is invisible to it.
// Every candidate directory below is one an engine installer actually uses.
func Resolve(name string) (string, error) {
	// A path rather than a name. Windows accepts either slash, so both count there.
	if strings.ContainsRune(name, filepath.Separator) || strings.ContainsRune(name, '/') {
		if info, err := os.Stat(name); err == nil && !info.IsDir() {
			return name, nil
		}
		return "", errors.New("no binary at " + name)
	}

	home, _ := os.UserHomeDir()
	candidates := []string{
		filepath.Join(home, ".local", "bin"), // claude's own installer
		filepath.Join(home, ".bun", "bin"),
		filepath.Join(home, ".npm-global", "bin"),
		"/opt/homebrew/bin", // Apple silicon
		"/usr/local/bin",    // Intel homebrew, and most npm prefixes
		"/usr/bin",
		"/bin", // some shell builtins resolve here only
		"/sbin",
		"/usr/sbin",
	}
	if runtime.GOOS == "windows" {
		// Where npm puts global installs by default, and where the native installers go. A
		// program started from the Start menu does get the user's PATH on Windows, but one
		// installed a moment ago is not on it until the next sign-in.
		for _, env := range []string{"APPDATA", "LOCALAPPDATA"} {
			if base := os.Getenv(env); base != "" {
				candidates = append(candidates, filepath.Join(base, "npm"))
			}
		}
		if base := os.Getenv("LOCALAPPDATA"); base != "" {
			candidates = append(candidates, filepath.Join(base, "Programs", name))
		}
	}
	for _, dir := range candidates {
		for _, candidate := range withExecutableSuffixes(filepath.Join(dir, name)) {
			if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
				return candidate, nil
			}
		}
	}

	if path, err := exec.LookPath(name); err == nil {
		return path, nil
	}

	// Last resort: ask the user's own login shell, which is the only thing that truly knows their
	// PATH. Interactive so profile files are read.
	if runtime.GOOS != "windows" {
		shell := os.Getenv("SHELL")
		if shell == "" {
			shell = "/bin/sh"
		}
		out, err := exec.Command(shell, "-ilc", "command -v "+name).Output()
		if err == nil {
			// `command -v` prints the name alone for a shell builtin, with no path. That is not a
			// binary we can spawn, so require something that looks like one.
			path := strings.TrimSpace(string(out))
			if strings.HasPrefix(path, "/") {
				return path, nil
			}
		}
	}

	return "", errors.New(name + " not found — install it, or set its path in Settings → Engines")
}

// withExecutableSuffixes expands a bare path into the forms Windows actually ships.
//
// `claude` installed through npm on Windows is a `.cmd` shim, not an `.exe`, and it carries no
// execute bit for a Unix-style check to find. A resolver that only looked for the bare name would
// report the engine as missing on a machine where it works fine from a prompt.
//
// An `.exe` wins over a shim beside it: it takes its arguments as given, where a batch file hands
// them to cmd.exe to re-read (see unshim). `.ps1` is not offered, because a PowerShell script is
// not something a process can be started from directly.
func withExecutableSuffixes(path string) []string {
	if runtime.GOOS != "windows" {
		return []string{path}
	}
	return []string{path + ".exe", path + ".cmd", path + ".bat", path}
}
