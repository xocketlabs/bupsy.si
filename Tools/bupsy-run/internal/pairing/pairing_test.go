package pairing

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func open(t *testing.T) (*Registry, *clock, string) {
	t.Helper()
	c := &clock{t: time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)}
	file := filepath.Join(t.TempDir(), "devices.json")
	r, err := Open(file, c.now)
	if err != nil {
		t.Fatal(err)
	}
	return r, c, file
}

func TestCodeShape(t *testing.T) {
	r, _, _ := open(t)
	for i := 0; i < 50; i++ {
		code := r.NewCode().Value
		if len(code) != codeLength || strings.Trim(code, codeAlphabet) != "" {
			t.Fatalf("code %q is not six unambiguous characters", code)
		}
	}
}

func TestCodeWorksOnce(t *testing.T) {
	r, _, _ := open(t)
	code := r.NewCode().Value
	// Typed loosely: lower case, with a dash, as a person might.
	typed := strings.ToLower(code[:3]) + "-" + code[3:]
	device, key, err := r.Pair(typed, "  Firefox on Linux  ")
	if err != nil {
		t.Fatal(err)
	}
	if device.Name != "Firefox on Linux" || len(key) < 43 {
		t.Errorf("device %+v, key %q", device, key)
	}
	if got, ok := r.Device(key); !ok || got.ID != device.ID {
		t.Error("the key it handed out does not let the device in")
	}
	if _, _, err := r.Pair(code, "again"); !errors.Is(err, ErrNoCode) {
		t.Errorf("a used code paired a second device: %v", err)
	}
}

func TestCodeExpires(t *testing.T) {
	r, c, _ := open(t)
	code := r.NewCode().Value
	c.t = c.t.Add(CodeLifetime)
	if _, _, err := r.Pair(code, "late"); !errors.Is(err, ErrExpired) {
		t.Errorf("an expired code: %v", err)
	}
	if _, _, err := r.Pair(code, "later"); !errors.Is(err, ErrNoCode) {
		t.Errorf("an expired code was not withdrawn: %v", err)
	}
}

func TestWrongTriesKillTheCode(t *testing.T) {
	r, _, _ := open(t)
	code := r.NewCode().Value
	wrong := "ZZZZZZ"
	if code == wrong {
		wrong = "YYYYYY"
	}
	for i := 1; i < MaxWrongTries; i++ {
		if _, _, err := r.Pair(wrong, "guess"); !errors.Is(err, ErrWrongCode) {
			t.Fatalf("try %d: %v", i, err)
		}
	}
	if _, _, err := r.Pair(wrong, "guess"); !errors.Is(err, ErrTooManyTries) {
		t.Fatalf("try %d: %v", MaxWrongTries, err)
	}
	// Even the right code is now useless: guessing has to start over against a new one.
	if _, _, err := r.Pair(code, "right, too late"); !errors.Is(err, ErrNoCode) {
		t.Errorf("the right code still worked after too many wrong tries: %v", err)
	}
	// A new code starts its own count.
	fresh := r.NewCode().Value
	if _, _, err := r.Pair(fresh, "ok"); err != nil {
		t.Errorf("a fresh code inherited the old one's wrong tries: %v", err)
	}
}

// The key never touches the disk; only its hash does, and the file is private.
func TestOnlyTheHashIsStored(t *testing.T) {
	r, c, file := open(t)
	_, key, err := r.Pair(r.NewCode().Value, "Chrome")
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), key) {
		t.Fatal("the device key was written to disk")
	}
	if !strings.Contains(string(data), Hash(key)) {
		t.Fatal("the key's hash was not written")
	}
	if filepath.Separator != '\\' {
		if info, _ := os.Stat(file); info.Mode().Perm()&0o077 != 0 {
			t.Errorf("devices file is %v", info.Mode().Perm())
		}
	}

	// A restart keeps the device paired, by its hash alone.
	again, err := Open(file, c.now)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := again.Device(key); !ok {
		t.Error("a paired device was forgotten across a restart")
	}
	if _, ok := again.Device(Hash(key)); ok {
		t.Error("the stored hash works as a key")
	}
	if _, ok := again.Device(""); ok {
		t.Error("an empty key got in")
	}

	device := again.Devices()[0]
	if err := again.Remove(device.ID); err != nil {
		t.Fatal(err)
	}
	if _, ok := again.Device(key); ok {
		t.Error("a removed device still gets in")
	}
}
