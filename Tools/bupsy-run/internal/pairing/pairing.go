// Package pairing decides which browsers may use Bupsy, and how a new one is let in.
//
// A port of the Mac app's RemoteDevices (Packages/BupsyKit/Sources/BupsyKit/Remote/
// RemoteDevices.swift), with the same rules so the two are equally hard to get into:
//
//   - A browser is let in once, by a short code. The code only ever lives in memory, lasts ten
//     minutes, works once, and dies after five wrong guesses, so it cannot be found by trying.
//   - In exchange it gets a long random key (256 bits) in a cookie, and every later request is
//     checked against that.
//   - Only the key's SHA-256 is written down. The file sits in the person's own config folder,
//     readable by every program they run — their bots included — and a hash is no use for getting
//     in. Comparisons are constant-time, so how long a check takes says nothing about how close a
//     guess was.
//
// Why a desktop app on loopback needs any of this: the bots run as the same user and can reach
// 127.0.0.1 too. Without a key, a bot could call the API and approve its own tool calls, which
// would make the approval gate decorative.
package pairing

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/store"
)

// Device is a browser the person paired.
type Device struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// KeyHash is the SHA-256 of the device's key, in hex. The key itself is never stored.
	KeyHash  string     `json:"keyHash"`
	PairedAt time.Time  `json:"pairedAt"`
	LastSeen *time.Time `json:"lastSeen,omitempty"`
}

// Code is a pairing code waiting to be used.
type Code struct {
	Value   string
	Expires time.Time
}

// Why a pairing failed. The messages are the ones the person reads.
var (
	ErrNoCode       = errors.New("there is no pairing code right now")
	ErrWrongCode    = errors.New("that code didn't work")
	ErrExpired      = errors.New("that code has expired")
	ErrTooManyTries = errors.New("too many wrong tries")
)

const (
	// CodeLifetime is how long a code works.
	CodeLifetime = 10 * time.Minute
	// MaxWrongTries is how many wrong guesses a code survives.
	MaxWrongTries = 5
	// codeAlphabet has no characters that can be misread for each other: no 0/O, 1/I/L.
	codeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
	codeLength   = 6
)

// Registry is the set of paired devices and the code, if any, that admits a new one.
type Registry struct {
	file string
	now  func() time.Time

	mu         sync.Mutex
	devices    []Device
	code       *Code
	wrongTries int
}

// Open loads the registry from file. A missing file is an empty registry.
func Open(file string, now func() time.Time) (*Registry, error) {
	if now == nil {
		now = time.Now
	}
	r := &Registry{file: file, now: now}
	data, err := os.ReadFile(file)
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return nil, err
	default:
		if err := json.Unmarshal(data, &r.devices); err != nil {
			return nil, err
		}
	}
	return r, nil
}

// NewCode makes a fresh code, replacing any earlier one.
func (r *Registry) NewCode() Code {
	r.mu.Lock()
	defer r.mu.Unlock()
	var b strings.Builder
	for i := 0; i < codeLength; i++ {
		// crypto/rand.Int is uniform over the range, so no letter is likelier than another.
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(codeAlphabet))))
		if err != nil {
			panic("bupsy: no randomness available: " + err.Error())
		}
		b.WriteByte(codeAlphabet[n.Int64()])
	}
	r.code = &Code{Value: b.String(), Expires: r.now().Add(CodeLifetime)}
	r.wrongTries = 0
	return *r.code
}

// CancelCode withdraws the code, if there is one.
func (r *Registry) CancelCode() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.code = nil
}

// Pair trades the code for a new device's key. The key is returned once, to hand to the device;
// it is not kept anywhere.
func (r *Registry) Pair(typed, name string) (Device, string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.code == nil {
		return Device{}, "", ErrNoCode
	}
	if !r.now().Before(r.code.Expires) {
		r.code = nil
		return Device{}, "", ErrExpired
	}
	normalised := strings.Map(func(c rune) rune {
		if c == '-' || c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			return -1
		}
		return c
	}, strings.ToUpper(typed))
	if subtle.ConstantTimeCompare([]byte(normalised), []byte(r.code.Value)) != 1 {
		r.wrongTries++
		if r.wrongTries >= MaxWrongTries {
			r.code = nil
			return Device{}, "", ErrTooManyTries
		}
		return Device{}, "", ErrWrongCode
	}
	// Used: it never works again.
	r.code = nil

	key := randomKey()
	name = strings.TrimSpace(name)
	if name == "" {
		name = "Device"
	}
	if runes := []rune(name); len(runes) > 40 {
		name = string(runes[:40])
	}
	now := r.now().UTC().Truncate(time.Second)
	device := Device{ID: store.NewID(), Name: name, KeyHash: Hash(key), PairedAt: now, LastSeen: &now}
	r.devices = append(r.devices, device)
	if err := r.save(); err != nil {
		r.devices = r.devices[:len(r.devices)-1]
		return Device{}, "", err
	}
	return device, key, nil
}

// Device returns the device a key belongs to, marking it seen.
func (r *Registry) Device(key string) (Device, bool) {
	if key == "" {
		return Device{}, false
	}
	hashed := []byte(Hash(key))
	r.mu.Lock()
	defer r.mu.Unlock()
	for i := range r.devices {
		if subtle.ConstantTimeCompare([]byte(r.devices[i].KeyHash), hashed) != 1 {
			continue
		}
		// Saved at most once a minute: a page polling every second would otherwise rewrite the
		// file every second.
		now := r.now().UTC().Truncate(time.Second)
		if seen := r.devices[i].LastSeen; seen == nil || now.Sub(*seen) >= time.Minute {
			r.devices[i].LastSeen = &now
			_ = r.save()
		}
		return r.devices[i], true
	}
	return Device{}, false
}

// Devices lists paired devices.
func (r *Registry) Devices() []Device {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]Device(nil), r.devices...)
}

// Remove unpairs a device. Its next request is refused.
func (r *Registry) Remove(id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	kept := r.devices[:0:0]
	for _, device := range r.devices {
		if device.ID != id {
			kept = append(kept, device)
		}
	}
	r.devices = kept
	return r.save()
}

func (r *Registry) save() error {
	if err := os.MkdirAll(filepath.Dir(r.file), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(r.devices, "", "  ")
	if err != nil {
		return err
	}
	return store.WriteFileAtomic(r.file, data)
}

// Hash is the SHA-256 of a key, in hex: what is stored in place of it.
func Hash(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:])
}

// randomKey is 256 random bits, URL-safe base64 without padding so it sits in a cookie as is.
func randomKey() string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("bupsy: no randomness available: " + err.Error())
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}
