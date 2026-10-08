// Package store keeps bots and their conversations on disk, as plain JSON files.
//
// The Mac app keeps the same things in SQLite through GRDB, which does not link off Apple
// platforms (docs/03-decisions.md #28), and this module takes no dependencies (#30) — so no SQLite
// driver either. Files turn out to suit the shape of the data anyway:
//
//   - each bot is one small JSON file, bots/<id>/bot.json, rewritten whole when it changes. One
//     file per bot rather than one roster file means a second process (`bupsy-desktop --new-bot`)
//     can add a bot while the app is running without either overwriting the other's copy.
//   - each conversation is an append-only NDJSON log, bots/<id>/log.ndjson. Nothing in it is ever
//     rewritten: a decision on an approval is a new line naming the approval, not an edit to the
//     old one. A crash can at worst leave a torn final line, which Load skips, and every line
//     before it is exactly as written. The engine's canonical events go in the same log, so the
//     record of what a bot did and what was shown about it cannot disagree.
package store

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/engine"
)

// Bot is one bot as stored.
type Bot struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Engine string `json:"engine"`
	// Model is empty for the engine's own default.
	Model    string `json:"model,omitempty"`
	Autonomy string `json:"autonomy"`
	// Job is the bot's standing instructions, put before every message it is sent — the same
	// thing the Mac app calls the persona prompt.
	Job     string `json:"job,omitempty"`
	Role    string `json:"role,omitempty"`
	Section string `json:"section,omitempty"`
	// Workdir is the folder the bot works in.
	Workdir string `json:"workdir,omitempty"`
	// Allowlist is the tools this bot may use without asking, above what its autonomy allows.
	Allowlist []string `json:"allowlist,omitempty"`
	Colour    string   `json:"colour"`
	// Conversation is the engine's own id for the thread, so the next message resumes it rather
	// than starting a stranger.
	Conversation string    `json:"conversation,omitempty"`
	Created      time.Time `json:"created"`
	LastRead     time.Time `json:"lastRead,omitempty"`
}

// Store is a directory of bots.
type Store struct {
	dir string

	mu   sync.Mutex
	bots map[string]Bot
}

// Open opens (creating if need be) the store in dir.
func Open(dir string) (*Store, error) {
	if err := os.MkdirAll(filepath.Join(dir, "bots"), 0o700); err != nil {
		return nil, err
	}
	return &Store{dir: dir, bots: map[string]Bot{}}, nil
}

// Dir is the store's root directory.
func (s *Store) Dir() string { return s.dir }

// Bots lists every bot, oldest first.
//
// The directory is read on every call, so a bot another process added appears without a restart.
// Bots already loaded are not re-read: only this process changes an existing bot.
func (s *Store) Bots() []Bot {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.discover()
	out := make([]Bot, 0, len(s.bots))
	for _, bot := range s.bots {
		out = append(out, bot)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].Created.Equal(out[j].Created) {
			return out[i].Created.Before(out[j].Created)
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// Bot returns one bot by id.
func (s *Store) Bot(id string) (Bot, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if bot, ok := s.bots[id]; ok {
		return bot, true
	}
	s.discover()
	bot, ok := s.bots[id]
	return bot, ok
}

func (s *Store) discover() {
	entries, err := os.ReadDir(filepath.Join(s.dir, "bots"))
	if err != nil {
		return
	}
	for _, entry := range entries {
		id := entry.Name()
		if _, known := s.bots[id]; known || !entry.IsDir() || !ValidID(id) {
			continue
		}
		data, err := os.ReadFile(filepath.Join(s.dir, "bots", id, "bot.json"))
		if err != nil {
			continue // a directory mid-creation; it will be complete next time
		}
		var bot Bot
		if err := json.Unmarshal(data, &bot); err != nil || bot.ID != id {
			continue
		}
		s.bots[id] = bot
	}
}

// Engines a bot may run on.
var Engines = []string{"claude", "codex"}

// AddBot validates and saves a new bot, filling in what was left out.
func (s *Store) AddBot(bot Bot) (Bot, error) {
	bot.Name = strings.TrimSpace(bot.Name)
	if bot.Name == "" {
		return Bot{}, errors.New("a bot needs a name")
	}
	if len([]rune(bot.Name)) > 40 {
		return Bot{}, errors.New("a bot's name can be at most 40 characters")
	}
	if !contains(Engines, bot.Engine) {
		return Bot{}, fmt.Errorf("unknown engine %q (want claude or codex)", bot.Engine)
	}
	if bot.Autonomy == "" {
		// The bottom of the ladder, as on the Mac: a new bot asks before everything until the
		// person decides otherwise.
		bot.Autonomy = engine.AutonomyAsk
	}
	if err := engine.CheckAutonomy(bot.Autonomy); err != nil {
		return Bot{}, err
	}
	if bot.Workdir != "" {
		abs, err := filepath.Abs(bot.Workdir)
		if err != nil {
			return Bot{}, err
		}
		bot.Workdir = abs
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.discover()
	for _, other := range s.bots {
		// Bots address each other by name, so two with one name would make a message ambiguous.
		if strings.EqualFold(other.Name, bot.Name) {
			return Bot{}, fmt.Errorf("there is already a bot called %s", other.Name)
		}
	}
	bot.ID = NewID()
	if bot.Colour == "" {
		bot.Colour = ColourFor(bot.Name)
	}
	if bot.Created.IsZero() {
		// Full precision: it is the sidebar's order, and two bots made in the same second must
		// still come out in the order they were made.
		bot.Created = time.Now().UTC()
	}
	if err := os.MkdirAll(filepath.Join(s.dir, "bots", bot.ID), 0o700); err != nil {
		return Bot{}, err
	}
	if err := s.write(bot); err != nil {
		return Bot{}, err
	}
	s.bots[bot.ID] = bot
	return bot, nil
}

// UpdateBot changes a bot and saves it.
func (s *Store) UpdateBot(id string, change func(*Bot)) (Bot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	bot, ok := s.bots[id]
	if !ok {
		return Bot{}, fmt.Errorf("no bot %s", id)
	}
	change(&bot)
	bot.ID = id
	if err := s.write(bot); err != nil {
		return Bot{}, err
	}
	s.bots[id] = bot
	return bot, nil
}

func (s *Store) write(bot Bot) error {
	data, err := json.MarshalIndent(bot, "", "  ")
	if err != nil {
		return err
	}
	return WriteFileAtomic(filepath.Join(s.dir, "bots", bot.ID, "bot.json"), data)
}

// Append adds one record to a bot's log.
//
// Opened, written and closed per record. A conversation produces a handful of lines a second at
// most, and holding no file open means nothing is lost or locked if the process dies, and Windows
// never refuses a rename or delete because the log happens to be open.
func (s *Store) Append(botID string, record Record) error {
	if !ValidID(botID) {
		return fmt.Errorf("not a bot id: %q", botID)
	}
	line, err := json.Marshal(record)
	if err != nil {
		return err
	}
	line = append(line, '\n')
	s.mu.Lock()
	defer s.mu.Unlock()
	file, err := os.OpenFile(s.logPath(botID), os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	// One write call per line, so a reader never sees half of one followed by half of another.
	if _, err := file.Write(line); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

// Load reads a bot's whole log. A line that does not parse — a torn final write — is skipped
// rather than failing the conversation.
func (s *Store) Load(botID string) ([]Record, error) {
	if !ValidID(botID) {
		return nil, fmt.Errorf("not a bot id: %q", botID)
	}
	file, err := os.Open(s.logPath(botID))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	var records []Record
	scanner := bufio.NewScanner(file)
	// An engine event can carry a large tool result, as in engine.ScanLines.
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		var record Record
		if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
			continue
		}
		records = append(records, record)
	}
	return records, scanner.Err()
}

func (s *Store) logPath(botID string) string {
	return filepath.Join(s.dir, "bots", botID, "log.ndjson")
}

// WriteFileAtomic replaces path with data, readable by this user only.
//
// Written beside and renamed over, so a reader — or a crash — sees the old file or the new one,
// never half of either. os.Rename replaces an existing file on Windows too.
func WriteFileAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Chmod(name, 0o600); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Rename(name, path); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}

// NewID is a random UUID (version 4), the same shape of id the Mac app gives bots and entries.
func NewID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("bupsy: no randomness available: " + err.Error())
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b[:])
	return strings.ToUpper(h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:])
}

// ValidID accepts ids NewID makes, and nothing that could step out of the store's directory.
func ValidID(id string) bool {
	if len(id) == 0 || len(id) > 64 {
		return false
	}
	for _, r := range id {
		if !(r >= '0' && r <= '9' || r >= 'A' && r <= 'F' || r >= 'a' && r <= 'f' || r == '-') {
			return false
		}
	}
	return true
}

// palette is the bot colours, from the Mac app's avatar choices. Pink first: it is Bupsy's own.
var palette = []string{
	"#d76abf", "#e0884f", "#4f9be0", "#3fae7a", "#9a7be0", "#d9a826", "#e0606a", "#3aa8b8",
}

// ColourFor picks a colour from a name, the same way every time, so a bot keeps its colour
// without one being chosen. The djb2 hash, as the Mac app derives a bot's hue.
func ColourFor(name string) string {
	hash := uint32(5381)
	for _, b := range []byte(name) {
		hash = hash*33 + uint32(b)
	}
	return palette[hash%uint32(len(palette))]
}

func contains(list []string, s string) bool {
	for _, item := range list {
		if item == s {
			return true
		}
	}
	return false
}
